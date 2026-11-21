// Unit tests for the license pool (src/license_pool.h): who a key admits.
//
// Build + run from relay-uws/test (no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_license_pool.cpp -o test_license_pool && ./test_license_pool
#include "license_pool.h"
#include <algorithm>
#include <cstdio>
#include <vector>

static int failures = 0;
static void check(const char* label, bool ok) {
    printf("  %s %s\n", ok ? "ok  " : "FAIL", label);
    if (!ok) failures++;
}

// Socket tokens for the tests: any distinct numbers stand for distinct sockets.
static SeatToken sock(int n) { return static_cast<SeatToken>(0x1000 + n); }

int main() {
    const std::string k = "AB12-CD32-BA30-LJ50";
    const std::string other = "QQ44-RT19-ZZ08-MN71";

    LicensePool off;
    check("disabled pool needs no key", off.validate(nullptr, "p1", sock(1)) == LicenseResult::NotRequired);
    check("and takes no seat", off.seats.empty() && off.holders.empty());

    LicensePool pool;
    pool.enabled = true;
    pool.keys = {k};
    check("no key is refused", pool.validate(nullptr, "p1", sock(1)) == LicenseResult::KeyRequired);
    const std::string empty;
    check("empty key is refused", pool.validate(&empty, "p1", sock(1)) == LicenseResult::KeyRequired);
    check("unknown key is refused", pool.validate(&other, "p1", sock(1)) == LicenseResult::InvalidKey);
    check("a refused key takes no seat", pool.seats.empty());

    // A person's devices share one key.
    for (int i = 1; i <= static_cast<int>(LicensePool::MAX_DEVICES_PER_KEY); i++) {
        std::string pid = "device" + std::to_string(i);
        check("device within the cap is admitted", pool.validate(&k, pid, sock(i)) == LicenseResult::Ok);
    }
    check("a device's second socket is admitted", pool.validate(&k, "device1", sock(11)) == LicenseResult::Ok);
    check("and takes no second seat", pool.seats_of(k) == LicensePool::MAX_DEVICES_PER_KEY);
    check("no refusal counted yet", pool.seats_full_refused == 0);
    check("one past the cap is refused", pool.validate(&k, "device6", sock(6)) == LicenseResult::KeyInUse);
    check("and counted for the stats", pool.seats_full_refused == 1);
    check("cap holds after the refusal", pool.holders[k].size() == LicensePool::MAX_DEVICES_PER_KEY);
    check("the refused socket holds nothing", pool.seats.count(sock(6)) == 0);

    // #153: a superseded ghost's close keeps its device's seat while the successor lives.
    pool.release(sock(1));
    check("a device keeps its seat while another of its sockets is open",
          pool.seats_of(k) == LicensePool::MAX_DEVICES_PER_KEY &&
              pool.validate(&k, "device6", sock(6)) == LicenseResult::KeyInUse);
    pool.release(sock(11));
    check("its last socket's close gives the seat back", pool.seats_of(k) == LicensePool::MAX_DEVICES_PER_KEY - 1);

    // #153: a socket refused after its key was judged gives its seat back on its close.
    check("a released seat admits the next device", pool.validate(&k, "device6", sock(6)) == LicenseResult::Ok);
    pool.release(sock(6));
    check("a socket refused later gives its seat back", pool.seats_of(k) == LicensePool::MAX_DEVICES_PER_KEY - 1);
    pool.release(sock(99));
    check("releasing a socket that holds nothing changes nothing",
          pool.holders[k].size() == LicensePool::MAX_DEVICES_PER_KEY - 1);
    pool.release(sock(6));
    check("releasing twice changes nothing", pool.seats_of(k) == LicensePool::MAX_DEVICES_PER_KEY - 1);
    check("a socket judged again holds one seat", pool.validate(&k, "device6", sock(6)) == LicenseResult::Ok &&
                                                      pool.validate(&k, "device6", sock(6)) == LicenseResult::Ok &&
                                                      pool.seats_of(k) == LicensePool::MAX_DEVICES_PER_KEY);

    // Reload that keeps the key kicks nobody; one that drops it kicks every socket on it.
    check("a device's second socket again", pool.validate(&k, "device2", sock(12)) == LicenseResult::Ok);
    check("keeping the key kicks nobody", pool.replace_keys({k, other}, true).empty());
    check("key survives the reload", pool.keys.count(k) == 1 && pool.keys.count(other) == 1);
    check("(a socket on the kept key)", pool.validate(&other, "device9", sock(20)) == LicenseResult::Ok);
    auto kicked = pool.replace_keys({other}, true).revoked;
    std::sort(kicked.begin(), kicked.end());
    check("dropping the key kicks every socket on it, a device's second one too",
          kicked == std::vector<SeatToken>{sock(2), sock(3), sock(4), sock(5), sock(6), sock(12)});
    check("kicked holders are forgotten", pool.holders.count(k) == 0 && pool.seats.count(sock(2)) == 0);
    check("the kept key's socket stays", pool.seats.count(sock(20)) == 1 && pool.seats_of(other) == 1);
    check("the dropped key no longer admits", pool.validate(&k, "device1", sock(1)) == LicenseResult::InvalidKey);
    check("the kept key admits", pool.validate(&other, "device1", sock(1)) == LicenseResult::Ok);
    // The key comes back and a kicked device holds it on a new socket: the kicked socket's
    // late close never takes that seat.
    pool.replace_keys({k, other}, true);
    check("(the key is back)", pool.validate(&k, "device2", sock(30)) == LicenseResult::Ok);
    pool.release(sock(2));
    check("a kicked socket's close never frees a seat taken since", pool.seats_of(k) == 1);

    pool.replace_keys({}, false);
    check("reload can disable the gate", pool.validate(nullptr, "p9", sock(40)) == LicenseResult::NotRequired);

    // A socket judged again under another key or device holds only its newest seat.
    LicensePool moved;
    moved.enabled = true;
    moved.keys = {k, other};
    moved.validate(&k, "first", sock(1));
    check("a socket judged again holds only its newest seat",
          moved.validate(&other, "second", sock(1)) == LicenseResult::Ok && moved.seats_of(k) == 0 &&
              moved.seats_of(other) == 1 && moved.seats.size() == 1);

    // A key with no holders leaves no entry behind.
    LicensePool tidy;
    tidy.enabled = true;
    tidy.keys = {k};
    tidy.validate(&k, "solo", sock(1));
    tidy.validate(&k, "solo", sock(2));
    tidy.release(sock(1));
    tidy.release(sock(2));
    check("last release removes the entry", tidy.holders.empty() && tidy.seats.empty());

    // HOL-SEC-203: a keys.json of the wrong shape reads as nothing and changes nothing. The
    // reload runs in a uSockets timer, where a throw ends the relay without its snapshot.
    LicensePool held;
    held.enabled = true;
    held.keys = {k};
    held.validate(&k, "member", sock(1));
    Kicks gone;
    bool reread = false;
    for (const char* text : {R"({"enabled":"yes","keys":["QQ44-RT19-ZZ08-MN71"]})",
                             R"({"enabled":true,"keys":"QQ44-RT19-ZZ08-MN71"})", R"(["QQ44-RT19-ZZ08-MN71"])",
                             R"("enabled")", R"({"enabled":1})", "{", ""}) {
        try {
            reread = held.reload_text(text, gone);
        } catch (...) {
            reread = true;
            check("a keys.json of the wrong shape never throws", false);
        }
        if (reread) break;
    }
    check("a keys.json with enabled as a string keeps the previous keys",
          !reread && held.enabled && held.keys == std::unordered_set<std::string>{k} && gone.empty() &&
              held.validate(&k, "member", sock(2)) == LicenseResult::Ok);
    check("a good keys.json still reloads",
          held.reload_text(R"({"enabled":true,"keys":["QQ44-RT19-ZZ08-MN71",5]})", gone) &&
              held.keys == std::unordered_set<std::string>{other} &&
              gone.revoked.size() == 2 && gone.keyless.empty() && held.seats.empty());
    // HOL-SEC-220: a keys.json that is there but does not read at boot shuts the gate,
    // never opens it, and the refusal is one a client retries.
    LicensePool broken;
    broken.refuse_unread();
    check("an unread keys file refuses every login, with a key or without",
          broken.validate(&k, "p1", sock(1)) == LicenseResult::Unreadable &&
              broken.validate(nullptr, "p2", sock(2)) == LicenseResult::Unreadable);
    check("and lets nobody in to be judged later", broken.seats.empty() && broken.keyless.empty());
    check("it says a key is needed", broken.enabled);
    check("and admits no session in grace", !broken.admits("") && !broken.admits(k));
    Kicks none;
    check("a file that reads lifts it",
          broken.reload_text(R"({"enabled":true,"keys":["AB12-CD32-BA30-LJ50"]})", none) && !broken.unread &&
              broken.validate(&k, "p1", sock(1)) == LicenseResult::Ok);
    LicensePool broken_open;
    broken_open.refuse_unread();
    check("one that turns the gate off opens it",
          broken_open.reload_text(R"({"enabled":false})", none) &&
              broken_open.validate(nullptr, "p1", sock(1)) == LicenseResult::NotRequired);

    // Reviewer's checks (fix/153 review 1, items 1 and 2).
    {
        LicensePool p;
        p.enabled = true;
        p.keys = {"K"};
        std::string key = "K";
        p.validate(&key, "d1", 1);
        p.validate(&key, "d2", 2);
        auto kicks = p.replace_keys({}, false);
        check("turning the gate off kicks nobody", kicks.empty());
    }
    {
        LicensePool p;
        p.enabled = false;
        p.validate(nullptr, "stranger", 7);
        auto kicks = p.replace_keys({"K"}, true);
        std::string key = "K";
        for (int i = 0; i < 5; i++) p.validate(&key, "dev" + std::to_string(i), 100 + i);
        check("turning the gate on closes (or seats) the sockets it let in keyless",
              kicks.keyless == std::vector<SeatToken>{7} && kicks.revoked.empty());
    }

    // The gate off and on again: a seat taken before it went off stays if its key does, a
    // key the file dropped meanwhile ends its sockets once the gate is back.
    LicensePool cycle;
    cycle.enabled = true;
    cycle.keys = {k, other};
    cycle.validate(&k, "a", sock(1));
    cycle.validate(&other, "b", sock(2));
    check("(the gate off, both keys dropped)", cycle.replace_keys({}, false).empty());
    check("a socket let in while the gate is off holds no seat",
          cycle.validate(&k, "c", sock(3)) == LicenseResult::NotRequired && cycle.seats.count(sock(3)) == 0 &&
              cycle.keyless.count(sock(3)) == 1);
    cycle.validate(nullptr, "d", sock(4));
    cycle.release(sock(4));
    auto back = cycle.replace_keys({k}, true);
    std::sort(back.revoked.begin(), back.revoked.end());
    check("the gate back on ends the socket whose key the file dropped meanwhile",
          back.revoked == std::vector<SeatToken>{sock(2)});
    check("and every socket the open gate let in, a closed one not again",
          back.keyless == std::vector<SeatToken>{sock(3)} && cycle.keyless.empty());
    check("a seat taken before the gate went off stays while its key does",
          cycle.seats.count(sock(1)) == 1 && cycle.seats_of(k) == 1);
    check("a socket judged with the gate on again sheds its keyless mark",
          cycle.validate(&k, "c", sock(3)) == LicenseResult::Ok && cycle.keyless.empty());

    // What a reload asks of a session in grace (it holds no seat): the key its last login
    // held, "" when the gate let it in without one.
    check("with the gate on, a session in grace stays only under a listed key",
          cycle.admits(k) && !cycle.admits(other) && !cycle.admits(""));
    cycle.replace_keys({k}, false);
    check("with the gate off every one stays", cycle.admits("") && cycle.admits(other));

    auto defaults = parse_keys_file("{}");
    check("missing fields read as off with no keys", defaults && !defaults->enabled && defaults->keys.empty());

    printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
