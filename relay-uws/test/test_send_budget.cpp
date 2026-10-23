// Unit tests for the send-buffer memory budget (src/send_budget.h): the running total of
// held bytes is exact and never negative, a fan-out past the budget evicts the heaviest
// share's least progressed socket (co-tenants before the sender trips), under pressure one
// share keeps to its cap without refusing an honest co-tenant, an honest
// 206 MB fan-out always passes, a single socket cannot hold two max frames, a buffer that
// does not REALLY drain (or an inbound frame that does not really grow) is found by the
// stall sweep, recipients are counted per block and per share in the prediction and the
// delivery alike, a malformed text msg never throws, and the predicted copy sizes match
// the frames the relay builds.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_send_budget.cpp -o test_send_budget && ./test_send_budget

#include "binary_frame.h"
#include "client_json.h"
#include "msg_plan.h"
#include "send_budget.h"

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

using namespace send_budget;
using Ledger64 = Ledger<uint64_t>;

static bool has(const std::vector<uint64_t>& v, uint64_t k) {
    for (auto x : v) {
        if (x == k) return true;
    }
    return false;
}

int main() {
    printf("send budget\n");

    // The total is a running sum of per-socket amounts, exact across grow, drain and close.
    {
        Ledger64 l;
        l.limits = limits_for(1000, /*test=*/true);
        l.out(1, 100, 0, 1);
        l.out(2, 50, 0, 2);
        check("total adds both sockets", l.total() == 150);
        l.out(1, 40, 0, 1);  // a drains
        check("total follows a drain exactly", l.total() == 90);
        l.out(2, 0, 0, 2);   // b empties
        check("an empty socket leaves the total", l.total() == 40);
        l.forget(1);
        check("a closed socket leaves nothing behind", l.total() == 0);
        check("no sockets remain", l.sockets() == 0);
    }

    // Re-observing the same amount changes nothing (idempotent hot path).
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 100, 0, 1);
        l.out(1, 100, 0, 1);
        check("a repeat observation does not double count", l.total() == 100);
        l.out(2, 0, 0, 2);
        check("a never-buffering repeat of zero is free", l.sockets() == 1);
    }

    // Never negative: forgetting a socket never charged leaves the total alone.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 100, 0, 1);
        l.forget(2);
        check("forgetting an untracked socket keeps the total", l.total() == 100);
        l.forget(1);
        check("the total reaches exactly zero", l.total() == 0);
    }

    // Inbound partial frames are charged at their buffer's capacity beside the unsent one.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 100, 0, 1);
        l.in(1, 300, 10, 0, 0, 1);
        check("an inbound partial frame adds to the socket's charge", l.total() == 400);
        l.in(1, 0, 0, 0, 0, 1);
        check("a finished inbound frame leaves only the unsent buffer", l.total() == 100);
    }

    // An honest MLS remove commit fan-out (~206 MB) always passes with the floored budget.
    {
        Ledger64 l;
        l.limits = limits_for(MIN_LIMIT);
        auto never = [](const uint64_t&) {};
        check("the honest 206 MB fan-out passes on an empty budget",
              l.admit(HONEST_FANOUT_BYTES, 99, 1, never) == Admit::Pass);
        check("the budget is never below two honest fan-outs", l.limits.limit >= 2 * HONEST_FANOUT_BYTES);
    }

    // The floor only where the box has the RAM: a small self-hosted VPS keeps its RAM.
    {
        check("an 8 GiB box gets a quarter (2 GiB)", default_limit(8192 * MiB) == 2048 * MiB);
        check("a 2 GiB box gets the honest floor", default_limit(2048 * MiB) == MIN_LIMIT);
        check("a 1 GiB box gets a third, never the 512 MiB floor", default_limit(1024 * MiB) == 1024 * MiB / 3);
        check("an unknown box gets the floor", default_limit(0) == MIN_LIMIT);
    }

    // N7: a frame that fits an EMPTY budget trips (uncounted) while the sender's own share
    // fills the budget and passes once it drains. A frame larger than the whole budget can
    // never fit, so it is refused once (counted), not looped.
    {
        Ledger64 l;
        l.limits = limits_for(MIN_LIMIT);
        auto never = [](const uint64_t&) {};
        check("a fan-out equal to the whole budget passes on empty", l.admit(MIN_LIMIT, 99, 1, never) == Admit::Pass);
        check("one byte past the whole budget can never fit: refused",
              l.admit(MIN_LIMIT + 1, 99, 1, never) == Admit::Refuse);
        l.out(1, 400 * MiB, 0, 7);  // the sender's own share holds a lot
        check("a 200 MB fan-out over a budget the sender's share fills trips",
              l.admit(200 * MiB, 1, 7, never) == Admit::Trip);
        l.out(1, 0, 0, 7);
        check("once it drains the same fan-out passes", l.admit(200 * MiB, 1, 7, never) == Admit::Pass);
    }

    // Two shares: a fan-out over the budget closes the heaviest OTHER share's least
    // recently drained socket, never an honest share's, and then passes.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 100, 0, 1);  // honest share 1
        l.out(2, 300, 0, 9);  // attacker share 9, older
        l.out(3, 300, 1, 9);
        std::vector<uint64_t> closed;
        auto close = [&](const uint64_t& k) { closed.push_back(k); };
        check("an honest fan-out over the budget passes", l.admit(500, 1, 1, close) == Admit::Pass);
        check("by closing the heaviest share's oldest socket only", closed.size() == 1 && closed[0] == 2);
        check("the honest share's socket stays", l.holds(1));
        check("and the closed one is forgotten", !l.holds(2) && l.total() == 400);
    }

    // Reviewer proof: one IPv4 address (34 sockets, one share) holds the budget with 1 KiB
    // trickle reads topped up by 1 KiB directs; an honest broadcast still passes and the
    // trickle readers are found stalled.
    {
        Ledger64 l;
        l.limits = limits_for(default_limit(8ull * 1024 * MiB));  // 2 GiB
        const uint64_t HOLD = 63 * MiB;
        int64_t t = 0;
        for (uint64_t k = 0; k < 34; k++) l.out(k, HOLD, t, 666);
        bool refills_fit = true;
        for (int round = 0; round < 30; round++) {
            t += 20000;
            for (uint64_t k = 0; k < 34; k++) {
                l.out(k, HOLD - 1024, t, 666);
                refills_fit = refills_fit && l.write_fits(k, HOLD - 1024, 1024 + FRAME_HEADER_BYTES, 666);
                l.out(k, HOLD, t, 666);
            }
        }
        check("under pressure a share over its cap dooms its stale sockets, which take no more writes",
              !refills_fit && !l.doomed().empty());
        check("trickle_reader_held_10_minutes_is_found_stalled", !l.stalled(t).empty());
        std::vector<uint64_t> closed;
        auto close = [&](const uint64_t& k) { closed.push_back(k); };
        check("honest_64KiB_broadcast_to_10_peers_passes_while_one_share_holds_the_budget",
              l.admit(64 * 1024 * 10, 999, 1, close) == Admit::Pass);
        check("(by closing the hog's sockets)", !closed.empty());
        auto over = l.over_budget();
        check("the sweep closes the hog's sockets until the box is out of pressure",
              !over.empty() && l.total() <= l.limits.limit / 2 && l.total() + 63 * MiB > l.limits.limit / 2);
    }

    // The sweep closes nothing while the budget and every share are within their lines,
    // nor for a share past its cap while the box holds under half its budget.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.limits.share_cap = 125;
        l.out(1, 100, 0, 1);
        l.out(2, 100, 0, 2);
        check("nothing over: nothing closed", l.over_budget().empty());
        l.out(3, 100, 1, 2);  // share 2 now 200 > 125
        check("share_cap_sleeps_without_pressure", l.over_budget().empty());
        l.out(4, 120, 0, 3);
        l.out(5, 120, 0, 4);  // 540 > 500: pressure
        auto over = l.over_budget();
        check("under pressure a share over its cap loses its least progressed socket",
              over.size() == 1 && over[0] == 2 && l.holds(3));
    }

    // A single absurd fan-out larger than the budget is refused whatever the total.
    {
        Ledger64 l;
        l.limits = limits_for(default_limit(8ull * 1024 * MiB));  // 8 GiB box -> 2 GiB budget
        auto never = [](const uint64_t&) {};
        check("64 MB x 68 recipients (4.3 GB) is refused", l.admit(68 * SOCKET_CAP, 99, 1, never) == Admit::Refuse);
        check("a modest fan-out passes", l.admit(2 * MiB * 68, 99, 1, never) == Admit::Pass);
    }

    // Per socket: one frame into an empty buffer passes; a second large write does not, so
    // a socket never holds two max frames. Per share: no write past the share's cap.
    // Strict: a recipient past its fan-out's count goes out only within the budget itself.
    {
        Ledger64 l;
        l.limits = limits_for(default_limit(8ull * 1024 * MiB));
        check("a 64 MB frame into an empty socket fits", l.write_fits(99, 0, SOCKET_CAP, 1));
        check("a 64 MB frame onto a 60 MB buffer is refused", !l.write_fits(99, 60 * MiB, SOCKET_CAP, 1));
        check("a small write onto a small buffer fits", l.write_fits(99, 1 * MiB, 1 * MiB, 1));
        check("a write that lands exactly on the socket cap fits", l.write_fits(99, 1 * MiB, SOCKET_CAP - 1 * MiB, 1));
        check("one byte over the socket cap is refused", !l.write_fits(99, 1 * MiB, SOCKET_CAP - 1 * MiB + 1, 1));
        for (uint64_t k = 0; k < 4; k++) l.out(k, 63 * MiB, 0, 5);  // share 5 at 252 MiB of 256
        check("a write that keeps the share within its cap fits", l.write_fits(0, 1 * MiB, 4 * MiB, 5));
        check("a write past the share's cap fits while the box has room", l.write_fits(0, 1 * MiB, 4 * MiB + 1, 5));
        check("(and dooms no one)", l.doomed().empty());
        Ledger64 s;
        s.limits = limits_for(1000, true);
        s.out(1, 100, 0, 1);
        s.out(2, 100, 0, 2);
        s.out(3, 100, 0, 3);
        s.out(4, 100, 0, 4);
        s.out(5, 100, 0, 5);
        s.out(6, 100, 0, 6);
        s.out(7, 100, 0, 7);
        s.out(8, 100, 0, 8);
        s.out(9, 100, 0, 9);  // 900 of 1000, hard 1250
        check("past the budget a counted recipient still fits under the hard line", s.write_fits(99, 0, 200, 10));
        check("an uncounted (strict) recipient does not", !s.write_fits(99, 0, 200, 10, /*strict=*/true));
    }

    // The stall sweep: a buffer that has not REALLY drained (64 KiB, or half of a smaller
    // one) for T is stalled; one that drains for real is not.
    {
        Ledger64 l;
        l.limits = limits_for(1000 * MiB, true);
        l.out(1, 10 * MiB, 0, 1);      // never drains
        l.out(2, 10 * MiB, 0, 2);
        l.out(2, 9 * MiB, 20000, 2);   // drains 1 MiB at t=20s
        l.out(3, 10 * MiB, 0, 3);
        for (int i = 1; i <= 100; i++) {
            l.out(3, 10 * MiB - 1024, i * 1000, 3);  // 1 KiB trickle, topped back up
            l.out(3, 10 * MiB, i * 1000, 3);
        }
        auto stuck = l.stalled(121000, STALL_MS);
        check("the never-draining socket is stalled", has(stuck, 1));
        check("a socket that drained for real inside T is not", !has(stuck, 2));
        check("a trickle that never adds up to 64 KiB is stalled", has(stuck, 3));
        auto edge = l.stalled(static_cast<int64_t>(STALL_MS), STALL_MS);
        check("a socket quiet for exactly the window is caught", has(edge, 1));
        Ledger64 small;
        small.limits = limits_for(1000, true);
        small.out(4, 100, 0, 4);
        small.out(4, 50, 1000, 4);  // half of a small buffer is real progress
        check("half of a small buffer drained is progress", !has(small.stalled(STALL_MS, STALL_MS), 4));
    }

    // Inbound: a partial frame that does not grow by 64 KiB in T is stalled; growth or a
    // control frame's tip leaving does not reset the clock unless it is real.
    {
        Ledger64 l;
        l.limits = limits_for(1000 * MiB, true);
        l.in(1, 64 * MiB, 1 * MiB, 0, 0, 1);
        l.in(1, 64 * MiB, 1 * MiB + 1024, 0, 60000, 1);    // 1 KiB: not progress
        l.in(1, 64 * MiB, 1 * MiB + 900, 0, 100000, 1);    // a control tip left: not progress
        l.in(2, 64 * MiB, 1 * MiB, 0, 0, 2);
        l.in(2, 64 * MiB, 2 * MiB, 0, 60000, 2);           // 1 MiB arrived: progress
        auto stuck = l.stalled(STALL_MS, STALL_MS);
        check("a trickled inbound frame is stalled", has(stuck, 1));
        check("an inbound frame arriving for real is not", !has(stuck, 2));
    }

    // Recipients: at most N per block and M per share, in walk order.
    {
        Limits lim = limits_for(MIN_LIMIT);
        lim.block_recipients = 2;
        lim.share_recipients = 3;
        Recipients r(lim);
        check("a block's first recipient counts", r.take("a", 1));
        check("its second too", r.take("a", 1));
        check("its third does not", !r.take("a", 1));
        check("another block of the same share counts", r.take("b", 1));
        check("but the share's fourth does not", !r.take("c", 1));
        check("another share is untouched", r.take("c", 2));
    }

    // Inbound: a finished message is progress even when the next partial frame is no
    // bigger (an honest stream of small messages on a slow link is never stalled).
    {
        Ledger64 l;
        l.limits = limits_for(1000 * MiB, true);
        for (int i = 0; i <= 130; i++) {
            l.in(1, 60 * 1024, 30 * 1024, static_cast<uint64_t>(i), i * 1000, 1);  // one message a second
            l.in(2, 60 * 1024, 30 * 1024, 0, i * 1000, 2);                          // the same frame, held
        }
        auto stuck = l.stalled(130000, STALL_MS);
        check("a socket finishing messages is not stalled", !has(stuck, 1));
        check("a partial frame that never finishes or grows is", has(stuck, 2));
    }

    // H1: eviction takes the LEAST RECENTLY DRAINED socket of the heaviest other share,
    // and keeps evicting until the fan-out fits; a share whose socket drained keeps it.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 100, 0, 1);   // honest
        l.out(2, 200, 0, 9);   // hog, older
        l.out(3, 200, 1, 9);
        l.out(4, 200, 2, 9);
        l.out(2, 50, 3, 9);    // 2 really drains: now the most recently drained of its share
        std::vector<uint64_t> closed;
        auto close = [&](const uint64_t& k) { closed.push_back(k); };
        // total 550; 550 + 700 > 1000: two hog sockets must go (3 then 4).
        check("a fan-out needing two evictions passes", l.admit(700, 1, 1, close) == Admit::Pass);
        check("the hog's least recently drained sockets go first", closed.size() == 2 && closed[0] == 3 && closed[1] == 4);
        check("the hog's socket that drained stays", l.holds(2));
        check("the honest socket stays", l.holds(1));
    }

    // H1: when the sender alone holds its share's bytes and that share holds the most, the
    // sender trips and nothing else is closed (a lighter share never pays for the heaviest).
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 400, 0, 7);  // the sender's share
        l.out(2, 300, 0, 3);  // a lighter share
        std::vector<uint64_t> closed;
        auto close = [&](const uint64_t& k) { closed.push_back(k); };
        check("the sender whose own share is heaviest trips", l.admit(400, 1, 7, close) == Admit::Trip);
        check("and no other share's socket is closed", closed.empty() && l.holds(2));
        check("another sender evicts the heaviest share instead", l.admit(400, 2, 3, close) == Admit::Pass &&
                                                                     closed.size() == 1 && closed[0] == 1);
    }

    // Review 2: when the heaviest share is the sender's own but its bytes sit on other
    // sockets of that address, tripping the sender frees nothing and it would trip again
    // on every resume: those sockets give way first, least progressed first, never the
    // sender. A sender that is itself its share's least progressed socket trips (its close
    // frees what it holds) and its co-tenant stays.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 400, 0, 7);  // a co-tenant of the sender's address, not reading
        l.out(2, 300, 0, 3);  // a lighter share
        std::vector<uint64_t> closed;
        auto close = [&](const uint64_t& k) { closed.push_back(k); };
        check("own_share_cotenant_evicted_before_sender_trips", l.admit(400, 9, 7, close) == Admit::Pass &&
                                                                     closed.size() == 1 && closed[0] == 1);
        check("(the lighter share keeps its socket)", l.holds(2));

        Ledger64 m;
        m.limits = limits_for(1000, true);
        m.out(1, 300, 0, 7);   // co-tenant, stale since t=0
        m.out(9, 100, 5, 7);   // the sender, buffering since t=5
        m.out(2, 250, 0, 3);
        std::vector<uint64_t> gone;
        auto drop = [&](const uint64_t& k) { gone.push_back(k); };
        check("a sender holding bytes evicts its staler co-tenant, never itself",
              m.admit(500, 9, 7, drop) == Admit::Pass && gone.size() == 1 && gone[0] == 1 && m.holds(9));

        Ledger64 n;
        n.limits = limits_for(1000, true);
        n.out(9, 300, 0, 7);   // the sender, stale since t=0
        n.out(1, 100, 5, 7);   // co-tenant, buffering since t=5
        n.out(2, 250, 0, 3);
        std::vector<uint64_t> none;
        auto keep = [&](const uint64_t& k) { none.push_back(k); };
        check("a sender that is its share's least progressed socket trips; its co-tenant stays",
              n.admit(500, 9, 7, keep) == Admit::Trip && none.empty() && n.holds(1));
    }

    // Review 2, fix 1 under pressure: a share past its cap dooms its least progressed
    // socket (closed by the next sweep, never inside the fan-out) instead of refusing an
    // honest receiver that drains; the receiver is refused only when it is the least
    // progressed itself, and a doomed socket takes no more writes.
    {
        const uint64_t CARRIER = 7;
        Ledger64 l;
        l.limits = limits_for(default_limit(7ull * 1024 * MiB));  // share cap 224 MiB
        for (uint64_t s = 0; s < 4; s++) l.out(500 + s, 200 * MiB, 0, 50 + s);
        for (uint64_t k = 1; k <= 4; k++) l.out(k, 60 * MiB, 0, CARRIER);
        l.out(100, 400 * 1024, 0, CARRIER);
        l.out(100, 200 * 1024, 5000, CARRIER);  // a real drain
        check("(pressure, and the carrier share past its cap with the next write)",
              l.total() > l.limits.limit / 2 && l.held_by(CARRIER) + 256 * 1024 > l.limits.share_cap);
        check("pressed_share_dooms_stale_cotenant_not_receiver",
              l.write_fits(100, 200 * 1024, 256 * 1024 + FRAME_HEADER_BYTES, CARRIER));
        const auto doomed = l.doomed();
        check("(one stale co-tenant doomed, the receiver not)",
              doomed.size() == 1 && has(doomed, 1) && !has(doomed, 100));
        check("nothing is closed or forgotten inside the write", l.holds(1));
        check("a doomed socket takes no more writes", !l.write_fits(1, 60 * MiB, 1024, CARRIER));
        check("a second write to the receiver dooms no one more",
              l.write_fits(100, 456 * 1024, 1024, CARRIER) && l.doomed().size() == 1);

        Ledger64 m;
        m.limits = limits_for(default_limit(7ull * 1024 * MiB));
        for (uint64_t s = 0; s < 4; s++) m.out(500 + s, 200 * MiB, 0, 50 + s);
        m.out(100, 200 * 1024, 0, CARRIER);      // stale since t=0
        for (uint64_t k = 1; k <= 4; k++) m.out(k, 60 * MiB, 1000, CARRIER);
        check("pressed_share_refuses_the_least_progressed_receiver",
              !m.write_fits(100, 200 * 1024, 256 * 1024 + FRAME_HEADER_BYTES, CARRIER) && m.doomed().empty());
        check("an empty receiver's first frame always fits",
              m.write_fits(200, 0, 256 * 1024, CARRIER) && m.doomed().empty());
    }

    // A socket is as stale as the staler of what it holds: a fresh drain of its unsent
    // buffer does not hide an inbound frame that has not grown.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.limits.share_cap = 100;
        l.in(1, 150, 10, 0, 0, 7);        // inbound frame held since t=0
        l.out(1, 200, 0, 7);
        l.out(1, 50, 9000, 7);            // a real drain at t=9 s
        l.out(2, 100, 5000, 7);           // buffering since t=5 s
        for (uint64_t k = 3; k <= 5; k++) l.out(k, 99, 0, 5 + k);  // pressure, lighter shares
        auto over = l.over_budget();
        check("staler_held_buffer_ranks_the_socket", !over.empty() && over[0] == 1 && l.holds(2));
    }

    // A doomed socket stays doomed when its buffer empties (the sweep still closes it),
    // and a forgotten one is never chosen again.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 100, 0, 1);
        l.doom(1);
        l.out(1, 0, 10, 1);
        check("a doomed socket whose buffer empties stays doomed", has(l.doomed(), 1));
        l.out(2, 300, 0, 2);
        l.out(3, 300, 5, 2);
        l.forget(2);
        l.out(4, 450, 0, 4);
        l.out(5, 400, 0, 5);  // total 1150 > 1000
        auto over = l.over_budget();
        check("a forgotten socket is never chosen again", over.size() == 1 && over[0] == 4);
    }

    // Review 2: a key the ledger does not hold never throws in admit or the sweep.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);
        l.out(1, 600, 0, 1);
        l.forget(2);
        l.doom(3);
        auto never = [](const uint64_t&) {};
        bool threw = false;
        try {
            l.admit(600, 3, 2, never);
            l.over_budget();
            l.write_fits(3, 10, 10, 2);
        } catch (...) {
            threw = true;
        }
        check("ledger_lookups_never_throw", !threw);
    }

    // M1: a stranger piles 50 sockets from one block into the room. The prediction counts
    // two of them, so the honest frame passes; the delivery holds the uncounted ones to
    // the budget itself and refuses them receiver-side, and every honest recipient (walked
    // LAST) still gets the frame.
    {
        Ledger64 l;
        l.limits = limits_for(1000, true);  // two per block
        l.limits.share_recipients = 3;
        struct Sim {
            uint64_t key;
            std::string block;
            uint64_t share;
            bool reaches;
        };
        std::vector<Sim> room;
        for (uint64_t k = 0; k < 50; k++) room.push_back({100 + k, "stranger", 99, true});
        room.push_back({1, "a", 1, true});
        room.push_back({2, "b", 2, true});
        room.push_back({3, "c", 3, true});
        room.push_back({4, "d", 4, false});  // not in the audience
        const uint64_t per_copy = 100;
        auto reaches = [](const Sim& p) -> std::optional<std::pair<std::string, uint64_t>> {
            if (!p.reaches) return std::nullopt;
            return std::make_pair(p.block, p.share);
        };
        const uint64_t predicted = predict(room, per_copy, l.limits, reaches);
        check("the prediction counts two strangers and the three honest", predicted == 5 * (per_copy + FRAME_HEADER_BYTES));
        std::vector<uint64_t> closed;
        auto close = [&](const uint64_t& k) { closed.push_back(k); };
        check("so the honest frame passes", l.admit(predicted, 999, 5, close) == Admit::Pass);
        Recipients delivery(l.limits, predicted);
        std::vector<uint64_t> got, refused;
        for (const auto& p : room) {
            if (!p.reaches) continue;
            if (l.write_ok(p.key, 0, per_copy + FRAME_HEADER_BYTES, p.share, &delivery, p.block)) {
                l.out(p.key, per_copy + FRAME_HEADER_BYTES, 0, p.share);
                got.push_back(p.key);
            } else {
                refused.push_back(p.key);
            }
        }
        check("every honest recipient gets the frame", has(got, 1) && has(got, 2) && has(got, 3));
        check("strangers past the count are refused receiver-side", !refused.empty() && !has(refused, 1));
        check("and the uncounted ones never take the box past the budget", l.total() <= l.limits.limit);
        check("an uncounted recipient goes out while the budget holds it", got.size() > 5);
    }

    // The prediction skips peers the delivery would skip and counts per block and share.
    {
        Limits lim = limits_for(MIN_LIMIT);
        lim.block_recipients = 1;
        lim.share_recipients = 2;
        std::vector<std::pair<std::string, uint64_t>> peers = {{"a", 1}, {"a", 1}, {"b", 1}, {"c", 1}, {"", 0}, {"d", 2}};
        auto reaches = [](const std::pair<std::string, uint64_t>& p) -> std::optional<std::pair<std::string, uint64_t>> {
            if (p.first.empty()) return std::nullopt;
            return p;
        };
        check("one copy per block, two per share, none for a skipped peer",
              predict(peers, 10, lim, reaches) == 3 * (10 + FRAME_HEADER_BYTES));
    }

    // C1: the text msg plan runs outside the handler's try, so a field of the wrong type
    // must never throw (it would kill the relay without a snapshot).
    {
        auto plan_ok = [](const char* text, bool want_fields) {
            const nlohmann::json j = client_json::parse(text);
            try {
                return msg_plan::fields(j).has_value() == want_fields;
            } catch (const std::exception&) {
                return false;
            }
        };
        check("msg_plan_room_number_does_not_throw", plan_ok("{\"type\":\"msg\",\"room\":1}", false));
        check("msg_plan_data_object_does_not_throw", plan_ok("{\"type\":\"msg\",\"room\":\"r\",\"data\":{}}", false));
        check("a msg without a room does not throw", plan_ok("{\"type\":\"msg\",\"data\":\"x\"}", false));
        check("a null data does not throw", plan_ok("{\"type\":\"msg\",\"room\":\"r\",\"data\":null}", false));
        check("a JSON array does not throw", plan_ok("[1,2]", false));
        check("unparseable text does not throw", plan_ok("{\"type\":", false));
        check("a well-formed msg is read", plan_ok("{\"type\":\"msg\",\"room\":\"r\",\"data\":\"x\"}", true));
        check("a msg without data reads as empty", plan_ok("{\"type\":\"msg\",\"room\":\"r\"}", true));
        const nlohmann::json j = client_json::parse("{\"type\":\"msg\",\"room\":\"rm\",\"data\":\"hello\"}");
        const auto f = msg_plan::fields(j);
        check("its room and data", f && *f->room == "rm" && f->data == "hello");
    }

    // L2: the predicted copy is the size of the frame the relay builds and sends.
    {
        const std::vector<std::string> texts = {"", "plain", "q\"uote", "back\\slash", "nl\nret\rtab\tbs\bff\f",
                                                std::string("ctl\x01\x1f\x7f", 6), "utf8 \xc5\xbc\xc3\xb3\xc5\x82w \xf0\x9f\x99\x82",
                                                std::string(3000, 'z')};
        bool msg_exact = true;
        for (const auto& room : texts) {
            for (const auto& data : texts) {
                const nlohmann::json out = {{"type", "msg"}, {"room", room}, {"from", "12D3KooWpeer"}, {"data", data}};
                msg_exact = msg_exact && msg_plan::out_size(room, "12D3KooWpeer", data) == out.dump().size();
            }
        }
        check("a msg copy's predicted size is its dumped size, escapes included", msg_exact);
        const std::string b = binary_frame::out_frame(0x05, {"room", "sender"}, "payload");
        check("a broadcast copy is [0x05][room\\0][sender\\0][payload]",
              b == std::string("\x05room\0sender\0payload", 20));
        check("and its predicted size is its built size", binary_frame::out_frame_size({"room", "sender"}, "payload") == b.size());
        const std::string t = binary_frame::out_frame(0x08, {"room", "topic", "sender"}, std::string(70000, 'p'));
        check("a topic copy is [0x08][room\\0][topic\\0][sender\\0][payload]",
              t.compare(0, 19, std::string("\x08room\0topic\0sender\0", 19)) == 0 && t.size() == 19 + 70000);
        check("and its predicted size is its built size",
              binary_frame::out_frame_size({"room", "topic", "sender"}, std::string(70000, 'p')) == t.size());
    }

    // L4: what /server-stats publishes is the budget's use in whole tens of percent.
    {
        check("an idle budget reads 0", used_pct(0, 1000) == 0);
        check("19 percent reads 10", used_pct(190, 1000) == 10);
        check("a full budget reads 100", used_pct(1000, 1000) == 100);
        check("past the budget still reads 100", used_pct(1300, 1000) == 100);
        check("an unset budget reads 0", used_pct(5, 0) == 0);
    }

    // Review 2, flaw 1: phones behind one carrier address (CGNAT v4, a mobile v6 /48)
    // share it with a stranger who holds most of the share's cap. While the box has room
    // the share cap never refuses the honest phone's next write.
    {
        const uint64_t CARRIER = 7;
        Ledger64 l;
        l.limits = limits_for(default_limit(7ull * 1024 * MiB));  // the real box, ~1.75 GiB
        for (uint64_t k = 1; k <= 4; k++) l.out(k, 60 * MiB, 0, CARRIER);
        l.out(100, 200 * 1024, 0, CARRIER);  // honest phone mid catch-up
        check("(the box holds well under its budget)", l.total() < l.limits.limit / 6);
        check("honest_cotenant_write_fits_when_box_has_room",
              l.write_fits(100, 200 * 1024, 256 * 1024 + FRAME_HEADER_BYTES, CARRIER));
        check("and the sweep closes no one on that share", l.over_budget().empty());
    }

    // Review 2, flaw 2: a socket that drains a byte now and then is no more recent than
    // one that has not drained at all, so it cannot push an honest co-tenant ahead of
    // itself in the victim order. Four other shares put the box under pressure.
    {
        const uint64_t CARRIER = 7;
        Ledger64 l;
        l.limits = limits_for(default_limit(7ull * 1024 * MiB));
        for (uint64_t s = 0; s < 4; s++) l.out(500 + s, 200 * MiB, 0, 50 + s);
        l.out(100, 2 * MiB, 0, CARRIER);  // honest slow phone, last drain at t=0
        for (uint64_t k = 1; k <= 4; k++) l.out(k, 61 * MiB, 0, CARRIER);
        for (uint64_t k = 1; k <= 4; k++) l.out(k, 61 * MiB - 1, 1000, CARRIER);  // 1 byte each
        l.out(1, 64 * MiB, 1000, CARRIER);  // share now over its cap
        check("(the box is under pressure)", l.total() > l.limits.limit / 2);
        auto closed = l.over_budget();
        check("(the sweep closes something)", !closed.empty());
        check("over_budget_evicts_the_byte_trickler_before_the_honest_phone",
              !closed.empty() && !has(closed, 100));
    }

    // Victim order follows the last REAL drain: the honest phone drained 1 MiB at t=5 s,
    // the strangers only trickle bytes later on, so a stranger goes first.
    {
        const uint64_t CARRIER = 7;
        Ledger64 l;
        l.limits = limits_for(default_limit(7ull * 1024 * MiB));
        for (uint64_t s = 0; s < 4; s++) l.out(500 + s, 200 * MiB, 0, 50 + s);
        l.out(100, 3 * MiB, 0, CARRIER);
        for (uint64_t k = 1; k <= 4; k++) l.out(k, 61 * MiB, 0, CARRIER);
        l.out(100, 2 * MiB, 5000, CARRIER);  // a real drain
        for (int64_t t = 6000; t <= 50000; t += 1000) {
            for (uint64_t k = 1; k <= 4; k++) l.out(k, 61 * MiB - static_cast<uint64_t>(t / 1000), t, CARRIER);
        }
        l.out(1, 64 * MiB, 50000, CARRIER);
        auto closed = l.over_budget();
        check("victim_order_ignores_byte_trickles", !closed.empty() && !has(closed, 100) && l.holds(100));
    }

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
