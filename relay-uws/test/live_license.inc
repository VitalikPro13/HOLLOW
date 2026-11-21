// --- Access-key seats on a members-only relay (#153) -----------------------------------
//
// run_live.sh starts a relay of its own for these (RELAY_LIVE_ONLY=license) with
// RELAY_LIVE_KEYS listing LICENSE_KEYS, the breaker scaled down as for =breaker_enforce.
// One key admits five devices at once; each case uses a key of its own.

static const std::vector<std::string> LICENSE_KEYS = {"LIVE-SEAT-IPLIMIT", "LIVE-SEAT-COOLDOWN",
                                                      "LIVE-SEAT-SUPERSEDE", "LIVE-SEAT-PATHS",
                                                      "LIVE-SEAT-REVOKE"};
static constexpr size_t SEATS_PER_KEY = 5;
static size_t g_seats_full_refusals = 0;

// A login carrying access key `key`: auth v3 asking for `session` (`v2` = no session),
// as `mode`. Its answer is read, whatever it is.
static std::unique_ptr<Peer> login_key(const Ident& id, const std::string& key, const std::string& session = "new",
                                       uint64_t in_h = 0, const std::string& mode = "full", bool v2 = false) {
    auto p = open_socket(id);
    p->send({{"type", "auth_hello"}});
    auto ch = next_json(*p, typed("auth_challenge"));
    if (!ch) return p;
    p->challenge = *ch;
    p->nonce = ch->value("nonce", "");
    p->relay_key = ch->value("door_key", "");
    const uint64_t ts = client_now_secs();
    const std::string digest = key.empty() ? std::string() : sha256_hex(key);
    json a = {{"type", "auth"},  {"peer_id", id.peer},     {"public_key", id.pub_b64}, {"timestamp", ts},
              {"nonce", p->nonce}, {"domain", g_domain}, {"license_key", key}};
    if (v2) {
        a["v"] = 2;
        a["signature"] = id.sign(auth_v2_message(g_domain, p->nonce, id.peer, ts, mode, digest));
    } else {
        a["v"] = 3;
        a["session"] = session;
        a["in_h"] = in_h;
        a["signature"] = id.sign(auth_v3_message(g_domain, p->nonce, id.peer, ts, mode, digest, session, in_h));
        p->ws.counted = in_h;
    }
    if (mode == "guest") a["guest"] = true;
    if (mode == "fetch") a["fetch"] = true;
    p->send(a);
    auto r = next_json(*p, json_where([](const json& j) {
        const std::string t = j.value("type", "");
        return t == "auth_ok" || t == "auth_failed" || t == "resumed";
    }));
    p->answer = r ? *r : json::object();
    const std::string t = p->answer.value("type", "");
    p->ok = t == "auth_ok" || t == "resumed";
    p->sid = t == "resumed" ? session : p->answer.value("sid", "");
    return p;
}

// Refused because every seat of the key is taken.
static bool key_full(Peer& p) {
    const bool full = !p.ok && refused_with(p, "license_key_in_use");
    if (full) g_seats_full_refusals++;
    return full;
}

// After every socket of `key` closed, whatever path each took, the key admits exactly
// SEATS_PER_KEY fresh devices again: no seat is left with no socket.
static void key_back_to_zero(const std::string& key, const std::string& label) {
    std::vector<std::unique_ptr<Peer>> fresh;
    bool all_in = true;
    for (size_t i = 0; i < SEATS_PER_KEY; i++) {
        fresh.push_back(login_key(Ident(), key));
        all_in = fresh.back()->ok && all_in;
    }
    check(label + ": the key admits five fresh devices again", all_in);
    auto extra = login_key(Ident(), key);
    check(label + ": and refuses a sixth", key_full(*extra));
    for (auto& p : fresh) p->ws.close_clean();
}

// keys.json as `file`; the relay reads it again within 30 s.
static void write_keys(const json& file) {
    if (FILE* f = fopen(g_keys_file.c_str(), "wb")) {
        const std::string text = file.dump();
        fwrite(text.data(), 1, text.size(), f);
        fclose(f);
    }
}

static json kept_keys() {
    json kept = json::array();
    for (size_t i = 0; i + 1 < LICENSE_KEYS.size(); i++) kept.push_back(LICENSE_KEYS[i]);
    return kept;
}

// Waits out the next reload (40 s at most) for the relay to close `p`, answering `keep`'s
// pings meanwhile so its socket outlives the wait.
static bool closed_within_reload(Peer& p, Peer* keep = nullptr) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(40'000);
    while (!p.ws.closed() && left_ms(deadline) > 0) {
        p.ws.pump(std::min(left_ms(deadline), 500));
        if (keep && !keep->ws.closed()) keep->ws.pump(1);
    }
    return p.ws.closed();
}

// A device whose socket dropped, its session left in grace.
static std::unique_ptr<Peer> into_grace(const Ident& id, const std::string& key) {
    auto p = login_key(id, key);
    p->ws.abort();
    sleep_ms(300);
    return p;
}

static void close_all(std::vector<std::unique_ptr<Peer>>& ps) {
    for (auto& p : ps) {
        if (!p->ws.closed()) p->ws.close_clean();
    }
    ps.clear();
}

// L1: a login the address refuses (ip_limit) after its key was judged gives the seat back.
static void license_ip_limit_refusal_frees_its_seat() {
    printf("license: a login refused ip_limit after its key was judged holds no seat\n");
    const std::string key = LICENSE_KEYS[0];
    const std::string room = room_name("seat-ip");
    std::vector<std::unique_ptr<Peer>> held;
    {
        // Three sockets an address (run_live.sh): two devices and a session that drops
        // into grace, whose slot a newcomer may not take in its first half.
        PinnedSource pin(61001);
        held.push_back(login_key(Ident(), key));
        held.push_back(login_key(Ident(), key));
        Ident idd;
        auto d = login_key(idd, key);
        check("(three devices of the key at one address)", held[0]->ok && held[1]->ok && d->ok);
        join(*held[0], room);
        join(*d, room);
        d->ws.abort();
        check("(the third dropped into grace)", next(*held[0], about("peer_left", room, idd.peer)).has_value());
        auto refused = login_key(Ident(), key);
        check("a newcomer there is refused ip_limit, after its key was judged",
              !refused->ok && closed_by_relay(*refused) && refused->ws.close_code == 1008 &&
                  refused->ws.close_reason == "ip_limit");
    }
    // Held now: the two devices. Three more seats are free.
    for (int i = 0; i < 3; i++) {
        held.push_back(login_key(Ident(), key));
        check("a device elsewhere takes a free seat (" + std::to_string(i + 1) + " of 3)", held.back()->ok);
    }
    auto sixth = login_key(Ident(), key);
    check("the key's five seats hold", key_full(*sixth));
    close_all(held);
    key_back_to_zero(key, "after an ip_limit refusal");
}

// L1: a login the breaker refuses (cooldown) after its key was judged gives the seat back.
static void license_cooldown_refusal_frees_its_seat() {
    printf("license: a login refused for cooldown after its key was judged holds no seat\n");
    const std::string key = LICENSE_KEYS[1];
    const std::string room = room_name("seat-cool");
    std::vector<std::unique_ptr<Peer>> held;
    Ident ida;
    auto a = login_key(ida, key);
    held.push_back(login_key(Ident(), key));
    check("(two devices of the key)", a->ok && held[0]->ok);
    join(*a, room);
    join(*held[0], room);
    flood(*a, room, "s", 20'000);
    auto hint = breaker_hint(*a);
    closed_by_relay(*a);
    sleep_ms(static_cast<int>(hint ? hint->value("after_ms", int64_t(0)) : 0) + 100);
    auto a2 = login_key(ida, key, a->sid, a->ws.counted);
    check("(the session is back after its pause)", resumed(*a2));
    a2->send(lock_get_of(30));
    auto hint2 = breaker_hint(*a2);
    const int64_t wait = hint2 ? hint2->value("after_ms", int64_t(0)) : 0;
    check("(paused again, for a while)", wait >= 3000 && closed_by_relay(*a2) && a2->ws.close_code == 1013);
    auto fresh = login_key(ida, key);
    check("a fresh login during the pause is refused cooldown, after its key was judged",
          fresh->answer.value("error", "") == "cooldown" && closed_by_relay(*fresh) && fresh->ws.close_code == 1013);
    // Held now: one device. Four more seats are free.
    for (int i = 0; i < 4; i++) {
        held.push_back(login_key(Ident(), key));
        check("a device takes a free seat (" + std::to_string(i + 1) + " of 4)", held.back()->ok);
    }
    auto sixth = login_key(Ident(), key);
    check("the key's five seats hold", key_full(*sixth));
    close_all(held);
    key_back_to_zero(key, "after a cooldown refusal");
}

// A device that logs in again while its old socket lingers keeps its seat: the ghost's
// eviction never frees the seat its live successor holds.
static void license_supersede_keeps_the_seat() {
    printf("license: a relogin that supersedes its own ghost keeps its seat\n");
    const std::string key = LICENSE_KEYS[2];
    std::vector<std::unique_ptr<Peer>> held;
    Ident ida;
    auto ghost = login_key(ida, key);
    auto live = login_key(ida, key);
    check("(a fresh login of the device while its old socket lingers)", ghost->ok && live->ok);
    check("(the old socket is superseded)", closed_by_relay(*ghost));
    Ident idv;
    auto ghost2 = login_key(idv, key, "", 0, "full", true);
    auto live2 = login_key(idv, key, "", 0, "full", true);
    check("(a v2 device does the same)", ghost2->ok && live2->ok && closed_by_relay(*ghost2));
    for (int i = 0; i < 3; i++) {
        held.push_back(login_key(Ident(), key));
        check("a device takes a free seat (" + std::to_string(i + 1) + " of 3)", held.back()->ok);
    }
    auto sixth = login_key(Ident(), key);
    check("the successors still hold their seats: a sixth device is refused", key_full(*sixth));
    held.push_back(std::move(live));
    held.push_back(std::move(live2));
    close_all(held);
    key_back_to_zero(key, "after a supersede");
}

// Every other way a socket of the key comes and goes: each seat comes back with the
// device's last socket, and the key is back to zero once all of them closed.
static void license_every_path_back_to_zero() {
    printf("license: seats come back on every path a socket takes\n");
    const std::string key = LICENSE_KEYS[3];
    const std::string room = room_name("seat-paths");
    std::vector<std::unique_ptr<Peer>> held;
    auto watcher = login_key(Ident(), key);
    join(*watcher, room);

    // A session dropped into grace, resumed, then moved to a newer socket while live.
    Ident ids;
    auto s1 = login_key(ids, key);
    join(*s1, room);
    const uint64_t read = s1->ws.counted;
    s1->ws.abort();
    check("(the session dropped into grace)", next(*watcher, about("peer_left", room, ids.peer)).has_value());
    auto s2 = login_key(ids, key, s1->sid, read);
    check("(it resumes)", resumed(*s2));
    auto s3 = login_key(ids, key, s2->sid, s2->ws.counted);
    check("(and moves to a newer socket)", resumed(*s3) && closed_by_relay(*s2));

    // A device's fetch socket beside its full one: the full one closes first.
    Ident idf;
    auto full = login_key(idf, key);
    auto fetch = login_key(idf, key, "", 0, "fetch", true);
    check("(a full and a fetch socket of one device)", full->ok && fetch->ok);
    // A guest socket and a v2 socket.
    auto guest = login_key(Ident(), key, "", 0, "guest", true);
    check("(a guest socket)", guest->ok);
    auto fifth = login_key(Ident(), key, "", 0, "full", true);
    check("(a v2 socket)", fifth->ok);
    auto sixth = login_key(Ident(), key);
    check("five devices hold the key, the fetch socket's beside its full one", key_full(*sixth));
    full->ws.close_clean();
    auto still = login_key(Ident(), key);
    check("a device's fetch socket keeps its seat after its full socket closed", key_full(*still));
    fetch->ws.close_clean();
    auto now_in = login_key(Ident(), key);
    check("its last socket's close gives the seat back", now_in->ok);
    held.push_back(std::move(now_in));
    held.push_back(std::move(watcher));
    held.push_back(std::move(s3));
    held.push_back(std::move(guest));
    held.push_back(std::move(fifth));
    close_all(held);
    key_back_to_zero(key, "after grace, resume, move, fetch, guest and v2 sockets");
}

// /server-stats counts the refusals of a full key, never which key.
static void license_stats_count_full_keys() {
    printf("license: /server-stats counts logins a full key refused\n");
    sleep_ms(5300);
    Socket s;
    const auto body = s.get("/server-stats");
    const json j = body ? json::parse(*body, nullptr, false) : json();
    const json lic = j.is_object() && j.contains("license") ? j["license"] : json();
    check("a members-only relay names its full-key refusals beside the breaker",
          lic.is_object() && keys_of(lic) == std::set<std::string>{"seats_full"} && j.contains("breaker"));
    check("counting every one (" + std::to_string(g_seats_full_refusals) + " here)",
          lic.is_object() && lic.value("seats_full", int64_t(-1)) == static_cast<int64_t>(g_seats_full_refusals));
}

// A key taken out of keys.json closes every socket it let in, fetch and guest sockets too.
static void license_revoked_key_closes_every_socket() {
    printf("license: a revoked key closes every socket it let in\n");
    const std::string key = LICENSE_KEYS[4];
    Ident idd;
    auto full = login_key(idd, key);
    auto fetch = login_key(idd, key, "", 0, "fetch", true);
    auto guest = login_key(Ident(), key, "", 0, "guest", true);
    check("(a full, a fetch and a guest socket on the key)", full->ok && fetch->ok && guest->ok);
    write_keys(json{{"enabled", true}, {"keys", kept_keys()}});
    auto revoked = [](Peer& p) {
        return closed_within_reload(p) && p.ws.close_code == 1008 && p.ws.close_reason == "license_revoked";
    };
    check("the full socket is closed license_revoked", revoked(*full));
    check("so is the fetch socket", revoked(*fetch));
    check("and the guest socket", revoked(*guest));
    auto again = login_key(Ident(), key);
    check("the key admits nobody now", !again->ok && refused_with(*again, "invalid_license_key"));
    key_back_to_zero(LICENSE_KEYS[0], "a kept key after the reload");
}

// Review item 2: a reload that turns the gate off, its keys dropped too, ends nobody.
static std::unique_ptr<Peer> g_seated;
static void license_gate_off_kicks_nobody() {
    printf("license: turning the gate off ends nobody\n");
    g_seated = login_key(Ident(), LICENSE_KEYS[0]);
    check("(a device holds a seat)", g_seated->ok);
    write_keys(json{{"enabled", false}, {"keys", json::array()}});
    check("its socket stays through the reload", !closed_within_reload(*g_seated));
    auto keyless = login_key(Ident(), "");
    check("(the reload is in: a login without a key gets in)", keyless->ok);
    keyless->ws.close_clean();
}

// HOL-SEC-220: a reload that turns the gate on ends every socket and session in grace the
// open gate let in; a seat taken before the gate went off stays while its key does.
static void license_gate_on_ends_the_keyless() {
    printf("license: turning the gate on ends what the open gate let in\n");
    auto full = login_key(Ident(), "");
    auto fetch = login_key(Ident(), "", "", 0, "fetch", true);
    auto keyed = login_key(Ident(), LICENSE_KEYS[1]);
    check("(a full, a fetch and a keyed socket, let in with the gate off)", full->ok && fetch->ok && keyed->ok);
    write_keys(json{{"enabled", true}, {"keys", kept_keys()}});
    auto ended = [](Peer& p) {
        return closed_within_reload(p, g_seated.get()) && p.ws.close_code == 1008 &&
               p.ws.close_reason == "license_required";
    };
    check("the keyless full socket is closed license_required", ended(*full));
    check("so is the fetch socket", ended(*fetch));
    check("and one that sent a key the open gate never judged", ended(*keyed));
    check("a seat taken before the gate went off stays", !g_seated->ws.closed());
    auto fresh = login_key(Ident(), "");
    check("a login without a key is refused again", !fresh->ok && refused_with(*fresh, "license_key_required"));
    g_seated->ws.close_clean();
    g_seated.reset();
    key_back_to_zero(LICENSE_KEYS[0], "after the gate went off and on");
}

// =license_grace (review item 7, HOL-SEC-220): run_live.sh starts this relay with graces
// of two minutes, so a session in grace outlives a keys.json reload, and keys.json listing
// LIVE-GRACE-A and LIVE-GRACE-B. A reload ends every session in grace its file no longer
// admits, and only those.
static bool resumed_with(const Ident& id, const Peer& gone, const std::string& key) {
    auto back = login_key(id, key, gone.sid, gone.ws.counted);
    const bool resumed = back->ok && answer_type(*back) == "resumed";
    back->ws.close_clean();
    return resumed;
}

static bool ended_with(const Ident& id, const Peer& gone, const std::string& key) {
    auto back = login_key(id, key, gone.sid, gone.ws.counted);
    const bool ended = back->ok && answer_type(*back) == "auth_ok" && resume_failed(*back) == "unknown";
    back->ws.close_clean();
    return ended;
}

// Logs in with `key` until `in` says the relay read keys.json again (40 s at most).
static bool reloaded(const std::string& key, bool in) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(40'000);
    while (left_ms(deadline) > 0) {
        // A v2 login holds no session, so the watching leaves no grace behind.
        auto p = login_key(Ident(), key, "", 0, "full", true);
        const bool ok = p->ok;
        if (!p->ws.closed()) p->ws.close_clean();
        if (ok == in) return true;
        sleep_ms(1000);
    }
    return false;
}

static void test_license_grace() {
    printf("license: a keys.json reload ends the sessions in grace it no longer admits\n");
    signal(SIGPIPE, SIG_IGN);
    const std::string ka = "LIVE-GRACE-A", kb = "LIVE-GRACE-B";
    Ident ida, idb;
    auto a = into_grace(ida, ka);
    auto b = into_grace(idb, kb);
    check("(two devices in grace, one on each key)", a->ok && b->ok && !a->sid.empty() && !b->sid.empty());
    write_keys(json{{"enabled", true}, {"keys", json::array({kb})}});
    check("(the reload that drops a key is in)", reloaded(ka, false));
    check("a session in grace under the revoked key ended with it", ended_with(ida, *a, kb));
    check("one under a kept key goes on", resumed_with(idb, *b, kb));
    auto held = into_grace(idb, kb);
    write_keys(json{{"enabled", false}, {"keys", json::array({kb})}});
    check("(the reload that turns the gate off is in)", reloaded("", true));
    Ident idc, idd;
    auto c = into_grace(idc, "");
    auto d = into_grace(idd, kb);
    check("(two devices let in with the gate off, now in grace)", c->ok && d->ok);
    write_keys(json{{"enabled", true}, {"keys", json::array({kb})}});
    check("(the reload that turns the gate on is in)", reloaded("", false));
    check("a session in grace the open gate let in ended", ended_with(idc, *c, kb));
    check("so did one whose login sent a key the open gate never judged", ended_with(idd, *d, kb));
    check("one that held a seat of a kept key before the gate went off goes on", resumed_with(idb, *held, kb));
}

// =license_unread (HOL-SEC-220): run_live.sh starts this relay with a keys.json that does
// not read. It refuses everyone, with a code no client takes as final, until it reads.
static void test_license_unread() {
    printf("license: a keys.json that does not read at boot shuts the relay\n");
    signal(SIGPIPE, SIG_IGN);
    Socket s;
    const auto body = s.get("/relay-status");
    const json st = body ? json::parse(*body, nullptr, false) : json();
    check("it says it needs a key", st.is_object() && st.value("license_required", false));
    auto refused = [](Peer& p) {
        return !p.ok && p.answer.value("error", "") == "keys_unreadable" && closed_by_relay(p) &&
               p.ws.close_code == 1013;
    };
    auto keyless = login_key(Ident(), "");
    check("a login without a key is refused, to retry", refused(*keyless));
    auto keyed = login_key(Ident(), "LIVE-UNREAD");
    check("so is one with the key the operator meant to list", refused(*keyed));
    auto fetch = login_key(Ident(), "LIVE-UNREAD", "", 0, "fetch", true);
    check("and a fetch login", refused(*fetch));
    write_keys(json{{"enabled", true}, {"keys", json::array({"LIVE-UNREAD"})}});
    std::unique_ptr<Peer> in;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(40'000);
    while (left_ms(deadline) > 0) {
        in = login_key(Ident(), "LIVE-UNREAD");
        if (in->ok) break;
        in->ws.close_clean();
        sleep_ms(2000);
    }
    check("once the file reads, its key gets in", in && in->ok);
    auto none = login_key(Ident(), "");
    check("and a login without one is refused as on any members-only relay",
          !none->ok && refused_with(*none, "license_key_required"));
    if (in) in->ws.close_clean();
}

static void test_license_seats() {
    if (g_keys_file.empty()) {
        check("RELAY_LIVE_KEYS names the relay's keys.json", false);
        return;
    }
    signal(SIGPIPE, SIG_IGN);
    license_ip_limit_refusal_frees_its_seat();
    license_cooldown_refusal_frees_its_seat();
    license_supersede_keeps_the_seat();
    license_every_path_back_to_zero();
    license_stats_count_full_keys();
    license_revoked_key_closes_every_socket();
    license_gate_off_kicks_nobody();
    license_gate_on_ends_the_keyless();
}
