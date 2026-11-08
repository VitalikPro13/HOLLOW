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

int main() {
    const std::string k = "AB12-CD32-BA30-LJ50";
    const std::string other = "QQ44-RT19-ZZ08-MN71";

    LicensePool off;
    check("disabled pool needs no key", off.validate(nullptr, "p1") == LicenseResult::NotRequired);

    LicensePool pool;
    pool.enabled = true;
    pool.keys = {k};
    check("no key is refused", pool.validate(nullptr, "p1") == LicenseResult::KeyRequired);
    const std::string empty;
    check("empty key is refused", pool.validate(&empty, "p1") == LicenseResult::KeyRequired);
    check("unknown key is refused", pool.validate(&other, "p1") == LicenseResult::InvalidKey);

    // A person's devices share one key.
    for (size_t i = 1; i <= LicensePool::MAX_DEVICES_PER_KEY; i++) {
        std::string pid = "device" + std::to_string(i);
        check("device within the cap is admitted", pool.validate(&k, pid) == LicenseResult::Ok);
    }
    check("a device re-authenticating is admitted", pool.validate(&k, "device1") == LicenseResult::Ok);
    check("one past the cap is refused", pool.validate(&k, "device6") == LicenseResult::KeyInUse);
    check("cap holds after the refusal", pool.holders[k].size() == LicensePool::MAX_DEVICES_PER_KEY);

    pool.release("device3");
    check("a released slot admits the next device", pool.validate(&k, "device6") == LicenseResult::Ok);
    pool.release("nobody");
    check("releasing a stranger changes nothing", pool.holders[k].size() == LicensePool::MAX_DEVICES_PER_KEY);

    // Reload that keeps the key kicks nobody; one that drops it kicks every holder.
    check("keeping the key kicks nobody", pool.replace_keys({k, other}, true).empty());
    check("key survives the reload", pool.keys.count(k) == 1 && pool.keys.count(other) == 1);
    auto kicked = pool.replace_keys({other}, true);
    std::sort(kicked.begin(), kicked.end());
    check("dropping the key kicks all its holders", kicked.size() == LicensePool::MAX_DEVICES_PER_KEY);
    check("kicked holders are forgotten", pool.holders.count(k) == 0);
    check("the dropped key no longer admits", pool.validate(&k, "device1") == LicenseResult::InvalidKey);
    check("the kept key admits", pool.validate(&other, "device1") == LicenseResult::Ok);

    pool.replace_keys({}, false);
    check("reload can disable the gate", pool.validate(nullptr, "p9") == LicenseResult::NotRequired);

    // A key with no holders leaves no entry behind.
    LicensePool tidy;
    tidy.enabled = true;
    tidy.keys = {k};
    tidy.validate(&k, "solo");
    tidy.release("solo");
    check("last release removes the entry", tidy.holders.empty());

    // HOL-SEC-203: a keys.json of the wrong shape reads as nothing and changes nothing. The
    // reload runs in a uSockets timer, where a throw ends the relay without its snapshot.
    LicensePool held;
    held.enabled = true;
    held.keys = {k};
    held.validate(&k, "member");
    std::vector<std::string> gone;
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
              held.validate(&k, "member") == LicenseResult::Ok);
    check("a good keys.json still reloads",
          held.reload_text(R"({"enabled":true,"keys":["QQ44-RT19-ZZ08-MN71",5]})", gone) &&
              held.keys == std::unordered_set<std::string>{other} && gone == std::vector<std::string>{"member"});
    auto defaults = parse_keys_file("{}");
    check("missing fields read as off with no keys", defaults && !defaults->enabled && defaults->keys.empty());

    printf("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
