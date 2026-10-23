#pragma once
#include "json.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

// What the send budget reads from a client's text "msg" before the handler runs. It
// runs outside the handler's try, so it never throws: value() on a field of the wrong
// type would unwind into uSockets and kill the relay without a snapshot. Header-only so
// test/test_send_budget.cpp drives it.
namespace msg_plan {

struct Fields {
    const std::string* room;
    std::string_view data;
};

// The room and data of a msg, or nullopt when either has the wrong type (the handler
// refuses those). A missing data is empty.
inline std::optional<Fields> fields(const nlohmann::json& j) {
    if (!j.is_object()) return std::nullopt;
    const auto room = j.find("room");
    if (room == j.end() || !room->is_string()) return std::nullopt;
    const auto data = j.find("data");
    if (data != j.end() && !data->is_string()) return std::nullopt;
    Fields f{&room->get_ref<const std::string&>(), {}};
    if (data != j.end()) f.data = data->get_ref<const std::string&>();
    return f;
}

// A string's size once nlohmann::json dumps it: quotes and escapes (client JSON is
// valid UTF-8, which it writes as is).
inline uint64_t json_string_size(std::string_view s) {
    uint64_t n = 2;
    for (unsigned char c : s) {
        if (c == '"' || c == '\\' || c == '\b' || c == '\f' || c == '\n' || c == '\r' || c == '\t') n += 2;
        else if (c < 0x20) n += 6;
        else n += 1;
    }
    return n;
}

// The size of the msg each receiver gets, {"data":..,"from":..,"room":..,"type":"msg"}.
inline uint64_t out_size(std::string_view room, std::string_view from, std::string_view data) {
    return 2 + 3 + 4 * 7 + 5 + json_string_size(data) + json_string_size(from) + json_string_size(room);
}

}  // namespace msg_plan
