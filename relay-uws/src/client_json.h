#pragma once
#include "json.hpp"

#include <cstddef>
#include <string_view>

// Every JSON text a client sends is parsed here. nlohmann parses and frees any depth
// without recursing, but dump(), copies and comparisons recurse once per level, so one
// frame nested a few hundred thousand deep overflowed the relay's stack (C-RP-01), a
// crash that takes no snapshot. Refusing the depth before parsing keeps every later
// walk shallow. Header-only so test/test_client_json.cpp drives it.
namespace client_json {

// Real frames nest at most 5 deep (a join's roster, push prefs).
static constexpr size_t MAX_DEPTH = 32;

// Whether no array or object in `text` opens deeper than `max_depth`. Brackets inside
// strings do not count, so for any text the parser accepts this is its exact nesting.
inline bool depth_within(std::string_view text, size_t max_depth) {
    size_t depth = 0;
    bool in_string = false;
    for (size_t i = 0; i < text.size(); i++) {
        const char c = text[i];
        if (in_string) {
            if (c == '\\') {
                i++;
            } else if (c == '"') {
                in_string = false;
            }
        } else if (c == '"') {
            in_string = true;
        } else if (c == '[' || c == '{') {
            if (++depth > max_depth) return false;
        } else if ((c == ']' || c == '}') && depth > 0) {
            depth--;
        }
    }
    return true;
}

// The parsed value, or a discarded one for text that is invalid or too deep. Never throws.
inline nlohmann::json parse(std::string_view text) {
    if (!depth_within(text, MAX_DEPTH)) return nlohmann::json(nlohmann::json::value_t::discarded);
    return nlohmann::json::parse(text, nullptr, /*allow_exceptions=*/false);
}

}  // namespace client_json
