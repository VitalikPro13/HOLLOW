// Unit tests for the client binary frame parsers (src/binary_frame.h). They were
// lifted out of ws_handler.cpp's handlers, so besides the layouts this pins them
// against the inline parsing they replaced, on every short frame over a small
// alphabet: a parser that splits one frame differently moves a message to another
// room or target.
//
// Build + run from relay-uws/test (header-only):
//   g++ -std=c++17 -I../src test_binary_frame.cpp -o test_binary_frame && ./test_binary_frame

#include "binary_frame.h"

#include <cstdio>
#include <string>
#include <string_view>

using namespace std::string_literals;

static int failures = 0;

static void check(const std::string& label, bool ok) {
    if (ok) {
        printf("  ok   %s\n", label.c_str());
    } else {
        printf("  FAIL %s\n", label.c_str());
        failures++;
    }
}

// The handlers' parsing before the move, verbatim but for returning instead of acting.
namespace before {

struct Fields {
    bool ok = false;
    std::string room, target, channel, payload;
    bool mention = false;
};

Fields chunk(std::string_view raw) {
    Fields f;
    if (raw.size() < 4) return f;
    size_t room_start = 1;
    auto room_nul_pos = raw.find('\0', room_start);
    if (room_nul_pos == std::string_view::npos) return f;
    std::string_view room_code = raw.substr(room_start, room_nul_pos - room_start);
    size_t peer_start = room_nul_pos + 1;
    if (peer_start >= raw.size()) return f;
    auto peer_nul_pos = raw.find('\0', peer_start);
    if (peer_nul_pos == std::string_view::npos) return f;
    std::string_view target_peer = raw.substr(peer_start, peer_nul_pos - peer_start);
    size_t payload_start = peer_nul_pos + 1;
    if (payload_start >= raw.size()) return f;
    f = {true, std::string(room_code), std::string(target_peer), "", std::string(raw.substr(payload_start))};
    return f;
}

Fields broadcast(std::string_view raw) {
    Fields f;
    if (raw.size() < 3) return f;
    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return f;
    std::string_view room_code = raw.substr(1, room_nul - 1);
    size_t payload_start = room_nul + 1;
    std::string_view payload = (payload_start < raw.size()) ? raw.substr(payload_start) : std::string_view{};
    f = {true, std::string(room_code), "", "", std::string(payload)};
    return f;
}

Fields direct(std::string_view raw) {
    Fields f;
    if (raw.size() < 5) return f;
    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return f;
    std::string_view room_code = raw.substr(1, room_nul - 1);
    size_t peer_start = room_nul + 1;
    if (peer_start >= raw.size()) return f;
    auto peer_nul = raw.find('\0', peer_start);
    if (peer_nul == std::string_view::npos) return f;
    std::string_view target_peer = raw.substr(peer_start, peer_nul - peer_start);
    size_t payload_start = peer_nul + 1;
    std::string_view payload = (payload_start < raw.size()) ? raw.substr(payload_start) : std::string_view{};
    f = {true, std::string(room_code), std::string(target_peer), "", std::string(payload)};
    return f;
}

Fields topic(std::string_view raw) {
    Fields f;
    if (raw.size() < 4) return f;
    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return f;
    std::string_view room_code = raw.substr(1, room_nul - 1);
    size_t topic_start = room_nul + 1;
    if (topic_start >= raw.size()) return f;
    auto topic_nul = raw.find('\0', topic_start);
    if (topic_nul == std::string_view::npos) return f;
    std::string_view topic = raw.substr(topic_start, topic_nul - topic_start);
    size_t payload_start = topic_nul + 1;
    std::string_view payload = (payload_start < raw.size()) ? raw.substr(payload_start) : std::string_view{};
    f = {true, std::string(room_code), std::string(topic), "", std::string(payload)};
    return f;
}

Fields channel_direct(std::string_view raw) {
    Fields f;
    if (raw.size() < 6) return f;
    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return f;
    std::string_view room_code = raw.substr(1, room_nul - 1);
    size_t target_start = room_nul + 1;
    if (target_start >= raw.size()) return f;
    auto target_nul = raw.find('\0', target_start);
    if (target_nul == std::string_view::npos) return f;
    std::string_view target_peer = raw.substr(target_start, target_nul - target_start);
    size_t channel_start = target_nul + 1;
    if (channel_start >= raw.size()) return f;
    auto channel_nul = raw.find('\0', channel_start);
    if (channel_nul == std::string_view::npos) return f;
    std::string_view channel = raw.substr(channel_start, channel_nul - channel_start);
    size_t flags_pos = channel_nul + 1;
    if (flags_pos >= raw.size()) return f;
    bool mention = (static_cast<uint8_t>(raw[flags_pos]) & 0x01) != 0;
    std::string_view payload = (flags_pos + 1 < raw.size()) ? raw.substr(flags_pos + 1) : std::string_view{};
    f = {true, std::string(room_code), std::string(target_peer), std::string(channel), std::string(payload), mention};
    return f;
}

std::string frame_sender(const std::string& frame) {
    const size_t room_end = frame.find('\0', 1);
    if (room_end == std::string::npos) return std::string();
    const size_t sender_end = frame.find('\0', room_end + 1);
    if (sender_end == std::string::npos) return std::string();
    return frame.substr(room_end + 1, sender_end - room_end - 1);
}

}  // namespace before

using before::Fields;

static Fields of(const std::optional<binary_frame::Direct>& d) {
    if (!d) return {};
    return {true, std::string(d->room), std::string(d->target), "", std::string(d->payload)};
}
static Fields of(const std::optional<binary_frame::Broadcast>& b) {
    if (!b) return {};
    return {true, std::string(b->room), "", "", std::string(b->payload)};
}
static Fields of(const std::optional<binary_frame::Topic>& t) {
    if (!t) return {};
    return {true, std::string(t->room), std::string(t->topic), "", std::string(t->payload)};
}
static Fields of(const std::optional<binary_frame::ChannelDirect>& c) {
    if (!c) return {};
    return {true, std::string(c->room), std::string(c->target), std::string(c->channel), std::string(c->payload),
            c->mention};
}

static bool same(const Fields& a, const Fields& b) {
    if (a.ok != b.ok) return false;
    if (!a.ok) return true;
    return a.room == b.room && a.target == b.target && a.channel == b.channel && a.payload == b.payload &&
           a.mention == b.mention;
}

// Every frame up to `max_len` bytes over {op, NUL, 'a', 0x01 (the mention bit)}: each
// parser must split every one exactly as the inline code did.
static void every_short_frame_splits_as_before(size_t max_len) {
    const char alphabet[] = {'\x09', '\0', 'a', '\x01'};
    size_t frames = 0, mismatches = 0;
    std::string raw;
    for (size_t len = 0; len <= max_len; len++) {
        size_t total = 1;
        for (size_t i = 0; i < len; i++) total *= 4;
        for (size_t n = 0; n < total; n++) {
            raw.assign(len, ' ');
            size_t v = n;
            for (size_t i = 0; i < len; i++, v /= 4) raw[i] = alphabet[v % 4];
            frames++;
            if (!same(of(binary_frame::parse_chunk(raw)), before::chunk(raw))) mismatches++;
            if (!same(of(binary_frame::parse_broadcast(raw)), before::broadcast(raw))) mismatches++;
            if (!same(of(binary_frame::parse_direct(raw)), before::direct(raw))) mismatches++;
            if (!same(of(binary_frame::parse_topic(raw)), before::topic(raw))) mismatches++;
            if (!same(of(binary_frame::parse_channel_direct(raw)), before::channel_direct(raw))) mismatches++;
            if (binary_frame::direct_frame_sender(raw) != before::frame_sender(raw)) mismatches++;
        }
    }
    check("all " + std::to_string(frames) + " frames up to " + std::to_string(max_len) +
              " bytes split exactly as the inline parsers did",
          mismatches == 0);
}

int main() {
    printf("binary_frame\n");

    // 0x02 file chunk.
    {
        const std::string f_raw = "\x02room\0target\0bytes"s;
        auto f = binary_frame::parse_chunk(f_raw);
        check("0x02 splits room, target and payload",
              f && f->room == "room" && f->target == "target" && f->payload == "bytes");
        check("0x02 without bytes is no chunk", !binary_frame::parse_chunk("\x02room\0target\0"s));
        check("0x02 without a target end is no chunk", !binary_frame::parse_chunk("\x02room\0target"s));
        check("0x02 shorter than 4 bytes is no chunk", !binary_frame::parse_chunk("\x02\0\0"s));
        const std::string e_raw = "\x02\0\0x"s;
        auto e = binary_frame::parse_chunk(e_raw);
        check("0x02 keeps an empty room and target for the handler to refuse",
              e && e->room.empty() && e->target.empty() && e->payload == "x");
        const std::string n_raw = "\x02r\0t\0a\0b"s;
        auto n = binary_frame::parse_chunk(n_raw);
        check("0x02 payload keeps its own NULs", n && n->payload == "a\0b"s);
    }

    // 0x03 / 0x0A room broadcast.
    {
        const std::string f_raw = "\x03room\0payload"s;
        auto f = binary_frame::parse_broadcast(f_raw);
        check("0x03 splits room and payload", f && f->room == "room" && f->payload == "payload");
        const std::string e_raw = "\x03room\0"s;
        auto e = binary_frame::parse_broadcast(e_raw);
        check("0x03 may carry an empty payload", e && e->room == "room" && e->payload.empty());
        check("0x03 without a room end is nothing", !binary_frame::parse_broadcast("\x03room"s));
        check("0x03 shorter than 3 bytes is nothing", !binary_frame::parse_broadcast("\x03\0"s));
    }

    // 0x04 / 0x08 direct.
    {
        const std::string f_raw = "\x04room\0target\0ct"s;
        auto f = binary_frame::parse_direct(f_raw);
        check("0x04 splits room, target and payload",
              f && f->room == "room" && f->target == "target" && f->payload == "ct");
        const std::string e_raw = "\x04room\0target\0"s;
        auto e = binary_frame::parse_direct(e_raw);
        check("0x04 may carry an empty payload (a push trigger)", e && e->target == "target" && e->payload.empty());
        check("0x04 without a target end is nothing", !binary_frame::parse_direct("\x04room\0target"s));
        check("0x04 shorter than 5 bytes is nothing", !binary_frame::parse_direct("\x04r\0t"s));
        check("0x04 ending at the room's NUL is nothing", !binary_frame::parse_direct("\x04room\0"s));
    }

    // 0x07 topic.
    {
        const std::string f_raw = "\x07room\0topic\0ct"s;
        auto f = binary_frame::parse_topic(f_raw);
        check("0x07 splits room, topic and payload",
              f && f->room == "room" && f->topic == "topic" && f->payload == "ct");
        const std::string e_raw = "\x07room\0topic\0"s;
        auto e = binary_frame::parse_topic(e_raw);
        check("0x07 may carry an empty payload", e && e->topic == "topic" && e->payload.empty());
        check("0x07 without a topic end is nothing", !binary_frame::parse_topic("\x07room\0topic"s));
        check("0x07 shorter than 4 bytes is nothing", !binary_frame::parse_topic("\x07r\0"s));
    }

    // 0x09 channel copy.
    {
        const std::string f_raw = "\x09room\0target\0chan\0\x01payload"s;
        auto f = binary_frame::parse_channel_direct(f_raw);
        check("0x09 splits room, target, channel, mention and payload",
              f && f->room == "room" && f->target == "target" && f->channel == "chan" && f->mention &&
                  f->payload == "payload");
        const std::string q_raw = "\x09room\0target\0chan\0\xfe"s;
        auto q = binary_frame::parse_channel_direct(q_raw);
        check("0x09 reads only bit 0 of the flags, and may carry no payload",
              q && !q->mention && q->payload.empty());
        check("0x09 without flags is nothing", !binary_frame::parse_channel_direct("\x09room\0target\0chan\0"s));
        check("0x09 without a channel end is nothing", !binary_frame::parse_channel_direct("\x09room\0target\0chan"s));
        check("0x09 shorter than 6 bytes is nothing", !binary_frame::parse_channel_direct("\x09\0\0\0\x01"s));
    }

    // The 0x06 frame a direct is delivered as, and the sender read back from it.
    {
        std::string frame = binary_frame::direct_frame("room", "sender", "a\0b"s);
        check("0x06 lays out room, sender and payload", frame == "\x06room\0sender\0a\0b"s);
        check("the sender reads back from a 0x06 frame", binary_frame::direct_frame_sender(frame) == "sender");
        check("a frame without a sender end names nobody", binary_frame::direct_frame_sender("\x06room\0x"s).empty());
        check("an empty frame names nobody", binary_frame::direct_frame_sender(std::string()).empty());
    }

    every_short_frame_splits_as_before(9);

    printf("\n%s (%d failures)\n", failures == 0 ? "PASS" : "FAIL", failures);
    return failures == 0 ? 0 : 1;
}
