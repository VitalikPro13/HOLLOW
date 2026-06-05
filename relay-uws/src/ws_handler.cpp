#include "ws_handler.h"
#include "crypto.h"
#include "json.hpp"
#include <cstdio>
#include <cstring>

using json = nlohmann::json;

static constexpr uint64_t TIMESTAMP_SKEW_SECS = 60;
static constexpr size_t MAX_ROOMS_PER_PEER = 10000;

static bool is_guest_peer(const RelayState& state, const std::string& peer_id) {
    auto it = state.peer_sockets.find(peer_id);
    if (it == state.peer_sockets.end()) return false;
    return it->second->getUserData()->is_guest;
}

static bool is_valid_nickname(std::string_view nick) {
    if (nick.size() < 3 || nick.size() > 20) return false;
    for (char c : nick) {
        if (!std::islower(static_cast<unsigned char>(c)) &&
            !std::isdigit(static_cast<unsigned char>(c)) && c != '_') {
            return false;
        }
    }
    return true;
}

static std::string to_lowercase(std::string_view s) {
    std::string result(s);
    for (char& c : result) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return result;
}

static bool is_valid_room_code(std::string_view room) {
    if (room.empty() || room.size() > 128) return false;
    for (char c : room) {
        if (!std::isalnum(static_cast<unsigned char>(c)) &&
            c != ':' && c != '-' && c != '_' && c != '.') {
            return false;
        }
    }
    return true;
}

static void send_json(SSLWebSocket* ws, const json& j) {
    std::string s = j.dump();
    ws->send(s, uWS::OpCode::TEXT);
}

static void send_to_peer(SSLWebSocket* ws, std::string_view data, uWS::OpCode op) {
    ws->send(data, op);
}

static void handle_auth(SSLWebSocket* ws, PerSocketData* data,
                         std::string_view message, RelayState& state) {
    json j;
    try {
        j = json::parse(message);
    } catch (...) {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }

    if (!j.contains("type") || j["type"] != "auth") {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }

    std::string peer_id = j.value("peer_id", "");
    std::string public_key = j.value("public_key", "");
    uint64_t timestamp = j.value("timestamp", uint64_t(0));
    std::string signature = j.value("signature", "");
    std::string license_key_val = j.value("license_key", "");
    const std::string* license_key_ptr = license_key_val.empty() ? nullptr : &license_key_val;
    bool guest = j.value("guest", false);

    if (peer_id.empty() || public_key.empty() || signature.empty()) {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }

    uint64_t now = now_unix_secs();
    uint64_t diff = (now > timestamp) ? (now - timestamp) : (timestamp - now);
    if (diff > TIMESTAMP_SKEW_SECS) {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }

    std::string signed_msg = "hollow-ws-auth:" + peer_id + ":" + std::to_string(timestamp);
    if (!verify_ed25519(public_key, signature, signed_msg)) {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }

    LicenseResult lr = state.license.validate_key(license_key_ptr, peer_id);
    switch (lr) {
        case LicenseResult::Ok:
        case LicenseResult::NotRequired:
            break;
        case LicenseResult::InvalidKey:
            send_json(ws, {{"type", "auth_failed"}, {"error", "invalid_license_key"}});
            ws->end(1008, "bad_license");
            return;
        case LicenseResult::KeyInUse:
            send_json(ws, {{"type", "auth_failed"}, {"error", "license_key_in_use"}});
            ws->end(1008, "bad_license");
            return;
        case LicenseResult::KeyRequired:
            send_json(ws, {{"type", "auth_failed"}, {"error", "license_key_required"}});
            ws->end(1008, "bad_license");
            return;
    }

    // Auth succeeded
    data->peer_id = peer_id;
    data->authenticated = true;
    data->license_key = license_key_val;

    if (guest) {
        data->is_guest = true;
        auto now = std::chrono::steady_clock::now();
        data->last_binary_activity = now;
        data->minute_window_start = now;
        state.guest_count++;
        state.guest_sockets.insert(ws);
    }

    if (data->auth_timer) {
        us_timer_close(data->auth_timer);
        data->auth_timer = nullptr;
    }

    state.peer_rooms[peer_id] = {};
    state.peer_sockets[peer_id] = ws;

    send_json(ws, {{"type", "auth_ok"}});
    // privacy: no connection logging
}

static void handle_join(SSLWebSocket* ws, PerSocketData* data,
                         const std::string& room, RelayState& state) {
    if (!is_valid_room_code(room)) {
        send_json(ws, {{"type", "error"}, {"error", "Invalid room code"}});
        return;
    }

    auto pit = state.peer_rooms.find(data->peer_id);
    size_t max_rooms = data->is_guest ? MAX_GUEST_ROOMS : MAX_ROOMS_PER_PEER;
    if (pit != state.peer_rooms.end() && pit->second.size() >= max_rooms) {
        send_json(ws, {{"type", "error"}, {"error", data->is_guest ? "Guest room limit reached" : "Too many rooms"}});
        return;
    }

    // Collect existing non-guest peer IDs before adding
    std::vector<std::string> existing_peers;
    auto& ws_room = state.ws_rooms[room];
    for (auto& [pid, peer_ws] : ws_room.peers) {
        if (!peer_ws->getUserData()->is_guest) {
            existing_peers.push_back(pid);
        }
    }

    // Add peer to room
    ws_room.peers[data->peer_id] = ws;

    // Track room on peer
    state.peer_rooms[data->peer_id].insert(room);

    // Send member list to joiner (excluding guests)
    std::vector<std::string> all_peers = existing_peers;
    if (!data->is_guest) {
        all_peers.push_back(data->peer_id);
    }
    json members_msg = {
        {"type", "members"},
        {"room", room},
        {"peers", all_peers}
    };
    send_json(ws, members_msg);

    // Notify existing non-guest peers (skip if joiner is a guest)
    if (!data->is_guest) {
        json join_msg = {
            {"type", "peer_joined"},
            {"room", room},
            {"peer_id", data->peer_id}
        };
        std::string join_str = join_msg.dump();
        for (auto& [pid, peer_ws] : ws_room.peers) {
            if (pid != data->peer_id && !peer_ws->getUserData()->is_guest) {
                send_to_peer(peer_ws, join_str, uWS::OpCode::TEXT);
            }
        }
    }
}

static void leave_room(RelayState& state, const std::string& peer_id,
                        const std::string& room) {
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return;

    rit->second.peers.erase(peer_id);

    bool should_notify = !rit->second.peers.empty();

    if (!should_notify) {
        state.ws_rooms.erase(rit);
    }

    auto pit = state.peer_rooms.find(peer_id);
    if (pit != state.peer_rooms.end()) {
        pit->second.erase(room);
    }

    bool leaving_peer_is_guest = is_guest_peer(state, peer_id);
    if (should_notify && !leaving_peer_is_guest) {
        json leave_msg = {
            {"type", "peer_left"},
            {"room", room},
            {"peer_id", peer_id}
        };
        std::string leave_str = leave_msg.dump();
        auto rit2 = state.ws_rooms.find(room);
        if (rit2 != state.ws_rooms.end()) {
            for (auto& [_, peer_ws] : rit2->second.peers) {
                if (!peer_ws->getUserData()->is_guest) {
                    send_to_peer(peer_ws, leave_str, uWS::OpCode::TEXT);
                }
            }
        }
    }
}

static void handle_msg(PerSocketData* data, const std::string& room,
                        const std::string& msg_data, RelayState& state) {
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return;

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) {
        // privacy: no connection logging
        return;
    }

    json broadcast = {
        {"type", "msg"},
        {"room", room},
        {"from", data->peer_id},
        {"data", msg_data}
    };
    std::string broadcast_str = broadcast.dump();
    for (auto& [pid, peer_ws] : rit->second.peers) {
        if (pid != data->peer_id) {
            send_to_peer(peer_ws, broadcast_str, uWS::OpCode::TEXT);
        }
    }
}

static void handle_direct(PerSocketData* data, const std::string& room,
                           const std::string& target, const std::string& msg_data,
                           RelayState& state) {
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return;

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) {
        // privacy: no connection logging
        return;
    }

    auto tit = rit->second.peers.find(target);
    if (tit == rit->second.peers.end()) return;

    json direct = {
        {"type", "direct"},
        {"room", room},
        {"from", data->peer_id},
        {"data", msg_data}
    };
    std::string direct_str = direct.dump();
    send_to_peer(tit->second, direct_str, uWS::OpCode::TEXT);
}

static void handle_binary_broadcast(PerSocketData* data,
                                     std::string_view raw, RelayState& state) {
    if (raw.size() <= 33) return;

    std::string room_hex = hex_encode(
        reinterpret_cast<const uint8_t*>(raw.data() + 1), 32);

    auto rit = state.ws_rooms.find(room_hex);
    if (rit == state.ws_rooms.end()) return;

    for (auto& [pid, peer_ws] : rit->second.peers) {
        if (pid != data->peer_id) {
            send_to_peer(peer_ws, raw, uWS::OpCode::BINARY);
        }
    }
}

static void handle_binary_direct(PerSocketData* data,
                                  std::string_view raw, RelayState& state) {
    // Parse: [0x02][room\0][target\0][payload]
    if (raw.size() < 4) return;

    size_t room_start = 1;
    auto room_nul_pos = raw.find('\0', room_start);
    if (room_nul_pos == std::string_view::npos) return;

    std::string_view room_code = raw.substr(room_start, room_nul_pos - room_start);

    size_t peer_start = room_nul_pos + 1;
    if (peer_start >= raw.size()) return;

    auto peer_nul_pos = raw.find('\0', peer_start);
    if (peer_nul_pos == std::string_view::npos) return;

    std::string_view target_peer = raw.substr(peer_start, peer_nul_pos - peer_start);

    size_t payload_start = peer_nul_pos + 1;
    if (payload_start >= raw.size()) return;

    std::string_view payload = raw.substr(payload_start);

    // Build forwarded frame: replace target with sender
    std::string forwarded;
    forwarded.reserve(1 + room_code.size() + 1 + data->peer_id.size() + 1 + payload.size());
    forwarded.push_back(0x02);
    forwarded.append(room_code);
    forwarded.push_back(0x00);
    forwarded.append(data->peer_id);
    forwarded.push_back(0x00);
    forwarded.append(payload);

    std::string room_str(room_code);
    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) return;

    std::string target_str(target_peer);
    auto tit = rit->second.peers.find(target_str);
    if (tit == rit->second.peers.end()) return;

    send_to_peer(tit->second, forwarded, uWS::OpCode::BINARY);
}

static void handle_binary_msg(PerSocketData* data,
                               std::string_view raw, RelayState& state) {
    // Parse: [0x03][room\0][payload]
    if (raw.size() < 3) return;

    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return;

    std::string_view room_code = raw.substr(1, room_nul - 1);
    std::string room_str(room_code);

    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) return;

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;

    size_t payload_start = room_nul + 1;
    std::string_view payload = (payload_start < raw.size())
        ? raw.substr(payload_start) : std::string_view{};

    // Build: [0x05][room\0][sender\0][payload]
    std::string forwarded;
    forwarded.reserve(1 + room_code.size() + 1 + data->peer_id.size() + 1 + payload.size());
    forwarded.push_back(0x05);
    forwarded.append(room_code);
    forwarded.push_back(0x00);
    forwarded.append(data->peer_id);
    forwarded.push_back(0x00);
    forwarded.append(payload);

    for (auto& [pid, peer_ws] : rit->second.peers) {
        if (pid != data->peer_id) {
            send_to_peer(peer_ws, forwarded, uWS::OpCode::BINARY);
        }
    }
}

static void handle_binary_direct_msg(PerSocketData* data,
                                      std::string_view raw, RelayState& state) {
    // Parse: [0x04][room\0][target\0][payload]
    if (raw.size() < 5) return;

    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return;

    std::string_view room_code = raw.substr(1, room_nul - 1);

    size_t peer_start = room_nul + 1;
    if (peer_start >= raw.size()) return;

    auto peer_nul = raw.find('\0', peer_start);
    if (peer_nul == std::string_view::npos) return;

    std::string_view target_peer = raw.substr(peer_start, peer_nul - peer_start);

    size_t payload_start = peer_nul + 1;
    std::string_view payload = (payload_start < raw.size())
        ? raw.substr(payload_start) : std::string_view{};

    std::string room_str(room_code);
    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) return;

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;

    std::string target_str(target_peer);
    auto tit = rit->second.peers.find(target_str);
    if (tit == rit->second.peers.end()) return;

    // Build: [0x06][room\0][sender\0][payload]
    std::string forwarded;
    forwarded.reserve(1 + room_code.size() + 1 + data->peer_id.size() + 1 + payload.size());
    forwarded.push_back(0x06);
    forwarded.append(room_code);
    forwarded.push_back(0x00);
    forwarded.append(data->peer_id);
    forwarded.push_back(0x00);
    forwarded.append(payload);

    send_to_peer(tit->second, forwarded, uWS::OpCode::BINARY);
}

static void handle_subscribe(PerSocketData* data, const std::string& room,
                              const json& topics_arr) {
    if (!data->authenticated) return;
    if (topics_arr.empty()) {
        data->subscriptions.erase(room);
    } else {
        auto& subs = data->subscriptions[room];
        subs.clear();
        for (const auto& t : topics_arr) {
            if (t.is_string()) subs.insert(t.get<std::string>());
        }
    }
}

static void handle_binary_topic_msg(PerSocketData* data,
                                     std::string_view raw, RelayState& state) {
    // Parse: [0x07][room\0][topic\0][payload]
    if (raw.size() < 4) return;

    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return;

    std::string_view room_code = raw.substr(1, room_nul - 1);
    std::string room_str(room_code);

    size_t topic_start = room_nul + 1;
    if (topic_start >= raw.size()) return;

    auto topic_nul = raw.find('\0', topic_start);
    if (topic_nul == std::string_view::npos) return;

    std::string_view topic = raw.substr(topic_start, topic_nul - topic_start);
    std::string topic_str(topic);

    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) return;

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;

    size_t payload_start = topic_nul + 1;
    std::string_view payload = (payload_start < raw.size())
        ? raw.substr(payload_start) : std::string_view{};

    // Build: [0x08][room\0][topic\0][sender\0][payload]
    std::string forwarded;
    forwarded.reserve(1 + room_code.size() + 1 + topic.size() + 1 + data->peer_id.size() + 1 + payload.size());
    forwarded.push_back(0x08);
    forwarded.append(room_code);
    forwarded.push_back(0x00);
    forwarded.append(topic);
    forwarded.push_back(0x00);
    forwarded.append(data->peer_id);
    forwarded.push_back(0x00);
    forwarded.append(payload);

    for (auto& [pid, peer_ws] : rit->second.peers) {
        if (pid == data->peer_id) continue;

        auto* peer_data = peer_ws->getUserData();
        auto sit = peer_data->subscriptions.find(room_str);
        if (sit == peer_data->subscriptions.end()) {
            // No subscriptions for this room — wildcard, send everything
            send_to_peer(peer_ws, forwarded, uWS::OpCode::BINARY);
        } else if (sit->second.count(topic_str)) {
            // Peer is subscribed to this topic
            send_to_peer(peer_ws, forwarded, uWS::OpCode::BINARY);
        }
    }
}

static void handle_claim_nickname(SSLWebSocket* ws, PerSocketData* data,
                                   const std::string& raw_nick, RelayState& state) {
    if (data->is_guest) return;

    std::string nickname = to_lowercase(raw_nick);
    if (!is_valid_nickname(nickname)) {
        send_json(ws, {{"type", "nickname_error"}, {"error", "invalid"}});
        return;
    }

    // Auto-release old nickname if peer already has one
    auto old = state.peer_to_nickname.find(data->peer_id);
    if (old != state.peer_to_nickname.end()) {
        state.nickname_to_peer.erase(old->second);
        state.peer_to_nickname.erase(old);
    }

    // Check availability
    if (state.nickname_to_peer.count(nickname)) {
        send_json(ws, {{"type", "nickname_error"}, {"error", "taken"}});
        return;
    }

    state.nickname_to_peer[nickname] = data->peer_id;
    state.peer_to_nickname[data->peer_id] = nickname;
    send_json(ws, {{"type", "nickname_claimed"}, {"nickname", nickname}});
}

static void handle_release_nickname(SSLWebSocket* ws, PerSocketData* data,
                                     RelayState& state) {
    auto it = state.peer_to_nickname.find(data->peer_id);
    if (it != state.peer_to_nickname.end()) {
        state.nickname_to_peer.erase(it->second);
        state.peer_to_nickname.erase(it);
    }
    send_json(ws, {{"type", "nickname_released"}});
}

static void handle_resolve_nickname(SSLWebSocket* ws, PerSocketData* /*data*/,
                                     const std::string& raw_nick, RelayState& state) {
    std::string nickname = to_lowercase(raw_nick);
    auto it = state.nickname_to_peer.find(nickname);
    if (it != state.nickname_to_peer.end()) {
        send_json(ws, {{"type", "nickname_resolved"}, {"nickname", nickname}, {"peer_id", it->second}});
    } else {
        send_json(ws, {{"type", "nickname_error"}, {"error", "not_found"}, {"nickname", nickname}});
    }
}

static void handle_text_message(SSLWebSocket* ws, PerSocketData* data,
                                 std::string_view message, RelayState& state) {
    json j;
    try {
        j = json::parse(message);
    } catch (...) {
        return;
    }

    std::string type = j.value("type", "");

    if (type == "join") {
        handle_join(ws, data, j.value("room", ""), state);
    } else if (type == "leave") {
        leave_room(state, data->peer_id, j.value("room", ""));
    } else if (type == "msg") {
        handle_msg(data, j.value("room", ""), j.value("data", ""), state);
    } else if (type == "direct") {
        handle_direct(data, j.value("room", ""), j.value("target", ""),
                      j.value("data", ""), state);
    } else if (type == "check_peers") {
        // Lightweight liveness check: client sends peer IDs + room IDs,
        // relay returns which peers are connected and which rooms are populated.
        json online_peers = json::array();
        json active_rooms = json::array();
        if (j.contains("peers") && j["peers"].is_array()) {
            for (auto& pid : j["peers"]) {
                if (pid.is_string()) {
                    const std::string& peer_id = pid.get_ref<const std::string&>();
                    if (state.peer_sockets.count(peer_id)) {
                        online_peers.push_back(peer_id);
                    }
                }
            }
        }
        if (j.contains("rooms") && j["rooms"].is_array()) {
            for (auto& rid : j["rooms"]) {
                if (rid.is_string()) {
                    const std::string& room_id = rid.get_ref<const std::string&>();
                    auto rit = state.ws_rooms.find(room_id);
                    if (rit != state.ws_rooms.end() && !rit->second.peers.empty()) {
                        active_rooms.push_back(room_id);
                    }
                }
            }
        }
        send_json(ws, {{"type", "peer_status"}, {"online", online_peers}, {"active_rooms", active_rooms}});
    } else if (type == "subscribe") {
        handle_subscribe(data, j.value("room", ""),
                         j.contains("topics") ? j["topics"] : json::array());
    } else if (type == "claim_nickname") {
        handle_claim_nickname(ws, data, j.value("nickname", ""), state);
    } else if (type == "release_nickname") {
        handle_release_nickname(ws, data, state);
    } else if (type == "resolve_nickname") {
        handle_resolve_nickname(ws, data, j.value("nickname", ""), state);
    }
}

// DoS protection: per-IP limits (34 conns, 10 new/min), guest rate limiting (10 binary/min),
// Ed25519 auth + license key revocation. IPs tracked in-memory only, never logged.


static void cleanup_peer(RelayState& state, const std::string& peer_id) {
    // Release temporary nickname
    auto nit = state.peer_to_nickname.find(peer_id);
    if (nit != state.peer_to_nickname.end()) {
        state.nickname_to_peer.erase(nit->second);
        state.peer_to_nickname.erase(nit);
    }

    state.license.release_key(peer_id);
    state.peer_sockets.erase(peer_id);

    auto pit = state.peer_rooms.find(peer_id);
    if (pit == state.peer_rooms.end()) return;

    // Copy the set since leave_room modifies it
    std::vector<std::string> rooms(pit->second.begin(), pit->second.end());
    for (auto& room : rooms) {
        leave_room(state, peer_id, room);
    }
    state.peer_rooms.erase(peer_id);
}

void setup_ws_handler(uWS::SSLApp& app, RelayState& state) {
    app.ws<PerSocketData>("/ws", {
        .compression = uWS::DISABLED,
        .maxPayloadLength = 64 * 1024 * 1024,
        .idleTimeout = 120,
        .maxBackpressure = 64 * 1024 * 1024,
        .sendPingsAutomatically = true,

        .open = [&state](SSLWebSocket* ws) {
            auto* data = ws->getUserData();

            // Per-IP connection limiting (in-memory only, never logged)
            std::string ip(ws->getRemoteAddressAsText());
            data->ip_key = ip;
            auto& ip_state = state.ip_states[ip];

            if (ip_state.active_count >= MAX_CONNS_PER_IP) {
                ws->end(1008, "ip_limit");
                return;
            }

            auto now = std::chrono::steady_clock::now();
            while (!ip_state.recent_connects.empty() &&
                   (now - ip_state.recent_connects.front()) > std::chrono::seconds(60)) {
                ip_state.recent_connects.pop_front();
            }
            if (ip_state.recent_connects.size() >= MAX_NEW_CONNS_PER_MIN_PER_IP) {
                ws->end(1008, "rate_limit");
                return;
            }

            ip_state.active_count++;
            ip_state.recent_connects.push_back(now);

            // 10-second auth timeout
            auto* loop = reinterpret_cast<struct us_loop_t*>(uWS::Loop::get());
            auto* timer = us_create_timer(loop, 0, sizeof(SSLWebSocket*));
            *reinterpret_cast<SSLWebSocket**>(us_timer_ext(timer)) = ws;
            data->auth_timer = timer;
            us_timer_set(timer, [](struct us_timer_t* t) {
                auto* target_ws = *reinterpret_cast<SSLWebSocket**>(us_timer_ext(t));
                auto* d = target_ws->getUserData();
                // Detach timer BEFORE end() — end() triggers close handler
                // which would double-free if auth_timer is still set
                d->auth_timer = nullptr;
                if (!d->authenticated) {
                    std::string err = R"({"type":"auth_failed","error":"Authentication failed"})";
                    target_ws->send(err, uWS::OpCode::TEXT);
                    target_ws->end(1008, "auth_timeout");
                }
                us_timer_close(t);
            }, 10000, 0);
        },

        .message = [&state](SSLWebSocket* ws, std::string_view message, uWS::OpCode opCode) {
            auto* data = ws->getUserData();

            if (!data->authenticated) {
                handle_auth(ws, data, message, state);
                return;
            }

            if (opCode == uWS::OpCode::TEXT) {
                if (message.size() > 1024 * 1024) return;
                handle_text_message(ws, data, message, state);
            } else if (opCode == uWS::OpCode::BINARY) {
                // 1-byte 0x00 = guest keepalive, don't process or count
                if (message.size() == 1 && static_cast<uint8_t>(message[0]) == 0x00) {
                    return;
                }
                if (message.size() > 1) {
                    uint8_t opcode = static_cast<uint8_t>(message[0]);

                    // Guest binary restrictions
                    if (data->is_guest) {
                        if (opcode == 0x04) return; // no SendDirect for guests
                        if (opcode == 0x03) {
                            auto now = std::chrono::steady_clock::now();
                            if ((now - data->minute_window_start) > std::chrono::seconds(60)) {
                                data->binary_frames_this_minute = 0;
                                data->minute_window_start = now;
                            }
                            if (data->binary_frames_this_minute >= GUEST_BINARY_PER_MIN) return;
                            data->binary_frames_this_minute++;
                            data->last_binary_activity = now;
                        }
                    }

                    switch (opcode) {
                        case 0x01:
                            handle_binary_broadcast(data, message, state);
                            break;
                        case 0x02:
                            handle_binary_direct(data, message, state);
                            break;
                        case 0x03:
                            handle_binary_msg(data, message, state);
                            break;
                        case 0x04:
                            handle_binary_direct_msg(data, message, state);
                            break;
                        case 0x07:
                            handle_binary_topic_msg(data, message, state);
                            break;
                        default:
                            break;
                    }
                }
            }
        },

        .drain = [](SSLWebSocket* /*ws*/) {},

        .close = [&state](SSLWebSocket* ws, int /*code*/, std::string_view /*reason*/) {
            auto* data = ws->getUserData();

            // IP tracking cleanup (in-memory only)
            if (!data->ip_key.empty()) {
                auto it = state.ip_states.find(data->ip_key);
                if (it != state.ip_states.end()) {
                    if (it->second.active_count > 0) it->second.active_count--;
                    if (it->second.active_count == 0) {
                        state.ip_states.erase(it);
                    }
                }
            }

            if (data->is_guest) {
                if (state.guest_count > 0) state.guest_count--;
                state.guest_sockets.erase(ws);
            }

            if (data->auth_timer) {
                us_timer_close(data->auth_timer);
                data->auth_timer = nullptr;
            }
            if (data->authenticated) {
                // privacy: no connection logging
                cleanup_peer(state, data->peer_id);
            }
        }
    });
}
