#pragma once
#include <algorithm>
#include <cstdint>
#include <functional>
#include <limits>
#include <string>
#include <string_view>
#include <tuple>
#include <unordered_map>
#include <utility>
#include <vector>

// Door-proof server rooms (design D1): in a room whose server has a join lock here,
// only a socket that proves the newest door's secret sees who else is in it, hears
// its broadcasts and reads its rings. Everyone else is listed to nobody and sees only
// itself; directs still reach it, because a member chooses whom to address.
//
// Header-only and free of uWebSockets and libsodium, so the rules are unit tested
// with stubs (test/test_door_room.cpp); the proof itself is checked in crypto.cpp.

namespace door_room {

// After the lock moves, who could see keeps seeing this long: nobody but the mover
// holds the new door yet, and the op that hands it out must still reach the members.
static constexpr int64_t GRACE_MS = 60'000;
static constexpr int64_t PROVED = std::numeric_limits<int64_t>::max();
// A proof is an HMAC-SHA256, URL-safe base64 without padding.
static constexpr size_t PROOF_TEXT_LEN = 43;
// Proofs that open no door yet, kept per address group from sockets that never saw the
// room: every lock move checks each stored proof (a DH apiece), so strangers piling junk
// proofs into a room would make a moderator's kick cost the relay per stranger (N3.5).
static constexpr size_t PENDING_PER_GROUP = 8;
// Below this many such proofs in a room every one is kept: members behind one address
// who prove a door the relay does not hold yet must not lose theirs (LOW 9).
static constexpr size_t PENDING_FREE = 64;

// A sender the room hides (a joiner, a member whose door is stale, anyone holding the
// server id) reaches at most this many provers per broadcast: enough for its door ask
// or join request to find answerers, never a way to make one frame cost every member.
static constexpr size_t HIDDEN_REACH = 3;
// The one topic a hidden sender writes: the ring that parks join requests.
static constexpr std::string_view JOIN_TOPIC = "~join";
// A sealed frame's magic and seal time, which rises with every frame its sender seals:
// what orders the provers, so each frame and each retry picks afresh.
static constexpr size_t REACH_SEED_BYTES = 12;

// Where `peer` falls in the order one frame of a hidden `sender` picks its provers by
// (lowest first). The client computes the same order from the frame it got (Rust
// `door_room::reach_rank`, pinned by test_door_room.cpp). Not a secret: a hidden
// sender may address any device in the room by a direct anyway.
class ReachOrder {
public:
    ReachOrder(std::string_view sender, std::string_view frame) {
        eat("hollow-reach1\n");
        eat(sender);
        eat("\n");
        eat(frame.substr(0, std::min(frame.size(), REACH_SEED_BYTES)));
        eat("\n");
    }

    uint64_t rank(std::string_view peer) const {
        uint64_t h = base_;
        for (unsigned char c : peer) {
            h ^= c;
            h *= 0x100000001b3ULL;
        }
        h ^= h >> 30;
        h *= 0xbf58476d1ce4e5b9ULL;
        h ^= h >> 27;
        h *= 0x94d049bb133111ebULL;
        return h ^ (h >> 31);
    }

private:
    void eat(std::string_view s) {
        for (unsigned char c : s) {
            base_ ^= c;
            base_ *= 0x100000001b3ULL;
        }
    }
    uint64_t base_ = 0xcbf29ce484222325ULL;
};

// The HIDDEN_REACH provers a hidden sender's frame reaches, of those offered: on-screen
// provers first, then away ones for the slots left. A client's view lists only on-screen
// peers, so its `door_room::reached` still agrees: with three on screen no away prover is
// picked, with fewer every on-screen one is.
class ReachPicks {
public:
    ReachPicks(std::string_view sender, std::string_view frame) : order_(sender, frame) {}

    void offer(const std::string& peer, bool away = false) {
        Entry entry{away, order_.rank(peer), peer};
        auto at = std::lower_bound(best_.begin(), best_.end(), entry);
        if (at != best_.end() && *at == entry) return;
        if (best_.size() == HIDDEN_REACH && at == best_.end()) return;
        best_.insert(at, std::move(entry));
        if (best_.size() > HIDDEN_REACH) best_.pop_back();
    }

    bool picked(const std::string& peer) const {
        for (const auto& entry : best_) {
            if (std::get<2>(entry) == peer) return true;
        }
        return false;
    }

    size_t size() const { return best_.size(); }

private:
    using Entry = std::tuple<bool, uint64_t, std::string>;
    ReachOrder order_;
    std::vector<Entry> best_;
};

// What a door proof's HMAC covers; pinned against the client's
// `ws_client::door_proof_message`.
inline std::string proof_message(const std::string& domain, const std::string& nonce, const std::string& peer,
                                 const std::string& room, const std::string& door, const std::string& relay_key) {
    return "hollow-door1\n" + domain + "\n" + nonce + "\n" + peer + "\n" + room + "\n" + door + "\n" + relay_key;
}

// One locked room's provers: when each stops seeing (PROVED = holds the newest door),
// and the last proof each showed, kept so a lock put back on the relay can judge it
// again.
struct Doors {
    std::unordered_map<std::string, int64_t> open;
    std::unordered_map<std::string, std::string> proofs;
    // Stored proofs that opened nothing when shown, by the group of the socket that
    // showed them, and how many each group holds.
    std::unordered_map<std::string, uint64_t> pending;
    std::unordered_map<uint64_t, size_t> pending_count;

    bool sees(const std::string& peer, int64_t now_ms) const {
        auto it = open.find(peer);
        return it != open.end() && it->second > now_ms;
    }

    bool in_grace() const {
        for (const auto& [peer, until] : open) {
            if (until != PROVED) return true;
        }
        return false;
    }

    // A join showing `proof` (empty = none). A proof that opens the newest door makes
    // the socket a prover; a re-join on the socket that already holds the slot keeps
    // what it had, so a refresh without a proof never hides a member; a new socket
    // proves again. Returns whether the peer sees afterwards.
    // A proof that opens nothing is kept from a socket that saw the room (a member ahead
    // of the relay's chain), while the room holds fewer than PENDING_FREE such proofs, or
    // while its `group` holds fewer than PENDING_PER_GROUP.
    bool join(const std::string& peer, const std::string& proof, bool opens, bool same_socket, int64_t now_ms,
              uint64_t group = 0) {
        if (!proof.empty()) {
            if (opens) {
                proofs[peer] = proof;
                unpend(peer);
            } else if ((same_socket && sees(peer, now_ms)) || pending.count(peer) || pending.size() < PENDING_FREE ||
                       pending_count[group] < PENDING_PER_GROUP) {
                proofs[peer] = proof;
                unpend(peer);
                pending[peer] = group;
                pending_count[group]++;
            }
        }
        if (opens) {
            open[peer] = PROVED;
        } else if (!same_socket) {
            open.erase(peer);
        }
        return sees(peer, now_ms);
    }

    void leave(const std::string& peer) {
        open.erase(peer);
        proofs.erase(peer);
        unpend(peer);
    }

    void unpend(const std::string& peer) {
        auto it = pending.find(peer);
        if (it == pending.end()) return;
        auto c = pending_count.find(it->second);
        if (c != pending_count.end() && --c->second == 0) pending_count.erase(c);
        pending.erase(it);
    }

    // The newest door changed, or the room just became locked (`was_locked` false:
    // everyone in it could see). A peer whose stored proof opens the new door proves
    // at once; anyone else who could see keeps seeing for the grace. Returns the peers
    // who see now and did not before.
    std::vector<std::string> relock(const std::vector<std::string>& peers, bool was_locked,
                                    const std::function<bool(const std::string& peer, const std::string& proof)>& opens,
                                    int64_t now_ms) {
        std::vector<std::string> newly;
        for (const auto& peer : peers) {
            const bool saw = !was_locked || sees(peer, now_ms);
            auto p = proofs.find(peer);
            if (p != proofs.end() && opens(peer, p->second)) {
                open[peer] = PROVED;
                unpend(peer);
                if (!saw) newly.push_back(peer);
            } else if (saw) {
                auto it = open.find(peer);
                int64_t until = now_ms + GRACE_MS;
                open[peer] = (it != open.end() && it->second != PROVED && it->second < until) ? it->second : until;
            } else {
                open.erase(peer);
            }
        }
        return newly;
    }

    // The peers whose grace ran out by `now_ms`; they no longer see.
    std::vector<std::string> expire(int64_t now_ms) {
        std::vector<std::string> gone;
        for (auto it = open.begin(); it != open.end();) {
            if (it->second <= now_ms) {
                gone.push_back(it->first);
                it = open.erase(it);
            } else {
                ++it;
            }
        }
        return gone;
    }
};

}  // namespace door_room
