// Unit tests for the pre-auth frame parser (src/auth_frame.h). Every frame here
// comes from a socket that has proven nothing yet, so the one property that
// matters is that no input throws: a malformed field is an invalid frame.
//
// Build + run from relay-uws/test (header-only, no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_auth_frame.cpp -o test_auth_frame && ./test_auth_frame

#include "auth_frame.h"

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

// Parses without throwing and says whether the frame was accepted.
static bool accepted(const std::string& frame) {
    try {
        return parse_auth_frame(frame).has_value();
    } catch (...) {
        printf("  FAIL threw on: %s\n", frame.c_str());
        failures++;
        return false;
    }
}

int main() {
    printf("auth frame\n");

    const std::string good =
        R"({"type":"auth","peer_id":"12D3KooWA","public_key":"k","timestamp":1790000000,)"
        R"("signature":"s","license_key":"L","guest":true,"fetch":false})";
    auto f = parse_auth_frame(good);
    check("a well-formed frame parses", f.has_value());
    check("its fields are read", f && f->peer_id == "12D3KooWA" && f->public_key == "k" &&
                                     f->timestamp == 1790000000 && f->signature == "s" &&
                                     f->license_key == "L" && f->guest && !f->fetch);
    auto bare = parse_auth_frame(R"({"type":"auth","peer_id":"p"})");
    check("absent optional fields default", bare && bare->timestamp == 0 && !bare->guest &&
                                                bare->license_key.empty());

    // I1: each of these crashed the relay before auth (value() throws on a type it
    // did not expect).
    check("a numeric peer id is refused", !accepted(R"({"type":"auth","peer_id":1})"));
    check("a string timestamp is refused", !accepted(R"({"type":"auth","timestamp":"x"})"));
    check("a negative timestamp is refused", !accepted(R"({"type":"auth","timestamp":-5})"));
    check("a fractional timestamp is refused", !accepted(R"({"type":"auth","timestamp":1.5})"));
    check("a string guest flag is refused", !accepted(R"({"type":"auth","guest":"x"})"));
    check("a null fetch flag is refused", !accepted(R"({"type":"auth","fetch":null})"));
    check("an object signature is refused", !accepted(R"({"type":"auth","signature":{}})"));
    check("an array license key is refused", !accepted(R"({"type":"auth","license_key":[1]})"));

    check("a non-auth type is refused", !accepted(R"({"type":"join","peer_id":"p"})"));
    check("a numeric type is refused", !accepted(R"({"type":7})"));
    check("a missing type is refused", !accepted(R"({"peer_id":"p"})"));
    check("a top-level array is refused", !accepted(R"([{"type":"auth"}])"));
    check("text that is not JSON is refused", !accepted("not json at all"));
    check("an empty frame is refused", !accepted(""));
    check("a frame past the size cap is refused",
          !accepted(R"({"type":"auth","peer_id":")" + std::string(MAX_AUTH_FRAME_BYTES, 'a') + R"("})"));
    const std::string deep = std::string(6000, '[') + std::string(6000, ']');
    check("a frame nested past the depth cap is refused",
          !accepted(R"({"type":"auth","peer_id":"p","x":)" + deep + "}") &&
              !is_auth_hello(R"({"type":"auth_hello","x":)" + deep + "}"));

    printf("auth v2\n");
    check("a hello is recognised", is_auth_hello(R"({"type":"auth_hello"})"));
    check("an auth frame is not a hello", !is_auth_hello(R"({"type":"auth","v":2})"));
    check("junk is not a hello", !is_auth_hello("not json") && !is_auth_hello(R"({"type":1})"));
    check("an oversized hello is not a hello",
          !is_auth_hello(R"({"type":"auth_hello","x":")" + std::string(MAX_AUTH_FRAME_BYTES, 'a') + R"("})"));

    const std::string nonce = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    auto v2 = parse_auth_frame(
        R"({"type":"auth","v":2,"peer_id":"12D3KooWA","public_key":"k","timestamp":1790000000,)"
        R"("nonce":")" + nonce + R"(","domain":"relay.example.com","signature":"s","fetch":true})");
    check("a v2 frame parses", v2 && v2->version == 2 && v2->nonce == nonce &&
                                   v2->domain == "relay.example.com" && v2->fetch);
    check("a frame without v is v1", f && f->version == 1);
    check("an unknown version is refused", !accepted(R"({"type":"auth","v":3})"));
    check("a string version is refused", !accepted(R"({"type":"auth","v":"2"})"));
    check("a numeric nonce is refused", !accepted(R"({"type":"auth","v":2,"nonce":5})"));
    check("a numeric domain is refused", !accepted(R"({"type":"auth","v":2,"domain":5})"));

    check("full, fetch and guest modes", auth_mode(false, false) == std::optional<std::string>("full") &&
                                         auth_mode(false, true) == std::optional<std::string>("fetch") &&
                                         auth_mode(true, false) == std::optional<std::string>("guest"));
    check("guest and fetch at once is no mode", !auth_mode(true, true).has_value());

    check("the domain drops the port and case", auth_domain("Relay.Example.com:8443") == "relay.example.com");
    check("a bare domain stays", auth_domain("relay.anonlisten.com") == "relay.anonlisten.com");
    check("an IPv6 literal keeps its brackets", auth_domain("[::1]:443") == "[::1]");

    check("a nonce is 64 lowercase hex", is_auth_nonce_shape(nonce));
    check("an uppercase nonce is not",
          !is_auth_nonce_shape("0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef"));
    check("a short nonce is not", !is_auth_nonce_shape("abcd"));

    // Pinned in rust/hollow_core/src/node/ws_client.rs
    // (auth_v2_message_matches_the_relays_pinned_vector); the digest is SHA-256("L").
    check("the signed v2 message matches the client's pinned vector",
          auth_v2_message("relay.example.com", nonce, "12D3KooWPeer", 1790000000, "fetch",
                          "72dfcfb0c470ac255cde83fb8fe38de8a128188e03ea5ba5b2a93adbea1062fa") ==
              "hollow-ws-auth2\nrelay.example.com\n" + nonce +
                  "\n12D3KooWPeer\n1790000000\nfetch\n"
                  "72dfcfb0c470ac255cde83fb8fe38de8a128188e03ea5ba5b2a93adbea1062fa");

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
