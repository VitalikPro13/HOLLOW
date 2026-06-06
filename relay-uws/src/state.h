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

// No soft backpressure — let uWebSockets buffer handle delivery.
// Hard limit (.maxBackpressure = 64MB) catches truly dead connections.

static constexpr size_t MAX_CONNS_PER_IP = 34;
static constexpr size_t MAX_NEW_CONNS_PER_MIN_PER_IP = 10;
static constexpr size_t MAX_GUEST_ROOMS = 3;
static constexpr int GUEST_IDLE_SECS = 1800;
static constexpr uint32_t GUEST_BINARY_PER_MIN = 10;

// Offline message store-and-forward buffer (RAM only).
// Bridges the gap between "sender sends to offline peer" and "peer's FCM
// fetch node (or full app) wakes up and joins the DM room". Holds ciphertext
// only — E2EE preserved. Durable delivery is still owned by full-node DM-sync;
// this buffer just makes push-notification previews accurate.
static constexpr size_t MAX_BUFFERED_MSGS_PER_PEER = 100;
static constexpr int64_t OFFLINE_BUFFER_TTL_SECS = 86400;  // 24 hours

using SSLWebSocket = uWS::WebSocket<true, true, struct PerSocketData>;

struct PerSocketData {
    std::string peer_id;
    bool authenticated = false;
    struct us_timer_t* auth_timer = nullptr;
    std::string license_key;
    bool is_guest = false;
    std::string ip_key;
    bool is_fetch = false;  // Invisible background fetch mode (FCM wake-up)
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
    ServerStatsCache stats_cache;

    // Temporary nickname registry (RAM only, released on disconnect)
    std::unordered_map<std::string, std::string> nickname_to_peer;  // nickname -> peer_id
    std::unordered_map<std::string, std::string> peer_to_nickname;  // peer_id -> nickname

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
        std::string room;              // DM room code the frame belongs to
        std::string frame;             // ready-to-send 0x06 binary frame
        std::chrono::steady_clock::time_point at;
    };
    std::unordered_map<std::string, std::deque<BufferedMsg>> offline_buffer;

    size_t online_users() const { return peer_sockets.size() - guest_count; }
};
