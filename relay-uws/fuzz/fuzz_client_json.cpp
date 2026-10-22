// Every JSON text a client sends goes through client_json::parse (src/client_json.h),
// whose depth rule is what keeps the recursive walks after it (dump, copies,
// comparisons) off the end of the relay's stack (C-RP-01). The rule must be exact:
// it refuses every text the parser would build deeper than MAX_DEPTH, and nothing
// the parser would build within it, so no real frame is lost to it.

#include <string>
#include <utility>
#include <vector>

#include "client_json.h"
#include "fuzz_support.h"

namespace {

// Nesting of a parsed value without recursing, so a deep one cannot crash the check.
size_t depth_of(const nlohmann::json& root) {
    size_t deepest = 0;
    std::vector<std::pair<const nlohmann::json*, size_t>> stack{{&root, 0}};
    while (!stack.empty()) {
        auto [j, d] = stack.back();
        stack.pop_back();
        if (!j->is_structured()) continue;
        deepest = std::max(deepest, d + 1);
        for (const auto& child : *j) stack.emplace_back(&child, d + 1);
    }
    return deepest;
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    if (size > 256 * 1024) return 0;
    const std::string_view text = fuzz::as_text(data, size);
    const nlohmann::json j = client_json::parse(text);
    // nlohmann alone would stop at a NUL and read the value before it.
    if (text.find('\0') != std::string_view::npos) {
        FUZZ_CHECK(j.is_discarded());
        return 0;
    }
    const nlohmann::json unbounded = nlohmann::json::parse(text, nullptr, /*allow_exceptions=*/false);

    if (unbounded.is_discarded()) {
        FUZZ_CHECK(j.is_discarded());
        return 0;
    }
    const size_t depth = depth_of(unbounded);
    FUZZ_CHECK(j.is_discarded() == (depth > client_json::MAX_DEPTH));
    if (j.is_discarded()) return 0;

    // What a handler may do with an accepted value: write it out and read it again.
    const std::string dumped = j.dump();
    const nlohmann::json again = client_json::parse(dumped);
    FUZZ_CHECK(!again.is_discarded());
    FUZZ_CHECK(again == j);
    return 0;
}
