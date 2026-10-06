// Unit tests for the pre-auth frame parser (src/auth_frame.h). Every frame here
// comes from a socket that has proven nothing yet, so the one property that
// matters is that no input throws: a malformed field is an invalid frame.
//
// Build + run from relay-uws/test (header-only, no uWebSockets, no libsodium):
//   g++ -std=c++17 -I../src test_auth_frame.cpp -o test_auth_frame && ./test_auth_frame

#include "auth_frame.h"

#include <cstdio>
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

// A v3 frame for `mode` asking for `session` with `in_h`; `extra` replaces or drops fields.
static std::string v3_frame(const std::string& mode, const nlohmann::json& session, const nlohmann::json& in_h,
                            const nlohmann::json& extra = nlohmann::json::object()) {
    nlohmann::json j = {{"type", "auth"}, {"v", 3}, {"peer_id", "12D3KooWA"}, {"public_key", "k"},
                        {"timestamp", 1790000000}, {"nonce", std::string(64, 'a')},
                        {"domain", "relay.example.com"}, {"signature", "s"}};
    if (!session.is_null()) j["session"] = session;
    if (!in_h.is_null()) j["in_h"] = in_h;
    if (mode == "guest") j["guest"] = true;
    if (mode == "fetch") j["fetch"] = true;
    for (auto it = extra.begin(); it != extra.end(); ++it) {
        if (it.value().is_null()) {
            j.erase(it.key());
        } else {
            j[it.key()] = it.value();
        }
    }
    return j.dump();
}

static void test_v3() {
    std::ifstream file("session_vectors.json");
    std::stringstream ss;
    ss << file.rdbuf();
    const nlohmann::json v = nlohmann::json::parse(ss.str(), nullptr, false);
    const bool loaded = v.is_object() && v.contains("auth_v3") && v["auth_v3"].is_array() &&
                        v["auth_v3"].size() >= 3 && v.contains("auth_v3_shape");
    check("the session vectors load", loaded);
    if (!loaded) return;

    // SHA-256("L"), as the v2 vector above pins it.
    const std::string digest_l = "72dfcfb0c470ac255cde83fb8fe38de8a128188e03ea5ba5b2a93adbea1062fa";
    size_t kat_ok = 0;
    for (const auto& k : v["auth_v3"]) {
        const std::string digest = k["license_key"].is_null() ? std::string() : digest_l;
        const std::string got =
            auth_v3_message(k["domain"].get<std::string>(), k["nonce"].get<std::string>(),
                            k["peer_id"].get<std::string>(), k["timestamp"].get<uint64_t>(),
                            k["mode"].get<std::string>(), digest, k["session"].get<std::string>(),
                            k["in_h"].get<uint64_t>());
        if (got == k["message"].get<std::string>()) kat_ok++;
    }
    check("the signed v3 message matches every pinned vector (" + std::to_string(kat_ok) + "/" +
              std::to_string(v["auth_v3"].size()) + ")",
          kat_ok == v["auth_v3"].size());

    size_t shapes_ok = 0;
    for (const auto& s : v["auth_v3_shape"]) {
        const std::string session = s["session"].get<std::string>();
        if (accepted(v3_frame(s["mode"].get<std::string>(), session, 0)) == s["ok"].get<bool>()) {
            shapes_ok++;
        } else {
            printf("    shape mismatch: %s %s\n", s["mode"].get<std::string>().c_str(), session.c_str());
        }
    }
    check("every mode and session field is judged the way the vectors say", shapes_ok == v["auth_v3_shape"].size());

    const std::string sid = "00112233445566778899aabbccddeeff";
    auto resume = parse_auth_frame(v3_frame("full", sid, 42));
    check("a resume frame parses with its sid and count",
          resume && resume->version == 3 && resume->session == sid && resume->in_h == 42);
    auto fresh = parse_auth_frame(v3_frame("full", "new", 0));
    check("a fresh session frame parses", fresh && fresh->version == 3 && fresh->session == "new" && fresh->in_h == 0);
    check("a new session counts nothing yet", !accepted(v3_frame("full", "new", 3)));
    check("a socket without a session counts nothing", !accepted(v3_frame("fetch", "none", 1)));
    check("a v3 frame without a session field is refused", !accepted(v3_frame("full", nullptr, 0)));
    check("a v3 frame without a count is refused", !accepted(v3_frame("full", sid, nullptr)));
    check("a numeric session is refused", !accepted(v3_frame("full", 5, 0)));
    check("a negative count is refused", !accepted(v3_frame("full", sid, -1)));
    check("a fractional count is refused", !accepted(v3_frame("full", sid, 1.5)));
    check("a string count is refused", !accepted(v3_frame("full", sid, "1")));
    check("a guest and fetch socket at once is no mode", !accepted(v3_frame("fetch", "none", 0, {{"guest", true}})));
    auto v2 = parse_auth_frame(v3_frame("full", "zzz", "x", {{"v", 2}}));
    check("a v2 frame keeps ignoring fields it never had", v2 && v2->version == 2 && v2->session.empty());

    // A resume names its sid; the relay compares it with the device's own.
    check("a sid matches itself", session::sid_equal(sid, sid));
    check("one differing character anywhere is no match",
          !session::sid_equal(sid, "10112233445566778899aabbccddeeff") &&
              !session::sid_equal(sid, "00112233445566778899aabbccddeefe") &&
              !session::sid_equal(sid, "00112233445566778899abbbccddeeff"));
    check("a prefix is no match", !session::sid_equal(sid, sid.substr(0, 31)) && !session::sid_equal(sid, ""));
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
    check("an unknown version is refused", !accepted(R"({"type":"auth","v":4})"));
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

    printf("auth v3 (resumable sessions)\n");
    test_v3();

    if (failures) {
        printf("%d FAILED\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
