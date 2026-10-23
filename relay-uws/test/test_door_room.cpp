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

// Every proof kept as opening nothing is a stored proof: the relay prices a lock move's
// DHs as proofs less pending, which must never wrap.
static bool pending_within_proofs(const door_room::Doors& d) {
    for (const auto& [peer, group] : d.pending) {
        (void)group;
        if (!d.proofs.count(peer)) return false;
    }
    return d.pending.size() <= d.proofs.size();
}

// Junk proofs (N3.5): every lock move checks each stored proof with a DH, so proofs that
// open nothing are kept only from a socket that saw the room, or up to PENDING_PER_GROUP
// per address group once the room holds PENDING_FREE of them.
static void test_junk_proofs() {
    door_room::Doors d;
    const std::string junk(door_room::PROOF_TEXT_LEN, 'j');
    for (size_t g = 0; g < door_room::PENDING_FREE; g++) d.join("crowd" + std::to_string(g), junk, false, false, 0, 100 + g);
    for (int i = 0; i < 40; i++) d.join("stranger" + std::to_string(i), junk, false, false, 0, 7);
    check("in a crowded room one group keeps at most 8 proofs that open nothing",
          d.proofs.size() == door_room::PENDING_FREE + door_room::PENDING_PER_GROUP);
    d.join("other-group", junk, false, false, 0, 8);
    check("another group keeps its own", d.proofs.count("other-group") == 1);
    d.join("member", "opening", true, false, 0, 9);
    check("a proof that opens is always kept", d.proofs.count("member") == 1 && d.sees("member", 0));
    d.join("member", junk, false, true, 0, 9);
    check("so is a new one from a socket that sees (a member ahead of the relay)", d.proofs.at("member") == junk);
    d.leave("stranger0");
    d.join("late", junk, false, false, 0, 7);
    check("a leave frees its group's place", d.proofs.count("late") == 1);
    auto newly = d.relock({"late"}, true, [](const std::string&, const std::string&) { return true; }, 0);
    check("a kept proof that opens the moved door proves", newly.size() == 1 && d.sees("late", 0));
    d.join("later", junk, false, false, 0, 7);
    check("and no longer holds its group's place", d.proofs.count("later") == 1);
    check("every pending proof is a stored proof", pending_within_proofs(d));
    d.join("later", "opening", true, true, 0, 7);
    d.leave("crowd0");
    d.relock({"crowd1", "member"}, true, [](const std::string&, const std::string&) { return false; }, 0);
    check("through joins, leaves and relocks", pending_within_proofs(d));
}

// A member ahead of the relay's chain, on a new socket, behind an address whose group
// already holds its 8 proofs that open nothing, in a room crowded with stale proofs: its
// proof is not kept, so the relock to its door does not prove it at once. It recovers by
// a DoorAsk or a rejoin (AR-36 residual, accepted). The same member re-proving on the
// socket that saw the room keeps its proof.
static void test_member_ahead_behind_a_full_group_in_a_crowded_room() {
    door_room::Doors d;
    const std::string stale(door_room::PROOF_TEXT_LEN, 's');
    const std::string ahead(door_room::PROOF_TEXT_LEN, 'a');
    for (size_t g = 0; g < door_room::PENDING_FREE; g++) d.join("stale" + std::to_string(g), stale, false, false, 0, 500 + g);
    for (int i = 0; i < 8; i++) d.join("nat" + std::to_string(i), ahead, false, false, 0, 42);
    d.join("ninth", ahead, false, false, 0, 42);
    check("the ninth proof behind the full group is not kept", d.proofs.count("ninth") == 0);
    check("pending stays within proofs", pending_within_proofs(d));
    const auto opens_ahead = [&](const std::string&, const std::string& proof) { return proof == ahead; };
    auto newly = d.relock({"ninth", "nat0"}, true, opens_ahead, 0);
    check("AR-36 residual: the ninth member does not prove on the relock",
          !d.sees("ninth", 0) && newly.size() == 1 && newly[0] == "nat0");

    door_room::Doors seen;
    for (size_t g = 0; g < door_room::PENDING_FREE; g++) {
        seen.join("stale" + std::to_string(g), stale, false, false, 0, 500 + g);
    }
    for (int i = 0; i < 8; i++) seen.join("nat" + std::to_string(i), ahead, false, false, 0, 42);
    seen.join("ninth", "old-door", true, false, 0, 42);
    seen.join("ninth", ahead, false, true, 0, 42);
    check("a member that saw the room on its socket keeps its proof", seen.proofs.at("ninth") == ahead);
    auto proved = seen.relock({"ninth"}, true, opens_ahead, 0);
    check("and proves on the relock", seen.sees("ninth", 0) && seen.open.at("ninth") == door_room::PROVED);
    check("pending stays within proofs there too", pending_within_proofs(seen) && proved.empty());
}

// LOW 9: members behind one address (a NAT) who prove a door the relay does not hold yet
// keep every proof in a room no junk crowds, so each still proves on the relock.
static void test_honest_nat_keeps_its_proofs() {
    door_room::Doors d;
    const std::string ahead(door_room::PROOF_TEXT_LEN, 'a');
    std::vector<std::string> members;
    for (int i = 0; i < 20; i++) {
        members.push_back("nat-member" + std::to_string(i));
        d.join(members.back(), ahead, false, false, 0, 42);
    }
    check("twenty proofs from one address are all kept", d.proofs.size() == 20);
    auto newly = d.relock(members, true, [](const std::string&, const std::string&) { return true; }, 0);
    check("and all twenty prove when the lock moves", newly.size() == 20);

    door_room::Doors crowded;
    const std::string junk(door_room::PROOF_TEXT_LEN, 'j');
    for (size_t g = 0; g < door_room::PENDING_FREE; g++) {
        crowded.join("junk" + std::to_string(g), junk, false, false, 0, 1000 + g);
    }
    for (int i = 0; i < 20; i++) crowded.join("nat" + std::to_string(i), ahead, false, false, 0, 42);
    check("under a junk crowd one address keeps at most 8",
          crowded.proofs.size() == door_room::PENDING_FREE + door_room::PENDING_PER_GROUP);
}

int main() {
    if (sodium_init() < 0) return 1;
    test_pinned_proof();
    test_doors();
    test_junk_proofs();
    test_honest_nat_keeps_its_proofs();
    test_member_ahead_behind_a_full_group_in_a_crowded_room();
    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
