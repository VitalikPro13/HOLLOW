#pragma once
#include <string>
#include <vector>
#include <unordered_map>
#include <unordered_set>
#include <chrono>
#include <cstdint>

#include <App.h>
#include "license.h"

constexpr size_t MAX_BACKPRESSURE_SOFT = 64 * 1024;

using SSLWebSocket = uWS::WebSocket<true, true, struct PerSocketData>;

struct PerSocketData {
    std::string peer_id;
    bool authenticated = false;
    uint32_t binary_rate_tokens = 100;
    std::chrono::steady_clock::time_point rate_last_refill;
    struct us_timer_t* auth_timer = nullptr;
    std::string license_key;
};

struct PeerEntry {
    std::string peer_id;
    std::vector<std::string> addresses;
    uint64_t last_seen;
};

struct WsRoom {
    std::unordered_map<std::string, SSLWebSocket*> peers;
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

    LicenseState license;
    ServerStatsCache stats_cache;

    size_t online_users() const { return peer_sockets.size(); }
};
