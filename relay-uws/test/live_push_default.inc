// The reserved `~default` push pref (src/push_pref.h) against a live relay: a server a
// phone never set wakes it at the default level, an entry it set wins, an older client's
// phone is woken as before and DMs never meet it. Included by test_relay_live.cpp; the
// restart part runs inside hs_restart.

// A phone that registered `token` and `prefs` and went away for good, so a channel copy to
// it wakes it.
static void pd_phone_away(const Ident& phone, const std::string& token, const json& prefs) {
    auto p = login(phone);
    p->send({{"type", "register_push_token"}, {"token", token}, {"platform", "android"}});
    next(*p, typed("push_token_registered"));
    p->send({{"type", "set_push_prefs"}, {"prefs", prefs}});
    settle({p.get()});
    p->ws.abort();
}

static void pd_post(Peer& from, const std::string& server, const Ident& to, const std::string& channel,
                    const std::string& text) {
    from.send_bin(channel_frame(server, to.peer, channel, text));
}

static void pd_mention(Peer& from, const std::string& server, const Ident& to, const std::string& text) {
    from.send_bin(frame(0x09, {server, to.peer, "c"}, std::string(1, '\x01') + text));
}

static void test_push_default() {
    printf("push default: a server a phone never set wakes it at its default level\n");
    int lfd = hold_push_port();
    if (lfd < 0) return;
    // A silent case comes before the wake in each phone: a wake starts its 5 s floor.
    {
        Ident phone;
        const std::string srv = random_hex(16), token = "pd-mentions-" + g_tag;
        pd_phone_away(phone, token, {{"~default", {{"level", "mentions"}, {"channels", json::object()}}}});
        auto s = login(Ident());
        join(*s, srv);
        settle({s.get()});
        pd_post(*s, srv, phone, "c", "pd-plain");
        check("a post in a server it never set wakes nothing", !pushed(lfd, token, 1500));
        pd_mention(*s, srv, phone, "pd-mention");
        check("a mention there wakes it", pushed(lfd, token, WAIT_MS));
    }
    {
        Ident phone;
        const std::string loud = random_hex(16), unset = random_hex(16), token = "pd-loud-" + g_tag;
        pd_phone_away(phone, token, {{"~default", {{"level", "mentions"}}}, {loud, {{"level", "all"}}}});
        auto s = login(Ident());
        join(*s, loud);
        join(*s, unset);
        settle({s.get()});
        pd_post(*s, unset, phone, "c", "pd-unset");
        check("(another server follows the default)", !pushed(lfd, token, 1500));
        pd_post(*s, loud, phone, "c", "pd-loud");
        check("a server set to every message wakes it on a post", pushed(lfd, token, WAIT_MS));
    }
    {
        Ident phone;
        const std::string set = random_hex(16), unset = random_hex(16), token = "pd-chan-" + g_tag;
        pd_phone_away(phone, token,
                      {{"~default", {{"level", "nothing"}, {"channels", {{"loud", "all"}}}}},
                       {set, {{"level", "mentions"}, {"channels", {{"loud", "all"}}}}}});
        auto s = login(Ident());
        join(*s, set);
        join(*s, unset);
        settle({s.get()});
        pd_post(*s, unset, phone, "loud", "pd-unset-loud");
        pd_mention(*s, unset, phone, "pd-unset-mention");
        check("a default of nothing silences a never-set server, mentions and its channels too",
              !pushed(lfd, token, 1500));
        pd_post(*s, set, phone, "quiet", "pd-set-quiet");
        check("a server's own level beats the default", !pushed(lfd, token, 1500));
        pd_post(*s, set, phone, "loud", "pd-set-loud");
        check("and a channel's own level beats its server's", pushed(lfd, token, WAIT_MS));
    }
    {
        Ident phone;
        const std::string named = random_hex(16), other = random_hex(16), token = "pd-old-" + g_tag;
        pd_phone_away(phone, token, {{named, {{"level", "mentions"}}}});
        auto s = login(Ident());
        join(*s, other);
        settle({s.get()});
        pd_post(*s, other, phone, "c", "pd-old");
        check("an older client's phone (no default) is woken by every post", pushed(lfd, token, WAIT_MS));
    }
    {
        Ident phone;
        const std::string room = room_name("pd-dm"), token = "pd-dm-" + g_tag;
        pd_phone_away(phone, token, {{"~default", {{"level", "nothing"}}}});
        auto s = login(Ident());
        join(*s, room);
        settle({s.get()});
        s->send({{"type", "direct"}, {"room", room}, {"target", phone.peer}, {"data", "pd-dm"}});
        check("a DM still wakes a phone whose default is nothing", pushed(lfd, token, WAIT_MS));
    }
    close(lfd);
}

// Across a restart (hs_restart): the default comes back with the rest of the phone's prefs.
struct PushDefaultRestart {
    Ident phone;
    std::string server;
    std::string token;
};

static PushDefaultRestart& pd_restart() {
    static PushDefaultRestart r;
    return r;
}

static void pd_restart_before() {
    PushDefaultRestart& r = pd_restart();
    r.server = random_hex(16);
    r.token = "pd-restart-" + g_tag;
    pd_phone_away(r.phone, r.token, {{"~default", {{"level", "mentions"}}}});
}

static void pd_restart_after() {
    printf("push default: a phone's default survives a relay restart\n");
    PushDefaultRestart& r = pd_restart();
    int lfd = hold_push_port();
    if (lfd < 0) return;
    auto s = login(Ident());
    join(*s, r.server);
    settle({s.get()});
    pd_post(*s, r.server, r.phone, "c", "pd-rs-plain");
    check("after the restart a post in a never-set server still wakes nothing", !pushed(lfd, r.token, 1500));
    pd_mention(*s, r.server, r.phone, "pd-rs-mention");
    check("and a mention still wakes it", pushed(lfd, r.token, WAIT_MS));
    close(lfd);
}
