#pragma once
#include <cstdint>
#include <functional>
#include <limits>
#include <string>
#include <unordered_map>
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
    bool join(const std::string& peer, const std::string& proof, bool opens, bool same_socket, int64_t now_ms) {
        if (!proof.empty()) proofs[peer] = proof;
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
