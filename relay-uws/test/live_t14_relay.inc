// 0.14 relay track (included by test_relay_live.cpp before main): batched presence, the
// short `members` answer, the visibility rule both ways, the connection limits as
// settings, the pre-login window, the connected budget and the breaker's mode.

// What a batching client keeps of one room, in the order it reads frames: `peer_joined`,
// `peer_left`, `presence` batches and both forms of `members` (ws_client's audit record).
struct Seen {
    std::string me;
    std::set<std::string> told;
    // "+id" / "-id" per change, "M" a full members, "S" a short one that matched, "X" one that did not.
    std::vector<std::string> events;
    size_t batches = 0;

    void apply(const json& j) {
        const std::string t = j.value("type", "");
        if (t == "members") {
            if (j.contains("digest")) {
                presence::Digest d;
                for (const auto& p : told) d.add(presence::tag(p));
                const bool same = j.value("digest", uint64_t{0}) == d.sum && j.value("count", uint64_t{0}) == d.count;
                events.push_back(same ? "S" : "X");
                return;
            }
            told = peers_of(j);
            told.erase(me);
            events.push_back("M");
        } else if (t == "peer_joined") {
            told.insert(j.value("peer_id", ""));
            events.push_back("+" + j.value("peer_id", ""));
        } else if (t == "peer_left") {
            told.erase(j.value("peer_id", ""));
            events.push_back("-" + j.value("peer_id", ""));
        } else if (t == "presence") {
            batches++;
            for (const auto& e : j.value("ev", json::array())) {
                const std::string s = e.is_string() ? e.get<std::string>() : std::string();
                if (s.size() < 2) continue;
                if (s[0] == '+') told.insert(s.substr(1));
                if (s[0] == '-') told.erase(s.substr(1));
                events.push_back(s);
            }
        }
    }
};

// Everything `p` holds for `room` after a round trip, applied in order; other frames stay.
static void read_room(Peer& p, Seen& seen, const std::string& room) {
    sync(p);
    for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end();) {
        auto j = as_json(*it);
        if (j && j->value("room", "") == room) {
            seen.apply(*j);
            it = p.ws.inbox.erase(it);
        } else {
            ++it;
        }
    }
}

// Reads `p`'s frames for `room` in order until its next `members` (inclusive).
static bool read_to_members(Peer& p, Seen& seen, const std::string& room, int timeout_ms = WAIT_MS) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end();) {
            auto j = as_json(*it);
            if (j && j->value("room", "") == room) {
                seen.apply(*j);
                const bool done = j->value("type", "") == "members";
                it = p.ws.inbox.erase(it);
                if (done) return true;
            } else {
                ++it;
            }
        }
        if (left_ms(deadline) <= 0 || !p.ws.pump(left_ms(deadline))) return false;
    }
}

static size_t index_of(const std::vector<std::string>& v, const std::string& x) {
    for (size_t i = 0; i < v.size(); i++) {
        if (v[i] == x) return i;
    }
    return v.size();
}

static const json PV2 = {{"pv", 2}};
static const json PV2_HAVE = {{"pv", 2}, {"have", true}};

// A batching viewer `v` joins `room` and is left reading it from a quiet window.
static std::unique_ptr<Peer> batching_viewer(Seen& seen, const std::string& room, Ident id = Ident()) {
    auto v = login3(id, "new", 0);
    seen.me = id.peer;
    if (auto m = join(*v, room, PV2)) seen.apply(*m);
    return v;
}

static void quiet_window() { sleep_ms(static_cast<int>(presence_batch::WINDOW_MS) + 60); }

static void presence_batch_coalesces() {
    printf("presence batches: joins inside one window reach a batching viewer together, in order\n");
    const std::string room = room_name("batch");
    Seen seen;
    auto v = batching_viewer(seen, room);
    auto legacy = login(Ident());
    join(*legacy, room);
    read_room(*v, seen, room);
    quiet_window();
    std::vector<std::unique_ptr<Peer>> js;
    for (int i = 0; i < 20; i++) js.push_back(login(Ident()));
    sync(*legacy);
    legacy->ws.inbox.clear();
    for (auto& j : js) j->send({{"type", "join"}, {"room", room}});
    for (auto& j : js) next(*j, typed("members", room));
    quiet_window();
    const size_t before = seen.batches;
    read_room(*v, seen, room);
    std::set<std::string> want;
    for (auto& j : js) want.insert(j->id.peer);
    std::set<std::string> plus;
    size_t n_plus = 0;
    for (const auto& e : seen.events) {
        if (e[0] == '+' && want.count(e.substr(1))) {
            plus.insert(e.substr(1));
            n_plus++;
        }
    }
    check("every join reaches the batching viewer once", plus == want && n_plus == 20);
    check("in at most three frames", seen.batches - before <= 3 && seen.batches - before >= 1);
    sync(*legacy);
    check("a viewer that did not ask for batches gets a frame per join", count(*legacy, typed("peer_joined", room)) == 20);
}

static void presence_batch_subject_first() {
    printf("presence batches: nobody hears from a device before hearing it came\n");
    const std::string room = room_name("subject");
    Seen seen;
    auto v = batching_viewer(seen, room);
    auto y = login(Ident());
    auto j = login(Ident());
    quiet_window();
    join(*y, room);  // flushes at once and opens a window
    j->send({{"type", "join"}, {"room", room}});
    j->send_bin(frame(0x03, {room}, "subject-bcast"));
    sleep_ms(300);
    sync(*v);
    size_t at_join = v->ws.inbox.size(), at_bcast = v->ws.inbox.size(), i = 0;
    for (const auto& f : v->ws.inbox) {
        if (f.text && f.data.find("+" + j->id.peer) != std::string::npos && at_join == v->ws.inbox.size()) at_join = i;
        if (!f.text && f.data.find("subject-bcast") != std::string::npos) at_bcast = i;
        i++;
    }
    check("the viewer reads the device's arrival before its broadcast",
          at_join < v->ws.inbox.size() && at_bcast < v->ws.inbox.size() && at_join < at_bcast);
}

// Review F1: a short answer is judged by the client at read time, and nothing the relay
// logged before it is left unsent, so a roster with the right count can never be wrong.
static void presence_short_answer_after_midflight_batch() {
    printf("presence: a short answer after batches in flight matches what the viewer was told\n");
    const std::string room = room_name("midflight");
    Seen seen;
    auto v = batching_viewer(seen, room);
    Ident ida, idc;
    auto a = login(ida);
    join(*a, room);
    auto c = login(idc);
    quiet_window();
    a->send({{"type", "leave"}, {"room", room}});
    sync(*a);
    join(*c, room);
    quiet_window();
    read_room(*v, seen, room);
    check("(the viewer was told the room as it is: C)", seen.told == std::set<std::string>{idc.peer});
    quiet_window();
    auto x = login(Ident());
    join(*x, room);  // flushes at once and opens a window
    c->send({{"type", "leave"}, {"room", room}});
    sync(*c);
    join(*a, room);
    v->send({{"type", "join"}, {"room", room}, {"pv", 2}, {"have", true}});
    check("(the answer came)", read_to_members(*v, seen, room));
    check("it is short and matches what the viewer read before it", !seen.events.empty() && seen.events.back() == "S");
    check("which is the room as it is", seen.told == (std::set<std::string>{ida.peer, x->id.peer}));
}

// Review F2: a device back on a fresh session is announced to a viewer before any
// `members` that viewer is sent, so its client still ends what it streamed to the old one.
static void presence_batch_fresh_session_survives_viewer_rejoin() {
    printf("presence: a fresh session's arrival reaches a viewer before its own re-join answer\n");
    const std::string room = room_name("fresh-rejoin");
    Seen seen;
    auto v = batching_viewer(seen, room);
    Ident idj;
    auto j1 = login3(idj, "new", 0);
    join(*j1, room);
    auto x = login(Ident());
    read_room(*v, seen, room);
    quiet_window();
    join(*x, room);  // flushes at once and opens a window
    auto j2 = login3(idj, "new", 0);
    j2->send({{"type", "join"}, {"room", room}});
    next(*j2, typed("members", room));
    v->send({{"type", "join"}, {"room", room}, {"pv", 2}, {"have", true}});
    check("(the answer came)", read_to_members(*v, seen, room));
    const size_t plus = index_of(seen.events, "+" + idj.peer);
    const size_t last_plus = [&] {
        size_t at = seen.events.size();
        for (size_t i = 0; i < seen.events.size(); i++) {
            if (seen.events[i] == "+" + idj.peer) at = i;
        }
        return at;
    }();
    const std::string answer = seen.events.empty() ? "" : seen.events.back();
    check("the viewer reads the device come again before its answer",
          plus < seen.events.size() && last_plus > index_of(seen.events, "+" + x->id.peer) &&
              last_plus + 2 == seen.events.size() && (answer == "S" || answer == "M"));
    (void)j1;
}

static void presence_short_answer() {
    printf("presence: which re-joins get the short answer\n");
    const std::string room = room_name("short");
    Seen seen;
    auto v = batching_viewer(seen, room);
    auto a = login(Ident());
    join(*a, room);
    read_room(*v, seen, room);
    auto m = join(*v, room, PV2_HAVE);
    check("a batching socket holding a view gets the digest, not the roster",
          m && m->contains("digest") && !m->contains("peers") && m->value("count", 0) == 1 &&
              m->value("digest", uint64_t{0}) == presence::tag(a->id.peer));
    m = join(*v, room, PV2);
    check("without have it gets the roster", m && peers_of(*m) == (std::set<std::string>{a->id.peer, seen.me}));
    auto l = login(Ident());
    join(*l, room);
    m = join(*l, room, PV2_HAVE);
    check("a socket whose first join chose frames keeps getting the roster", m && m->contains("peers"));
    auto n = login(Ident());
    m = join(*n, room, PV2_HAVE);
    check("a socket new to the room gets the roster", m && m->contains("peers") && !m->contains("digest"));
    m = join(*v, room, {{"pv", "2"}, {"have", "yes"}});
    check("fields of the wrong type read as absent", m && m->contains("peers"));
    v->send({{"type", "inactive"}});
    m = join(*v, room, PV2_HAVE);
    check("an inactive socket gets the roster", m && m->contains("peers") && !m->contains("digest"));
}

// Review F5: a digest never runs ahead of the batches the socket was sent.
static void presence_digest_after_batch() {
    printf("presence: an audit inside a window reads the same as what was sent\n");
    const std::string room = room_name("digest-batch");
    Ident idv;
    auto v = login3(idv, "new", 0);
    Told told{idv.peer, {}, 0};
    told_join(*v, room, PV2);
    auto x = login(Ident());
    auto y = login(Ident());
    check("(joined)", audit(*v, told, room) == Audit::Same);
    quiet_window();
    join(*x, room);
    join(*y, room);
    check("an audit right after a held change finds nothing to re-join for", audit(*v, told, room) == Audit::Same);
    std::set<std::string> want{x->id.peer, y->id.peer};
    check("and the viewer knows both", told.rooms[room] == want);
}

// The Told model of the digest tests reads batches too.
static void presence_batch_inactive_withheld() {
    printf("presence: a batch for an inactive session waits for its `active`\n");
    const std::string room = room_name("batch-inactive");
    Seen seen;
    Ident idv;
    auto v = batching_viewer(seen, room, idv);
    v->send({{"type", "inactive"}});
    sync(*v);
    auto a = login(Ident());
    join(*a, room);
    quiet_window();
    sync(*v);
    check("nothing reaches it while it is inactive", count(*v, typed("presence", room)) == 0);
    // Its own re-join's answer gives it a place in the next window: the per-viewer slice.
    auto x = login(Ident());
    auto y = login(Ident());
    auto z = login(Ident());
    quiet_window();
    join(*x, room);  // flushes at once and opens a window
    join(*y, room);  // waits in the window, so the re-join below stamps the viewer
    join(*v, room, PV2);
    join(*z, room);
    quiet_window();
    sync(*v);
    check("nor while it holds a place of its own in a window", count(*v, typed("presence", room)) == 0);
    v->send({{"type", "active"}});
    auto m = next_json(*v, typed("members", room));
    check("its active answers the room with who is there", m && peers_of(*m).count(a->id.peer));
}

static void presence_batch_split_256() {
    printf("presence batches: a long window is several frames of at most 256 changes\n");
    const std::string room = room_name("batch-256");
    Seen seen;
    auto v = batching_viewer(seen, room);
    std::vector<std::unique_ptr<Peer>> js;
    for (int i = 0; i < 300; i++) js.push_back(login(Ident()));
    quiet_window();
    for (auto& j : js) j->send({{"type", "join"}, {"room", room}});
    for (auto& j : js) next(*j, typed("members", room));
    quiet_window();
    sync(*v);
    size_t biggest = 0, events = 0;
    for (auto it = v->ws.inbox.begin(); it != v->ws.inbox.end(); ++it) {
        auto j = as_json(*it);
        if (!j || j->value("type", "") != "presence" || j->value("room", "") != room) continue;
        biggest = std::max(biggest, j->value("ev", json::array()).size());
        events += j->value("ev", json::array()).size();
    }
    check("no frame carries more than 256", biggest > 0 && biggest <= 256);
    check("and none is lost", events == 300);
}

static void presence_batch_leading_edge_latency() {
    printf("presence batches: an isolated join is told at once\n");
    const std::string room = room_name("batch-edge");
    Seen seen;
    auto v = batching_viewer(seen, room);
    auto j = login(Ident());
    quiet_window();
    const auto t0 = std::chrono::steady_clock::now();
    j->send({{"type", "join"}, {"room", room}});
    auto f = next_json(*v, typed("presence", room), 1000);
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    printf("       told after %lld ms\n", static_cast<long long>(ms));
    check("well inside the window", f && ms < presence_batch::WINDOW_MS / 2);
}

// The visibility rule both ways (review F12): an inbox socket that becomes an owner is
// announced, and one whose re-shown roster no longer counts it is announced gone.
static void presence_inbox_visibility_both_ways() {
    printf("presence: an inbox socket is announced when it starts or stops being an owner\n");
    Ident master, d1, d2;
    const std::string room = "inbox:" + master.peer;
    const json roster = legacy_roster(master, {&d1, &d2});
    auto o1 = login(d1);
    join(*o1, room, {{"inbox_roster", roster}});
    auto o2 = login(d2);
    join(*o2, room);
    settle({o2.get(), o1.get()});
    check("(a plain join is announced to nobody)", !got(*o1, about("peer_joined", room, d2.peer)));
    join(*o2, room, {{"inbox_roster", roster}});
    check("the same socket showing a roster that counts it is announced",
          next(*o1, about("peer_joined", room, d2.peer)).has_value());
    join(*o2, room, {{"inbox_roster", json{{"not", "a roster"}}}});
    check("re-showing one that proves nothing is announced as a leave",
          next(*o1, about("peer_left", room, d2.peer)).has_value());
    join(*o2, room);
    settle({o2.get(), o1.get()});
    check("and a plain re-join after it stays silent", !got(*o1, about("peer_joined", room, d2.peer)));
}

// Review F4: the fold's own demotion rides the room's log, so it never overtakes a
// batched arrival of the same device.
static void presence_batch_inbox_demotion_after_upgrade() {
    printf("presence batches: a demotion never overtakes the device's batched arrival\n");
    Ident master, d1, d2, d3;
    const std::string room = "inbox:" + master.peer;
    const json roster = legacy_roster(master, {&d1, &d2, &d3});
    Seen seen;
    seen.me = d1.peer;
    auto o1 = login(d1);
    if (auto m = join(*o1, room, {{"inbox_roster", roster}, {"pv", 2}})) seen.apply(*m);
    auto o2 = login(d2);
    auto o3 = login(d3);
    join(*o2, room);
    join(*o3, room);
    quiet_window();
    join(*o3, room, {{"inbox_roster", roster}});  // flushes at once and opens a window
    join(*o2, room, {{"inbox_roster", roster}});  // held
    join(*o1, room, {{"inbox_roster", roster_removing(master, {&d1, &d2, &d3}, d2, d1)}, {"pv", 2}});
    quiet_window();
    read_room(*o1, seen, room);
    check("the owner reads the device come and go, in that order",
          index_of(seen.events, "+" + d2.peer) < index_of(seen.events, "-" + d2.peer) &&
              index_of(seen.events, "-" + d2.peer) < seen.events.size());
    check("and no longer lists it", !seen.told.count(d2.peer) && seen.told.count(d3.peer));
}

// The pin of 1a: after a lock move every member re-joins with the new door on the socket that
// holds its slot, and nobody is told it came, batching or not.
static void presence_rejoin_same_socket_is_quiet_after_lock_move() {
    printf("presence: re-joins with the new door after a lock move announce nothing\n");
    Ident owner, change, change2, idv;
    Door door, door2;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    const json base = base_link(room, door, change, owner, nonce, true);
    Seen seen;
    seen.me = idv.peer;
    auto v = login3(idv, "new", 0);
    v->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", base}});
    next(*v, typed("lock_chain"));
    if (auto m = join(*v, room, {{"door_proof", door_proof(*v, room, door)}, {"pv", 2}})) seen.apply(*m);
    auto legacy = login(Ident());
    join(*legacy, room, {{"door_proof", door_proof(*legacy, room, door)}});
    auto a = login(Ident());
    join(*a, room, {{"door_proof", door_proof(*a, room, door)}});
    quiet_window();
    read_room(*v, seen, room);
    check("(both provers were announced)", seen.told == (std::set<std::string>{legacy->id.peer, a->id.peer}));
    json links = base;
    links.push_back(successor_link(room, 2, door2, change2, change, owner));
    v->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", links}});
    auto put = next_json(*v, typed("lock_chain"));
    check("(the lock moves)", put && put->value("put", false));
    sync(*legacy);
    legacy->ws.inbox.clear();
    const size_t mark = seen.events.size();
    auto ma = join(*a, room, {{"door_proof", door_proof(*a, room, door2)}});
    check("a member re-joins with the new door on its old socket", ma && ma->value("proved", false));
    join(*legacy, room, {{"door_proof", door_proof(*legacy, room, door2)}});
    auto mv = join(*v, room, {{"door_proof", door_proof(*v, room, door2)}, {"pv", 2}, {"have", true}});
    check("a batching member's own re-join is answered short", mv && mv->contains("digest") && !mv->contains("peers"));
    if (mv) seen.apply(*mv);
    quiet_window();
    read_room(*v, seen, room);
    bool announced = false;
    for (size_t i = mark; i < seen.events.size(); i++) announced |= seen.events[i][0] == '+' || seen.events[i][0] == '-';
    check("a batching member is told of no re-join", !announced && seen.events.back() == "S");
    sync(*legacy);
    check("nor is a member that takes a frame per arrival",
          count(*legacy, typed("peer_joined", room)) == 0 && count(*legacy, typed("peer_left", room)) == 0);
}

// A viewer that joins while a window is open is sent nothing its roster already covered.
static void presence_batch_join_mid_window() {
    printf("presence batches: a viewer joining mid-window gets no event from before its join\n");
    const std::string room = room_name("midwin");
    Seen sv, sw;
    auto v = batching_viewer(sv, room);
    auto x = login(Ident());
    auto y = login(Ident());
    Ident idw;
    auto w = login3(idw, "new", 0);
    sw.me = idw.peer;
    read_room(*v, sv, room);
    quiet_window();
    join(*x, room);  // flushes at once and opens a window
    join(*y, room);
    if (auto m = join(*w, room, PV2)) sw.apply(*m);
    check("the late joiner's roster lists the arrival still in the window", sw.told.count(y->id.peer) == 1);
    quiet_window();
    read_room(*w, sw, room);
    check("and it is sent no batch naming it", index_of(sw.events, "+" + y->id.peer) == sw.events.size());
    read_room(*v, sv, room);
    check("an earlier viewer is told of both arrivals, in order",
          index_of(sv.events, "+" + y->id.peer) < index_of(sv.events, "+" + idw.peer) &&
              index_of(sv.events, "+" + idw.peer) < sv.events.size());
}

// A forwarder's room is pairwise: every viewer keeps a frame per arrival, batching or not.
static void presence_batch_fwd_room_legacy() {
    printf("presence batches: a forwarder's room keeps a frame per arrival\n");
    Ident idx;
    auto x = login3(idx, "new", 0);
    const std::string room = "fwd:" + idx.peer;
    join(*x, room, PV2);
    quiet_window();
    std::vector<std::unique_ptr<Peer>> viewers;
    for (int i = 0; i < 5; i++) viewers.push_back(login(Ident()));
    for (auto& a : viewers) join(*a, room);
    quiet_window();
    sync(*x);
    check("the forwarder gets a peer_joined per viewer", count(*x, typed("peer_joined", room)) == 5);
    check("and no batch", count(*x, typed("presence", room)) == 0);
}

// Review F10c (RELAY_LIVE_ONLY=breaker_enforce): the subject flush a device's frame sets off
// writes other devices' arrivals to every viewer, and none of that is charged to the device.
static void presence_batch_flush_charges_nobody_else() {
    printf("breaker (enforced): a presence flush set off by a device's frame is charged to nobody\n");
    const std::string room = room_name("brk-flush");
    std::vector<std::unique_ptr<Peer>> viewers, crowd;
    for (int i = 0; i < 8; i++) {
        viewers.push_back(login3(Ident(), "new", 0));
        join(*viewers.back(), room, PV2);
    }
    for (int i = 0; i < 40; i++) crowd.push_back(login(Ident()));
    Ident idj;
    auto j = login3(idj, "new", 0);
    quiet_window();
    for (auto& c : crowd) c->send({{"type", "join"}, {"room", room}});
    j->send({{"type", "join"}, {"room", room}});
    next(*j, typed("members", room));
    const int64_t s0 = spent_of(idj.peer);
    j->send_bin(frame(0x03, {room}, "flush-1"));
    sync(*j);
    const int64_t storm = spent_of(idj.peer) - s0;
    quiet_window();
    const int64_t s1 = spent_of(idj.peer);
    j->send_bin(frame(0x03, {room}, "flush-2"));
    sync(*j);
    const int64_t quiet = spent_of(idj.peer) - s1;
    sync(*viewers.front());
    check("(the viewers read the crowd's arrivals)", count(*viewers.front(), typed("presence", room)) >= 1);
    check("the frame that set off the flush cost what the same frame costs in a quiet room",
          s0 >= 0 && storm == quiet && quiet > 0);
}

// The section 52 follow-up: a device whose reconnect hint was lost is told the wait at login.
static void breaker_lost_hint_waits_at_login() {
    printf("breaker (enforced): a device that lost its hint is told the wait when it logs in\n");
    const std::string room = room_name("brk-lost");
    Ident ida;
    auto a = login3(ida, "new", 0);
    auto b = login3(Ident(), "new", 0);
    join(*a, room);
    join(*b, room);
    flood(*a, room, "lh", 20'000);
    closed_by_relay(*a);
    a->ws.inbox.clear();  // the hint never reached the device
    auto again = login3(ida, a->sid, a->ws.counted);
    const int64_t wait = again->answer.value("after_ms", int64_t(0));
    check("its resume is answered with the wait it missed",
          again->answer.value("type", "") == "auth_failed" && again->answer.value("error", "") == "cooldown" && wait > 0);
    check("closed 1013, never 1008", closed_by_relay(*again) && again->ws.close_code == 1013);
    sleep_ms(static_cast<int>(wait) + 200);
    auto back = login3(ida, a->sid, a->ws.counted);
    check("after the wait it resumes", resumed(*back));
}

// --- Limits (conn_limits.h), with run_live.sh's test numbers: 3 sockets an address, ten new
// ones a minute with a burst of thirty.

static void limits_refuse_1008() {
    printf("limits: every refusal closes 1008 with its reason\n");
    {
        PinnedSource pin(60020);
        bool all_in = true;
        for (int i = 0; i < 30; i++) all_in = let_in_and_closed() && all_in;
        check("an address opens its burst of thirty, closing each", all_in);
        check("the next is refused 1008 rate_limit", refused_for_rate());
    }
    {
        PinnedSource pin(60021);
        auto x = login(Ident());
        auto y = login(Ident());
        auto z = login(Ident());
        check("past the cap a login that frees nothing of its own is refused 1008 ip_limit", refused_at_login(Ident()));
        std::vector<std::unique_ptr<Peer>> pending;
        for (int i = 0; i < 3; i++) {
            pending.push_back(open_socket(Ident()));
            pending.back()->send({{"type", "auth_hello"}});
        }
        bool challenged = true;
        for (auto& p : pending) challenged = next_json(*p, typed("auth_challenge")).has_value() && challenged;
        check("another cap's worth comes in to settle at login", challenged);
        auto over = open_socket(Ident());
        over->send({{"type", "auth_hello"}});
        check("past two caps a socket is refused 1008 ip_limit at once",
              closed_by_relay(*over) && over->ws.close_code == 1008 && over->ws.close_reason == "ip_limit");
    }
}

static void breaker_mode_named() {
    printf("breaker: the mode in force rides auth_ok\n");
    auto p = login3(Ident(), "new", 0);
    const char* want = getenv("RELAY_LIVE_BREAKER_MODE");
    const bool enforce = want && std::string(want) == "enforce";
    check(enforce ? "an enforcing relay says so" : "a shadow relay says nothing",
          p->ok && p->answer.value("enforced", false) == enforce);
}

// RELAY_LIVE_ONLY=window: LOGIN_WINDOW_PER_BLOCK=8, LOGIN_WINDOW_TOTAL=24 (run_live.sh).
static void login_window_stalled_first() {
    printf("login window: a stalled socket gives way, never a slow honest login\n");
    std::vector<std::unique_ptr<Peer>> silent;
    {
        PinnedSource pin(60030);  // 127.0.1.32: block 127.0.1.0/24
        for (int i = 0; i < 6; i++) silent.push_back(open_socket(Ident()));
    }
    sleep_ms(static_cast<int>(login_window::STALL_MS) + 300);
    // An honest login answering every 600 ms from another address of the block.
    std::unique_ptr<Peer> slow;
    {
        PinnedSource pin(60031);
        slow = open_socket(Ident());
    }
    std::vector<std::unique_ptr<Peer>> burst;
    {
        PinnedSource pin(60032);
        for (int i = 0; i < 3; i++) burst.push_back(open_socket(Ident()));
    }
    sleep_ms(600);
    slow->send({{"type", "auth_hello"}});
    auto ch = next_json(*slow, typed("auth_challenge"));
    check("the slow honest login is still in", ch.has_value());
    size_t closed = 0;
    for (auto& s : silent) {
        s->send({{"type", "auth_hello"}});
        if (closed_by_relay(*s) && s->ws.close_code == 1008 && s->ws.close_reason == "login_busy") closed++;
    }
    check("the block's stalled sockets gave way, closed 1008 login_busy", closed >= 1);
    bool burst_in = true;
    for (auto& b : burst) {
        b->send({{"type", "auth_hello"}});
        burst_in = next_json(*b, typed("auth_challenge")).has_value() && burst_in;
    }
    check("and every newcomer came in", burst_in);
}

// A login whose network takes seconds between its frames is not stalled: only five quiet
// seconds make an entry give way (login_window::STALL_MS), never one slow round trip.
static void login_window_slow_login_is_not_stalled() {
    printf("login window: a login quiet for 2.5 s keeps its place when its block fills\n");
    std::unique_ptr<Peer> slow;
    {
        PinnedSource pin(61750);  // 127.0.248.2: a block no other case uses
        slow = open_socket(Ident());
    }
    sleep_ms(2'500);
    std::vector<std::unique_ptr<Peer>> burst;
    {
        PinnedSource pin(61751);
        for (int i = 0; i < 10; i++) burst.push_back(open_socket(Ident()));
    }
    slow->send({{"type", "auth_hello"}});
    check("the slow login still gets its challenge", next_json(*slow, typed("auth_challenge")).has_value());
    for (auto& b : burst) b->send({{"type", "auth_hello"}});
    bool burst_in = true;
    for (auto& b : burst) burst_in = next_json(*b, typed("auth_challenge")).has_value() && burst_in;
    check("and so does every newcomer", burst_in);
}

static void login_window_total_heaviest_stalled() {
    printf("login window: past the total, stalled sockets go before a progressing pool\n");
    std::vector<std::unique_ptr<Peer>> silent;
    for (int b = 0; b < 4; b++) {
        PinnedSource pin(60250 + b * 250);  // four other /24s
        for (int i = 0; i < 5; i++) silent.push_back(open_socket(Ident()));
    }
    sleep_ms(static_cast<int>(login_window::STALL_MS) + 300);
    PinnedSource pin(60040);
    size_t honest_in = 0;
    std::vector<std::unique_ptr<Peer>> honest;
    for (int i = 0; i < 20; i++) {
        honest.push_back(open_socket(Ident()));
        honest.back()->send({{"type", "auth_hello"}});
    }
    for (auto& h : honest) honest_in += next_json(*h, typed("auth_challenge")).has_value() ? 1 : 0;
    check("every honest login of the pool came in", honest_in == honest.size());
}

// RELAY_LIVE_ONLY=connected: CONNECTED_LIMIT=12.
static void limits_connected_budget_sheds_heaviest() {
    printf("connected budget: past it the heaviest address gives way, and only it\n");
    std::vector<std::unique_ptr<Peer>> heavy, light;
    {
        PinnedSource pin(60050);
        for (int i = 0; i < 3; i++) heavy.push_back(login3(Ident(), "new", 0));
        for (int i = 0; i < 3; i++) heavy.push_back(login(Ident()));
    }
    {
        PinnedSource pin(60051);
        for (int i = 0; i < 2; i++) light.push_back(login3(Ident(), "new", 0));
    }
    std::vector<std::unique_ptr<Peer>> others;
    for (int i = 0; i < 6; i++) others.push_back(login3(Ident(), "new", 0));
    sleep_ms(300);
    for (auto* group : {&heavy, &light}) {
        for (auto& p : *group) p->ws.pump(10);
    }
    size_t heavy_gone = 0, light_gone = 0;
    for (auto& p : heavy) heavy_gone += closed_by_relay(*p) ? 1 : 0;
    for (auto& p : light) light_gone += closed_by_relay(*p) ? 1 : 0;
    check("the heaviest address lost sockets", heavy_gone >= 1);
    check("a lighter one lost none", light_gone == 0);
    PinnedSource pin(60050);
    auto more = open_socket(Ident());
    more->send({{"type", "auth_hello"}});
    check("a newcomer of the heaviest address is refused 1008 relay_full",
          closed_by_relay(*more) && more->ws.close_code == 1008 && more->ws.close_reason == "relay_full");
}

// --- Carrier NAT (RELAY_LIVE_ONLY=cgnat: the default limits, no exemption): 300 users of
// one address reconnect together.

// The auth v3 half of login3 on a socket already open and challenged.
static void auth3(Peer& p, const Ident& id, const std::string& session, uint64_t in_h) {
    const uint64_t ts = client_now_secs();
    p.id = id;
    json a = {{"type", "auth"}, {"v", 3}, {"peer_id", id.peer}, {"public_key", id.pub_b64}, {"timestamp", ts},
              {"nonce", p.nonce}, {"domain", g_domain}, {"session", session}, {"in_h", in_h},
              {"signature", id.sign(auth_v3_message(g_domain, p.nonce, id.peer, ts, "full", "", session, in_h))}};
    p.ws.counted = in_h;
    p.send(a);
}

static void read_auth3(Peer& p, const std::string& session) {
    auto r = next_json(p, json_where([](const json& j) {
        const std::string t = j.value("type", "");
        return t == "auth_ok" || t == "auth_failed" || t == "resumed";
    }));
    p.answer = r ? *r : json::object();
    const std::string t = p.answer.value("type", "");
    p.ok = t == "auth_ok" || t == "resumed";
    p.sid = t == "resumed" ? session : p.answer.value("sid", "");
}

// Opens `n` sockets from the pinned source and has each challenged before any logs in.
static std::vector<std::unique_ptr<Peer>> open_challenged(size_t n) {
    std::vector<std::unique_ptr<Peer>> ps;
    for (size_t i = 0; i < n; i++) {
        ps.push_back(open_socket(Ident()));
        ps.back()->send({{"type", "auth_hello"}});
    }
    for (auto& p : ps) {
        auto ch = next_json(*p, typed("auth_challenge"));
        p->nonce = ch ? ch->value("nonce", "") : "";
    }
    return ps;
}

static void cgnat_zombies_resume() {
    printf("cgnat: 300 sessions resume at once beside their 300 old sockets\n");
    PinnedSource pin(61000);
    std::vector<Ident> ids(300);
    std::vector<std::unique_ptr<Peer>> old;
    std::vector<std::pair<std::string, uint64_t>> held;
    for (auto& id : ids) {
        old.push_back(login3(id, "new", 0));
        held.push_back({old.back()->sid, old.back()->ws.counted});
    }
    size_t in_old = 0;
    for (auto& p : old) in_old += p->ok ? 1 : 0;
    check("(300 sessions from one address)", in_old == 300);
    // The address's burst refills (run_live.sh gives this relay 6,000 new sockets a minute, so
    // seconds stand for the minutes a carrier NAT's users were connected before it rebinds).
    sleep_ms(3'500);
    // The carrier rebinds: the relay still holds every old socket while all 300 new ones open.
    const auto t0 = std::chrono::steady_clock::now();
    auto fresh = open_challenged(ids.size());
    size_t challenged = 0;
    for (auto& p : fresh) challenged += p->nonce.empty() ? 0 : 1;
    for (size_t i = 0; i < ids.size(); i++) auth3(*fresh[i], ids[i], held[i].first, held[i].second);
    size_t back = 0, refused = 0;
    for (size_t i = 0; i < ids.size(); i++) {
        read_auth3(*fresh[i], held[i].first);
        if (resumed(*fresh[i])) back++;
        else if (closed_by_relay(*fresh[i])) refused++;
    }
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    printf("       %zu challenged, %zu resumed, %zu refused, %lld ms\n", challenged, back, refused,
           static_cast<long long>(ms));
    check("600 sockets of one address are let in (300 past the cap of 512 would not be before)", challenged == 300);
    check("every session resumed, none refused", back == 300 && refused == 0);
}

static void cgnat_fresh_logins() {
    printf("cgnat: 300 fresh devices behind one address log in at once with the floor credit\n");
    PinnedSource pin(61001);
    const auto t0 = std::chrono::steady_clock::now();
    auto ps = open_challenged(300);
    for (auto& p : ps) auth3(*p, Ident(), "new", 0);
    size_t in = 0, floor = 0;
    for (auto& p : ps) {
        read_auth3(*p, "new");
        if (p->ok) in++;
        if (p->answer.value("credit", int64_t{0}) >= 100'000) floor++;
    }
    const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
    printf("       %zu in, %zu at 100k or more, %lld ms\n", in, floor, static_cast<long long>(ms));
    check("all logged in", in == 300);
    check("all start at the floor or above (review F3)", floor == 300);
}

// V5 (RELAY_LIVE_ONLY=window_total: LOGIN_WINDOW_TOTAL=500): a reconnect wave of 600 honest
// logins from one address arrives while 400 silent sockets from four other /24s hold the window.
// Only silent sockets give way (review F7).
static void login_window_total_wave() {
    printf("login window: a 600-login wave past the total window closes only stalled sockets\n");
    std::vector<std::unique_ptr<Peer>> silent;
    for (int block = 0; block < 4; block++) {
        PinnedSource pin(60000 + 250 * block);
        for (int i = 0; i < 100; i++) silent.push_back(open_socket(Ident()));
    }
    sleep_ms(static_cast<int>(login_window::STALL_MS) + 300);
    PinnedSource pin(61500);
    size_t in = 0, honest_closed = 0;
    std::vector<std::unique_ptr<Peer>> honest;
    for (int wave = 0; wave < 3; wave++) {
        auto ps = open_challenged(200);
        for (auto& p : ps) auth3(*p, Ident(), "new", 0);
        for (auto& p : ps) {
            read_auth3(*p, "new");
            if (p->ok) in++;
            else if (p->ws.closed()) honest_closed++;
            honest.push_back(std::move(p));
        }
    }
    size_t busy = 0;
    std::map<std::string, size_t> why;
    for (auto& s : silent) {
        for (int i = 0; i < 20 && !s->ws.closed(); i++) s->ws.pump(10);
        why[s->ws.closed() ? std::to_string(s->ws.close_code) + " " + s->ws.close_reason : "open"]++;
        if (s->ws.closed() && s->ws.close_code == 1008 && s->ws.close_reason == "login_busy") busy++;
    }
    printf("       %zu of 600 in, %zu honest closed, %zu silent closed login_busy\n", in, honest_closed, busy);
    for (const auto& [k, n] : why) printf("       silent: %zu %s\n", n, k.c_str());
    check("every honest login came in", in == 600 && honest_closed == 0);
    check("the silent sockets made room", busy >= 100);
}

static void cgnat_beside_silent_neighbours() {
    printf("cgnat: 300 fresh logins while 300 silent sockets of the same /24 hold the window\n");
    std::vector<std::unique_ptr<Peer>> silent;
    {
        PinnedSource pin(61250);  // 127.0.246.2
        for (int i = 0; i < 300; i++) silent.push_back(open_socket(Ident()));
    }
    sleep_ms(static_cast<int>(login_window::STALL_MS) + 300);
    PinnedSource pin(61251);  // same /24
    size_t in = 0;
    std::vector<std::unique_ptr<Peer>> ps;
    for (int i = 0; i < 300; i++) {
        ps.push_back(login3(Ident(), "new", 0));
        if (ps.back()->ok) in++;
    }
    printf("       %zu of 300 in\n", in);
    check("every honest login came in", in == 300);
}

// --- Review fix round (C3-C6) ---------------------------------------------------------------

// What the relay still holds of `peer` in its presence tables (test builds only).
static json presence_report(const std::string& peer) {
    Socket s;
    auto body = s.get("/presence-test?peer=" + peer);
    json j = body ? json::parse(*body, nullptr, false) : json();
    return j.is_object() ? j : json::object();
}

// Review C3: a room that goes while its log still names a subject takes that entry with it,
// though the subject never sends again.
static void presence_subjects_go_with_their_room() {
    printf("presence batches: a room erased with its log pending leaves nothing in the subject table\n");
    const std::string room = room_name("subj-erase");
    Seen sv;
    auto v = batching_viewer(sv, room);
    Ident idj;
    auto j = login(idj);
    quiet_window();
    j->send({{"type", "join"}, {"room", room}});
    j->send({{"type", "leave"}, {"room", room}});
    sync(*j);
    sleep_ms(20);
    v->send({{"type", "leave"}, {"room", room}});
    sync(*v);
    sleep_ms(static_cast<int>(presence_batch::WINDOW_MS) + 200);
    const json r = presence_report(idj.peer);
    check("no room names the departed subject", r.value("rooms_naming_peer", int64_t(-1)) == 0);
    check("and the subject table is empty", r.value("subjects", int64_t(-1)) == 0);
}

// Review C5 (RELAY_LIVE_ONLY=window): sockets that repeat auth_hello every second take no
// step, so five seconds after their first hello they give way like silent ones.
static void login_window_repeated_hello_still_stalls() {
    printf("login window: repeating auth_hello is no progress\n");
    std::vector<std::unique_ptr<Peer>> repeaters;
    for (int i = 0; i < 8; i++) {
        PinnedSource pin(62000 + i);  // 127.0.249.x: a block no other case uses
        repeaters.push_back(open_socket(Ident()));
    }
    const auto first = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - first <
           std::chrono::milliseconds(static_cast<int>(login_window::STALL_MS) + 300)) {
        for (auto& r : repeaters) r->send({{"type", "auth_hello"}});
        sleep_ms(1'000);
    }
    std::vector<std::unique_ptr<Peer>> newcomers;
    {
        PinnedSource pin(62100);
        for (int i = 0; i < 3; i++) newcomers.push_back(open_socket(Ident()));
    }
    bool in = true;
    for (auto& n : newcomers) {
        n->send({{"type", "auth_hello"}});
        in = next_json(*n, typed("auth_challenge")).has_value() && in;
    }
    check("every newcomer comes in", in);
    size_t pushed = 0;
    for (auto& r : repeaters) {
        if (closed_by_relay(*r) && r->ws.close_code == 1008 && r->ws.close_reason == "login_busy") pushed++;
    }
    printf("       %zu of 8 repeaters gave way\n", pushed);
    check("each pushed out a repeater, closed 1008 login_busy", pushed == 3);
}

// Review C6 (RELAY_LIVE_ONLY=rate_exempt: 10 new a minute, a burst of 30): the fresh-start
// floor keeps the operator's rate and burst, not the compiled 120 a minute and 512. The
// listed address skips the connection rate, so only the floor's own count limits it.
static void start_floor_follows_the_operator_rate() {
    printf("breaker: the fresh-start floor follows the operator's connection rate\n");
    PinnedSource pin(RATE_EXEMPT_SOURCE);
    size_t full = 0, floor = 0, low = 0, other = 0;
    int64_t last = -1;
    for (int i = 0; i < 40; i++) {
        Ident id;
        auto p = login(id);
        last = breaker_of(id.peer).value("start", int64_t(-1));
        if (last == 400'000) {
            full++;
        } else if (last == 100'000) {
            floor++;
        } else if (last == 24'000) {
            low++;
        } else {
            other++;
        }
        p->ws.close_clean();
    }
    printf("       %zu full, %zu at the floor, %zu low\n", full, floor, low);
    check("the pool's credit goes first", full == 3 && other == 0);
    // Every start spends the floor's allowance, the pool-funded ones too: 30 - 3 at the floor.
    check("then the floor for the rest of the operator's burst of 30", floor >= 27 && floor <= 28);
    check("then the low tier", low >= 9 && last == 24'000);
}

// Review C4 (run_restart.sh): a session back from a snapshot learns presence by single frames
// until a join says pv 2; from then on its batches start after what it was already sent.
struct T14Restart {
    Ident v;
    std::string room;
    std::string sid;
    uint64_t read = 0;
    std::unique_ptr<Peer> before;
};

static T14Restart& t14_restart() {
    static T14Restart r;
    return r;
}

static void t14_restart_before() {
    T14Restart& r = t14_restart();
    r.room = room_name("t14-rs");
    r.before = login3(r.v, "new", 0);
    join(*r.before, r.room, PV2);
    settle({r.before.get()});
    r.sid = r.before->sid;
    r.read = r.before->ws.counted;
}

// Reads `p`'s frames for `room` in order until `seen` holds every event in `want`.
static bool read_until_seen(Peer& p, Seen& seen, const std::string& room, const std::vector<std::string>& want) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(WAIT_MS);
    const auto all_seen = [&] {
        for (const auto& e : want) {
            if (index_of(seen.events, e) == seen.events.size()) return false;
        }
        return true;
    };
    for (;;) {
        for (auto it = p.ws.inbox.begin(); it != p.ws.inbox.end();) {
            auto j = as_json(*it);
            if (j && j->value("room", "") == room) {
                seen.apply(*j);
                it = p.ws.inbox.erase(it);
            } else {
                ++it;
            }
        }
        if (all_seen()) return true;
        if (left_ms(deadline) <= 0 || !p.ws.pump(left_ms(deadline))) return false;
    }
}

static void t14_restart_after() {
    printf("presence batches: a restored session that turns to pv 2 is told each change once\n");
    T14Restart& r = t14_restart();
    auto v = login3(r.v, r.sid, r.read);
    Seen seen;
    seen.me = r.v.peer;
    check("(the session resumes)", resumed(*v) && read_to_members(*v, seen, r.room));
    Ident idw;
    auto w = login3(idw, "new", 0);
    join(*w, r.room, PV2);
    check("(the batching member reaches it as a frame)", read_until_seen(*v, seen, r.room, {"+" + idw.peer}));
    Ident idx, idy;
    auto x = login(idx);
    auto y = login(idy);
    quiet_window();
    // The first arrival flushes at once and opens a window; the second waits in the log for
    // the batching member while the restored session already took it as a frame. Neither
    // arrival sends anything more: a frame from it would flush the log first.
    x->send({{"type", "join"}, {"room", r.room}});
    y->send({{"type", "join"}, {"room", r.room}});
    const std::string px = "+" + idx.peer, py = "+" + idy.peer;
    check("(both arrivals reach it as frames)", read_until_seen(*v, seen, r.room, {px, py}));
    const std::string second = index_of(seen.events, px) < index_of(seen.events, py) ? idy.peer : idx.peer;
    check("(the second arrival still waits in the room's log)",
          presence_report(second).value("rooms_naming_peer", int64_t(-1)) == 1);
    v->send({{"type", "join"}, {"room", r.room}, {"pv", 2}});
    check("(it answers the join)", read_to_members(*v, seen, r.room));
    quiet_window();
    read_room(*v, seen, r.room);
    const auto times = [&](const std::string& e) { return std::count(seen.events.begin(), seen.events.end(), e); };
    printf("       arrivals told %td and %td times\n", times(px), times(py));
    check("each arrival reached it exactly once", times(px) == 1 && times(py) == 1);
}
