// Unit tests for the session bounds (src/session_bounds.h): every ring frame charged to
// the global buffer budget and released exactly once, the budget burying ring frames
// as tombstones, the session table cap, the per-IP slots a grace session holds; the
// restart snapshot of sessions (src/session_snapshot.h), the drain hint (src/drain.h)
// and the grace setting (src/config.h).
//
// Needs the uWebSockets/uSockets headers (state.h includes App.h); nothing is linked
// from them. Build + run from relay-uws/test:
//   g++ -std=c++20 -I../src -I../uWebSockets/src -I../uSockets/src
//       test_session_bounds.cpp -o test_session_bounds && ./test_session_bounds

#include "config.h"
#include "drain.h"
#include "session_bounds.h"
#include "session_snapshot.h"
#include "snapshot_codec.h"

#include <cstdint>
#include <cstdio>
#include <map>
#include <random>
#include <set>
#include <string>
#include <vector>

using session::Frame;
using session::Kind;
using session::Session;

static int failures = 0;
static constexpr size_t W = OfflineIndex::FRAME_OVERHEAD_BYTES;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

// A peer id of the real shape (base58, 52 characters), one per `i`.
static std::string peer(int i) {
    static const char* alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    std::string s = "12D3KooWPeer" + std::string(36, 'x');
    for (int k = 0; k < 4; k++) {
        s.push_back(alphabet[i % 58]);
        i /= 58;
    }
    return s;
}
static std::string sid(int i) {
    std::string s = std::to_string(1000000 + i);
    return std::string(32 - s.size(), 'a') + s;
}

static Session& mint(RelayState& st, const std::string& p, uint64_t share) {
    Session& s = st.sessions[p];
    s.sid = sid(static_cast<int>(st.sessions.size()));
    s.peer_id = p;
    s.share = share;
    return s;
}

static Frame frame(std::shared_ptr<const std::string> bytes, uint64_t share, Kind kind = Kind::Other,
                   const std::string& room = "") {
    Frame f;
    f.bytes = std::move(bytes);
    f.share = share;
    f.kind = kind;
    f.room = room;
    return f;
}

static std::shared_ptr<const std::string> buf(size_t n, char c = 'x') {
    return std::make_shared<const std::string>(n, c);
}

// What a device holding nothing past `h` is replayed, gaps counted.
static uint64_t replay_count(const session::Ring& r, uint64_t h) {
    uint64_t n = 0;
    r.replay_after(h, [&n](const Frame&, uint64_t gap) { n += gap ? gap : 1; });
    return n;
}

// The buffer budget as ws_handler.cpp spends it (evict_over_budget + drop_frame), at a
// budget of the test's choosing: a victim is looked up in the two buffers, then
// released. Ring frames are in neither, so released() is what buries them.
static void spend_over(RelayState& st, size_t budget) {
    while (st.buffer_index.bytes() > budget) {
        auto victim = st.buffer_index.victim();
        if (!victim) break;
        const uint64_t seq = victim->first;
        const auto& loc = victim->second;
        if (loc.is_topic) {
            auto it = st.topic_buffers.find(loc.key);
            if (it != st.topic_buffers.end()) {
                auto& tb = it->second;
                for (auto f = tb.frames.begin(); f != tb.frames.end(); ++f) {
                    if (f->seq != seq) continue;
                    tb.bytes -= std::min(tb.bytes, f->frame.size());
                    tb.frames.erase(f);
                    break;
                }
            }
        } else {
            auto it = st.offline_buffer.find(loc.key);
            if (it != st.offline_buffer.end()) {
                auto& q = it->second;
                for (auto m = q.begin(); m != q.end(); ++m) {
                    if (m->seq != seq) continue;
                    q.erase(m);
                    break;
                }
                if (q.empty()) st.offline_buffer.erase(it);
            }
        }
        st.buffer_index.released(seq);
    }
}

// A DM frame deposited the way buffer_offline_msg does it, without its per-target caps.
static uint64_t deposit_dm(RelayState& st, const std::string& target, uint64_t share, size_t n) {
    uint64_t seq = st.buffer_index.stamp(target, false, share, n);
    st.offline_buffer[target].push_back({"dmroom", std::string(n, 'd'), "sender", std::chrono::steady_clock::now(),
                                         false, false, seq, share});
    return seq;
}

// Every frame the relay holds, and what the budget should weigh them at.
struct Held {
    size_t frames = 0;
    size_t bytes = 0;
};

static Held held(const RelayState& st) {
    Held h;
    for (const auto& [target, q] : st.offline_buffer) {
        for (const auto& m : q) {
            h.frames++;
            h.bytes += m.frame.size() + W;
        }
    }
    for (const auto& [key, tb] : st.topic_buffers) {
        for (const auto& f : tb.frames) {
            h.frames++;
            h.bytes += f.frame.size() + W;
        }
    }
    std::set<const void*> buffers;
    for (const auto& [p, s] : st.sessions) {
        for (const auto& f : s.ring.entries()) {
            if (f.tombstone()) continue;
            h.frames++;
            h.bytes += W;
            if (buffers.insert(f.bytes.get()).second) h.bytes += f.size();
        }
    }
    return h;
}

// The index matches what is held, every ring frame names its own stamp and every ring's
// counters still cover (acked, sent].
static bool exact(const RelayState& st) {
    const Held h = held(st);
    if (st.buffer_index.live() != h.frames || st.buffer_index.bytes() != h.bytes) {
        printf("    index %zu frames / %zu bytes, held %zu / %zu\n", st.buffer_index.live(), st.buffer_index.bytes(),
               h.frames, h.bytes);
        return false;
    }
    for (const auto& [p, s] : st.sessions) {
        size_t bytes = 0;
        for (const auto& f : s.ring.entries()) {
            if (f.tombstone()) {
                if (f.budget_seq != 0) return false;
                continue;
            }
            bytes += f.size();
            auto it = st.buffer_index.where.find(f.budget_seq);
            if (f.budget_seq == 0 || it == st.buffer_index.where.end() || !it->second.is_session ||
                it->second.key != p) {
                return false;
            }
        }
        if (bytes != s.ring.bytes()) return false;
        if (replay_count(s.ring, s.ring.acked()) != s.ring.sent() - s.ring.acked()) return false;
    }
    return true;
}

static void budget_tests() {
    printf("ring frames and the global buffer budget\n");

    {
        RelayState st;
        Session& a = mint(st, peer(1), 7);
        session_bounds::ring_push(st, a, frame(buf(100), 9));
        check("a ring frame is charged with its overhead",
              st.buffer_index.live() == 1 && st.buffer_index.bytes() == 100 + W && exact(st));
        auto victim = st.buffer_index.victim();
        check("its stamp is a session stamp under the sender's share",
              a.ring.entries()[0].budget_seq != 0 && victim && victim->second.is_session &&
                  st.buffer_index.frames.held(9) == 100 + W);
    }

    {
        RelayState st;
        Session& a = mint(st, peer(1), 1);
        Session& b = mint(st, peer(2), 1);
        Session& c = mint(st, peer(3), 1);
        auto shared = buf(5000);
        for (Session* s : {&a, &b, &c}) session_bounds::ring_push(st, *s, frame(shared, 4));
        check("a fan-out's buffer is charged once, every holder its overhead",
              st.buffer_index.live() == 3 && st.buffer_index.bytes() == 5000 + 3 * W &&
                  st.buffer_index.shared_buffers() == 1 && exact(st));
        session_bounds::ring_ack(st, a, 1);
        check("the charge moves on when its holder acks first",
              st.buffer_index.live() == 2 && st.buffer_index.bytes() == 5000 + 2 * W && exact(st));
        session_bounds::ring_ack(st, b, 1);
        session_bounds::ring_ack(st, c, 1);
        check("the last holder's ack frees the buffer",
              st.buffer_index.live() == 0 && st.buffer_index.bytes() == 0 && st.buffer_index.shared_buffers() == 0);
    }

    {
        RelayState st;
        Session& a = mint(st, peer(1), 1);
        for (int i = 0; i < 5; i++) session_bounds::ring_push(st, a, frame(buf(10 + i), 3));
        check("an ack out of range changes nothing", !session_bounds::ring_ack(st, a, 9) && st.buffer_index.live() == 5);
        check("an ack releases exactly what it covers",
              session_bounds::ring_ack(st, a, 3) && st.buffer_index.live() == 2 && exact(st));
        Frame keep = frame(buf(40), 3, Kind::Direct, "dmroom");
        session_bounds::ring_push(st, a, std::move(keep));
        auto all = session_bounds::ring_take_all(st, a);
        bool unstamped = all.size() == 3;
        for (const auto& f : all) unstamped = unstamped && f.budget_seq == 0;
        check("an end releases every frame and hands them over unstamped",
              unstamped && st.buffer_index.live() == 0 && st.buffer_index.bytes() == 0 && all[2].room == "dmroom");
    }

    {
        RelayState st;
        Session& a = mint(st, peer(1), 1);
        for (size_t i = 0; i < session::RING_MAX_FRAMES + 10; i++) session_bounds::ring_push(st, a, frame(buf(1), 5));
        check("the per-session frame cap releases what it buries",
              a.ring.real_frames() == session::RING_MAX_FRAMES && st.buffer_index.live() == session::RING_MAX_FRAMES &&
                  exact(st));
        session_bounds::ring_push(st, a, frame(buf(session::RING_MAX_BYTES + 1), 5));
        check("a frame bigger than a ring is counted, never charged",
              a.ring.sent() == session::RING_MAX_FRAMES + 11 && st.buffer_index.live() == session::RING_MAX_FRAMES &&
                  exact(st));
    }

    {
        RelayState st;
        Session& a = mint(st, peer(1), 1);
        for (int i = 0; i < 3; i++) session_bounds::ring_push(st, a, frame(buf(3 * 1024 * 1024), 6));
        session_bounds::ring_push(st, a, frame(buf(1024), 2));
        check("the per-session byte cap releases what it buries",
              a.ring.bytes() <= session::RING_MAX_BYTES && a.ring.real_frames() == 3 && exact(st));
    }

    // At the real budget: buffered frames from a thousand light shares fill it, and the
    // heaviest share's ring frames give way as tombstones, counters whole.
    {
        RelayState st;
        const size_t light = (MAX_BUFFER_TOTAL_BYTES - 6 * 1024 * 1024) / 1000;
        for (int i = 0; i < 1000; i++) {
            st.buffer_index.stamp("filler-" + std::to_string(i), false, 1000 + i, light - W);
        }
        const size_t fillers = st.buffer_index.live();
        Session& a = mint(st, peer(1), 1);
        Session& b = mint(st, peer(2), 1);
        for (int i = 0; i < 4; i++) {
            auto shared = buf(2 * 1024 * 1024, static_cast<char>('a' + i));
            session_bounds::ring_push(st, a, frame(shared, 77));
            session_bounds::ring_push(st, b, frame(shared, 77));
        }
        check("the budget holds after ring pushes", st.buffer_index.bytes() <= MAX_BUFFER_TOTAL_BYTES);
        check("no buffered frame of a light share went", st.buffer_index.live() - a.ring.real_frames() -
                                                              b.ring.real_frames() == fillers);
        check("the flooding share's oldest frames became tombstones",
              a.ring.real_frames() < 4 && a.ring.gap_after(0) && a.ring.entries().front().tombstone());
        check("the rings still count every frame", a.ring.sent() == 4 && b.ring.sent() == 4 &&
                                                       replay_count(a.ring, 0) == 4 && replay_count(b.ring, 0) == 4);
        bool stamps_ok = true;
        for (const Session* s : {&a, &b}) {
            for (const auto& f : s->ring.entries()) {
                if (!f.tombstone()) stamps_ok = stamps_ok && st.buffer_index.where.count(f.budget_seq) == 1;
            }
        }
        check("every frame left holds a live stamp", stamps_ok);
    }

    // A buffered frame the budget picks is never dropped inside a ring push: the push
    // may run inside a loop over those buffers. The loop's settle point drops it.
    {
        RelayState st;
        // Weighed at the whole budget, held as a few bytes: the test needs the charge only.
        const uint64_t big = st.buffer_index.stamp("target", false, 5, MAX_BUFFER_TOTAL_BYTES - W);
        st.offline_buffer["target"].push_back(
            {"dmroom", "dm", "sender", std::chrono::steady_clock::now(), false, false, big, 5});
        Session& a = mint(st, peer(1), 1);
        session_bounds::ring_push(st, a, frame(buf(100), 9));
        check("a ring push leaves the buffered victim alone",
              st.buffer_index.where.count(big) == 1 && st.offline_buffer["target"].size() == 1 &&
                  st.buffer_index.bytes() > MAX_BUFFER_TOTAL_BYTES && a.ring.real_frames() == 1);
        spend_over(st, MAX_BUFFER_TOTAL_BYTES);
        check("the settle point drops it", st.buffer_index.where.count(big) == 0 && st.offline_buffer.empty() &&
                                              a.ring.real_frames() == 1 && exact(st));
    }

    // ws_handler's own eviction (drop_frame) finds a ring frame in neither buffer and
    // releases it: the ring buries it.
    {
        RelayState st;
        Session& a = mint(st, peer(1), 1);
        for (int i = 0; i < 6; i++) session_bounds::ring_push(st, a, frame(buf(1000), 8));
        deposit_dm(st, "target", 2, 500);
        spend_over(st, 3 * (1000 + W) + 500 + W);
        check("drop_frame's release buries the ring's oldest frames",
              a.ring.real_frames() == 3 && a.ring.entries().front().tombstone() &&
                  a.ring.entries().front().gap == 3 && st.offline_buffer["target"].size() == 1 && exact(st));
        check("and the device is replayed one gap for them", replay_count(a.ring, 0) == 6 && a.ring.gap_after(0));
    }

    // Random pushes, fan-outs, acks, ends, deposits and evictions: the stamp count
    // always equals the frames held.
    {
        RelayState st;
        std::mt19937_64 rng(12345);
        auto pick = [&rng](uint64_t n) { return n ? rng() % n : 0; };
        std::vector<std::string> peers;
        for (int i = 0; i < 6; i++) {
            peers.push_back(peer(i));
            mint(st, peers.back(), i % 3);
        }
        bool ok = true;
        int ops = 0;
        for (; ops < 4000 && ok; ops++) {
            const uint64_t r = pick(100);
            Session& s = st.sessions[peers[pick(peers.size())]];
            if (r < 35) {
                session_bounds::ring_push(st, s, frame(buf(1 + pick(5000)), pick(4)));
            } else if (r < 50) {
                auto shared = buf(1 + pick(20000));
                const uint64_t share = pick(4);
                for (const auto& p : peers) {
                    if (pick(2)) session_bounds::ring_push(st, st.sessions[p], frame(shared, share));
                }
            } else if (r < 70) {
                const uint64_t lo = s.ring.acked(), hi = s.ring.sent();
                session_bounds::ring_ack(st, s, lo + pick(hi - lo + 1));
            } else if (r < 74) {
                const std::string p = s.peer_id;
                session_bounds::ring_take_all(st, s);
                st.sessions.erase(p);
                mint(st, p, pick(3));
            } else if (r < 90) {
                deposit_dm(st, "t" + std::to_string(pick(5)), pick(4), pick(3000));
            } else {
                spend_over(st, 40000 + pick(80000));
            }
            ok = exact(st);
        }
        check("4000 random operations keep the index exact (" + std::to_string(ops) + " run)", ok);
    }

    printf("\n");
}

static void table_tests() {
    printf("the session table cap\n");

    {
        RelayState st;
        for (int i = 0; i < 10; i++) mint(st, peer(i), static_cast<uint64_t>(i));
        check("below the cap nothing goes", session_bounds::make_room(st, 3).empty());
    }

    {
        RelayState st;
        st.sessions.reserve(session::MAX_SESSIONS);
        const auto now = std::chrono::steady_clock::now();
        size_t n = 0;
        // One address share holds 1000 sessions, half of them in grace; everyone else one.
        for (; n < 1000; n++) {
            Session& s = mint(st, "flood-" + std::to_string(n), 42);
            if (n % 2) {
                s.state = session::State::Grace;
                s.grace_until = now + std::chrono::seconds(1000 - static_cast<int64_t>(n));
            }
        }
        for (; n < session::MAX_SESSIONS; n++) mint(st, "user-" + std::to_string(n), 100000 + n);
        auto out = session_bounds::make_room(st, 5);
        check("at the cap one session goes", out.size() == 1);
        check("it is the heaviest share's", !out.empty() && out[0].rfind("flood-", 0) == 0);
        check("in grace, the one closest to its end", !out.empty() && out[0] == "flood-999");
        if (!out.empty()) st.sessions.erase(out[0]);
        mint(st, "user-new", 5);
        out = session_bounds::make_room(st, 5);
        check("the next mint takes the heaviest share's next", out.size() == 1 && out[0] == "flood-997");

        // Every share holds one: the requester's own share pays first.
        RelayState even;
        even.sessions.reserve(session::MAX_SESSIONS);
        for (size_t i = 0; i < session::MAX_SESSIONS; i++) mint(even, "one-" + std::to_string(i), i);
        out = session_bounds::make_room(even, 77);
        check("a newcomer whose share already holds one evicts its own", out.size() == 1 && out[0] == "one-77");
        even.sessions["one-12"].state = session::State::Grace;
        even.sessions["one-12"].grace_until = now;
        out = session_bounds::make_room(even, session::MAX_SESSIONS + 5);
        check("a newcomer with nothing yet evicts a session in grace first", out.size() == 1 && out[0] == "one-12");

        // Counted with its newcomer, the requester's share ties the heaviest: it pays,
        // even with a live session against the other's session in grace.
        const uint64_t mine = session::MAX_SESSIONS + 100, theirs = session::MAX_SESSIONS + 200;
        for (const char* p : {"one-1", "one-2"}) even.sessions[p].share = mine;
        for (const char* p : {"one-3", "one-4", "one-5"}) even.sessions[p].share = theirs;
        even.sessions["one-4"].state = session::State::Grace;
        even.sessions["one-4"].grace_until = now - std::chrono::seconds(5);
        out = session_bounds::make_room(even, mine);
        check("a tie with the newcomer counted falls on the newcomer's share",
              out.size() == 1 && (out[0] == "one-1" || out[0] == "one-2"));
    }

    printf("\n");
}

// The per-IP accounting as ws_handler.cpp keeps it: .open counts a socket, .close
// uncounts it unless its session holds the slot.
struct Ip {
    RelayState& st;
    void open(const std::string& key) { st.ip_states[key].active_count++; }
    void close(const std::string& key) {
        auto it = st.ip_states.find(key);
        if (it == st.ip_states.end()) return;
        if (it->second.active_count > 0) it->second.active_count--;
        if (it->second.active_count == 0) st.ip_states.erase(it);
    }
    uint32_t count(const std::string& key) const {
        auto it = st.ip_states.find(key);
        return it == st.ip_states.end() ? 0 : it->second.active_count;
    }
};

static void ip_slot_tests() {
    printf("per-IP slots of sessions in grace\n");

    {
        RelayState st;
        Ip ip{st};
        Session& s = mint(st, peer(1), 1);
        ip.open("10.0.0.1");
        session_bounds::hold_ip_slot(st, s, "10.0.0.1");  // its socket closed, .close skips its decrement
        check("a grace session keeps its socket's slot", ip.count("10.0.0.1") == 1 && s.ip_key == "10.0.0.1");
        ip.open("10.0.0.1");
        session_bounds::release_ip_slot(st, s);  // resumed on a socket counted by .open
        check("a resume frees the held slot, the new socket keeps its own",
              ip.count("10.0.0.1") == 1 && s.ip_key.empty());
        session_bounds::release_ip_slot(st, s);
        check("a second release changes nothing", ip.count("10.0.0.1") == 1);
        session_bounds::hold_ip_slot(st, s, "10.0.0.1");
        session_bounds::release_ip_slot(st, s);  // grace expiry
        check("expiry frees the slot and the address entry", ip.count("10.0.0.1") == 0 && st.ip_states.empty());
    }

    {
        RelayState st;
        Ip ip{st};
        Session& s = mint(st, peer(1), 1);
        ip.open("10.0.0.1");
        session_bounds::hold_ip_slot(st, s, "10.0.0.1");
        ip.open("10.0.0.2");  // resumed from another address, its held slot never released
        session_bounds::hold_ip_slot(st, s, "10.0.0.2");
        check("a hold over a slot never released frees the old one first",
              ip.count("10.0.0.1") == 0 && ip.count("10.0.0.2") == 1);
        session_bounds::release_ip_slot(st, s);
        check("and nothing leaks once it is gone", st.ip_states.empty());
    }

    {
        RelayState st;
        Ip ip{st};
        for (int i = 0; i < 3; i++) {
            Session& s = mint(st, peer(i), 1);
            ip.open("10.0.0.9");
            s.state = session::State::Grace;
            s.grace_until = std::chrono::steady_clock::now() + std::chrono::seconds(100 - i);
            session_bounds::hold_ip_slot(st, s, "10.0.0.9");
        }
        // A live session still naming the address (its slot was never released) is not
        // one to end for a slot.
        Session& live = mint(st, peer(7), 1);
        ip.open("10.0.0.9");
        live.ip_key = "10.0.0.9";
        for (size_t i = ip.count("10.0.0.9"); i < MAX_CONNS_PER_IP; i++) ip.open("10.0.0.9");
        check("grace slots fill an address up to the cap", ip.count("10.0.0.9") == MAX_CONNS_PER_IP);
        auto victim = session_bounds::grace_slot_victim(st, "10.0.0.9");
        check("a full address names the grace slot closest to its end", victim && *victim == peer(2));
        check("an address holding no grace slot names none", !session_bounds::grace_slot_victim(st, "10.0.0.8"));
        mint(st, peer(8), 1).ip_key = "10.0.0.7";
        check("an address named only by a live session names none",
              !session_bounds::grace_slot_victim(st, "10.0.0.7"));
        if (victim) {
            session_bounds::release_ip_slot(st, st.sessions[*victim]);
            st.sessions.erase(*victim);
        }
        check("ending it frees one slot for the device coming back", ip.count("10.0.0.9") == MAX_CONNS_PER_IP - 1);
    }

    {
        RelayState st;
        Ip ip{st};
        Session& s = mint(st, peer(1), 1);
        ip.open("10.0.0.1");
        session_bounds::hold_ip_slot(st, s, "10.0.0.1");
        const std::string p = s.peer_id;
        session_bounds::ring_take_all(st, s);
        session_bounds::release_ip_slot(st, s);  // ended by the table cap, as on expiry
        st.sessions.erase(p);
        check("an evicted session frees its slot", st.ip_states.empty());
    }

    printf("\n");
}

static void snapshot_tests() {
    printf("sessions across a restart\n");

    RelayState st;
    auto fan = buf(700, 'f');
    Session& a = mint(st, peer(1), 31);
    a.state = session::State::Live;
    a.rooms = {{"inbox:12D3KooWMaster", true}, {"srv", false}};
    a.subscriptions = {{"srv", {"general"}}, {"other", {}}};
    a.inactive = true;
    a.in_h = 17;
    a.door_nonce = "nonce";
    a.ip_key = "10.0.0.1";
    session_bounds::ring_push(st, a, frame(buf(50), 4));
    session_bounds::ring_push(st, a, frame(fan, 4));
    session_bounds::ring_push(st, a, frame(buf(300), 5, Kind::Direct, "dmroom"));
    session_bounds::ring_push(st, a, frame(buf(200), 5, Kind::DirectImage, "dmroom"));
    session_bounds::ring_push(st, a, frame(buf(100), 4));
    st.buffer_index.released(a.ring.entries()[3].budget_seq);  // the budget picks the image
    session_bounds::ring_ack(st, a, 1);
    Frame text = frame(std::make_shared<const std::string>(R"({"type":"lock_chain"})"), 4);
    text.binary = false;
    session_bounds::ring_push(st, a, std::move(text));
    Session& b = mint(st, peer(2), 32);
    b.state = session::State::Grace;
    session_bounds::ring_push(st, b, frame(fan, 4));
    Session& c = mint(st, peer(3), 33);
    c.state = session::State::Grace;

    st.nickname_to_peer["vitalik_7"] = peer(1);
    st.peer_to_nickname[peer(1)] = "vitalik_7";
    st.nickname_expiry["vitalik_7"] = 2000000000;
    st.nickname_to_master["vitalik_7"] = peer(100);
    st.nickname_proof["vitalik_7"] = {"CAESIA==", 1790000000000, "c2ln"};
    st.linkcode_to_peer["AB12CD"] = peer(2);
    st.peer_to_linkcode[peer(2)] = "AB12CD";
    st.linkcode_expiry["AB12CD"] = 2000000000;
    st.nickname_to_peer["gone_nick"] = peer(3);
    st.peer_to_nickname[peer(3)] = "gone_nick";
    st.nickname_expiry["gone_nick"] = 1000;
    st.nickname_to_peer["no_session"] = "12D3KooWSomeoneElse";
    st.peer_to_nickname["12D3KooWSomeoneElse"] = "no_session";
    check("the live state is exact before the restart", exact(st));

    snapshot::Data d;
    session_snapshot::capture(st, d);
    check("every session is captured", d.sessions.size() == 3);
    check("the shared fan-out buffer is written once", d.buffers.size() == 4);
    snapshot::Data back;
    const bool decoded = snapshot::decode(snapshot::encode(d), back);
    check("the capture survives the codec", decoded && back.sessions.size() == 3);

    check("the image the budget picked is a tombstone before the restart",
          a.ring.entries()[2].tombstone() && a.ring.real_frames() == 4 && exact(st));
    RelayState r;
    const auto now = std::chrono::steady_clock::now();
    const size_t dropped = session_snapshot::restore(r, snapshot::Data(back), now, 300, 1800000000);
    check("nothing is dropped", dropped == 0 && r.sessions.size() == 3);
    const Session& ra = r.sessions[peer(1)];
    const Session& rb = r.sessions[peer(2)];
    check("every session comes back in grace, restored, its timer starting now",
          ra.state == session::State::Grace && rb.state == session::State::Grace && ra.restored && rb.restored &&
              ra.grace_until == now + std::chrono::seconds(300) && r.sessions[peer(3)].restored);
    check("the door nonce and the per-IP slot stay behind",
          ra.door_nonce.empty() && ra.ip_key.empty());
    check("rooms with owner flags, subscriptions, counters and flags come back",
          ra.rooms == a.rooms && ra.subscriptions == a.subscriptions && ra.in_h == 17 && ra.inactive &&
              ra.sid == a.sid && ra.share == 31);
    std::vector<std::string> was, now_is;
    a.ring.replay_after(0, [&was](const Frame& f, uint64_t n) { was.push_back(n ? session::gap_frame(n) : *f.bytes); });
    ra.ring.replay_after(0, [&now_is](const Frame& f, uint64_t n) {
        now_is.push_back(n ? session::gap_frame(n) : *f.bytes);
    });
    check("the ring replays the same, its tombstone included",
          was == now_is && ra.ring.sent() == a.ring.sent() && ra.ring.acked() == a.ring.acked() &&
              ra.ring.gap_after(0));
    bool meta = ra.ring.entries().size() == a.ring.entries().size();
    for (size_t i = 0; meta && i < ra.ring.entries().size(); i++) {
        const auto& x = a.ring.entries()[i];
        const auto& y = ra.ring.entries()[i];
        meta = meta && x.kind == y.kind && x.room == y.room && x.binary == y.binary && x.share == y.share;
    }
    check("each frame keeps its kind, room, binary flag and share", meta);
    check("the fan-out buffer is shared again", !ra.ring.entries().empty() && !rb.ring.entries().empty() &&
                                                    ra.ring.entries()[0].bytes == rb.ring.entries()[0].bytes &&
                                                    r.buffer_index.shared_buffers() == 4);
    check("the restored rings are charged exactly", exact(r) && r.buffer_index.live() == 5);
    check("a session's nickname comes back with its master and proof",
          r.nickname_to_peer["vitalik_7"] == peer(1) && r.peer_to_nickname[peer(1)] == "vitalik_7" &&
              r.nickname_to_master["vitalik_7"] == peer(100) &&
              r.nickname_proof["vitalik_7"].sig == "c2ln" && r.nickname_expiry["vitalik_7"] == 2000000000);
    check("its link code comes back", r.linkcode_to_peer["AB12CD"] == peer(2) && r.peer_to_linkcode[peer(2)] == "AB12CD");
    check("an expired nickname does not", !r.nickname_to_peer.count("gone_nick") && !r.peer_to_nickname.count(peer(3)));
    check("a binding no session holds is not carried", !r.nickname_to_peer.count("no_session"));
    session_bounds::ring_ack(r, r.sessions[peer(1)], r.sessions[peer(1)].ring.sent());
    check("a restored ring acks like any other", exact(r) && r.buffer_index.live() == 1);

    // A record the codec read but that is not a session this relay could have held
    // is dropped alone. Each case spoils the record of the session with a full ring.
    auto bad = [&](auto&& spoil) {
        snapshot::Data x = back;
        for (auto& s : x.sessions) {
            if (s.peer_id == peer(1)) spoil(x, s);
        }
        RelayState t;
        const size_t gone = session_snapshot::restore(t, std::move(x), now, 120, 1800000000);
        return gone == 1 && t.sessions.size() == 2 && !t.sessions.count(peer(1)) && exact(t);
    };
    using Rec = snapshot::SessionRec;
    using Data = snapshot::Data;
    check("a sid of the wrong shape", bad([](Data&, Rec& s) { s.sid = "XYZ"; }));
    check("a peer id of the wrong shape", bad([](Data&, Rec& s) { s.peer_id = "not a peer"; }));
    check("a ring that does not cover its counters", bad([](Data&, Rec& s) { s.sent += 1; }));
    check("an unknown frame kind", bad([](Data&, Rec& s) { s.frames.back().kind = 9; }));
    check("a room of the wrong shape", bad([](Data&, Rec& s) { s.rooms.push_back({"bad room!", false}); }));
    check("a room held twice", bad([](Data&, Rec& s) { s.rooms.push_back(s.rooms.front()); }));
    check("a topic of the wrong shape", bad([](Data&, Rec& s) {
        s.subscriptions.push_back({"srv2", {std::string(200, 't')}});
    }));
    check("a nickname of the wrong shape", bad([](Data&, Rec& s) { s.nickname.nickname = "NO"; }));
    check("a link code of the wrong shape", bad([](Data&, Rec& s) {
        s.has_link_code = true;
        s.link_code.code = "abc";
    }));
    check("a frame room of the wrong shape", bad([](Data&, Rec& s) { s.frames.front().room = "no room"; }));
    check("a second record for one peer, the first kept", [&] {
        Data x = back;
        for (auto& s : x.sessions) {
            if (s.peer_id == peer(3)) s.peer_id = peer(1);
        }
        RelayState t;
        const size_t gone = session_snapshot::restore(t, std::move(x), now, 120, 1800000000);
        return gone == 1 && t.sessions.size() == 2 && t.sessions.count(peer(1)) && exact(t);
    }());
    check("a real frame larger than a ring", bad([](Data& x, Rec& s) {
        x.buffers.push_back(std::string(session::RING_MAX_BYTES + 1, 'z'));
        s.frames.back().buffer = static_cast<uint32_t>(x.buffers.size() - 1);
    }));

    // More sessions than the table holds: the share holding the most gives way.
    {
        Data x;
        const uint64_t shares[] = {1, 1, 1, 2, 3};
        for (int i = 0; i < 5; i++) {
            Rec rec;
            rec.sid = sid(i);
            rec.peer_id = peer(20 + i);
            rec.share = shares[i];
            x.sessions.push_back(rec);
        }
        RelayState t;
        const size_t gone = session_snapshot::restore(t, std::move(x), now, 120, 1800000000, 3);
        size_t of_one = 0;
        for (const auto& [p, s] : t.sessions) of_one += s.share == 1;
        check("a table past its cap sheds the heaviest share's sessions",
              gone == 2 && t.sessions.size() == 3 && of_one == 1);
    }

    // A ring written under bigger caps comes back within this build's.
    {
        Data x;
        Rec rec;
        rec.sid = sid(1);
        rec.peer_id = peer(30);
        const uint64_t n = session::RING_MAX_FRAMES + 3;
        rec.sent = n;
        for (uint64_t i = 1; i <= n; i++) {
            x.buffers.push_back("f" + std::to_string(i));
            snapshot::SessionFrame f;
            f.seq = i;
            f.buffer = static_cast<uint32_t>(i - 1);
            f.share = 5;
            f.budget_seq = i;
            rec.frames.push_back(f);
        }
        x.sessions.push_back(rec);
        RelayState t;
        session_snapshot::restore(t, std::move(x), now, 120, 1800000000);
        const Session& s = t.sessions[peer(30)];
        check("a restored ring over the frame cap is held to it, its stamps exact",
              s.ring.real_frames() == session::RING_MAX_FRAMES && s.ring.sent() == n && s.ring.gap_after(0) &&
                  exact(t));
    }

    printf("\n");
}

static void drain_tests() {
    printf("the drain hint\n");

    check("the hint names its wait", drain::hint(2500) == R"({"type":"reconnect","after_ms":2500})");
    check("the lowest draw waits the floor", drain::pick([](uint32_t) { return 0u; }) == session::DRAIN_MIN_MS);
    check("the highest draw waits the ceiling",
          drain::pick([](uint32_t n) { return n - 1; }) == session::DRAIN_MAX_MS);
    std::mt19937 rng(7);
    int64_t lo = INT64_MAX, hi = 0;
    for (int i = 0; i < 20000; i++) {
        const int64_t n = drain::pick([&rng](uint32_t m) { return static_cast<uint32_t>(rng() % m); });
        lo = std::min(lo, n);
        hi = std::max(hi, n);
    }
    check("every wait falls in [2000, 10000] and both ends are reached", lo == 2000 && hi == 10000);

    RelayState st;
    auto sock = [](uintptr_t n) { return reinterpret_cast<SSLWebSocket*>(n * 64); };
    for (int i = 0; i < 4; i++) {
        Session& s = mint(st, peer(i), 1);
        s.state = i == 3 ? session::State::Grace : session::State::Live;
        if (i != 3) st.peer_sockets[peer(i)] = sock(i + 1);
    }
    st.peer_sockets["12D3KooWNoSession"] = sock(9);
    // A session in grace whose device also holds a socket without a session.
    st.peer_sockets[peer(3)] = sock(8);
    // A live session whose socket was superseded has no socket to tell.
    mint(st, peer(4), 1).state = session::State::Live;
    st.peer_sockets[peer(4)] = sock(7);
    auto socket_of = [&](const std::string& p, const Session&) -> SSLWebSocket* {
        auto it = st.peer_sockets.find(p);
        return it == st.peer_sockets.end() || it->second == sock(7) ? nullptr : it->second;
    };
    std::vector<std::string> log;
    std::map<SSLWebSocket*, std::string> got;
    drain::shutdown(
        st, socket_of,
        [&](SSLWebSocket* ws, const std::string& text) {
            log.push_back("send");
            got[ws] = text;
        },
        [](uint32_t m) { return m / 2; }, [&] { log.push_back("snapshot"); }, [&] { log.push_back("close"); });
    check("every live session's socket gets the hint", got.size() == 3 && got.count(sock(1)) && got.count(sock(2)) &&
                                                           got.count(sock(3)));
    check("a socket without a session does not", !got.count(sock(9)));
    check("nor does a socket whose session is in grace", !got.count(sock(8)));
    check("nor a session whose socket is not its own", !got.count(sock(7)));
    check("the hint carries the drawn wait", got[sock(1)] == drain::hint(6000));
    check("hints, then the snapshot, then the close, nothing after",
          log == std::vector<std::string>{"send", "send", "send", "snapshot", "close"});

    printf("\n");
}

static Config parse(std::vector<std::string> args) {
    std::vector<char*> argv;
    static std::string name = "hollow-relay";
    argv.push_back(name.data());
    for (auto& a : args) argv.push_back(a.data());
    return parse_args(static_cast<int>(argv.size()), argv.data());
}

static void config_tests() {
    printf("the grace setting\n");
    check("the default is 120 s", parse({}).session_grace_secs == 120);
    check("a value in range is taken", parse({"--session-grace-secs", "300"}).session_grace_secs == 300);
    check("below 30 is raised to 30", parse({"--session-grace-secs", "5"}).session_grace_secs == 30);
    check("above 600 is lowered to 600", parse({"--session-grace-secs", "9999"}).session_grace_secs == 600);
    check("the bounds themselves are taken", parse({"--session-grace-secs", "30"}).session_grace_secs == 30 &&
                                                 parse({"--session-grace-secs", "600"}).session_grace_secs == 600);
    printf("\n");
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0);
    printf("session bounds\n\n");
    budget_tests();
    table_tests();
    ip_slot_tests();
    snapshot_tests();
    drain_tests();
    config_tests();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
