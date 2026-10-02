// Unit tests for door-proof server rooms (src/door_room.h, the proof in crypto.cpp).
// The pinned proof is the one the Rust test
// `node::ws_client::tests::door_proof_matches_the_relays_pinned_vector` pins, computed a
// third time outside both: if the HMAC message or the key exchange drift apart, every
// member of every locked server is hidden from the others. Change both or neither.
//
// Build + run from relay-uws/test (libsodium, and OpenSSL for crypto.cpp):
//   g++ -std=c++17 -I../src test_door_room.cpp ../src/crypto.cpp -lsodium -lcrypto
//       -o test_door_room && ./test_door_room

#include "door_room.h"
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

static const char* DOMAIN = "relay.example.org";
static const char* NONCE = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
static const char* PEER = "12D3KooWK99VoVxNE7XzyBwXEzW7xhK7Gpv85r9F3V3fyKSUKPH5";
static const char* ROOM = "8ef8bc89d3891dca86ff72c6783e396351aed5ba";
static const char* PINNED_DOOR = "e06Qm75__kTEZaIgA31gjuNYl9Me-XLwf3SJLLD3PxM";
static const char* PINNED_RELAY = "D6poTtKIZ7l_Smot7l34zpdOdrcBjj8iocTPJnhXDyA";
static const char* PINNED_PROOF = "iyHv-DBusf2SG9eXxTNOd1-VpXZM77eeFbZbz9Su9Lo";

static void test_pinned_proof() {
    unsigned char door_sk[32];
    unsigned char relay_sk[32];
    memset(door_sk, 0x11, sizeof(door_sk));
    memset(relay_sk, 0x22, sizeof(relay_sk));
    DoorKey relay;
    door_key_from(relay, relay_sk);
    check("the relay key's public half is the pinned one", relay.text == PINNED_RELAY);

    const std::string msg = door_room::proof_message(DOMAIN, NONCE, PEER, ROOM, PINNED_DOOR, relay.text);
    check("a door secret makes the pinned proof", door_proof_make(door_sk, relay.pk, msg) == PINNED_PROOF);
    check("the pinned proof opens the door", door_proof_opens(relay, PINNED_DOOR, msg, PINNED_PROOF));

    auto other = [&](const std::string& nonce, const std::string& peer, const std::string& room) {
        return door_proof_opens(relay, PINNED_DOOR,
                                door_room::proof_message(DOMAIN, nonce, peer, room, PINNED_DOOR, relay.text),
                                PINNED_PROOF);
    };
    check("no other socket's nonce", !other(std::string(64, 'f'), PEER, ROOM));
    check("no other peer", !other(NONCE, "12D3KooWOther", ROOM));
    check("no other room", !other(NONCE, PEER, "00112233445566778899aabbccddeeff00112233"));

    unsigned char other_sk[32];
    memset(other_sk, 0x33, sizeof(other_sk));
    DoorKey other_door;
    door_key_from(other_door, other_sk);
    check("no other door", !door_proof_opens(relay, other_door.text, msg, PINNED_PROOF));

    DoorKey other_relay;
    door_key_from(other_relay, other_sk);
    check("not on another relay", !door_proof_opens(other_relay, PINNED_DOOR, msg, PINNED_PROOF));

    check("a malformed proof proves nothing", !door_proof_opens(relay, PINNED_DOOR, msg, "short"));
    check("a padded proof proves nothing", !door_proof_opens(relay, PINNED_DOOR, msg, std::string(PINNED_PROOF) + "="));
    const std::string zero_door(43, 'A');
    check("a low-order door proves nothing", !door_proof_opens(relay, zero_door, msg, PINNED_PROOF));
    unsigned char zero[32] = {0};
    check("nor makes a proof", door_proof_make(door_sk, zero, msg).empty());
}

static void test_doors() {
    using door_room::Doors;
    const auto never = [](const std::string&, const std::string&) { return false; };
    const auto always = [](const std::string&, const std::string&) { return true; };

    Doors d;
    check("a proof that opens the door makes a prover", d.join("a", "pa", true, false, 0));
    check("one that does not, nobody", !d.join("b", "pb", false, false, 0));
    check("a re-join on the same socket keeps a prover", d.join("a", "", false, true, 10));
    check("a new socket proves again", !d.join("a", "", false, false, 10));
    d.join("a", "pa", true, false, 20);

    auto newly = d.relock({"a", "b"}, true, never, 1000);
    check("a lock move keeps a prover for the grace", d.sees("a", 1000 + door_room::GRACE_MS - 1));
    check("and no longer", !d.sees("a", 1000 + door_room::GRACE_MS));
    check("a non-prover gains nothing from a move", !d.sees("b", 1000) && newly.empty());
    check("the room is in grace", d.in_grace());

    d.relock({"a", "b"}, true, never, 5000);
    check("a second move never extends the grace", !d.sees("a", 1000 + door_room::GRACE_MS));

    check("re-proving ends the grace", d.join("a", "pa2", true, true, 2000) && d.sees("a", 1 << 30));
    check("nothing left in grace", !d.in_grace());

    Doors e;
    e.join("a", "pa", false, false, 0);
    e.join("b", "pb", false, false, 0);
    newly = e.relock({"a", "b"}, false, never, 0);
    check("a lock on an open room keeps everyone for the grace", e.sees("a", 1) && e.sees("b", 1));
    check("nobody is newly shown", newly.empty());
    auto gone = e.expire(door_room::GRACE_MS);
    check("the grace runs out for both", gone.size() == 2 && !e.sees("a", door_room::GRACE_MS));

    Doors f;
    f.join("a", "pa", false, false, 0);
    newly = f.relock({"a"}, true, always, 0);
    check("a stored proof that opens a lock put back proves at once", f.sees("a", 1 << 30));
    check("and is newly shown", newly.size() == 1 && newly[0] == "a");

    f.leave("a");
    check("a leave forgets the prover and its proof", !f.sees("a", 0) && f.proofs.empty());
}

int main() {
    if (sodium_init() < 0) return 1;
    test_pinned_proof();
    test_doors();
    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
