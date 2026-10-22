// The restart snapshot (src/snapshot_codec.h). Only the relay writes it, into a memfd
// systemd hands back, so it is hostile only when that memory is damaged; a damaged
// one must decode to nothing rather than crash the relay as it starts. A snapshot
// that decodes must write out and decode again to the same bytes, and its JSON parts
// are read the way snapshot.cpp restores them.

#include <string>

#include "fuzz_support.h"
#include "join_lock.h"
#include "roster.h"
#include "snapshot_codec.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    snapshot::Data d;
    if (!snapshot::decode(fuzz::as_text(data, size), d)) return 0;
    const std::string once = snapshot::encode(d);
    snapshot::Data again;
    FUZZ_CHECK(snapshot::decode(once, again));
    FUZZ_CHECK(again.sessions_dropped == 0);
    FUZZ_CHECK(snapshot::encode(again) == once);

    for (const auto& l : d.locks) {
        (void)join_lock::links_from_json(nlohmann::json::parse(l.links_json, nullptr, /*allow_exceptions=*/false));
    }
    for (const auto& r : d.rosters) {
        (void)roster::from_json(nlohmann::json::parse(r.json, nullptr, /*allow_exceptions=*/false));
    }
    return 0;
}
