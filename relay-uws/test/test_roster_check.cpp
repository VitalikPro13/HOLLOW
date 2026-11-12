// Unit tests for when the relay answers a `roster_check` (src/roster_check.h, design
// ROSTER-CHECK). The cases in roster_check_vectors.json are read by the client's harness
// relay too (node/roster_check.rs): change both or neither.
//
// Build + run from relay-uws/test (libsodium, and OpenSSL for crypto.cpp):
//   g++ -std=c++17 -I../src test_roster_check.cpp ../src/crypto.cpp -lsodium -lcrypto
//       -o test_roster_check && ./test_roster_check

#include "roster_check.h"
#include "roster_book.h"
#include "roster_crypto.h"
#include "crypto.h"

#include <sodium.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>

using json = nlohmann::json;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static std::string b64(const unsigned char* data, size_t len) {
    std::string out(sodium_base64_encoded_len(len, sodium_base64_VARIANT_ORIGINAL), '\0');
    sodium_bin2base64(out.data(), out.size(), data, len, sodium_base64_VARIANT_ORIGINAL);
    out.resize(strlen(out.c_str()));
    return out;
}

struct Ident {
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    unsigned char sk[crypto_sign_SECRETKEYBYTES];
    std::string peer;

    Ident() {
        crypto_sign_keypair(pk, sk);
        unsigned char proto[36] = {0x08, 0x01, 0x12, 0x20};
        memcpy(proto + 4, pk, 32);
        peer = derive_peer_id(b64(proto, sizeof(proto)));
    }

    std::string sign(const std::string& msg) const {
        unsigned char sig[crypto_sign_BYTES];
        crypto_sign_detached(sig, nullptr, reinterpret_cast<const unsigned char*>(msg.data()), msg.size(), sk);
        return b64(sig, sizeof(sig));
    }
};

static void test_vectors() {
    printf("vectors\n");
    std::ifstream f("roster_check_vectors.json");
    const json v = json::parse(f, nullptr, false);
    check("roster_check_vectors.json parses", v.is_object() && v["cases"].is_array() && !v["cases"].empty());
    if (!v.is_object()) return;
    for (const auto& c : v["cases"]) {
        roster_check::Facts facts;
        facts.full = c.at("full").get<bool>();
        facts.master = c.at("master").get<std::string>();
        facts.device = c.at("device").get<std::string>();
        facts.nonce = c.at("n").get<std::string>();
        facts.room = c.at("room").get<std::string>();
        facts.asker_in_room = c.at("asker_in_room").get<bool>();
        facts.locked = c.at("locked").get<bool>();
        facts.newest_door = c.at("newest_door").get<bool>();
        facts.device_listed = c.at("device_listed").get<bool>();
        facts.placed = c.at("placed").get<bool>();
        check(c.at("name").get<std::string>(), roster_check::answers(facts) == c.at("answers").get<bool>());
    }
}

// A legacy-base roster for `master` naming `members`; `gone` removed by `by` when set.
static roster::Roster legacy(const Ident& master, const std::vector<const Ident*>& members, const Ident* gone = nullptr,
                             const Ident* by = nullptr) {
    roster::Roster r = roster::Roster::named(master.peer);
    for (const auto* d : members) {
        r.legacy.push_back({d->peer, master.sign(roster::legacy_payload(master.peer, d->peer))});
        r.consents.push_back({d->peer, d->sign(roster::consent_payload(master.peer, d->peer))});
    }
    if (gone && by) {
        roster::Removal x;
        x.base = roster::LEGACY_BASE;
        x.device = gone->peer;
        x.by = by->peer;
        x.sig = by->sign(roster::removal_payload(master.peer, roster::LEGACY_BASE, gone->peer, {}));
        r.removals.push_back(x);
    }
    return r;
}

static void test_places() {
    printf("which devices the fold places\n");
    const RosterCrypto c = roster_crypto();
    Ident master, phone, laptop, stranger;
    RosterBook book;
    const int64_t now = 1'790'000'000'000;
    book.show(master.peer, legacy(master, {&phone, &laptop}), phone.peer, 1, now, c);
    // A stranger's own consent, shown for a master it does not belong to.
    roster::Roster planted = roster::Roster::named(master.peer);
    planted.consents.push_back({stranger.peer, stranger.sign(roster::consent_payload(master.peer, stranger.peer))});
    book.show(master.peer, planted, stranger.peer, 2, now, c);
    const RosterBook::Held* held = book.get(master.peer);
    check("the record holds the planted consent", held && std::any_of(held->roster.consents.begin(), held->roster.consents.end(),
                                                                       [&](const roster::Consent& x) { return x.device == stranger.peer; }));
    roster::State s = book.fold(*held, now, c);
    check("a member is placed", roster_check::places(s, phone.peer));
    check("a planted consent places nothing", !roster_check::places(s, stranger.peer));
    check("nor does the master id", !roster_check::places(s, master.peer));

    book.show(master.peer, legacy(master, {&phone, &laptop}, &laptop, &phone), phone.peer, 1, now, c);
    s = book.fold(*book.get(master.peer), now, c);
    check("a removed device is still placed (the answer carries its removal)", roster_check::places(s, laptop.peer));
    check("and is no member", !s.is_member(laptop.peer));
}

static void test_dump_cache() {
    printf("the answer's statements\n");
    const RosterCrypto c = roster_crypto();
    Ident master, phone, laptop;
    RosterBook book;
    const int64_t now = 1'790'000'000'000;
    book.show(master.peer, legacy(master, {&phone, &laptop}), phone.peer, 1, now, c);
    const std::string first = book.dump(*book.get(master.peer));
    check("the dump is the held roster", first == roster::to_json(book.get(master.peer)->roster).dump());
    book.show(master.peer, legacy(master, {&phone, &laptop}), phone.peer, 1, now, c);
    check("an unchanged roster keeps the dump", book.dump(*book.get(master.peer)) == first);
    book.show(master.peer, legacy(master, {&phone, &laptop}, &laptop, &phone), phone.peer, 1, now, c);
    const std::string after = book.dump(*book.get(master.peer));
    check("a change dumps afresh, removal included",
          after != first && after == roster::to_json(book.get(master.peer)->roster).dump() &&
              after.find(laptop.peer) != std::string::npos && !book.get(master.peer)->roster.removals.empty());
}

int main() {
    if (sodium_init() < 0) return 2;
    test_vectors();
    test_places();
    test_dump_cache();
    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
