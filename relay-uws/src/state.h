#pragma once
#include <string>
#include <vector>
#include <deque>
#include <unordered_map>
#include <unordered_set>
#include <chrono>
#include <cstdint>

#include <App.h>
#include "license.h"
#include "reports.h"

// No soft backpressure — let uWebSockets buffer handle delivery.
// Hard limit (.maxBackpressure = 64MB) catches truly dead connections.

static constexpr size_t MAX_CONNS_PER_IP = 34;
static constexpr size_t MAX_NEW_CONNS_PER_MIN_PER_IP = 10;
// Per-IP daily byte budget (anti-drain backstop). Counts BINARY frames in
// BOTH directions per ip_limit_key (v4 address / v6 /64 prefix). ~300x a
// heavy chatter's organic relay traffic — false positives ~ 0 while capping
// a 24/7 drain bot at ~10 GB/day instead of ~4 TB. Fixed UTC-day window.
// RAM only, never logged (same privacy model as the connection caps).
// On exhaustion: explicit close 1008 "bandwidth_limit" — NEVER silent drops.
// If CGNAT/campus IPs ever bite, scale the budget by active_count per IP
// before touching this number.
static constexpr uint64_t DAILY_BYTE_BUDGET = 10ull * 1024 * 1024 * 1024;
static constexpr size_t MAX_GUEST_ROOMS = 3;
static constexpr int GUEST_IDLE_SECS = 1800;
static constexpr uint32_t GUEST_BINARY_PER_MIN = 10;

// Offline message store-and-forward buffer (RAM only).
// Bridges the gap between "sender sends to offline peer" and "peer's FCM
// fetch node (or full app) wakes up and joins the DM room". Holds ciphertext
// only — E2EE preserved. Durable delivery is still owned by full-node DM-sync;
// this buffer just makes push-notification previews accurate.
static constexpr size_t MAX_BUFFERED_MSGS_PER_PEER = 100;
// Separate, tiny cap for inlined-image frames: a push notification can only
// show ONE image preview and we send one notification per peer, so buffering
// more than the latest image per peer is wasted RAM.
static constexpr size_t MAX_BUFFERED_IMAGES_PER_PEER = 1;
static constexpr int64_t OFFLINE_BUFFER_TTL_SECS = 86400;  // 24 hours

// Channel push notifications (0x09 frames — per-offline-member channel
// message copies fanned out by the SENDER; the relay never learns server
// membership). Separate buffer cap so chatty servers can't evict buffered DMs.
static constexpr size_t MAX_BUFFERED_CHANNEL_MSGS_PER_PEER = 30;

// Opt-in offline delivery ("message-availability cache") — the relay stays an
// availability HELPER, never a source of truth: it retains the SAME E2EE,
// Ed25519-signed ciphertext it already routes, the receiver verifies + dedups
// exactly as if a peer served it, and peer-to-peer sync remains the
// correctness floor. RAM only (nothing survives a restart — deliberate).
// Opted-in peers get a bigger DM text/FileHeader window + their own retention;
// inlined-image frames stay at the 24h push baseline (no media bytes ride the
// extended tier).
static constexpr size_t MAX_OPTIN_MSGS_PER_PEER = 500;
// Opted-in peers keep several inlined offline images (the push baseline keeps
// exactly ONE — a push notification shows one preview, but an offline inbox
// user expects every image sent while away). Still 24h TTL — inlined bytes
// never ride the extended retention.
static constexpr size_t MAX_OPTIN_IMAGES_PER_PEER = 8;
static constexpr int64_t OFFLINE_RETENTION_MIN_SECS = 3600;            // 1 hour
static constexpr int64_t OFFLINE_RETENTION_MAX_SECS = 7 * 86400;       // 7 days
// Per-channel topic ring buffers (server-owner opt-in, registered by member
// clients on connect). One copy per channel serves every late joiner —
// deletion is by retention expiry, never by delivery, because "everyone got
// it" is unknowable to a relay that refuses to learn membership.
static constexpr size_t MAX_TOPIC_BUFFER_MSGS = 200;                    // frames per channel
static constexpr size_t MAX_TOPIC_BUFFER_BYTES = 1024 * 1024;           // 1 MB per channel
static constexpr size_t MAX_TOPIC_CHANNELS_PER_CALL = 128;              // defensive cap
static constexpr size_t MAX_TOPIC_BUFFERS_TOTAL = 65536;                // defensive cap
static constexpr int64_t TOPIC_BUFFER_IDLE_EXPIRE_SECS = 7 * 86400;     // no member re-registered
// Global budget across ALL buffered frames (DM + topic). Oldest-first
// eviction when exceeded — organic use never gets near this.
static constexpr size_t MAX_BUFFER_TOTAL_BYTES = 512ull * 1024 * 1024;
// Anti-spam: non-mention channel pushes are heavily throttled — the banner has
// no content until the device fetches, so repeats add nothing. Mentions are
// urgent and bypass the long window.
static constexpr int CHANNEL_PUSH_DEBOUNCE_SECS = 120;         // non-mention, per (peer, server)
static constexpr int CHANNEL_PUSH_MENTION_DEBOUNCE_SECS = 10;  // mention, per (peer, server)
static constexpr int CHANNEL_PUSH_MIN_GAP_SECS = 5;            // any channel push, per peer
static constexpr uint32_t CHANNEL_PUSH_MAX_WHILE_OFFLINE = 3;  // non-mention cap until app reconnects

using SSLWebSocket = uWS::WebSocket<true, true, struct PerSocketData>;

struct PerSocketData {
    std::string peer_id;
    bool authenticated = false;
    struct us_timer_t* auth_timer = nullptr;
    std::string license_key;
    bool is_guest = false;
    std::string ip_key;
    bool is_fetch = false;  // Invisible background fetch mode (FCM wake-up)
    // Cached pointer into state.ip_states for zero-lookup per-frame byte
    // accounting. Stable while this socket is open: unordered_map values
    // survive rehash, and an entry is never erased while active_count > 0.
    struct IpState* ip_state = nullptr;
    // Set when a NEWER socket for the same peer_id authenticates and takes over
    // this peer's room/socket state. A superseded ghost must NOT run the shared
    // peer cleanup on close (it would evict the live successor from every room);
    // it only cleans up its own per-connection accounting (IP/guest). See
    // handle_auth supersede path + cleanup_peer guard in ws_handler.cpp.
    bool superseded = false;
    std::chrono::steady_clock::time_point last_binary_activity;
    uint32_t binary_frames_this_minute = 0;
    std::chrono::steady_clock::time_point minute_window_start;

    // Per-room channel subscriptions (room_code -> set of topic strings).
    // Empty set = wildcard (receive all messages for that room).
    std::unordered_map<std::string, std::unordered_set<std::string>> subscriptions;
};

struct PeerEntry {
    std::string peer_id;
    std::vector<std::string> addresses;
    uint64_t last_seen;
};

struct WsRoom {
    std::unordered_map<std::string, SSLWebSocket*> peers;
};

struct IpState {
    uint32_t active_count = 0;
    std::deque<std::chrono::steady_clock::time_point> recent_connects;
    // Daily byte budget (binary frames both directions, UTC-day window).
    // An entry with bytes_today > 0 survives active_count == 0 so a
    // reconnect can't reset the counter; sweep_ip_budgets purges stale days.
    uint64_t bytes_today = 0;
    uint32_t budget_day = 0;  // unix day (secs/86400) the counter belongs to
};

struct ServerStatsCache {
    std::string cached_json;
    std::chrono::steady_clock::time_point fetched_at;
    uint64_t prev_rx_bytes = 0;
    uint64_t prev_tx_bytes = 0;
    std::chrono::steady_clock::time_point prev_sample_at;
    double rx_mbps = 0.0;
    double tx_mbps = 0.0;
    bool has_prev = false;

    bool is_fresh() const {
        return (std::chrono::steady_clock::now() - fetched_at) < std::chrono::seconds(5);
    }
};

struct RelayState {
    // HTTP signaling rooms
    std::unordered_map<std::string, std::vector<PeerEntry>> signaling_rooms;

    // WebSocket rooms
    std::unordered_map<std::string, WsRoom> ws_rooms;

    // peer_id -> set of room codes
    std::unordered_map<std::string, std::unordered_set<std::string>> peer_rooms;

    // peer_id -> WebSocket pointer (for license kicks + online count)
    std::unordered_map<std::string, SSLWebSocket*> peer_sockets;

    // Per-IP connection tracking (in-memory only, never logged/persisted)
    std::unordered_map<std::string, IpState> ip_states;
    std::unordered_set<SSLWebSocket*> guest_sockets;
    size_t guest_count = 0;

    LicenseState license;
    ReportsState reports;
    ServerStatsCache stats_cache;

    // Temporary nickname registry (RAM only, released on disconnect, 10-min TTL).
    // The TTL + a dead-holder live-check on claim/resolve prevent a stale binding
    // (an old identity that never cleanly released) from permanently blocking the
    // nickname for a new claimer — the bug where "123" stayed bound to a dead peer.
    std::unordered_map<std::string, std::string> nickname_to_peer;  // nickname -> peer_id
    std::unordered_map<std::string, std::string> peer_to_nickname;  // peer_id -> nickname
    std::unordered_map<std::string, uint64_t>    nickname_expiry;   // nickname -> expiry unix secs

    // Multi-device link-code registry (RAM only, released on disconnect, 5-min TTL,
    // consumed on resolve). Mirrors the nickname registry. Used by Step 4 device
    // linking so an empty device can find its populated sibling by a short code.
    std::unordered_map<std::string, std::string> linkcode_to_peer;  // code -> peer_id
    std::unordered_map<std::string, std::string> peer_to_linkcode;  // peer_id -> code
    std::unordered_map<std::string, uint64_t>    linkcode_expiry;   // code -> expiry unix secs

    // Push notification tokens (RAM only — re-registered on each app launch)
    // peer_id -> { token, platform ("android"/"ios") }
    struct PushToken {
        std::string token;
        std::string platform;
    };
    std::unordered_map<std::string, PushToken> push_tokens;
    // Debounce: track last push time per peer to avoid flooding
    std::unordered_map<std::string, std::chrono::steady_clock::time_point> last_push_sent;

    // Offline message buffer (RAM only). Key = target peer_id.
    // Each entry is the fully-formed 0x06 direct-message frame to replay when
    // the target joins the matching DM room. Capped per-peer + TTL-swept.
    struct BufferedMsg {
        std::string room;              // DM/server room code the frame belongs to
        std::string frame;             // ready-to-send 0x06 binary frame
        std::chrono::steady_clock::time_point at;
        bool is_image = false;         // inlined-image frame (separate cap)
        bool is_channel = false;       // channel message frame (separate cap)
    };
    std::unordered_map<std::string, std::deque<BufferedMsg>> offline_buffer;

    // Opt-in offline delivery registry (RAM only — re-registered on every
    // connect like push prefs). Presence = opted in; value = retention secs
    // (clamped to OFFLINE_RETENTION_MIN/MAX_SECS).
    std::unordered_map<std::string, int64_t> offline_optin;

    // Per-channel topic ring buffers. Key = room + '\0' + topic. Frames are
    // stored in the outbound 0x08 fan-out form (room/topic/sender/payload) so
    // catch-up replay is a straight send. Ciphertext only — E2EE preserved.
    struct TopicFrame {
        std::string frame;
        std::string sender;  // catch-up skips the requester's own frames
                             // (live fan-out never echoes the sender; MLS
                             // can't decrypt your own ciphertext)
        std::chrono::steady_clock::time_point at;
    };
    struct TopicBuffer {
        std::deque<TopicFrame> frames;
        size_t bytes = 0;
        int64_t retention_secs = 86400;
        std::chrono::steady_clock::time_point last_registered;
    };
    std::unordered_map<std::string, TopicBuffer> topic_buffers;

    // Total bytes across offline_buffer + topic_buffers frames (global budget).
    size_t buffer_total_bytes = 0;

    // Channel push prefs (RAM only — replaced wholesale by set_push_prefs,
    // re-sent by the app on every connect). peer_id -> server room -> pref.
    // Filtering happens HERE because iOS alert pushes can't be suppressed
    // after delivery. Unknown server / unregistered peer defaults to "all".
    struct ServerPushPref {
        std::string level;  // "all" / "mentions" / "nothing"
        std::unordered_map<std::string, std::string> channels;  // channel_id -> level
    };
    std::unordered_map<std::string,
        std::unordered_map<std::string, ServerPushPref>> push_prefs;

    // Channel push throttling state. count_since_offline resets when the full
    // app (non-fetch) rejoins the server room.
    struct ChannelPushState {
        std::chrono::steady_clock::time_point last{};
        uint32_t count_since_offline = 0;
    };
    std::unordered_map<std::string,
        std::unordered_map<std::string, ChannelPushState>> channel_push_state;
    // Per-peer floor across ALL channel pushes (multi-server burst guard).
    std::unordered_map<std::string, std::chrono::steady_clock::time_point> last_channel_push_any;

    size_t online_users() const { return peer_sockets.size() - guest_count; }
};
