// --- People online (#150): /server-stats counts identities, never sockets ---
//
// run_live.sh starts a relay of its own for these (RELAY_LIVE_ONLY=people), naming the
// forwarder BRK_FORWARDER_SEED derives, so every count is exact.

static std::chrono::steady_clock::time_point g_people_read{};

// `online_users` as /server-stats tells it, read once its five-second cache ran out.
static int64_t people_online() {
    const auto ready = g_people_read + std::chrono::milliseconds(5300);
    while (std::chrono::steady_clock::now() < ready) usleep(100'000);
    Socket s;
    const auto body = s.get("/server-stats");
    g_people_read = std::chrono::steady_clock::now();
    const json j = body ? json::parse(*body, nullptr, false) : json();
    if (!j.is_object() || !j.contains("online_users") || !j["online_users"].is_number_integer()) return -1;
    return j["online_users"].get<int64_t>();
}

// Checks the count, naming what the relay said.
static void expect_people(const std::string& label, int64_t want) {
    const int64_t got = people_online();
    check(label + " (relay says " + std::to_string(got) + ")", got == want);
}

static Ident people_forwarder() {
    Ident fwd;
    unsigned char seed[crypto_sign_SEEDBYTES];
    memset(seed, BRK_FORWARDER_SEED, sizeof(seed));
    crypto_sign_seed_keypair(fwd.pk, fwd.sk, seed);
    unsigned char proto[36] = {0x08, 0x01, 0x12, 0x20};
    memcpy(proto + 4, fwd.pk, 32);
    fwd.pub_b64 = b64(proto, sizeof(proto));
    fwd.peer = derive_peer_id(fwd.pub_b64);
    return fwd;
}

static void test_people_online() {
    printf("server stats: people online are identities on screen\n");
    expect_people("a fresh relay counts nobody", 0);

    const Ident fwd = people_forwarder();
    auto x = login3(fwd, "new", 0);
    x->send({{"type", "get_media_forwarder"}});
    auto named = next_json(*x, typed("media_forwarder"));
    check("the relay names this socket its forwarder", named && named->value("peer_id", "") == fwd.peer);

    // Identity M on two devices, each owning M's inbox by the fold.
    Ident m, d1, d2;
    const std::string inbox_m = "inbox:" + m.peer;
    const json roster_m = legacy_roster(m, {&d1, &d2});
    auto a1 = login3(d1, "new", 0);
    auto a2 = login3(d2, "new", 0);
    join(*a1, inbox_m, {{"inbox_roster", roster_m}});
    join(*a2, inbox_m, {{"inbox_roster", roster_m}});

    // A device the fold places nowhere, a guest, and identity N's only device off screen.
    auto lone = login(Ident());
    auto g = login(Ident(), "guest");
    Ident n, dn;
    auto h = login3(dn, "new", 0);
    join(*h, "inbox:" + n.peer, {{"inbox_roster", legacy_roster(n, {&dn})}});
    h->send({{"type", "inactive"}});
    settle({x.get(), a1.get(), a2.get(), lone.get(), g.get(), h.get()});
    expect_people("two people: M once, the lone device; not the forwarder, the guest or the hidden", 2);

    h->send({{"type", "active"}});
    auto bare = login(m);
    settle({h.get(), bare.get()});
    expect_people("N back on screen and a login as M's bare master key: three", 3);

    join(*a1, inbox_m, {{"inbox_roster", roster_removing(m, {&d1, &d2}, d2, d1)}});
    settle({a1.get(), a2.get()});
    expect_people("a device M's roster removed counts as itself", 4);

    const uint64_t read = a1->ws.counted;
    a1->ws.abort();
    auto a1b = login3(d1, a1->sid, read);
    check("a device of M resumes its session", resumed(*a1b));
    a2->send({{"type", "inactive"}});
    settle({a1b.get(), a2.get()});
    expect_people("M stays one person through a resume", 3);

    a1b->send({{"type", "inactive"}});
    bare->ws.abort();
    settle({a1b.get()});
    expect_people("with M's devices off screen and the bare login gone, M is nobody", 2);
}

// A legacy-base roster for `master`: `members` belong, `asking` wait as pending joins the
// master signed and each device consented to, `removed` were removed by members[0].
static json people_roster(const Ident& master, const std::vector<const Ident*>& members,
                          const std::vector<const Ident*>& asking, const std::vector<const Ident*>& removed = {}) {
    roster::Roster r = roster::Roster::named(master.peer);
    for (const auto* d : members) {
        r.legacy.push_back({d->peer, master.sign(roster::legacy_payload(master.peer, d->peer))});
        r.consents.push_back({d->peer, d->sign(roster::consent_payload(master.peer, d->peer))});
    }
    for (const auto* d : asking) {
        r.pendings.push_back({roster::LEGACY_BASE, d->peer,
                              master.sign(roster::pending_payload(master.peer, roster::LEGACY_BASE, d->peer))});
        r.consents.push_back({d->peer, d->sign(roster::consent_payload(master.peer, d->peer))});
    }
    for (const auto* d : removed) {
        roster::Removal x;
        x.base = roster::LEGACY_BASE;
        x.device = d->peer;
        x.by = members[0]->peer;
        x.sig = members[0]->sign(roster::removal_payload(master.peer, roster::LEGACY_BASE, d->peer, {}));
        r.removals.push_back(x);
    }
    std::sort(r.pendings.begin(), r.pendings.end());
    std::sort(r.consents.begin(), r.consents.end());
    return json::parse(roster::to_json(r).dump());
}

static void test_people_pending() {
    printf("server stats: a pending device counts as its identity, and nobody else can make it so\n");
    expect_people("(the earlier sockets are gone)", 0);

    // P's member desktop and P's restored phone, still waiting.
    Ident p, desk, phone;
    const std::string inbox = "inbox:" + p.peer;
    auto a = login3(desk, "new", 0);
    auto b = login3(phone, "new", 0);
    join(*a, inbox, {{"inbox_roster", people_roster(p, {&desk}, {&phone})}});
    join(*b, inbox, {{"inbox_roster", people_roster(p, {&desk}, {&phone})}});
    settle({a.get(), b.get()});
    expect_people("a member desktop and its pending phone are one person", 1);

    // A stranger naming itself pending under its own signature, and a device pending in
    // another identity's roster shown into P's inbox: each stays its own person, while P's
    // roster changing (a second device asks) leaves the phone P.
    Ident s, z, q, tablet;
    join(*a, inbox, {{"inbox_roster", people_roster(p, {&desk}, {&phone, &tablet})}});
    roster::Roster forged = roster::Roster::named(p.peer);
    forged.pendings.push_back({roster::LEGACY_BASE, s.peer, s.sign(roster::pending_payload(p.peer, roster::LEGACY_BASE, s.peer))});
    forged.consents.push_back({s.peer, s.sign(roster::consent_payload(p.peer, s.peer))});
    auto sx = login(s);
    join(*sx, inbox, {{"inbox_roster", json::parse(roster::to_json(forged).dump())}});
    auto qx = login(q);
    join(*qx, inbox, {{"inbox_roster", people_roster(z, {}, {&q})}});
    settle({a.get(), sx.get(), qx.get(), b.get()});
    expect_people("a forged pending join and another master's roster merge nobody", 3);

    // The desktop removes the phone while it is in the inbox: it is P's no longer.
    join(*a, inbox, {{"inbox_roster", people_roster(p, {&desk}, {&phone, &tablet}, {&phone})}});
    settle({a.get(), b.get()});
    expect_people("a pending device P's roster removed counts as itself", 4);

    // A watch asks, leaves the inbox, and is removed there: the change reaches it at the count.
    Ident watch;
    auto w = login(watch);
    join(*w, inbox, {{"inbox_roster", people_roster(p, {&desk}, {&watch})}});
    w->send({{"type", "leave"}, {"room", inbox}});
    settle({w.get()});
    join(*a, inbox, {{"inbox_roster", people_roster(p, {&desk}, {&watch}, {&watch})}});
    settle({a.get()});
    expect_people("and so does one removed after it left the inbox", 5);
}
