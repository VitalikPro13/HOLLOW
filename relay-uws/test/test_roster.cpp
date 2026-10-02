// Unit tests for the relay's roster mirror (src/roster.h, src/roster_book.h, design
// ID-1R). The vectors in roster_vectors.json come from the Rust code
// (identity/roster_vectors.rs): every case is one roster shown on an inbox join, and
// this relay must land on the same held roster, byte for byte, the same first sights
// and the same members. If they drift, the relay lets in a device the apps refuse, or
// shuts out one they accept. Change both or neither.
//
// Build + run from relay-uws/test (libsodium, and OpenSSL for crypto.cpp):
//   g++ -std=c++17 -I../src test_roster.cpp ../src/crypto.cpp -lsodium -lcrypto
//       -o test_roster && ./test_roster

#include "roster_book.h"
#include "roster_crypto.h"

#include <sodium.h>

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

using json = nlohmann::json;

static std::vector<std::string> strings(const json& j) {
    std::vector<std::string> out;
    for (const auto& e : j) out.push_back(e.get<std::string>());
    return out;
}

static std::unordered_map<std::string, int64_t> seen_of(const json& j) {
    std::unordered_map<std::string, int64_t> out;
    for (auto it = j.begin(); it != j.end(); ++it) out[it.key()] = it.value().get<int64_t>();
    return out;
}

// One vector: hold what the case holds, show what it shows, compare everything.
static bool run_case(const json& c, const RosterCrypto& crypto, std::string& why) {
    const std::string master = c["master"];
    const std::string device = c["device"];
    const int64_t now = c["now_ms"];
    RosterBook book;
    if (!c["held"].is_null()) {
        auto held = roster::from_json(c["held"]);
        if (!held) {
            why = "held roster does not parse";
            return false;
        }
        book.restore(master, *held, seen_of(c["held_seen"]), 1);
    }
    auto shown = roster::from_json(c["shown"]);
    if (!shown) {
        why = "shown roster does not parse";
        return false;
    }
    RosterBook::Shown out = book.show(master, *shown, device, 2, now, crypto);

    const RosterBook::Held* held = book.get(master);
    const roster::Roster merged = held ? held->roster : roster::Roster::named(master);
    const std::string merged_json = roster::to_json(merged).dump();
    if (sha256_hex(merged_json) != c["merged_sha256"].get<std::string>()) {
        why = "held roster differs: " + merged_json.substr(0, 600);
        return false;
    }
    const auto counts = c["merged_counts"];
    const size_t got[7] = {merged.recoveries.size(), merged.phrase_admits.size(), merged.consents.size(),
                           merged.vouches.size(), merged.pendings.size(), merged.legacy.size(),
                           merged.removals.size()};
    for (size_t i = 0; i < 7; i++) {
        if (got[i] != counts[i].get<size_t>()) {
            why = "count " + std::to_string(i) + " differs";
            return false;
        }
    }
    std::unordered_map<std::string, int64_t> seen = held ? held->seen_ms : std::unordered_map<std::string, int64_t>{};
    if (seen != seen_of(c["seen"])) {
        why = "first sights differ";
        return false;
    }
    roster::State st = held ? book.fold(*held, now, crypto) : roster::State{};
    if (!held) st.base = roster::LEGACY_BASE;
    std::map<std::string, std::string> removed;
    for (auto it = c["removed"].begin(); it != c["removed"].end(); ++it) removed[it.key()] = it.value();
    const auto members = strings(c["members"]);
    const auto pending = strings(c["pending"]);
    if (st.base != c["base"].get<std::string>() || st.is_protected != c["protected"].get<bool>() ||
        st.no_wait != c["no_wait"].get<bool>() ||
        std::vector<std::string>(st.members.begin(), st.members.end()) != members ||
        std::vector<std::string>(st.pending.begin(), st.pending.end()) != pending || st.removed != removed) {
        why = "fold differs";
        return false;
    }
    if (out.member != c["member"].get<bool>()) {
        why = "membership of the shown device differs";
        return false;
    }
    return true;
}

// Ed25519 keys from a seed of one repeated byte, as the Rust tests make them.
struct Key {
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    unsigned char sk[crypto_sign_SECRETKEYBYTES];
    std::string id;

    explicit Key(unsigned char tag) {
        unsigned char seed[crypto_sign_SEEDBYTES];
        memset(seed, tag, sizeof(seed));
        crypto_sign_seed_keypair(pk, sk, seed);
        unsigned char mh[38] = {0x00, 0x24, 0x08, 0x01, 0x12, 0x20};
        memcpy(mh + 6, pk, 32);
        id = base58(mh, sizeof(mh));
    }
    std::string sign(const std::string& msg) const {
        unsigned char sig[crypto_sign_BYTES];
        crypto_sign_detached(sig, nullptr, reinterpret_cast<const unsigned char*>(msg.data()), msg.size(), sk);
        std::string out(sodium_base64_encoded_len(sizeof(sig), sodium_base64_VARIANT_ORIGINAL), '\0');
        sodium_bin2base64(out.data(), out.size(), sig, sizeof(sig), sodium_base64_VARIANT_ORIGINAL);
        out.resize(strlen(out.c_str()));
        return out;
    }
    static std::string base58(const unsigned char* data, size_t len) {
        static const char* A = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
        size_t zeros = 0;
        while (zeros < len && data[zeros] == 0) zeros++;
        std::vector<unsigned char> b((len - zeros) * 138 / 100 + 1, 0);
        for (size_t i = zeros; i < len; i++) {
            int carry = data[i];
            for (size_t j = b.size(); j-- > 0;) {
                carry += 256 * b[j];
                b[j] = static_cast<unsigned char>(carry % 58);
                carry /= 58;
            }
        }
        size_t it = 0;
        while (it < b.size() && b[it] == 0) it++;
        std::string s(zeros, '1');
        for (; it < b.size(); it++) s += A[b[it]];
        return s;
    }
};

int main() {
    if (sodium_init() < 0) return 1;
    printf("roster\n");
    const RosterCrypto crypto = roster_crypto();

    // Peer ids: the relay reads the same key the client does, and nothing else.
    {
        Key k(0x7a);
        unsigned char pk[32];
        check("a peer id names its key", peer_id_key(k.id, pk) && memcmp(pk, k.pk, 32) == 0);
        check("a mistyped id names none", !peer_id_key(k.id.substr(0, k.id.size() - 1) + "0", pk));
        check("an extra leading 1 names none", !peer_id_key("1" + k.id, pk));
        check("a huge id is refused before decoding", !peer_id_key(std::string(100000, 'z'), pk));
        check("an empty id names none", !peer_id_key("", pk));
    }

    // The vectors the Rust code wrote.
    {
        std::ifstream f("roster_vectors.json");
        std::stringstream ss;
        ss << f.rdbuf();
        json v = json::parse(ss.str(), nullptr, false);
        check("the vectors load", v.is_object() && v["cases"].is_array() && v["cases"].size() >= 100);
        size_t ok = 0, total = 0;
        for (const auto& c : v["cases"]) {
            std::string why;
            total++;
            if (run_case(c, crypto, why)) {
                ok++;
            } else {
                printf("  FAIL vector %s: %s\n", c["name"].get<std::string>().c_str(), why.c_str());
                failures++;
            }
        }
        check("every vector lands where the Rust code does (" + std::to_string(ok) + "/" + std::to_string(total) + ")",
              ok == total && total > 0);
    }

    // A roster's JSON is read as strictly as serde reads it.
    {
        Key m(1);
        auto good = roster::from_json(json::parse(R"({"master":")" + m.id + R"(","consents":[],"unknown":5})"));
        check("unknown fields are ignored", good.has_value() && good->master == m.id);
        check("missing fields default", roster::from_json(json::parse("{}")).has_value());
        check("a wrong type refuses the roster", !roster::from_json(json::parse(R"({"master":5})")));
        check("a null refuses the roster", !roster::from_json(json::parse(R"({"r_pub":null})")));
        check("a float time refuses the roster",
              !roster::from_json(json::parse(R"({"recoveries":[{"at_ms":1.5}]})")));
        check("a statement that is not an object refuses the roster",
              !roster::from_json(json::parse(R"({"vouches":["x"]})")));
        check("a non-string id refuses the roster",
              !roster::from_json(json::parse(R"({"recoveries":[{"keep":[1]}]})")));
        check("a time past i64 refuses the roster",
              !roster::from_json(json::parse(R"({"recoveries":[{"at_ms":18446744073709551615}]})")));
    }

    // The book: a removal shown by anyone sticks, an older roster takes nothing back,
    // and the record is charged to a member's share once one shows it.
    {
        Key m(1), r(2), owner(10), other(11);
        const int64_t now = 1800000000000;
        roster::Roster base = roster::Roster::named(m.id);
        auto consent = [&](const Key& d) { return roster::Consent{d.id, d.sign(roster::consent_payload(m.id, d.id))}; };
        base.consents = {consent(owner), consent(other)};
        for (const Key* d : {&owner, &other}) {
            base.legacy.push_back({d->id, m.sign(roster::legacy_payload(m.id, d->id))});
        }
        RosterBook book;
        auto first = book.show(m.id, base, other.id, 7, now, crypto);
        check("a legacy member owns the inbox", first.member);
        check("the record is charged to the member who showed it", book.ledger.share_of(m.id) == uint64_t{7});
        roster::Roster removing = base;
        removing.removals.push_back({roster::LEGACY_BASE, other.id, owner.id, {},
                                     owner.sign(roster::removal_payload(m.id, roster::LEGACY_BASE, other.id, {}))});
        auto by_stranger = book.show(m.id, removing, "12D3KooWStranger", 9, now, crypto);
        check("a removal shown by a stranger changes the held roster", by_stranger.changed && !by_stranger.member);
        check("and the record stays with the member's share", book.ledger.share_of(m.id) == uint64_t{7});
        check("the removed device is out", !book.show(m.id, base, other.id, 7, now, crypto).member);
        check("the remover is still in", book.show(m.id, base, owner.id, 7, now, crypto).member);

        // The phrase makes the roster protected: the pinned key stays, and a recovery
        // key someone else minted changes nothing.
        roster::Roster phrase = removing;
        std::string r_pub(sodium_base64_encoded_len(32, sodium_base64_VARIANT_ORIGINAL), '\0');
        sodium_bin2base64(r_pub.data(), r_pub.size(), r.pk, 32, sodium_base64_VARIANT_ORIGINAL);
        r_pub.resize(strlen(r_pub.c_str()));
        phrase.r_pub = r_pub;
        std::string p = roster::recovery_payload(m.id, r_pub, now - 1000, {owner.id}, false);
        phrase.recoveries.push_back({now - 1000, {owner.id}, false, r.sign(p), m.sign(p)});
        auto protect = book.show(m.id, phrase, owner.id, 7, now, crypto);
        check("a recovery shown by the owner holds", protect.member && protect.state.is_protected);
        Key fake(3);
        roster::Roster forged = roster::Roster::named(m.id);
        std::string f_pub(sodium_base64_encoded_len(32, sodium_base64_VARIANT_ORIGINAL), '\0');
        sodium_bin2base64(f_pub.data(), f_pub.size(), fake.pk, 32, sodium_base64_VARIANT_ORIGINAL);
        f_pub.resize(strlen(f_pub.c_str()));
        forged.r_pub = f_pub;
        std::string fp = roster::recovery_payload(m.id, f_pub, now, {other.id}, false);
        forged.recoveries.push_back({now, {other.id}, false, fake.sign(fp), m.sign(fp)});
        forged.consents = {consent(other)};
        auto thief = book.show(m.id, forged, other.id, 9, now, crypto);
        check("a recovery key minted by a master-key holder is ignored", !thief.member);
        check("and the owner keeps the inbox", book.show(m.id, base, owner.id, 7, now, crypto).member);
        check("a roster past a ceiling counts nobody", [&] {
            roster::Roster big = base;
            big.pendings.resize(roster::MAX_PENDING + 1);
            return !book.show(m.id, big, owner.id, 7, now, crypto).member;
        }());
    }

    // Fair share: a flood of records from one address share evicts only that share's.
    {
        Key m(1), owner(10);
        const int64_t now = 1800000000000;
        RosterBook book;
        book.budget = 64 * 1024;
        roster::Roster real = roster::Roster::named(m.id);
        real.consents = {{owner.id, owner.sign(roster::consent_payload(m.id, owner.id))}};
        real.legacy = {{owner.id, m.sign(roster::legacy_payload(m.id, owner.id))}};
        book.show(m.id, real, owner.id, 1, now, crypto);
        for (int i = 0; i < 150; i++) {
            Key junk(static_cast<unsigned char>(100 + i));
            roster::Roster r = roster::Roster::named(junk.id);
            r.consents = {{junk.id, junk.sign(roster::consent_payload(junk.id, junk.id))}};
            r.legacy = {{junk.id, junk.sign(roster::legacy_payload(junk.id, junk.id))}};
            book.show(junk.id, r, junk.id, 99, now, crypto);
        }
        check("the real record survives a flood from another share", book.get(m.id) != nullptr);
        check("the table stays within its budget", book.ledger.total() <= book.budget);
    }

    if (failures) {
        printf("%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("all ok\n");
    return 0;
}
