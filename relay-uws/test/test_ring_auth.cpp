// Unit tests for who may change a server's catch-up rings (src/ring_auth.h). The
// crypto is stubbed: a signature is "SIG:" + key + ":" + the payload, so every test
// can see exactly which bytes were signed and by which key.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_ring_auth.cpp -o test_ring_auth && ./test_ring_auth

#include "ring_auth.h"

#include <cstdio>
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

static const LockCrypto& stub_crypto() {
    static const LockCrypto c{
        [](const std::string& key, const std::string& sig, const std::string& msg) {
            return sig == "SIG:" + key + ":" + msg;
        },
        [](const std::string& key) { return "peer-of-" + key; },
        [](const std::string& owner, const std::string& nonce) { return owner + nonce; },
    };
    return c;
}

static LockLink link_with_change(uint64_t n, const std::string& change) {
    LockLink l;
    l.n = n;
    l.change = change;
    return l;
}

int main() {
    printf("ring control\n");

    ring_auth::Control c;
    c.room = "0123456789abcdef0123456789abcdef01234567";
    c.owner = "";
    c.ts_ms = 1790000000000;
    c.retention_secs = 86400;
    c.clear = false;
    c.channels = {"3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b", "~join"};

    // 0.12.1 and older clients sign ring1, which names no relay.
    check("the ring1 payload stays as 0.12.1 clients sign it",
          ring_auth::payload_ring1(c) ==
              "hollow-ring1\n0123456789abcdef0123456789abcdef01234567\n\n1790000000000\n86400\nkeep\n"
              "3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b\n~join");

    // Pinned in rust/hollow_core/src/node/ring_auth.rs
    // (ring_control_payload_matches_the_relays_pinned_vector).
    c.version = 2;
    check("the ring2 payload matches the client's pinned vector",
          ring_auth::payload_ring2(c, "relay.example.com") ==
              "hollow-ring2\nrelay.example.com\n0123456789abcdef0123456789abcdef01234567\n\n1790000000000\n"
              "86400\nkeep\n3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b\n~join");

    std::vector<LockLink> chain = {link_with_change(1, "OLDCHANGE"), link_with_change(2, "CHANGE")};
    const int64_t now = c.ts_ms + 1000;
    const ring_auth::Relay relay{"relay.example.com", false};
    const auto sign = [&relay](const ring_auth::Control& k) {
        return "SIG:CHANGE:" + ring_auth::payload_ring2(k, relay.domain);
    };
    c.sig = sign(c);
    check("a control signed by the newest lock's change key counts",
          ring_auth::authorized(c, &chain, now, stub_crypto(), relay));

    ring_auth::Control old_key = c;
    old_key.sig = "SIG:OLDCHANGE:" + ring_auth::payload_ring2(c, relay.domain);
    check("a control signed by an older lock's change key does not",
          !ring_auth::authorized(old_key, &chain, now, stub_crypto(), relay));

    check("no chain on this relay, no control", !ring_auth::authorized(c, nullptr, now, stub_crypto(), relay));
    std::vector<LockLink> empty;
    check("an empty chain, no control", !ring_auth::authorized(c, &empty, now, stub_crypto(), relay));

    ring_auth::Control longer = c;
    longer.retention_secs = 7 * 86400;
    check("the retention is under the signature", !ring_auth::authorized(longer, &chain, now, stub_crypto(), relay));
    ring_auth::Control cleared = c;
    cleared.clear = true;
    check("clear is under the signature", !ring_auth::authorized(cleared, &chain, now, stub_crypto(), relay));
    ring_auth::Control more = c;
    more.channels.push_back("extra");
    check("the channel list is under the signature", !ring_auth::authorized(more, &chain, now, stub_crypto(), relay));
    ring_auth::Control moved = c;
    moved.room = "fedcba9876543210fedcba9876543210fedcba98";
    check("the room is under the signature", !ring_auth::authorized(moved, &chain, now, stub_crypto(), relay));

    check("a control ten minutes stale is refused",
          !ring_auth::authorized(c, &chain, c.ts_ms + ring_auth::MAX_SKEW_MS + 1, stub_crypto(), relay));
    check("a control ten minutes ahead is refused",
          !ring_auth::authorized(c, &chain, c.ts_ms - ring_auth::MAX_SKEW_MS - 1, stub_crypto(), relay));

    ring_auth::Control newline = c;
    newline.channels = {"a\nkeep"};
    newline.sig = sign(newline);
    check("a channel that could forge the payload's lines is refused",
          !ring_auth::authorized(newline, &chain, now, stub_crypto(), relay));
    check("the join topic is a channel", ring_auth::is_channel_shape("~join"));
    check("an empty channel is not", !ring_auth::is_channel_shape(""));
    check("a channel over 128 bytes is not", !ring_auth::is_channel_shape(std::string(129, 'a')));

    printf("relay domain (hollow-ring2)\n");
    {
        check("a control signed for another relay is refused",
              !ring_auth::authorized(c, &chain, now, stub_crypto(), ring_auth::Relay{"relay.other.net", true}));
        ring_auth::Control blank = c;
        blank.sig = "SIG:CHANGE:" + ring_auth::payload_ring2(c, "");
        check("a relay with no domain takes no ring2 control, not even one naming none",
              !ring_auth::authorized(blank, &chain, now, stub_crypto(), ring_auth::Relay{"", true}));
        check("a ring2 control is judged as ring2 while ring1 is still taken",
              ring_auth::authorized(c, &chain, now, stub_crypto(), ring_auth::Relay{relay.domain, true}));

        ring_auth::Control old = c;
        old.version = 1;
        old.sig = "SIG:CHANGE:" + ring_auth::payload_ring1(old);
        check("a ring1 control counts while the switch is on",
              ring_auth::authorized(old, &chain, now, stub_crypto(), ring_auth::Relay{relay.domain, true}));
        check("a ring1 control is refused once the switch is off",
              !ring_auth::authorized(old, &chain, now, stub_crypto(), relay));

        ring_auth::Control down = c;
        down.version = 1;
        check("a ring2 signature presented as ring1 is refused",
              !ring_auth::authorized(down, &chain, now, stub_crypto(), ring_auth::Relay{relay.domain, true}));
        ring_auth::Control up = old;
        up.version = 2;
        check("a ring1 signature presented as ring2 is refused",
              !ring_auth::authorized(up, &chain, now, stub_crypto(), ring_auth::Relay{relay.domain, true}));
    }

    printf("parse\n");
    {
        ring_auth::Control p;
        bool is_signed = false;
        auto j = nlohmann::json::parse(
            R"({"type":"set_topic_buffer","room":"r","owner":"o","channels":["a","b"],)"
            R"("retention_secs":3600,"clear":false,"ts":5,"sig":"s"})");
        check("a signed control parses", ring_auth::parse(j, p, is_signed) && is_signed &&
                                             p.room == "r" && p.owner == "o" && p.channels.size() == 2 &&
                                             p.retention_secs == 3600 && p.ts_ms == 5 && p.sig == "s" &&
                                             p.version == 1);
    }
    {
        ring_auth::Control p;
        bool is_signed = false;
        auto j = nlohmann::json::parse(R"({"type":"set_topic_buffer","room":"r","v":2,"ts":5,"sig":"s"})");
        check("a ring2 control parses as ring2", ring_auth::parse(j, p, is_signed) && is_signed && p.version == 2);
    }
    {
        ring_auth::Control p;
        bool is_signed = true;
        auto j = nlohmann::json::parse(R"({"type":"set_topic_buffer","room":"r","channels":["a"]})");
        check("an unsigned request parses as unsigned", ring_auth::parse(j, p, is_signed) && !is_signed);
    }
    {
        ring_auth::Control p;
        bool is_signed = false;
        check("a numeric signature is refused",
              !ring_auth::parse(nlohmann::json::parse(R"({"room":"r","sig":5})"), p, is_signed));
        check("a string retention is refused",
              !ring_auth::parse(nlohmann::json::parse(R"({"room":"r","retention_secs":"x"})"), p, is_signed));
        check("a non-array channel list is refused",
              !ring_auth::parse(nlohmann::json::parse(R"({"room":"r","channels":"a"})"), p, is_signed));
        check("a numeric channel is refused",
              !ring_auth::parse(nlohmann::json::parse(R"({"room":"r","channels":[1]})"), p, is_signed));
        check("a version that is not 2 is refused",
              !ring_auth::parse(nlohmann::json::parse(R"({"room":"r","v":1,"sig":"s"})"), p, is_signed));
        check("a string version is refused",
              !ring_auth::parse(nlohmann::json::parse(R"({"room":"r","v":"2","sig":"s"})"), p, is_signed));
        check("a string clear flag is refused",
              !ring_auth::parse(nlohmann::json::parse(R"({"room":"r","clear":"yes"})"), p, is_signed));
    }

    // A legacy id's topics carry the owner a control is signed for, so a lock filed
    // under the id in a stranger's own name reaches only rings no member uses.
    {
        const std::string owner = "12D3KooWRealOwner";
        ring_auth::Control legacy = c;
        legacy.room = "0123456789abcdef0123456789abcdef";
        legacy.owner = owner;
        legacy.channels = {owner + ".3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b", owner + ".~join"};
        legacy.sig = sign(legacy);
        check("a legacy control inside its owner's topics counts",
              ring_auth::authorized(legacy, &chain, now, stub_crypto(), relay));

        ring_auth::Control squatter = legacy;
        squatter.owner = "12D3KooWSquatter";
        squatter.sig = sign(squatter);
        check("a control naming another owner's topics is refused",
              !ring_auth::authorized(squatter, &chain, now, stub_crypto(), relay));

        ring_auth::Control plain = legacy;
        plain.channels = {"3f2c9a8e-1b4d-4e6f-9a0b-1c2d3e4f5a6b"};
        plain.sig = sign(plain);
        check("a legacy control over plain channel ids is refused",
              !ring_auth::authorized(plain, &chain, now, stub_crypto(), relay));

        ring_auth::Control bare = legacy;
        bare.channels = {owner + "."};
        bare.sig = sign(bare);
        check("the owner prefix alone is not a topic", !ring_auth::authorized(bare, &chain, now, stub_crypto(), relay));

        check("a self-certifying id's topics are plain channel ids",
              ring_auth::topic_prefix(c.room, owner).empty() && ring_auth::authorized(c, &chain, now, stub_crypto(), relay));

        const std::string key = legacy.room + std::string(1, '\0') + owner + ".chan";
        check("a legacy ring counts against its owner",
              ring_auth::ring_namespace(key) == legacy.room + "|" + owner);
        check("a plain legacy ring counts against its room",
              ring_auth::ring_namespace(legacy.room + std::string(1, '\0') + "chan") == legacy.room);
        check("a self-certifying ring counts against its room",
              ring_auth::ring_namespace(c.room + std::string(1, '\0') + "x.chan") == c.room);
    }

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
