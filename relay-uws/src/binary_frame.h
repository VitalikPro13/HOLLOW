#pragma once
#include <cstdint>
#include <initializer_list>
#include <optional>
#include <string>
#include <string_view>

// The client binary frames, split into their fields and nothing more: who may send
// them, and where, stays in ws_handler.cpp. Any authenticated socket reaches these
// parsers with any bytes, so each answers nullopt for a frame it cannot split and
// never reads past `raw`. Every view points into `raw`. Header-only and free of
// uWebSockets so test/test_binary_frame.cpp and fuzz/fuzz_binary_frame.cpp drive it.
//
// None checks the opcode byte: the dispatcher picked the parser by it.
namespace binary_frame {

// 0x02 (file chunk) and 0x04/0x08 (direct): [op][room\0][target\0][payload].
struct Direct {
    std::string_view room;
    std::string_view target;
    std::string_view payload;
};

// 0x03/0x0A (room broadcast): [op][room\0][payload].
struct Broadcast {
    std::string_view room;
    std::string_view payload;
};

// 0x07 (topic broadcast): [op][room\0][topic\0][payload].
struct Topic {
    std::string_view room;
    std::string_view topic;
    std::string_view payload;
};

// 0x09 (channel copy for an offline member): [op][room\0][target\0][channel\0][flags:1][payload],
// flags bit 0 = mention.
struct ChannelDirect {
    std::string_view room;
    std::string_view target;
    std::string_view channel;
    bool mention = false;
    std::string_view payload;
};

// A file chunk always carries bytes.
inline std::optional<Direct> parse_chunk(std::string_view raw) {
    if (raw.size() < 4) return std::nullopt;
    const size_t room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return std::nullopt;
    const size_t target_start = room_nul + 1;
    if (target_start >= raw.size()) return std::nullopt;
    const size_t target_nul = raw.find('\0', target_start);
    if (target_nul == std::string_view::npos) return std::nullopt;
    const size_t payload_start = target_nul + 1;
    if (payload_start >= raw.size()) return std::nullopt;
    return Direct{raw.substr(1, room_nul - 1), raw.substr(target_start, target_nul - target_start),
                  raw.substr(payload_start)};
}

inline std::optional<Broadcast> parse_broadcast(std::string_view raw) {
    if (raw.size() < 3) return std::nullopt;
    const size_t room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return std::nullopt;
    const size_t payload_start = room_nul + 1;
    return Broadcast{raw.substr(1, room_nul - 1),
                     payload_start < raw.size() ? raw.substr(payload_start) : std::string_view{}};
}

inline std::optional<Direct> parse_direct(std::string_view raw) {
    if (raw.size() < 5) return std::nullopt;
    const size_t room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return std::nullopt;
    const size_t target_start = room_nul + 1;
    if (target_start >= raw.size()) return std::nullopt;
    const size_t target_nul = raw.find('\0', target_start);
    if (target_nul == std::string_view::npos) return std::nullopt;
    const size_t payload_start = target_nul + 1;
    return Direct{raw.substr(1, room_nul - 1), raw.substr(target_start, target_nul - target_start),
                  payload_start < raw.size() ? raw.substr(payload_start) : std::string_view{}};
}

inline std::optional<Topic> parse_topic(std::string_view raw) {
    if (raw.size() < 4) return std::nullopt;
    const size_t room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return std::nullopt;
    const size_t topic_start = room_nul + 1;
    if (topic_start >= raw.size()) return std::nullopt;
    const size_t topic_nul = raw.find('\0', topic_start);
    if (topic_nul == std::string_view::npos) return std::nullopt;
    const size_t payload_start = topic_nul + 1;
    return Topic{raw.substr(1, room_nul - 1), raw.substr(topic_start, topic_nul - topic_start),
                 payload_start < raw.size() ? raw.substr(payload_start) : std::string_view{}};
}

inline std::optional<ChannelDirect> parse_channel_direct(std::string_view raw) {
    if (raw.size() < 6) return std::nullopt;
    const size_t room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return std::nullopt;
    const size_t target_start = room_nul + 1;
    if (target_start >= raw.size()) return std::nullopt;
    const size_t target_nul = raw.find('\0', target_start);
    if (target_nul == std::string_view::npos) return std::nullopt;
    const size_t channel_start = target_nul + 1;
    if (channel_start >= raw.size()) return std::nullopt;
    const size_t channel_nul = raw.find('\0', channel_start);
    if (channel_nul == std::string_view::npos) return std::nullopt;
    const size_t flags_pos = channel_nul + 1;
    if (flags_pos >= raw.size()) return std::nullopt;
    ChannelDirect out;
    out.room = raw.substr(1, room_nul - 1);
    out.target = raw.substr(target_start, target_nul - target_start);
    out.channel = raw.substr(channel_start, channel_nul - channel_start);
    out.mention = (static_cast<uint8_t>(raw[flags_pos]) & 0x01) != 0;
    out.payload = flags_pos + 1 < raw.size() ? raw.substr(flags_pos + 1) : std::string_view{};
    return out;
}

// The 0x06 frame a direct reaches its target as: [0x06][room\0][sender\0][payload].
inline std::string direct_frame(std::string_view room, std::string_view sender, std::string_view payload) {
    std::string frame;
    frame.reserve(1 + room.size() + 1 + sender.size() + 1 + payload.size());
    frame.push_back(0x06);
    frame.append(room);
    frame.push_back(0x00);
    frame.append(sender);
    frame.push_back(0x00);
    frame.append(payload);
    return frame;
}

// The frame a broadcast (0x05, fields room and sender) or a topic send (0x08, fields
// room, topic and sender) reaches each receiver as: the opcode, each field NUL-ended,
// then the payload.
inline uint64_t out_frame_size(std::initializer_list<std::string_view> fields, std::string_view payload) {
    uint64_t n = 1 + payload.size();
    for (std::string_view f : fields) n += f.size() + 1;
    return n;
}

inline std::string out_frame(uint8_t op, std::initializer_list<std::string_view> fields, std::string_view payload) {
    std::string frame;
    frame.reserve(out_frame_size(fields, payload));
    frame.push_back(static_cast<char>(op));
    for (std::string_view f : fields) {
        frame.append(f);
        frame.push_back(0x00);
    }
    frame.append(payload);
    return frame;
}

// The sender a 0x06 frame names, "" when it names none.
inline std::string direct_frame_sender(std::string_view frame) {
    const size_t room_end = frame.find('\0', 1);
    if (room_end == std::string_view::npos) return std::string();
    const size_t sender_end = frame.find('\0', room_end + 1);
    if (sender_end == std::string_view::npos) return std::string();
    return std::string(frame.substr(room_end + 1, sender_end - room_end - 1));
}

}  // namespace binary_frame
