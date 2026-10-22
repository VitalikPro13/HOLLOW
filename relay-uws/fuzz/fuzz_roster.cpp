// Rosters shown on `inbox:` joins (src/roster.h, src/roster_book.h), one after
// another, the way inbox_owner_by_roster takes them: the JSON read as strictly as
// serde, the size measured as the relay would hold it, then verified, merged into
// the held roster and folded. The input is a JSON array of {"inbox", "device",
// "roster"} shows. The held roster must keep fitting its ceilings, write out and
// read back unchanged (the restart snapshot keeps it that way), and showing the same
// roster twice must change nothing (else every join drops the inbox's owners).

#include <string>

#include "client_json.h"
#include "fuzz_support.h"
#include "roster_book.h"

namespace {

std::string text_field(const nlohmann::json& j, const char* field) {
    auto it = j.find(field);
    return it != j.end() && it->is_string() ? it->get<std::string>() : std::string();
}

void round_trips(const roster::Roster& r) {
    const std::string text = roster::to_json(r).dump();
    auto back = roster::from_json(nlohmann::json::parse(text, nullptr, false));
    FUZZ_CHECK(back && *back == r);
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const nlohmann::json shows = client_json::parse(fuzz::as_text(data, size));
    if (!shows.is_array()) return 0;
    static const RosterCrypto crypto = fuzz::roster_crypto();
    RosterBook book;
    book.budget = 256 * 1024;
    int64_t now_ms = 1800000000000;
    uint64_t share = 1;
    size_t n = 0;
    for (const auto& show : shows) {
        if (++n > 8) break;
        if (!show.is_object()) continue;
        auto roster_it = show.find("roster");
        if (roster_it == show.end()) continue;
        std::optional<roster::Roster> shown = roster::from_json(*roster_it);
        if (!shown || roster::to_json(*shown).dump().size() > roster::MAX_ROSTER_BYTES) continue;
        round_trips(*shown);

        std::string master = text_field(show, "inbox");
        if (master.empty()) master = shown->master;
        const std::string device = text_field(show, "device");
        const RosterBook::Shown out = book.show(master, *shown, device, share++ % 3, now_ms, crypto);
        if (out.member) FUZZ_CHECK(out.state.members.count(device) == 1);

        const RosterBook::Held* held = book.get(master);
        // A roster for another master or past a ceiling is not taken at all.
        if (shown->master != master || !shown->within_caps()) {
            FUZZ_CHECK(!out.member && !out.changed);
            continue;
        }
        if (!held) continue;
        FUZZ_CHECK(held->roster.master == master);
        FUZZ_CHECK(held->roster.within_caps());
        round_trips(held->roster);
        const roster::State folded = book.fold(*held, now_ms, crypto);
        FUZZ_CHECK(folded.members == out.state.members && folded.removed == out.state.removed &&
                   folded.pending == out.state.pending && folded.base == out.state.base);
        for (const auto& d : folded.members) FUZZ_CHECK(folded.removed.count(d) == 0);

        const roster::Roster before = held->roster;
        const RosterBook::Shown again = book.show(master, *shown, device, share % 3, now_ms, crypto);
        if (const RosterBook::Held* after = book.get(master)) {
            FUZZ_CHECK(!again.changed && after->roster == before);
        }
        // Later shows land a little later, so pending joins can mature.
        now_ms += 3LL * 24 * 60 * 60 * 1000;
    }
    return 0;
}
