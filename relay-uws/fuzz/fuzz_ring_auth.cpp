// Ring control (`set_topic_buffer`, src/ring_auth.h) as handle_set_topic_buffer reads
// it: the client's JSON through client_json, the control's fields, then the rules a
// signed one must pass. With stand-in signatures, anything authorized must still be
// fresh, well formed and inside its owner's topics.

#include <string>
#include <vector>

#include "client_json.h"
#include "fuzz_support.h"
#include "ring_auth.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const nlohmann::json j = client_json::parse(fuzz::as_text(data, size));
    if (j.is_discarded()) return 0;
    ring_auth::Control c;
    bool is_signed = false;
    if (!ring_auth::parse(j, c, is_signed)) return 0;
    FUZZ_CHECK(is_signed == j.contains("sig"));

    static const LockCrypto crypto = fuzz::lock_crypto();
    LockLink tip;
    tip.n = 1;
    tip.change = "change-key";
    const std::vector<LockLink> chain{tip};
    const int64_t now_ms = 1800000000000;
    const ring_auth::Relay relays[] = {{"relay.example.com", false}, {"relay.example.com", true}, {"", true}};
    for (const auto& relay : relays) {
        if (!ring_auth::authorized(c, &chain, now_ms, crypto, relay)) continue;
        FUZZ_CHECK(!c.sig.empty() && c.ts_ms > 0);
        const int64_t skew = now_ms > c.ts_ms ? now_ms - c.ts_ms : c.ts_ms - now_ms;
        FUZZ_CHECK(skew <= ring_auth::MAX_SKEW_MS);
        FUZZ_CHECK(ring_auth::in_own_topics(c));
        for (const auto& ch : c.channels) FUZZ_CHECK(ring_auth::is_channel_shape(ch));
        FUZZ_CHECK(c.version == 2 ? !relay.domain.empty() : relay.accept_ring1);
    }
    FUZZ_CHECK(!ring_auth::authorized(c, nullptr, now_ms, crypto, relays[1]));

    // The ring keys a control's channels would name, and the server each counts against.
    const std::string prefix = c.room + '\0' + ring_auth::topic_prefix(c.room, c.owner);
    for (const auto& ch : c.channels) {
        const std::string ns = ring_auth::ring_namespace(prefix + ch);
        FUZZ_CHECK(ns.compare(0, c.room.size(), c.room) == 0 || c.room.find('\0') != std::string::npos);
    }
    (void)ring_auth::payload_ring1(c);
    (void)ring_auth::payload_ring2(c, "relay.example.com");
    return 0;
}
