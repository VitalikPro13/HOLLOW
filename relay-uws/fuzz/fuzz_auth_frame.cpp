// The pre-auth frames (src/auth_frame.h): the only input any socket on the internet
// reaches the relay with before proving anything. Runs every step handle_auth takes
// on the frame's own fields before the session work: the parse, the peer id derived
// from the claimed key, the signed message and the real signature check. An
// exception escaping here is the HOL-SEC-028 crash class (it ends the relay).

#include <string>

#include "auth_frame.h"
#include "crypto.h"
#include "fuzz_support.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
    const std::string_view message = fuzz::as_text(data, size);
    const bool hello = is_auth_hello(message);
    const std::optional<AuthFrame> frame = parse_auth_frame(message);
    FUZZ_CHECK(!(hello && frame));
    if (size > MAX_AUTH_FRAME_BYTES) FUZZ_CHECK(!hello && !frame);
    // nlohmann alone stops at a NUL and reads the value before it; JSON never has one.
    if (message.find('\0') != std::string_view::npos) FUZZ_CHECK(!hello && !frame);

    const std::string domain = auth_domain(message.substr(0, 256));
    for (char c : domain) FUZZ_CHECK(!(c >= 'A' && c <= 'Z'));
    if (!frame) return 0;

    FUZZ_CHECK(frame->version >= 1 && frame->version <= 3);
    const std::optional<std::string> mode = auth_mode(frame->guest, frame->fetch);
    if (frame->version == 3) {
        FUZZ_CHECK(mode.has_value());
        FUZZ_CHECK(session::auth_session_ok(*mode, frame->session));
    }
    (void)auth_time_ok(frame->version, frame->timestamp, 1790000000);
    (void)is_auth_nonce_shape(frame->nonce);

    const std::string derived = derive_peer_id(frame->public_key);
    (void)(derived == frame->peer_id);
    const std::string digest = frame->license_key.empty() ? std::string() : sha256_hex(frame->license_key);
    std::string signed_msg;
    if (frame->version >= 2 && mode) {
        signed_msg = frame->version == 3
                         ? auth_v3_message(frame->domain, frame->nonce, frame->peer_id, frame->timestamp, *mode,
                                           digest, frame->session, frame->in_h)
                         : auth_v2_message(frame->domain, frame->nonce, frame->peer_id, frame->timestamp, *mode,
                                           digest);
    } else {
        signed_msg = "hollow-ws-auth:" + frame->peer_id + ":" + std::to_string(frame->timestamp);
    }
    (void)verify_ed25519(frame->public_key, frame->signature, signed_msg);
    return 0;
}
