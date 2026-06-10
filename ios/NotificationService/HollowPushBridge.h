//  HollowPushBridge.h
//  Bridging header exposing the Rust C-ABI (from libhollow_core.a) to the
//  Notification Service Extension's Swift code.
//
//  Set this file as the NSE target's "Objective-C Bridging Header"
//  (SWIFT_OBJC_BRIDGING_HEADER) in Build Settings, and make the NSE target link
//  libhollow_core.a (the same static lib the Runner force-loads — add a "Build
//  Rust library" script phase or reference the already-built .a, plus
//  -force_load in OTHER_LDFLAGS for the NSE target).
//
//  The symbols are implemented in rust/hollow_core/src/push_enrich.rs.

#ifndef HOLLOW_PUSH_BRIDGE_H
#define HOLLOW_PUSH_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Connect to OUR relay (fetch-peer mode), pull the buffered ciphertext for
// `sender_peer_id`, decrypt on-device, persist, and return the message text(s).
//
// The APNs push carries NO content — this fetch is how the NSE gets the message
// without leaking content to Apple/Google. Returns a heap-allocated C string
// containing a JSON array [{"text","message_id","timestamp","has_image"}] (may be
// "[]"), or NULL on hard failure. Free the result with hollow_push_string_free.
//
// data_dir:       absolute path to a Hollow data dir the NSE can read/write
//                 (App Group container or a copy); must contain messages.db +
//                 the identity file.
// relay_domain:   e.g. "relay.anonlisten.com" (or "" for the default).
// sender_peer_id: the peer whose DM triggered the push (from the push data).
// license_key:    license key, or "" if none.
// timeout_secs:   overall fetch timeout (NSE has ~30s; pass ~15).
// server_room:    "" for a DM wake. For a CHANNEL wake (type=channel_wake),
//                 the server id from the push data — joins the server room and
//                 decrypts buffered channel messages via MLS instead of Olm.
//                 Channel entries additionally carry server_id/channel_id/
//                 server_name/channel_name/sender_name resolved on-device.
char *hollow_push_fetch_and_decrypt(const char *data_dir,
                                    const char *relay_domain,
                                    const char *sender_peer_id,
                                    const char *license_key,
                                    uint32_t timeout_secs,
                                    const char *server_room);

// Free a string returned by hollow_push_fetch_and_decrypt / hollow_push_decrypt.
void hollow_push_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* HOLLOW_PUSH_BRIDGE_H */
