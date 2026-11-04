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
static const char* PINNED_OWNER_DEVICE = "12D3KooWGjSE7eCu5f1Pa8pGxscmoEcdQ5BRMGqbyMvL2dhrPCS5";
static const char* PINNED_MOD = "12D3KooWK98A5qKRAA9qZccvoJLvcLu68PCFZLNfdd81iQLvHj6W";
static const char* PINNED_MOD_DEVICE = "12D3KooWG3t2M63pjiZP7UHsWruK1tQomm9kMsTm4FS3YMTfE6ao";
static const char* PINNED_NONCE = "00112233445566778899aabbccddeeff";
static const char* PINNED_DEVICE_CHAIN =
    R"([{"n":1,"door":"zo060cy2M-x7cMF4FKXHbs0CloUFDTRHRboFhw5YfVk","change":"CAESIO1JKMYo0cLG6ukDOJBZlWEpWSc6XGP5NjbBRhSshzfR","sig":"hADu+IFDBj9pUpXj92etL6dWrmeZk/4DoQUxpU0wDJ5l7GewH8s+CNNfHfAe9OLcJk7lX+AupdjRLD+UexRACA==","owner":"CAESIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c","nonce":"00112233445566778899aabbccddeeff","dev":{"device":"CAESIGa+fjMsekUzMr2dCn99sFX1xe8aBq2mbZizn7aBDEc6","master":"12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5","sig":"QSgrTGbw/mbhrOLAw6cM2q06vNldJ9PP2XnvbQ0ra3dF0jzcWD5A1eEpTgBfjtyeWMS8UnLQQK+dfOi5Ru1aAg=="}},{"n":2,"door":"rAGyIJ6GNU-4UyN7XeD0-rE8f8v0M6YcAZNpYX_s8Qs","change":"CAESIG56HN0psLeP0Tr0xVmP7/TvKpcWbjym8uT7/M2AUFvx","sig":"rMKiInifn0Nl07+eV0lMkYk/XXLQRDF8sDT/aqxZSpqmSFspymgQw4MGZJ7VtVbFXNtJ8sbHTdQDcs+Dv1AJCw==","dev":{"device":"CAESIFycbfJhycuEBHV3aq782US0BTKPqyj5s6le9ASQ096E","master":"12D3KooWK98A5qKRAA9qZccvoJLvcLu68PCFZLNfdd81iQLvHj6W","sig":"gi+p/7czh9a7nQyDkdFpcPc6681Jm5RQo9oyVuCpSoLTbP+V81Av9sjC7mqZjfatPW9/ci3xCryPdRnIG5FuAw=="}}])";
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

static std::string id_of(const Key& k) { return derive_peer_id(k.text); }

// The proof that `device`, a device of `master`, made `l`.
static LockLink by(const std::string& server, LockLink l, const std::string& master, const Key& device) {
    l.dev_device = device.text;
    l.dev_master = master;
    l.has_dev = true;
    l.dev_sig = device.sign(join_lock::dev_payload(server, l));
    return l;
}

// A relay fold that counts exactly these (master, device) pairs.
static LockCounted counting(std::vector<std::pair<const Key*, const Key*>> pairs) {
    std::vector<std::string> keys;
    for (const auto& [m, d] : pairs) keys.push_back(id_of(*m) + "|" + id_of(*d));
    return [keys](const std::string& master, const std::string& device) {
        for (const auto& k : keys) {
            if (k == master + "|" + device) return true;
        }
        return false;
    };
}

static const LockCounted nobody = [](const std::string&, const std::string&) { return false; };

static LockLink base_link(const std::string& server, uint64_t n, const Key& owner, const std::string& nonce,
                          unsigned char door_tag, const Key& change, const Key* device = nullptr) {
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
    return device ? by(server, l, id_of(owner), *device) : l;
}

static LockLink next_link(const std::string& server, const LockLink& prev, const Key& prev_change,
                          unsigned char door_tag, const Key& change, const Key* master = nullptr,
                          const Key* device = nullptr) {
    LockLink l;
    l.n = prev.n + 1;
    l.door = door(door_tag);
    l.change = change.text;
    l.sig = prev_change.sign(join_lock::payload(server, l));
    return device ? by(server, l, id_of(*master), *device) : l;
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
    Key owner(1), od(21), mod(6), md(22), c1(11), c2(12), c3(13), c4(14), stranger(9);
    const LockCounted counted = counting({{&owner, &od}, {&mod, &md}});
    std::string nonce = "aa";
    std::string server = genesis_server_id(derive_peer_id(owner.text), nonce);

    LockLink first = base_link(server, 1, owner, nonce, 1, c1, &od);
    auto stored = join_lock::relay_put(server, {}, {first}, crypto, counted);
    check("a first valid chain is taken", stored.has_value());
    check("an extension of nothing is not",
          !join_lock::relay_put(server, {}, {next_link(server, first, c1, 2, c2, &owner, &od)}, crypto, counted));

    LockLink a = next_link(server, first, c1, 2, c2, &owner, &od);
    LockLink b = next_link(server, first, c1, 3, c3, &owner, &od);
    stored = join_lock::relay_put(server, *stored, {a}, crypto, counted);
    check("the first extension wins", stored && stored->back() == a);
    check("a second extension of the same lock loses", !join_lock::relay_put(server, *stored, {b}, crypto, counted));
    check("so does a whole chain ending in it", !join_lock::relay_put(server, *stored, {first, b}, crypto, counted));
    check("a link signed by the wrong key is refused",
          !join_lock::relay_put(server, *stored, {next_link(server, a, c1, 4, c4, &owner, &od)}, crypto, counted));

    LockLink compact = base_link(server, a.n, owner, nonce, 2, c2, &od);
    auto shorter = join_lock::relay_put(server, *stored, {compact}, crypto, counted);
    check("the owner's re-signing compacts the chain", shorter && shorter->size() == 1 && shorter->back() == compact);
    auto again = join_lock::relay_put(server, *shorter, {first, a}, crypto, counted);
    check("republishing the longer chain changes nothing", again && *again == *shorter);

    LockLink rogue = next_link(server, compact, c2, 5, c3, &mod, &md);
    stored = join_lock::relay_put(server, *shorter, {rogue}, crypto, counted);
    check("a mod's extension is taken first", stored && stored->back() == rogue);
    check("a reset must pass the newest lock",
          !join_lock::relay_put(server, *stored, {base_link(server, rogue.n, owner, nonce, 6, c4, &od)}, crypto, counted));
    LockLink reset = base_link(server, rogue.n + 1, owner, nonce, 7, c4, &od);
    auto after = join_lock::relay_put(server, *stored, {reset}, crypto, counted);
    check("the owner resets past a fork", after && after->size() == 1 && after->back() == reset);
    check("the fork cannot come back", !join_lock::relay_put(server, *after, {compact, rogue}, crypto, counted));
    Key c5(16);
    LockLink rogue_past = next_link(server, rogue, c3, 9, c5, &mod, &md);
    LockLink rogue_further = next_link(server, rogue_past, c5, 10, c1, &mod, &md);
    check("not even grown past the reset",
          !join_lock::relay_put(server, *after, {compact, rogue, rogue_past, rogue_further}, crypto, counted));
    Key impostor_change(15);
    check("nobody else resets",
          !join_lock::relay_put(server, *after, {base_link(server, 99, stranger, nonce, 8, impostor_change, &od)}, crypto,
                                counted));
}

// C4: an owner-signed link proves nothing by the master key alone.
static void test_counted_bases() {
    printf("an owner base needs a counted device\n");
    Key owner(1), od(21), mod(6), md(22), c1(11), c2(12);
    const LockCounted counted = counting({{&owner, &od}, {&mod, &md}});
    std::string nonce = "aa";
    std::string server = genesis_server_id(derive_peer_id(owner.text), nonce);
    LockLink first = base_link(server, 1, owner, nonce, 1, c1, &od);
    check("a counted owner device's first lock", join_lock::relay_put(server, {}, {first}, crypto, counted).has_value());
    check("no roster held, or one that does not count it", !join_lock::relay_put(server, {}, {first}, crypto, nobody));
    check("the master key alone", !join_lock::relay_put(server, {}, {base_link(server, 1, owner, nonce, 1, c1)}, crypto, counted));
    LockLink by_mod = by(server, base_link(server, 1, owner, nonce, 1, c1), id_of(owner), md);
    check("a device of another identity", !join_lock::relay_put(server, {}, {by_mod}, crypto, counted));
    LockLink lied = by(server, base_link(server, 1, owner, nonce, 1, c1), id_of(mod), md);
    check("an owner base's device names the owner", join_lock::link_device(server, lied, crypto).empty() &&
                                                       join_lock::base_owner(server, lied, crypto).empty());
    LockLink second = next_link(server, first, c1, 2, c2, &owner, &od);
    std::vector<LockLink> stored{first, second};
    const LockCounted removed = counting({{&mod, &md}});
    Key c3(13);
    check("an owner device removed since resets nothing",
          !join_lock::relay_put(server, stored, {base_link(server, 3, owner, nonce, 3, c3, &od)}, crypto, removed));
    check("nor re-signs the newest lock",
          !join_lock::relay_put(server, stored, {base_link(server, 2, owner, nonce, 2, c2, &od)}, crypto, removed));
    auto same = join_lock::relay_put(server, stored, stored, crypto, removed);
    check("a chain the relay holds is no new base", same && *same == stored);
    LockLink torn = first;
    torn.dev_sig = od.sign("something else");
    check("a proof that does not verify is a forgery", join_lock::base_owner(server, torn, crypto).empty());
}

// The review's MAX_N probe: resets are bounded, and a frozen lock gives way.
static void test_reset_step() {
    printf("a reset jumps at most RESET_STEP, and a frozen lock gives way\n");
    Key owner(1), od(21), thief(23), c1(11), c2(12), c3(13);
    const LockCounted counted = counting({{&owner, &od}});
    std::string nonce = "aa";
    std::string server = genesis_server_id(derive_peer_id(owner.text), nonce);
    LockLink first = base_link(server, 1, owner, nonce, 1, c1, &od);
    LockLink second = next_link(server, first, c1, 2, c2, &owner, &od);
    std::vector<LockLink> stored{first, second};
    const uint64_t step = join_lock::RESET_STEP;
    check("one past the step", !join_lock::relay_put(server, stored, {base_link(server, 2 + step + 1, owner, nonce, 3, c3, &od)}, crypto, counted));
    check("the ceiling", !join_lock::relay_put(server, stored, {base_link(server, join_lock::MAX_N, owner, nonce, 3, c3, &od)}, crypto, counted));
    check("a thief's reset to the ceiling", !join_lock::relay_put(server, stored, {base_link(server, join_lock::MAX_N, owner, nonce, 3, c3, &thief)}, crypto, counted));
    LockLink edge = base_link(server, 2 + step, owner, nonce, 3, c3, &od);
    auto taken = join_lock::relay_put(server, stored, {edge}, crypto, counted);
    check("the step itself", taken && taken->back() == edge);

    std::vector<LockLink> frozen{base_link(server, join_lock::MAX_N, owner, nonce, 4, c3)};
    LockLink start = base_link(server, 1, owner, nonce, 5, c1, &od);
    check("a frozen lock: not for the master key alone",
          !join_lock::relay_put(server, frozen, {base_link(server, 1, owner, nonce, 5, c1)}, crypto, counted));
    check("nor an uncounted device", !join_lock::relay_put(server, frozen, {start}, crypto, nobody));
    auto over = join_lock::relay_put(server, frozen, {start}, crypto, counted);
    check("a counted owner device starts over", over && over->size() == 1 && over->back() == start);
    std::vector<LockLink> below{base_link(server, join_lock::FROZEN_FROM, owner, nonce, 4, c3)};
    check("a lock below the line is not frozen", !join_lock::relay_put(server, below, {start}, crypto, counted));
}

// M5 and N11: a removed device extends nothing, and its dark links give way.
static void test_dead_links() {
    printf("a link made by an uncounted device is dead\n");
    Key owner(1), od(21), mod(6), md(22), other(8), xd(24), c1(11), c2(12), c3(13), c4(14), c5(15);
    const LockCounted both = counting({{&owner, &od}, {&mod, &md}});
    const LockCounted mod_removed = counting({{&owner, &od}});
    std::string nonce = "aa";
    std::string server = genesis_server_id(derive_peer_id(owner.text), nonce);
    LockLink first = base_link(server, 1, owner, nonce, 1, c1, &od);
    LockLink second = next_link(server, first, c1, 2, c2, &owner, &od);
    std::vector<LockLink> stored{first, second};
    LockLink by_mod = next_link(server, second, c2, 3, c3, &mod, &md);
    check("made by a device the fold no longer counts", !join_lock::relay_put(server, stored, {by_mod}, crypto, mod_removed));
    check("or by no device, after a link that names one",
          !join_lock::relay_put(server, stored, {next_link(server, second, c2, 3, c3)}, crypto, mod_removed));
    check("the same link while it counts", join_lock::relay_put(server, stored, {by_mod}, crypto, both).has_value());
    std::vector<LockLink> old{base_link(server, 1, owner, nonce, 1, c1), next_link(server, first, c1, 2, c2)};
    check("a 0.13 base is no base here", !join_lock::relay_put(server, {}, old, crypto, both));
    check("but a 0.13 link extends a 0.13 one",
          join_lock::relay_put(server, old, {next_link(server, old[1], c2, 3, c3)}, crypto, nobody).has_value());

    LockLink dark = next_link(server, second, c2, 3, c3, &mod, &md);
    LockLink darker = next_link(server, dark, c3, 4, c4, &mod, &md);
    auto held = join_lock::relay_put(server, stored, {dark, darker}, crypto, both);
    check("the stolen mod device moves the lock twice", held && held->size() == 4);
    if (!held) return;
    LockLink fork = next_link(server, second, c2, 5, c5, &owner, &od);
    check("a live tip is never forked", !join_lock::relay_put(server, *held, {fork}, crypto, both));
    check("a fork made by no device", !join_lock::relay_put(server, *held, {next_link(server, second, c2, 5, c5)}, crypto, mod_removed));
    check("a fork made by an uncounted device",
          !join_lock::relay_put(server, *held, {next_link(server, second, c2, 5, c5, &other, &xd)}, crypto, mod_removed));
    auto after = join_lock::relay_put(server, *held, {fork}, crypto, mod_removed);
    check("once the fold drops the thief, a counted holder extends past it",
          after && after->size() == 3 && after->back() == fork && (*after)[1] == second);
    if (after) {
        check("and the thief's branch is gone",
              !join_lock::relay_put(server, *after, {next_link(server, dark, c3, 6, c1, &mod, &md)}, crypto, mod_removed));
    }
    std::vector<LockLink> old13{base_link(server, 1, owner, nonce, 1, c1), next_link(server, first, c1, 2, c2),
                                next_link(server, second, c2, 3, c3)};
    LockLink fork13 = next_link(server, old13[1], c2, 5, c5, &owner, &od);
    check("on a 0.13 chain a 0.13 link replaces nothing",
          !join_lock::relay_put(server, old13, {next_link(server, old13[1], c2, 5, c5)}, crypto, both));
    check("nor does a counted device's: a link without a proof is never dead",
          !join_lock::relay_put(server, old13, {fork13}, crypto, mod_removed));
    auto republished = join_lock::relay_put(server, {}, {first, second, dark}, crypto, both);
    check("an honest republish keeps the thief's link its own",
          republished && join_lock::relay_put(server, *republished, {fork}, crypto, mod_removed).has_value());
}

// Only the owner, or the identity whose removed device made every link it replaces,
// forks past a dead link: an older change key alone (an ex-mod's) moves nothing.
static void test_dead_link_identity() {
    printf("a dead link gives way only to the owner or its own identity\n");
    Key owner(1), od(21), mod(6), md(22), md2(23), ex(8), xd(24), c1(11), c2(12), c3(13), c4(14), cx(19);
    std::string nonce = "aa";
    std::string server = genesis_server_id(derive_peer_id(owner.text), nonce);
    {
        // A 0.13 chain held at the 0.14 deploy: E held L2's change key and was kicked at L3.
        LockLink b = base_link(server, 1, owner, nonce, 1, c1);
        LockLink l2 = next_link(server, b, c1, 2, c2);
        LockLink l3 = next_link(server, l2, c2, 3, c3);
        std::vector<LockLink> held{b, l2, l3};
        const LockCounted all = counting({{&owner, &od}, {&ex, &xd}, {&mod, &md}});
        check("an ex-mod's counted device does not fork past a 0.13 kick link",
              !join_lock::relay_put(server, held, {next_link(server, l2, c2, 9, cx, &ex, &xd)}, crypto, all));
        check("nor does the owner's: a 0.13 link is never dead",
              !join_lock::relay_put(server, held, {next_link(server, l2, c2, 9, cx, &owner, &od)}, crypto, all));
        check("an honest mod still moves the lock",
              join_lock::relay_put(server, held, {next_link(server, l3, c3, 4, c4, &mod, &md)}, crypto, all).has_value());
    }
    {
        // A 0.14 chain: mod device md demoted E at L3 and was later removed honestly.
        LockLink b = base_link(server, 1, owner, nonce, 1, c1, &od);
        LockLink l2 = next_link(server, b, c1, 2, c2, &mod, &md);
        LockLink l3 = next_link(server, l2, c2, 3, c3, &mod, &md);
        std::vector<LockLink> held{b, l2, l3};
        const LockCounted md_removed = counting({{&owner, &od}, {&ex, &xd}, {&mod, &md2}});
        check("another identity's counted device does not fork past it",
              !join_lock::relay_put(server, held, {next_link(server, l2, c2, 9, cx, &ex, &xd)}, crypto, md_removed));
        check("the removed device's sibling does",
              join_lock::relay_put(server, held, {next_link(server, l2, c2, 9, cx, &mod, &md2)}, crypto, md_removed).has_value());
        check("and so does the owner's device",
              join_lock::relay_put(server, held, {next_link(server, l2, c2, 9, cx, &owner, &od)}, crypto, md_removed).has_value());
        // Two dead links of two identities after the fork point.
        LockLink l4 = next_link(server, l3, c3, 4, c4, &ex, &xd);
        std::vector<LockLink> mixed{b, l2, l3, l4};
        const LockCounted both_removed = counting({{&owner, &od}, {&mod, &md2}});
        check("a sibling replaces no dead link of another identity",
              !join_lock::relay_put(server, mixed, {next_link(server, l2, c2, 9, cx, &mod, &md2)}, crypto, both_removed));
        check("the owner replaces them all",
              join_lock::relay_put(server, mixed, {next_link(server, l2, c2, 9, cx, &owner, &od)}, crypto, both_removed).has_value());
    }
}

static void test_pinned_device_chain() {
    printf("pinned device chain (shared with the Rust test)\n");
    auto links = join_lock::links_from_json(nlohmann::json::parse(PINNED_DEVICE_CHAIN));
    check("it parses", links.has_value() && links->size() == 2);
    if (!links) return;
    check("it verifies back to its owner", join_lock::verify_chain(PINNED_SERVER, *links, crypto) == PINNED_OWNER);
    auto owner_dev = join_lock::link_device(PINNED_SERVER, (*links)[0], crypto);
    auto mod_dev = join_lock::link_device(PINNED_SERVER, (*links)[1], crypto);
    check("its base names the owner's device", owner_dev.master == PINNED_OWNER && owner_dev.device == PINNED_OWNER_DEVICE);
    check("its next link names the mod's", mod_dev.master == PINNED_MOD && mod_dev.device == PINNED_MOD_DEVICE);
    auto round = join_lock::links_from_json(join_lock::links_to_json(*links));
    check("it survives the relay's own JSON", round && *round == *links);
    auto torn = *links;
    torn[1].dev_master = PINNED_OWNER;
    check("a proof naming another identity breaks it", join_lock::verify_chain(PINNED_SERVER, torn, crypto).empty());
}

static void test_legacy_records() {
    printf("legacy ids are kept per owner\n");
    Key owner(1), squatter(2), c1(11), c2(12), od(21), sd(25);
    const LockCounted counted = counting({{&owner, &od}, {&squatter, &sd}});
    std::string legacy = "0123456789abcdef0123456789abcdef";
    std::string owner_id = derive_peer_id(owner.text);
    std::string squatter_id = derive_peer_id(squatter.text);
    JoinLocks locks;
    std::vector<LockLink> current;
    check("a squatter cannot file under the owner's name",
          !locks.put(legacy, owner_id, {base_link(legacy, 1, squatter, "", 1, c1, &sd)}, crypto, counted, current, 2));
    check("under its own name it can",
          locks.put(legacy, squatter_id, {base_link(legacy, 1, squatter, "", 1, c1, &sd)}, crypto, counted, current, 2));
    check("which does not touch the owner's record", locks.get(join_lock::record_key(legacy, owner_id)) == nullptr);
    check("the owner files its own",
          locks.put(legacy, owner_id, {base_link(legacy, 1, owner, "", 2, c2, &od)}, crypto, counted, current, 1));
    const auto* held = locks.get(join_lock::record_key(legacy, owner_id));
    check("and reads it back", held && held->size() == 1 && join_lock::verify_chain(legacy, *held, crypto) == owner_id);
}

// HOL-SEC-069: one account filing chains under ids of its own could hold the relay's
// whole memory. The table keeps a byte budget, and a flood evicts only its own share.
static void test_budget() {
    printf("the table keeps a byte budget and a flood pays for itself\n");
    Key owner(1), flooder(2), c1(11), c2(12), od(21), fd(26);
    const LockCounted counted = counting({{&owner, &od}, {&flooder, &fd}});
    std::string owner_id = derive_peer_id(owner.text);
    std::string flooder_id = derive_peer_id(flooder.text);
    JoinLocks locks;
    locks.budget = 64 * 1024;
    std::vector<LockLink> current;
    std::string real = genesis_server_id(owner_id, "aa");
    LockLink real_base = base_link(real, 1, owner, "aa", 1, c1, &od);
    check("a real server files its chain", locks.put(real, owner_id, {real_base}, crypto, counted, current, 1));
    size_t filed = 0;
    for (int i = 0; i < 400; i++) {
        char hex[33];
        snprintf(hex, sizeof(hex), "%032x", i);
        if (locks.put(hex, flooder_id, {base_link(hex, 1, flooder, "", 2, c2, &fd)}, crypto, counted, current, 9)) filed++;
    }
    check("the flood files, it is never refused", filed == 400);
    check("the table stays within its budget", locks.bytes() <= locks.budget);
    check("the flood lost its own oldest records", locks.get(join_lock::record_key("00000000000000000000000000000000", flooder_id)) == nullptr);
    check("the real server's chain survives", locks.get(real) != nullptr);
    const auto* newest = locks.get(join_lock::record_key("0000000000000000000000000000018f", flooder_id));
    check("the flood keeps its newest", newest != nullptr);
    check("a re-put of the same chain changes nothing",
          locks.put(real, owner_id, {real_base}, crypto, counted, current, 9) && locks.ledger.share_of(real) == std::optional<uint64_t>(1));
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
    Key od(21);
    LockLink proved = by(server, good, derive_peer_id(owner.text), od);
    check("a device proof in its shape is well formed", join_lock::well_formed(proved));
    LockLink odd_master = proved;
    odd_master.dev_master[0] = '0';
    check("a proof's master is a base58 peer id", !join_lock::well_formed(odd_master));
    LockLink short_sig = proved;
    short_sig.dev_sig.pop_back();
    check("a proof's signature has its length", !join_lock::well_formed(short_sig));
    check("a dev that is not an object does not parse",
          !join_lock::link_from_json(nlohmann::json::parse(R"({"n":1,"door":"x","change":"y","sig":"z","dev":"w"})")));
    check("nor one missing its master",
          !join_lock::link_from_json(nlohmann::json::parse(R"({"n":1,"door":"x","change":"y","sig":"z","dev":{"device":"a","sig":"b"}})")));
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
    test_pinned_device_chain();
    test_put_rules();
    test_counted_bases();
    test_reset_step();
    test_dead_links();
    test_dead_link_identity();
    test_legacy_records();
    test_budget();
    test_shapes();
    printf(failures == 0 ? "ALL PASSED\n" : "%d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
