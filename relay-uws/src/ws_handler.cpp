#include "ws_handler.h"
#include "crypto.h"
#include "json.hpp"
#include <cstdio>
#include <cstring>

using json = nlohmann::json;

static constexpr uint64_t TIMESTAMP_SKEW_SECS = 60;
static constexpr size_t MAX_ROOMS_PER_PEER = 100;

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
    if (ws->getBufferedAmount() < MAX_BACKPRESSURE_SOFT) {
        ws->send(data, op);
    }
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

    if (data->auth_timer) {
        us_timer_close(data->auth_timer);
        data->auth_timer = nullptr;
    }

    state.peer_rooms[peer_id] = {};
    state.peer_sockets[peer_id] = ws;

    send_json(ws, {{"type", "auth_ok"}});
    fprintf(stderr, "[ws] Authenticated: %s\n", peer_id.c_str());
}

static void handle_join(SSLWebSocket* ws, PerSocketData* data,
                         const std::string& room, RelayState& state) {
    if (!is_valid_room_code(room)) {
        send_json(ws, {{"type", "error"}, {"error", "Invalid room code"}});
        return;
    }

    auto pit = state.peer_rooms.find(data->peer_id);
    if (pit != state.peer_rooms.end() && pit->second.size() >= MAX_ROOMS_PER_PEER) {
        send_json(ws, {{"type", "error"}, {"error", "Too many rooms"}});
        return;
    }

    // Collect existing peer IDs before adding
    std::vector<std::string> existing_peers;
    auto& ws_room = state.ws_rooms[room];
    for (auto& [pid, _] : ws_room.peers) {
        existing_peers.push_back(pid);
    }

    // Add peer to room
    ws_room.peers[data->peer_id] = ws;

    // Track room on peer
    state.peer_rooms[data->peer_id].insert(room);

    // Send member list to joiner (including self)
    std::vector<std::string> all_peers = existing_peers;
    all_peers.push_back(data->peer_id);
    json members_msg = {
        {"type", "members"},
        {"room", room},
        {"peers", all_peers}
    };
    send_json(ws, members_msg);

    // Notify existing peers
    json join_msg = {
        {"type", "peer_joined"},
        {"room", room},
        {"peer_id", data->peer_id}
    };
    std::string join_str = join_msg.dump();
    for (auto& [pid, peer_ws] : ws_room.peers) {
        if (pid != data->peer_id) {
            send_to_peer(peer_ws, join_str, uWS::OpCode::TEXT);
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

    if (should_notify) {
        json leave_msg = {
            {"type", "peer_left"},
            {"room", room},
            {"peer_id", peer_id}
        };
        std::string leave_str = leave_msg.dump();
        auto rit2 = state.ws_rooms.find(room);
        if (rit2 != state.ws_rooms.end()) {
            for (auto& [_, peer_ws] : rit2->second.peers) {
                send_to_peer(peer_ws, leave_str, uWS::OpCode::TEXT);
            }
        }
    }
}

static void handle_msg(PerSocketData* data, const std::string& room,
                        const std::string& msg_data, RelayState& state) {
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return;

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) {
        fprintf(stderr, "[ws] Msg from %s to room they haven't joined — dropping\n",
                data->peer_id.c_str());
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
        fprintf(stderr, "[ws] Direct from %s to room they haven't joined — dropping\n",
                data->peer_id.c_str());
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
    }
}

static bool check_rate_limit(PerSocketData* data) {
    auto now = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(now - data->rate_last_refill).count();
    uint32_t refill = static_cast<uint32_t>(elapsed * 20.0);
    if (refill > 0) {
        data->binary_rate_tokens = std::min(data->binary_rate_tokens + refill, 100u);
        data->rate_last_refill = now;
    }
    if (data->binary_rate_tokens == 0) return false;
    data->binary_rate_tokens--;
    return true;
}

static void cleanup_peer(RelayState& state, const std::string& peer_id) {
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
        .maxPayloadLength = 10 * 1024 * 1024,
        .idleTimeout = 120,
        .maxBackpressure = 256 * 1024,
        .sendPingsAutomatically = true,

        .open = [&state](SSLWebSocket* ws) {
            auto* data = ws->getUserData();
            data->rate_last_refill = std::chrono::steady_clock::now();

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
                handle_text_message(ws, data, message, state);
            } else if (opCode == uWS::OpCode::BINARY) {
                if (!check_rate_limit(data)) return;
                if (message.size() > 1) {
                    switch (static_cast<uint8_t>(message[0])) {
                        case 0x01:
                            handle_binary_broadcast(data, message, state);
                            break;
                        case 0x02:
                            handle_binary_direct(data, message, state);
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
            if (data->auth_timer) {
                us_timer_close(data->auth_timer);
                data->auth_timer = nullptr;
            }
            if (data->authenticated) {
                fprintf(stderr, "[ws] Disconnected: %s\n", data->peer_id.c_str());
                cleanup_peer(state, data->peer_id);
            }
        }
    });
}
