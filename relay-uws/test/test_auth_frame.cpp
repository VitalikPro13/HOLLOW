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

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
