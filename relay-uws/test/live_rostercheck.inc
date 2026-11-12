// roster_check end to end (design ROSTER-CHECK): included by test_relay_live.cpp. Which
// facts answer is pinned by roster_check_vectors.json (test_roster_check.cpp); these
// cases prove the handler reads each fact off the live room, session and roster book.

static std::optional<json> roster_ask(Peer& p, const std::string& room, const std::string& master,
                                      const std::string& device) {
    const std::string n = random_hex(4);
    p.send({{"type", "roster_check"}, {"room", room}, {"master", master}, {"device", device}, {"n", n}});
    return next_json(p, json_where([n](const json& j) { return j.value("type", "") == "roster_checked" && j.value("n", "") == n; }));
}

static bool holds_roster(const std::optional<json>& a) { return a && a->contains("roster") && (*a)["roster"].is_object(); }

static bool names_removal_of(const std::optional<json>& a, const std::string& device) {
    if (!holds_roster(a)) return false;
    for (const auto& r : (*a)["roster"].value("removals", json::array())) {
        if (r.value("device", "") == device) return true;
    }
    return false;
}

static void rc_unlocked_room() {
    printf("roster_check: an unlocked server room\n");
    Ident master, d1, d2, idj, stranger;
    const std::string room = random_hex(16);
    auto j = login3(idj, "new", 0);
    check("a login says the relay answers roster checks", j->answer.value("roster_check", false));
    // The remover shows the roster in which it removed d2; d2 still sits in the room.
    auto r1 = login(d1);
    join(*r1, "inbox:" + master.peer, {{"inbox_roster", roster_removing(master, {&d1, &d2}, d2, d1)}});
    auto r2 = login3(d2, "new", 0);
    join(*r2, room);
    join(*j, room);
    auto a = roster_ask(*j, room, master.peer, d2.peer);
    check("a co-occupant is handed the held statements, the removal included", names_removal_of(a, d2.peer));
    check("the answer echoes what was asked",
          a && a->value("room", "") == room && a->value("master", "") == master.peer && a->value("device", "") == d2.peer);

    // A stranger's own consent planted in the master's record places nothing.
    roster::Roster planted = roster::Roster::named(master.peer);
    planted.consents.push_back({stranger.peer, stranger.sign(roster::consent_payload(master.peer, stranger.peer))});
    auto x = login(stranger);
    join(*x, "inbox:" + master.peer, {{"inbox_roster", json::parse(roster::to_json(planted).dump())}});
    join(*x, room);
    auto ax = roster_ask(*j, room, master.peer, stranger.peer);
    check("a device only its own consent ties to the master gets null", ax && ax->contains("roster") && (*ax)["roster"].is_null());
    auto ab = roster_ask(*x, room, master.peer, d2.peer);
    check("(the stranger may still ask about a device the fold places: it sits in that room)", holds_roster(ab));

    auto k = login(Ident());
    auto ak = roster_ask(*k, room, master.peer, d2.peer);
    check("an asker outside the room gets null", ak && (*ak)["roster"].is_null());
    auto f = login(Ident(), "fetch");
    join(*f, room);
    auto af = roster_ask(*f, room, master.peer, d2.peer);
    check("a fetch socket gets null", af && (*af)["roster"].is_null());

    const std::string named = "rc-" + g_tag;
    join(*j, named);
    join(*r2, named);
    auto an = roster_ask(*j, named, master.peer, d2.peer);
    check("a room not named like a server gets null", an && (*an)["roster"].is_null());

    r2->send({{"type", "inactive"}});
    check("(it is hidden)", next(*j, about("peer_left", room, d2.peer)).has_value());
    auto ah = roster_ask(*j, room, master.peer, d2.peer);
    check("a device presence hides gets null", ah && (*ah)["roster"].is_null());
    r2->send({{"type", "active"}});
    check("(it is shown again)", next(*j, about("peer_joined", room, d2.peer)).has_value());
    check("and is answered again once shown", holds_roster(roster_ask(*j, room, master.peer, d2.peer)));
}

static void rc_locked_room() {
    printf("roster_check: a locked server room\n");
    Ident owner, change, change2, master, d1, d2;
    Door door, door2;
    const std::string nonce = random_hex(16);
    const std::string room = genesis_server_id(owner.peer, nonce);
    const json base = base_link(room, door, change, owner, nonce, true);
    auto b = login(Ident());
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", base}});
    next(*b, typed("lock_chain"));
    auto r1 = login(d1);
    join(*r1, "inbox:" + master.peer, {{"inbox_roster", legacy_roster(master, {&d1, &d2})}});
    auto r2 = login(d2);
    join(*r2, room, {{"door_proof", door_proof(*r2, room, door)}});
    auto q = login(Ident());
    join(*q, room);
    auto aq = roster_ask(*q, room, master.peer, d2.peer);
    check("a socket without the door gets null", aq && (*aq)["roster"].is_null());
    join(*b, room, {{"door_proof", door_proof(*b, room, door)}});
    check("a prover of the newest door is answered", holds_roster(roster_ask(*b, room, master.peer, d2.peer)));
    json links = base;
    links.push_back(successor_link(room, 2, door2, change2, change, owner));
    b->send({{"type", "lock_put"}, {"server", room}, {"owner", ""}, {"links", links}});
    auto put = next_json(*b, typed("lock_chain"));
    check("(the lock moves on)", put && put->value("put", false));
    auto ag = roster_ask(*b, room, master.peer, d2.peer);
    check("a prover the move left in grace gets null", ag && (*ag)["roster"].is_null());
    auto c = login(Ident());
    auto mc = join(*c, room, {{"door_proof", door_proof(*c, room, door2)}});
    check("(a prover of the new door)", mc && mc->value("proved", false));
    check("asks about a device still in its grace and is answered", holds_roster(roster_ask(*c, room, master.peer, d2.peer)));
}

static void rc_resume_says_so() {
    printf("roster_check: a resumed session is told the relay answers\n");
    Ident id;
    auto p = login3(id, "new", 0);
    const std::string sid = p->sid;
    const uint64_t read = p->ws.counted;
    p->ws.abort();
    auto r = login3(id, sid, read);
    check("(it resumes)", r->answer.value("type", "") == "resumed");
    check("the resume says the relay answers roster checks", r->answer.value("roster_check", false));
}

static void rostercheck_live() {
    rc_unlocked_room();
    rc_locked_room();
    rc_resume_says_so();
}
