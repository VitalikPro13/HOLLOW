// Sibling push mutes (src/sib_mute.h, t14-iospush) against a live relay: a computer of an
// identity silences its siblings' channel wakes for the servers it names; nobody else can,
// and a removed computer's marks go with its removal. Included by test_relay_live.cpp.

// A v2 login holds no session to end: the socket goes once the relay has read it, so the
// address keeps room under the run's three sockets each.
static void sib_leave(Peer& p) {
    settle({&p});
    p.ws.abort();
}

// A phone of `master` that registered `token`, showed `roster` on its inbox and went away
// for good, so a channel copy to it buffers and wakes it.
static void sib_phone_away(const Ident& master, const Ident& phone, const json& roster, const std::string& token,
                           const json& prefs = json::object()) {
    auto p = login(phone);
    join(*p, "inbox:" + master.peer, {{"inbox_roster", roster}});
    p->send({{"type", "register_push_token"}, {"token", token}, {"platform", "android"}});
    next(*p, typed("push_token_registered"));
    if (!prefs.empty()) p->send(prefs);
    sib_leave(*p);
}

static json sib_frame(const Ident& master, int64_t at, int64_t set_at, const json& servers) {
    return {{"type", "mute_siblings"}, {"master", master.peer}, {"at", at}, {"set_at", set_at}, {"servers", servers}};
}

static int64_t sib_now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch())
        .count();
}

static void test_sib_mute() {
    printf("sibling mutes: a computer silences its phones' wakes of the servers it names\n");
    int lfd = hold_push_port();
    if (lfd < 0) {
        printf("  skip sibling mutes (127.0.0.1:3001 stays taken)\n");
        return;
    }
    const int64_t now = sib_now_ms();
    // Mentions skip the 120 s debounce; each case wakes its own phone, so the 5 s floor
    // per phone never meets another case.
    auto post = [](Peer& from, const std::string& server, const Ident& to, const std::string& text) {
        from.send_bin(channel_frame(server, to.peer, "c", text));
    };
    auto mention = [](Peer& from, const std::string& server, const Ident& to, const std::string& text) {
        from.send_bin(frame(0x09, {server, to.peer, "c"}, std::string(1, '\x01') + text));
    };

    // OFF from a computer of the identity: the named server stays silent, another wakes.
    {
        Ident master, desk, phone;
        const std::string adult = random_hex(16), plain = random_hex(16);
        const json roster = legacy_roster(master, {&desk, &phone});
        const std::string token = "sib-off-" + g_tag;
        sib_phone_away(master, phone, roster, token);
        auto d = login(desk);
        join(*d, "inbox:" + master.peer, {{"inbox_roster", roster}});
        d->send(sib_frame(master, now, now, {adult}));
        auto s = login(Ident());
        join(*s, adult);
        join(*s, plain);
        settle({d.get(), s.get()});
        mention(*s, adult, phone, "sib-adult");
        check("a server a computer muted wakes nothing, a mention neither", !pushed(lfd, token, 1500));
        post(*s, plain, phone, "sib-plain");
        check("another server still wakes the phone", pushed(lfd, token, WAIT_MS));
    }

    // Nobody but the identity's own computer, on a full socket that owns its inbox, writes;
    // and it writes nothing into a sibling that holds no push token.
    {
        Ident master, desk, phone, other, stranger;
        const std::string adult = random_hex(16);
        const json roster = legacy_roster(master, {&desk, &phone, &other});
        const std::string token = "sib-who-" + g_tag;
        sib_phone_away(master, phone, roster, token);
        auto d = login(desk);
        join(*d, "inbox:" + master.peer, {{"inbox_roster", roster}});  // owns it, sends nothing
        auto f = login(desk, "fetch");
        join(*f, "inbox:" + master.peer, {{"inbox_roster", roster}});
        f->send(sib_frame(master, now, now, {adult}));
        auto x = login(stranger);
        join(*x, "inbox:" + master.peer, {{"inbox_roster", roster}});  // proves nothing for a stranger
        x->send(sib_frame(master, now, now, {adult}));
        auto o = login(other);
        join(*o, "inbox:" + master.peer);  // a device of the identity that never proved it here
        o->send(sib_frame(master, now, now, {adult}));
        auto s = login(Ident());
        join(*s, adult);
        settle({d.get(), f.get(), x.get(), o.get(), s.get()});
        mention(*s, adult, phone, "sib-who");
        check("a fetch socket, another identity and an unproved socket silence nothing", pushed(lfd, token, WAIT_MS));
        d->send(sib_frame(master, now, now, {adult}));
        settle({d.get()});
        check("a sibling with no push token takes no mark", deny_report(other.peer).value("prefs", true) == false);
    }

    // ON at the same choice with a newer view of the flags lifts the marks; equal stamps
    // and an older choice change nothing.
    {
        Ident master, desk, phone;
        const std::string adult = random_hex(16);
        const json roster = legacy_roster(master, {&desk, &phone});
        const std::string token = "sib-on-" + g_tag;
        sib_phone_away(master, phone, roster, token);
        auto d = login(desk);
        join(*d, "inbox:" + master.peer, {{"inbox_roster", roster}});
        d->send(sib_frame(master, now, now, {adult}));
        d->send(sib_frame(master, now, now, json::array()));      // equal stamps: no-op
        d->send(sib_frame(master, now - 1, now + 1, json::array()));  // an older choice: no-op
        auto s = login(Ident());
        join(*s, adult);
        settle({d.get(), s.get()});
        mention(*s, adult, phone, "sib-on-1");
        check("equal stamps and an older choice keep the mark", !pushed(lfd, token, 1500));
        d->send(sib_frame(master, now, now + 1, json::array()));
        settle({d.get()});
        mention(*s, adult, phone, "sib-on-2");
        check("a newer view of the flags at the same choice lifts it", pushed(lfd, token, WAIT_MS));
    }

    // The phone's own later prefs keep the mark; its own local yes lifts it for itself.
    {
        Ident master, desk, phone;
        const std::string adult = random_hex(16);
        const json roster = legacy_roster(master, {&desk, &phone});
        const std::string token = "sib-own-" + g_tag;
        sib_phone_away(master, phone, roster, token);
        auto d = login(desk);
        join(*d, "inbox:" + master.peer, {{"inbox_roster", roster}});
        d->send(sib_frame(master, now, now, {adult}));
        settle({d.get()});
        auto p = login(phone);
        p->send({{"type", "set_push_prefs"}, {"prefs", {{adult, {{"level", "all"}}}}}});
        sib_leave(*p);
        auto s = login(Ident());
        join(*s, adult);
        settle({s.get()});
        mention(*s, adult, phone, "sib-own-1");
        check("a phone's stale prefs never undo its computer's OFF", !pushed(lfd, token, 1500));
        auto pf = login(phone, "fetch");
        pf->send({{"type", "set_push_prefs"}, {"prefs", json::object()}, {"sib_local", true}});
        settle({pf.get(), s.get()});
        pf->ws.abort();
        mention(*s, adult, phone, "sib-own-fetch");
        check("a push isolate's socket never speaks for the device's prefs", !pushed(lfd, token, 1500));
        auto p2 = login(phone);
        p2->send({{"type", "set_push_prefs"}, {"prefs", json::object()}, {"sib_local", true}});
        sib_leave(*p2);
        settle({s.get()});
        mention(*s, adult, phone, "sib-own-2");
        check("its own local yes lifts the marks for itself", pushed(lfd, token, WAIT_MS));
    }

    // Equal stamps only add: a flag the computer read late (an older op caught up after a
    // newer one) is muted though its view's stamp did not move.
    {
        Ident master, desk, phone;
        const std::string adult = random_hex(16), late = random_hex(16);
        const json roster = legacy_roster(master, {&desk, &phone});
        const std::string token = "sib-late-" + g_tag;
        sib_phone_away(master, phone, roster, token);
        auto d = login(desk);
        join(*d, "inbox:" + master.peer, {{"inbox_roster", roster}});
        d->send(sib_frame(master, now, now + 2, {adult}));
        d->send(sib_frame(master, now, now + 2, {late}));
        auto s = login(Ident());
        join(*s, adult);
        join(*s, late);
        settle({d.get(), s.get()});
        mention(*s, late, phone, "sib-late-1");
        check("a flag read late at the same stamps is muted", !pushed(lfd, token, 1500));
        mention(*s, adult, phone, "sib-late-2");
        check("and the earlier mark stands", !pushed(lfd, token, 1500));
    }

    // A phone caught up to its computer's view lifts the marks for itself; the same frame
    // or an older one never sets them again (review LOW-8).
    {
        Ident master, desk, phone;
        const std::string adult = random_hex(16);
        const json roster = legacy_roster(master, {&desk, &phone});
        const std::string token = "sib-view-" + g_tag;
        sib_phone_away(master, phone, roster, token);
        auto d = login(desk);
        join(*d, "inbox:" + master.peer, {{"inbox_roster", roster}});
        d->send(sib_frame(master, now, now + 5, {adult}));
        settle({d.get()});
        auto p = login(phone);
        p->send({{"type", "set_push_prefs"}, {"prefs", json::object()}, {"sib_view", {{"at", now}, {"set_at", now + 4}}}});
        sib_leave(*p);
        auto s = login(Ident());
        join(*s, adult);
        settle({s.get()});
        mention(*s, adult, phone, "sib-view-1");
        check("a phone behind its computer's view keeps the marks", !pushed(lfd, token, 1500));
        auto p2 = login(phone);
        p2->send({{"type", "set_push_prefs"}, {"prefs", json::object()}, {"sib_view", {{"at", now}, {"set_at", now + 5}}}});
        sib_leave(*p2);
        d->send(sib_frame(master, now, now + 4, {adult}));
        settle({d.get(), s.get()});
        mention(*s, adult, phone, "sib-view-2");
        check("a phone caught up lifts them, and an older frame sets nothing", pushed(lfd, token, WAIT_MS));
    }

    // A computer the identity removes takes its marks with it at once (review H1).
    {
        Ident master, gone, keeper, phone;
        const std::string adult = random_hex(16);
        const json roster = legacy_roster(master, {&gone, &keeper, &phone});
        const std::string token = "sib-gone-" + g_tag;
        sib_phone_away(master, phone, roster, token);
        auto g = login(gone);
        join(*g, "inbox:" + master.peer, {{"inbox_roster", roster}});
        g->send(sib_frame(master, now + 60'000, now + 60'000, {adult}));
        settle({g.get()});
        auto k = login(keeper);
        join(*k, "inbox:" + master.peer, {{"inbox_roster", roster_removing(master, {&gone, &keeper, &phone}, gone, keeper)}});
        auto s = login(Ident());
        join(*s, adult);
        settle({k.get(), s.get()});
        mention(*s, adult, phone, "sib-gone");
        check("a removed writer's marks are gone with its removal", pushed(lfd, token, WAIT_MS));
    }
    close(lfd);
}
