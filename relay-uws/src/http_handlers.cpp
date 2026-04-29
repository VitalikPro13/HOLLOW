#include "http_handlers.h"
#include "crypto.h"
#include "json.hpp"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <algorithm>

using json = nlohmann::json;
using HttpResponse = uWS::HttpResponse<true>;
using HttpRequest = uWS::HttpRequest;

static constexpr size_t MAX_PEERS_PER_ROOM = 50;
static constexpr size_t MAX_ADDRS_PER_PEER = 5;
static constexpr uint64_t STALE_THRESHOLD_SECS = 180;
static constexpr uint64_t TIMESTAMP_SKEW_SECS = 60;
static constexpr size_t MAX_BOOTSTRAP_PEERS = 10;

static void cors_headers(HttpResponse* res) {
    res->writeHeader("Access-Control-Allow-Origin", "*");
    res->writeHeader("Content-Type", "application/json");
}

static void json_response(HttpResponse* res, const json& j, const std::string& status = "200 OK") {
    cors_headers(res);
    res->writeStatus(status);
    res->end(j.dump());
}

static void json_error(HttpResponse* res, const std::string& error,
                       const std::string& status = "400 Bad Request") {
    cors_headers(res);
    res->writeStatus(status);
    res->end(json({{"error", error}}).dump());
}

static void handle_register(HttpResponse* res, HttpRequest* /*req*/, RelayState& state) {
    std::string buffer;
    res->onData([res, &state, buffer = std::move(buffer)](
        std::string_view data, bool last) mutable {
        buffer.append(data);
        if (!last) return;

        json j;
        try { j = json::parse(buffer); }
        catch (...) { json_error(res, "Invalid JSON"); return; }

        std::string room_code = j.value("room_code", "");
        std::string peer_id = j.value("peer_id", "");
        auto addresses = j.value("addresses", std::vector<std::string>{});
        uint64_t timestamp = j.value("timestamp", uint64_t(0));
        std::string public_key = j.value("public_key", "");
        std::string signature = j.value("signature", "");

        if (room_code.empty() || room_code.size() > 64) {
            json_error(res, "Invalid room_code"); return;
        }
        if (addresses.empty()) {
            json_error(res, "addresses must be a non-empty array"); return;
        }
        if (peer_id.empty() || public_key.empty() || signature.empty()) {
            json_error(res, "Missing required fields"); return;
        }

        uint64_t now = now_unix_secs();
        uint64_t diff = (now > timestamp) ? (now - timestamp) : (timestamp - now);
        if (diff > TIMESTAMP_SKEW_SECS) {
            json_error(res, "Timestamp too far from server time", "403 Forbidden"); return;
        }

        if (addresses.size() > MAX_ADDRS_PER_PEER) {
            addresses.resize(MAX_ADDRS_PER_PEER);
        }

        std::string addrs_joined;
        for (size_t i = 0; i < addresses.size(); i++) {
            if (i > 0) addrs_joined += ",";
            addrs_joined += addresses[i];
        }

        std::string signed_message = "hollow-register:" + room_code + ":" +
            peer_id + ":" + addrs_joined + ":" + std::to_string(timestamp);

        if (!verify_ed25519(public_key, signature, signed_message)) {
            json_error(res, "Invalid signature", "403 Forbidden"); return;
        }

        auto& peers = state.signaling_rooms[room_code];

        // Remove stale entries
        peers.erase(
            std::remove_if(peers.begin(), peers.end(),
                [now](const PeerEntry& p) {
                    return now - p.last_seen >= STALE_THRESHOLD_SECS;
                }),
            peers.end()
        );

        // Upsert this peer
        auto it = std::find_if(peers.begin(), peers.end(),
            [&peer_id](const PeerEntry& p) { return p.peer_id == peer_id; });

        if (it != peers.end()) {
            it->addresses = std::move(addresses);
            it->last_seen = now;
        } else {
            if (peers.size() >= MAX_PEERS_PER_ROOM) {
                // Evict oldest
                auto oldest = std::min_element(peers.begin(), peers.end(),
                    [](const PeerEntry& a, const PeerEntry& b) {
                        return a.last_seen < b.last_seen;
                    });
                if (oldest != peers.end()) peers.erase(oldest);
            }
            peers.push_back({peer_id, std::move(addresses), now});
        }

        size_t count = peers.size();
        json_response(res, {{"ok", true}, {"peers_in_room", count}});
    });
    res->onAborted([]() {});
}

static void handle_unregister(HttpResponse* res, HttpRequest* /*req*/, RelayState& state) {
    std::string buffer;
    res->onData([res, &state, buffer = std::move(buffer)](
        std::string_view data, bool last) mutable {
        buffer.append(data);
        if (!last) return;

        json j;
        try { j = json::parse(buffer); }
        catch (...) { json_error(res, "Invalid JSON"); return; }

        std::string room_code = j.value("room_code", "");
        std::string peer_id = j.value("peer_id", "");
        uint64_t timestamp = j.value("timestamp", uint64_t(0));
        std::string public_key = j.value("public_key", "");
        std::string signature = j.value("signature", "");

        if (room_code.empty() || room_code.size() > 64) {
            json_error(res, "Invalid room_code"); return;
        }
        if (peer_id.empty() || public_key.empty() || signature.empty()) {
            json_error(res, "Missing required fields"); return;
        }

        uint64_t now = now_unix_secs();
        uint64_t diff = (now > timestamp) ? (now - timestamp) : (timestamp - now);
        if (diff > TIMESTAMP_SKEW_SECS) {
            json_error(res, "Timestamp too far from server time", "403 Forbidden"); return;
        }

        std::string signed_message = "hollow-unregister:" + room_code + ":" +
            peer_id + ":" + std::to_string(timestamp);

        if (!verify_ed25519(public_key, signature, signed_message)) {
            json_error(res, "Invalid signature", "403 Forbidden"); return;
        }

        auto it = state.signaling_rooms.find(room_code);
        if (it != state.signaling_rooms.end()) {
            auto& peers = it->second;
            peers.erase(
                std::remove_if(peers.begin(), peers.end(),
                    [&peer_id](const PeerEntry& p) { return p.peer_id == peer_id; }),
                peers.end()
            );
            if (peers.empty()) {
                state.signaling_rooms.erase(it);
            }
        }

        json_response(res, {{"ok", true}});
    });
    res->onAborted([]() {});
}

static void handle_bootstrap(HttpResponse* res, HttpRequest* req, RelayState& state) {
    std::string room_code(req->getParameter("room_code"));

    cors_headers(res);

    if (room_code.empty() || room_code.size() > 64) {
        res->writeStatus("400 Bad Request");
        res->end(json({{"error", "Invalid room code"}}).dump());
        return;
    }

    auto it = state.signaling_rooms.find(room_code);
    if (it == state.signaling_rooms.end()) {
        res->end(json({{"peers", json::array()}}).dump());
        return;
    }

    uint64_t now = now_unix_secs();
    json peers_arr = json::array();
    size_t count = 0;
    for (auto& p : it->second) {
        if (count >= MAX_BOOTSTRAP_PEERS) break;
        if (now - p.last_seen < STALE_THRESHOLD_SECS) {
            peers_arr.push_back({{"peer_id", p.peer_id}, {"addresses", p.addresses}});
            count++;
        }
    }

    res->end(json({{"peers", peers_arr}}).dump());
}

static void handle_health(HttpResponse* res) {
    cors_headers(res);
    res->end(R"({"status":"ok","service":"hollow-signaling"})");
}

static void handle_turn_credentials(HttpResponse* res, const Config& config) {
    cors_headers(res);

    if (config.turn_secret.empty()) {
        res->writeStatus("503 Service Unavailable");
        res->end(json({{"error", "TURN not configured"}}).dump());
        return;
    }

    uint64_t ttl = 3600;
    uint64_t expiry = now_unix_secs() + ttl;
    std::string username = std::to_string(expiry) + ":hollow";
    std::string password = hmac_sha1_base64(config.turn_secret, username);

    json resp = {
        {"username", username},
        {"password", password},
        {"ttl", ttl},
        {"uris", {
            "turn:relay.anonlisten.com:3478",
            "turn:relay.anonlisten.com:3478?transport=tcp",
            "turns:relay.anonlisten.com:5349"
        }}
    };
    res->end(resp.dump());
}

static void handle_server_stats(HttpResponse* res, RelayState& state) {
    cors_headers(res);

    if (state.stats_cache.has_prev && state.stats_cache.is_fresh()) {
        res->end(state.stats_cache.cached_json);
        return;
    }

    uint64_t mem_total_kb = 0, mem_available_kb = 0;
    {
        std::ifstream f("/proc/meminfo");
        if (f.is_open()) {
            std::string line;
            while (std::getline(f, line)) {
                if (line.compare(0, 9, "MemTotal:") == 0) {
                    std::istringstream iss(line);
                    std::string label; uint64_t val;
                    iss >> label >> val;
                    mem_total_kb = val;
                } else if (line.compare(0, 13, "MemAvailable:") == 0) {
                    std::istringstream iss(line);
                    std::string label; uint64_t val;
                    iss >> label >> val;
                    mem_available_kb = val;
                }
            }
        }
    }

    uint64_t rx_bytes = 0, tx_bytes = 0;
    {
        std::ifstream f("/proc/net/dev");
        if (f.is_open()) {
            std::string line;
            while (std::getline(f, line)) {
                // Trim leading whitespace
                size_t start = line.find_first_not_of(" \t");
                if (start == std::string::npos) continue;
                std::string trimmed = line.substr(start);
                if (trimmed.compare(0, 6, "ens16:") == 0) {
                    std::istringstream iss(trimmed.substr(6));
                    uint64_t vals[10];
                    for (int i = 0; i < 10; i++) iss >> vals[i];
                    rx_bytes = vals[0];
                    tx_bytes = vals[8];
                }
            }
        }
    }

    auto now = std::chrono::steady_clock::now();
    double rx_mbps = 0.0, tx_mbps = 0.0;
    if (state.stats_cache.has_prev) {
        double elapsed = std::chrono::duration<double>(
            now - state.stats_cache.prev_sample_at).count();
        if (elapsed > 0.5) {
            double rx_delta = static_cast<double>(
                rx_bytes > state.stats_cache.prev_rx_bytes
                    ? rx_bytes - state.stats_cache.prev_rx_bytes : 0);
            double tx_delta = static_cast<double>(
                tx_bytes > state.stats_cache.prev_tx_bytes
                    ? tx_bytes - state.stats_cache.prev_tx_bytes : 0);
            rx_mbps = (rx_delta * 8.0) / (elapsed * 1000000.0);
            tx_mbps = (tx_delta * 8.0) / (elapsed * 1000000.0);
        } else {
            rx_mbps = state.stats_cache.rx_mbps;
            tx_mbps = state.stats_cache.tx_mbps;
        }
    }

    uint64_t mem_used_kb = (mem_total_kb > mem_available_kb)
        ? mem_total_kb - mem_available_kb : 0;

    auto round2 = [](double v) { return std::round(v * 100.0) / 100.0; };

    json resp = {
        {"mem_total_kb", mem_total_kb},
        {"mem_used_kb", mem_used_kb},
        {"rx_mbps", round2(rx_mbps)},
        {"tx_mbps", round2(tx_mbps)},
        {"bandwidth_cap_mbps", 400},
        {"online_users", state.online_users()}
    };

    state.stats_cache.cached_json = resp.dump();
    state.stats_cache.fetched_at = now;
    state.stats_cache.prev_rx_bytes = rx_bytes;
    state.stats_cache.prev_tx_bytes = tx_bytes;
    state.stats_cache.prev_sample_at = now;
    state.stats_cache.rx_mbps = rx_mbps;
    state.stats_cache.tx_mbps = tx_mbps;
    state.stats_cache.has_prev = true;

    res->end(state.stats_cache.cached_json);
}

static void handle_relay_status(HttpResponse* res, RelayState& state) {
    cors_headers(res);
    json resp = {
        {"license_required", state.license.enabled},
        {"version", "0.1.0"}
    };
    res->end(resp.dump());
}

void setup_http_handlers(uWS::SSLApp& app, RelayState& state, const Config& config) {
    app.options("/*", [](HttpResponse* res, HttpRequest* /*req*/) {
        res->writeHeader("Access-Control-Allow-Origin", "*");
        res->writeHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        res->writeHeader("Access-Control-Allow-Headers", "Content-Type");
        res->end();
    });

    app.post("/register", [&state](HttpResponse* res, HttpRequest* req) {
        handle_register(res, req, state);
    });

    app.post("/unregister", [&state](HttpResponse* res, HttpRequest* req) {
        handle_unregister(res, req, state);
    });

    app.get("/bootstrap/:room_code", [&state](HttpResponse* res, HttpRequest* req) {
        handle_bootstrap(res, req, state);
    });

    app.get("/health", [](HttpResponse* res, HttpRequest* /*req*/) {
        handle_health(res);
    });

    app.get("/turn-credentials", [&config](HttpResponse* res, HttpRequest* /*req*/) {
        handle_turn_credentials(res, config);
    });

    app.get("/server-stats", [&state](HttpResponse* res, HttpRequest* /*req*/) {
        handle_server_stats(res, state);
    });

    app.get("/relay-status", [&state](HttpResponse* res, HttpRequest* /*req*/) {
        handle_relay_status(res, state);
    });
}
