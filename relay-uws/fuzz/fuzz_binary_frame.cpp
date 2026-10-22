// The client binary frames (src/binary_frame.h), which every authenticated socket
// reaches with any bytes. Beyond not crashing, each split must put the frame back
// together exactly: a field that swallowed or dropped a byte would deliver a message
// to another room or target than the one the sender named.

#include <string>

#include "binary_frame.h"
#include "fuzz_support.h"

namespace {

const std::string SENDER = "12D3KooWAaYVakMyznsMrUbM1TPKUnduj2tCfQiM6zujqQmepeqr";

bool no_nul(std::string_view s) { return s.find('\0') == std::string_view::npos; }

std::string joined(char op, std::initializer_list<std::string_view> fields, std::string_view tail) {
    std::string out(1, op);
    for (auto f : fields) {
        out.append(f);
        out.push_back('\0');
    }
    out.append(tail);
    return out;
}

}  // namespace

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const std::string_view raw = fuzz::as_text(data, size);
    const char op = raw.empty() ? '\0' : raw[0];

    if (auto f = binary_frame::parse_chunk(raw)) {
        FUZZ_CHECK(no_nul(f->room) && no_nul(f->target) && !f->payload.empty());
        FUZZ_CHECK(joined(op, {f->room, f->target}, f->payload) == raw);
    }
    if (auto f = binary_frame::parse_broadcast(raw)) {
        FUZZ_CHECK(no_nul(f->room));
        FUZZ_CHECK(joined(op, {f->room}, f->payload) == raw);
    }
    if (auto f = binary_frame::parse_direct(raw)) {
        FUZZ_CHECK(no_nul(f->room) && no_nul(f->target));
        FUZZ_CHECK(joined(op, {f->room, f->target}, f->payload) == raw);
        // What the target receives names the room, the sender and the same bytes.
        const std::string delivered = binary_frame::direct_frame(f->room, SENDER, f->payload);
        FUZZ_CHECK(binary_frame::direct_frame_sender(delivered) == SENDER);
        auto back = binary_frame::parse_direct(delivered);
        FUZZ_CHECK(back && back->room == f->room && back->target == SENDER && back->payload == f->payload);
    }
    if (auto f = binary_frame::parse_topic(raw)) {
        FUZZ_CHECK(no_nul(f->room) && no_nul(f->topic));
        FUZZ_CHECK(joined(op, {f->room, f->topic}, f->payload) == raw);
    }
    if (auto f = binary_frame::parse_channel_direct(raw)) {
        FUZZ_CHECK(no_nul(f->room) && no_nul(f->target) && no_nul(f->channel));
        const size_t flags_pos = 1 + f->room.size() + 1 + f->target.size() + 1 + f->channel.size() + 1;
        FUZZ_CHECK(flags_pos < raw.size());
        FUZZ_CHECK(f->mention == ((static_cast<uint8_t>(raw[flags_pos]) & 1) != 0));
        FUZZ_CHECK(joined(op, {f->room, f->target, f->channel}, raw.substr(flags_pos, 1)) + std::string(f->payload) ==
                   raw);
    }
    (void)binary_frame::direct_frame_sender(raw);
    return 0;
}
