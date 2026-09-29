// Unit tests for the join lock chains (src/join_lock.h): what the relay takes as a
// server's newest lock. The pinned chain is the one the Rust test
// `node::join_lock::tests::a_pinned_chain_verifies_as_the_relay_verifies_it` pins:
// if the signed payloads ever drift apart, either the relay refuses every real
// chain or it keeps one the clients reject. Change both or neither.
//
// Build + run from relay-uws/test (libsodium, and OpenSSL for crypto.cpp):
//   g++ -std=c++17 -I../src test_join_lock.cpp ../src/crypto.cpp -lsodium -lcrypto
//       -o test_join_lock && ./test_join_lock

#include "join_lock.h"
#include "crypto.h"

#include <sodium.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

static const char* PINNED_SERVER = "8ef8bc89d3891dca86ff72c6783e396351aed5ba";
static const char* PINNED_OWNER = "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5";
static const char* PINNED_NONCE = "00112233445566778899aabbccddeeff";
static const char* PINNED_CHAIN =
    R"([{"n":1,"door":"zo060cy2M-x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk","change":"CAESIO1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfR","sig":"hADu+IFDBj9pUpXj92etL6dWrmeZk/4DoQUxpU0wDJ5l7GewH8s+CNNfHfAe9OLcJk7lX+AupdjRLD+UexRACA==","owner":"CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c","nonce":"00112233445566778899aabbccddeeff"},{"n":2,"door":"rAGyIJ6GNU-4UyN7XeD0-rE8f8v0M6YcAZNpYX_s8Qs","change":"CAESIG56HN0psLeP0Tr0xVmP7/TvKpcWbjym8uT7/M2AUFvx","sig":"rMKiInifn0Nl07+eV0lMkYk/XXLQRDF8sDT/aqxZSpqmSFspymgQw4MGZJ7VtVbFXNtJ8sbHTdQDcs+Dv1AJCw=="}])";

static const LockCrypto crypto{verify_ed25519, derive_peer_id, genesis_server_id};

static std::string b64(const unsigned char* data, size_t len, int variant) {
    std::string out(sodium_base64_encoded_len(len, variant), '\0');
    sodium_bin2base64(out.data(), out.size(), data, len, variant);
    out.resize(strlen(out.c_str()));
    return out;
}

// An Ed25519 key from a seed of one repeated byte, as the Rust tests make them.
struct Key {
    unsigned char pk[crypto_sign_PUBLICKEYBYTES];
    unsigned char sk[crypto_sign_SECRETKEYBYTES];
    std::string text;  // protobuf-encoded public key, standard base64

    explicit Key(unsigned char tag) {
        unsigned char seed[crypto_sign_SEEDBYTES];
        memset(seed, tag, sizeof(seed));
        crypto_sign_seed_keypair(pk, sk, seed);
        unsigned char proto[36] = {0x08, 0x01, 0x12, 0x20};
        memcpy(proto + 4, pk, 32);
        text = b64(proto, sizeof(proto), sodium_base64_VARIANT_ORIGINAL);
    }

    std::string sign(const std::string& msg) const {
        unsigned char sig[crypto_sign_BYTES];
        crypto_sign_detached(sig, nullptr, reinterpret_cast<const unsigned char*>(msg.data()), msg.size(), sk);
        return b64(sig, sizeof(sig), sodium_base64_VARIANT_ORIGINAL);
    }
};

// Any 32 bytes stand in for a door: the relay never reads it as a key.
static std::string door(unsigned char tag) {
    unsigned char bytes[32];
    memset(bytes, tag, sizeof(bytes));
    return b64(bytes, sizeof(bytes), sodium_base64_VARIANT_URLSAFE_NO_PADDING);
}

static LockLink base_link(const std::string& server, uint64_t n, const Key& owner, const std::string& nonce,
                          unsigned char door_tag, const Key& change) {
    LockLink l;
    l.n = n;
    l.door = door(door_tag);
    l.change = change.text;
    l.owner = owner.text;
    l.has_owner = true;
    if (join_lock::is_genesis_id(server)) {
        l.nonce = nonce;
        l.has_nonce = true;
    }
    l.sig = owner.sign(join_lock::payload(server, l));
    return l;
}

static LockLink next_link(const std::string& server, const LockLink& prev, const Key& prev_change,
                          unsigned char door_tag, const Key& change) {
    LockLink l;
    l.n = prev.n + 1;
    l.door = door(door_tag);
    l.change = change.text;
    l.sig = prev_change.sign(join_lock::payload(server, l));
    return l;
}

static void test_pinned_chain() {
    printf("pinned chain (shared with the Rust test)\n");
    check("the genesis id hashes from the owner and the nonce",
          genesis_server_id(PINNED_OWNER, PINNED_NONCE) == PINNED_SERVER);
    auto links = join_lock::links_from_json(nlohmann::json::parse(PINNED_CHAIN));
    check("it parses", links.has_value() && links->size() == 2);
    if (!links) return;
    check("it verifies back to its owner", join_lock::verify_chain(PINNED_SERVER, *links, crypto) == PINNED_OWNER);
    auto round = join_lock::links_from_json(join_lock::links_to_json(*links));
    check("it survives the relay's own JSON", round && *round == *links);

    auto swapped = *links;
    swapped[1].door = swapped[0].door;
    check("a door changed after signing breaks it", join_lock::verify_chain(PINNED_SERVER, swapped, crypto).empty());
    check("another server's id breaks it",
          join_lock::verify_chain("0000000000000000000000000000000000000000", *links, crypto).empty());
    std::vector<LockLink> tail(links->begin() + 1, links->end());
    check("a chain that does not start with the owner is none", join_lock::verify_chain(PINNED_SERVER, tail, crypto).empty());
}

static void test_put_rules() {
    printf("put rules\n");
    Key owner(1), c1(11), c2(12), c3(13), c4(14), stranger(9);
    std::string nonce = "aa";
    std::string server = genesis_server_id(derive_peer_id(owner.text), nonce);

    LockLink first = base_link(server, 1, owner, nonce, 1, c1);
    auto stored = join_lock::relay_put(server, {}, {first}, crypto);
    check("a first valid chain is taken", stored.has_value());
    check("an extension of nothing is not", !join_lock::relay_put(server, {}, {next_link(server, first, c1, 2, c2)}, crypto));

    LockLink a = next_link(server, first, c1, 2, c2);
    LockLink b = next_link(server, first, c1, 3, c3);
    stored = join_lock::relay_put(server, *stored, {a}, crypto);
    check("the first extension wins", stored && stored->back() == a);
    check("a second extension of the same lock loses", !join_lock::relay_put(server, *stored, {b}, crypto));
    check("so does a whole chain ending in it", !join_lock::relay_put(server, *stored, {first, b}, crypto));
    check("a link signed by the wrong key is refused",
          !join_lock::relay_put(server, *stored, {next_link(server, a, c1, 4, c4)}, crypto));

    LockLink compact = base_link(server, a.n, owner, nonce, 2, c2);
    auto shorter = join_lock::relay_put(server, *stored, {compact}, crypto);
    check("the owner's re-signing compacts the chain", shorter && shorter->size() == 1 && shorter->back() == compact);
    auto again = join_lock::relay_put(server, *shorter, {first, a}, crypto);
    check("republishing the longer chain changes nothing", again && *again == *shorter);

    LockLink rogue = next_link(server, compact, c2, 5, c3);
    stored = join_lock::relay_put(server, *shorter, {rogue}, crypto);
    check("a mod's extension is taken first", stored && stored->back() == rogue);
    check("a reset must pass the newest lock",
          !join_lock::relay_put(server, *stored, {base_link(server, rogue.n, owner, nonce, 6, c4)}, crypto));
    LockLink reset = base_link(server, rogue.n + 1, owner, nonce, 7, c4);
    auto after = join_lock::relay_put(server, *stored, {reset}, crypto);
    check("the owner resets past a fork", after && after->size() == 1 && after->back() == reset);
    check("the fork cannot come back", !join_lock::relay_put(server, *after, {compact, rogue}, crypto));
    Key c5(16);
    LockLink rogue_past = next_link(server, rogue, c3, 9, c5);
    LockLink rogue_further = next_link(server, rogue_past, c5, 10, c1);
    check("not even grown past the reset",
          !join_lock::relay_put(server, *after, {compact, rogue, rogue_past, rogue_further}, crypto));
    Key impostor_change(15);
    check("nobody else resets",
          !join_lock::relay_put(server, *after, {base_link(server, 99, stranger, nonce, 8, impostor_change)}, crypto));
}

static void test_legacy_records() {
    printf("legacy ids are kept per owner\n");
    Key owner(1), squatter(2), c1(11), c2(12);
    std::string legacy = "0123456789abcdef0123456789abcdef";
    std::string owner_id = derive_peer_id(owner.text);
    std::string squatter_id = derive_peer_id(squatter.text);
    JoinLocks locks;
    std::vector<LockLink> current;
    check("a squatter cannot file under the owner's name",
          !locks.put(legacy, owner_id, {base_link(legacy, 1, squatter, "", 1, c1)}, crypto, current, 2));
    check("under its own name it can", locks.put(legacy, squatter_id, {base_link(legacy, 1, squatter, "", 1, c1)}, crypto, current, 2));
    check("which does not touch the owner's record", locks.get(join_lock::record_key(legacy, owner_id)) == nullptr);
    check("the owner files its own", locks.put(legacy, owner_id, {base_link(legacy, 1, owner, "", 2, c2)}, crypto, current, 1));
    const auto* held = locks.get(join_lock::record_key(legacy, owner_id));
    check("and reads it back", held && held->size() == 1 && join_lock::verify_chain(legacy, *held, crypto) == owner_id);
}

// HOL-SEC-069: one account filing chains under ids of its own could hold the relay's
// whole memory. The table keeps a byte budget, and a flood evicts only its own share.
static void test_budget() {
    printf("the table keeps a byte budget and a flood pays for itself\n");
    Key owner(1), flooder(2), c1(11), c2(12);
    std::string owner_id = derive_peer_id(owner.text);
    std::string flooder_id = derive_peer_id(flooder.text);
    JoinLocks locks;
    locks.budget = 64 * 1024;
    std::vector<LockLink> current;
    std::string real = genesis_server_id(owner_id, "aa");
    check("a real server files its chain", locks.put(real, owner_id, {base_link(real, 1, owner, "aa", 1, c1)}, crypto, current, 1));
    size_t filed = 0;
    for (int i = 0; i < 400; i++) {
        char hex[33];
        snprintf(hex, sizeof(hex), "%032x", i);
        if (locks.put(hex, flooder_id, {base_link(hex, 1, flooder, "", 2, c2)}, crypto, current, 9)) filed++;
    }
    check("the flood files, it is never refused", filed == 400);
    check("the table stays within its budget", locks.bytes() <= locks.budget);
    check("the flood lost its own oldest records", locks.get(join_lock::record_key("00000000000000000000000000000000", flooder_id)) == nullptr);
    check("the real server's chain survives", locks.get(real) != nullptr);
    const auto* newest = locks.get(join_lock::record_key("0000000000000000000000000000018f", flooder_id));
    check("the flood keeps its newest", newest != nullptr);
    check("a re-put of the same chain changes nothing",
          locks.put(real, owner_id, {base_link(real, 1, owner, "aa", 1, c1)}, crypto, current, 9) && locks.ledger.share_of(real) == std::optional<uint64_t>(1));
}

static void test_shapes() {
    printf("shapes\n");
    Key owner(1), c1(11);
    std::string server = genesis_server_id(derive_peer_id(owner.text), "aa");
    LockLink good = base_link(server, 1, owner, "aa", 1, c1);
    check("a good link is well formed", join_lock::well_formed(good));
    LockLink big = good;
    big.n = join_lock::MAX_N + 1;
    check("a number past 2^53 is not", !join_lock::well_formed(big));
    LockLink long_door = good;
    long_door.door += "A";
    check("a long door is not", !join_lock::well_formed(long_door));
    LockLink nonce_on_next = good;
    nonce_on_next.has_owner = false;
    nonce_on_next.owner.clear();
    check("a nonce belongs to an owner-signed link", !join_lock::well_formed(nonce_on_next));
    check("a link missing a field does not parse",
          !join_lock::link_from_json(nlohmann::json::parse(R"({"n":1,"door":"x","change":"y"})")));
    check("a number that is not one does not parse",
          !join_lock::link_from_json(nlohmann::json::parse(R"({"n":"1","door":"x","change":"y","sig":"z"})")));
    check("one bad link spoils the array",
          !join_lock::links_from_json(nlohmann::json::parse(R"([{"n":1,"door":"x","change":"y","sig":"z"},7])")));
    check("a 32-hex id is a server id", join_lock::is_server_id_shape("0123456789abcdef0123456789abcdef"));
    check("free text is not", !join_lock::is_server_id_shape("inbox:someone"));
}

int main() {
    if (sodium_init() < 0) return 2;
    test_pinned_chain();
    test_put_rules();
    test_legacy_records();
    test_budget();
    test_shapes();
    printf(failures == 0 ? "ALL PASSED\n" : "%d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
