#include "ws_handler.h"
#include "crypto.h"
#include "json.hpp"
#include <cstdio>
#include <cstring>
#include <thread>
#include <mutex>
#include <condition_variable>
#include <deque>
#include <atomic>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

using json = nlohmann::json;

static constexpr uint64_t TIMESTAMP_SKEW_SECS = 60;
static constexpr size_t MAX_ROOMS_PER_PEER = 10000;
static constexpr int PUSH_SIDECAR_PORT = 3001;
static constexpr int PUSH_DEBOUNCE_SECS = 10;

static bool is_guest_peer(const RelayState& state, const std::string& peer_id) {
    auto it = state.peer_sockets.find(peer_id);
    if (it == state.peer_sockets.end()) return false;
    return it->second->getUserData()->is_guest;
}

// Check if a peer in a room is invisible (guest or fetch-mode).
// Looks up the room peers map since fetch-mode peers aren't in peer_sockets.
static bool is_invisible_in_room(const RelayState& state, const std::string& peer_id,
                                  const std::string& room) {
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return true;
    auto pit = rit->second.peers.find(peer_id);
    if (pit == rit->second.peers.end()) return true;
    auto* d = pit->second->getUserData();
    return d->is_guest || d->is_fetch;
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

// Forward declarations — offline buffer replay is used by handle_join (defined
// earlier than the buffer helpers).
static void replay_buffered_msgs(SSLWebSocket* ws, const std::string& peer_id,
                                 const std::string& room, bool full_node,
                                 RelayState& state);
// cleanup_peer is defined near the close handler but used by handle_auth's
// supersede path (evict a stale duplicate connection's room state).
static void cleanup_peer(RelayState& state, const std::string& peer_id,
                         SSLWebSocket* expected_ws);

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
    bool fetch = j.value("fetch", false);

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

    if (fetch) {
        data->is_fetch = true;
    }

    if (data->auth_timer) {
        us_timer_close(data->auth_timer);
        data->auth_timer = nullptr;
    }

    // Supersede a stale duplicate connection. A client that reconnects (mobile
    // resume, network blip, TLS re-handshake) opens a NEW socket while its old
    // TCP socket may still be half-open — the relay won't notice the dead socket
    // until the 120s idleTimeout fires. Without this, the old socket lingers in
    // peer_sockets + every room map; when it finally closes, cleanup_peer would
    // leave_room ALL of this peer's rooms and broadcast peer_left — evicting the
    // LIVE new socket from every room and telling friends the peer went offline
    // (the "Pixel left all rooms with no reconnect for ~14 min" churn). Fix: the
    // moment a newer socket authenticates for this peer_id, fully evict the old
    // one (its rooms + socket entry) and mark it superseded so its later close
    // is a no-op for the shared peer state. Only the genuinely live socket owns
    // the peer's presence. Fetch-mode peers never register in peer_sockets, so
    // they never supersede a full node (and vice-versa — full node wins).
    if (!data->is_fetch) {
        auto existing = state.peer_sockets.find(peer_id);
        if (existing != state.peer_sockets.end() && existing->second != ws) {
            SSLWebSocket* ghost = existing->second;
            ghost->getUserData()->superseded = true;
            // Evict the ghost's room memberships + socket entry. leave_room
            // broadcasts peer_left, but the new socket immediately re-joins
            // (WsEvent::Connected re-join loop), so friends get a fresh
            // peer_joined + members snapshot — net presence stays correct.
            cleanup_peer(state, peer_id, ghost);
            // Close the dead socket so it stops consuming a connection slot.
            ghost->end(1000, "superseded");
        }
        state.peer_sockets[peer_id] = ws;
    }
    state.peer_rooms[peer_id] = {};

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
        auto* pd = peer_ws->getUserData();
        if (!pd->is_guest && !pd->is_fetch) {
            existing_peers.push_back(pid);
        }
    }

    // Add peer to room
    ws_room.peers[data->peer_id] = ws;

    // Track room on peer
    state.peer_rooms[data->peer_id].insert(room);

    // Send member list to joiner (excluding guests and fetch-mode peers)
    std::vector<std::string> all_peers = existing_peers;
    if (!data->is_guest && !data->is_fetch) {
        all_peers.push_back(data->peer_id);
    }
    json members_msg = {
        {"type", "members"},
        {"room", room},
        {"peers", all_peers}
    };
    send_json(ws, members_msg);

    // Notify existing non-guest peers (skip if joiner is a guest or fetch-mode)
    if (!data->is_guest && !data->is_fetch) {
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

    // Full-app join: reset the channel-push offline cap for this room — the
    // app is (re)synced from here, so future offline bursts may push again.
    if (!data->is_guest && !data->is_fetch) {
        auto cit = state.channel_push_state.find(data->peer_id);
        if (cit != state.channel_push_state.end()) {
            cit->second.erase(room);
            if (cit->second.empty()) state.channel_push_state.erase(cit);
        }
    }

    // Replay any buffered offline messages for this peer in this room.
    // Works for both fetch-mode (FCM wake) and full-node joins. Guests never
    // have offline buffers (they don't register push tokens).
    if (!data->is_guest) {
        replay_buffered_msgs(ws, data->peer_id, room, !data->is_fetch, state);
    }
}

// Remove `peer_id` from `room`. If `expected_ws` is non-null, only erase the
// room slot when it currently points at that exact socket — this prevents a
// stale/superseded duplicate connection from erasing the LIVE socket's room
// membership (the room slot may have already been overwritten by the newer
// socket's re-join). Pass nullptr to force the erase (used by the supersede
// path, where the ghost IS the slot owner being evicted).
static void leave_room(RelayState& state, const std::string& peer_id,
                        const std::string& room,
                        SSLWebSocket* expected_ws = nullptr) {
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return;

    if (expected_ws != nullptr) {
        auto pit = rit->second.peers.find(peer_id);
        if (pit == rit->second.peers.end() || pit->second != expected_ws) {
            // The live socket already owns this room slot (or the peer isn't in
            // it). Do NOT erase or broadcast peer_left — the peer is still here.
            return;
        }
    }

    // Check visibility BEFORE erasing from room
    bool leaving_peer_invisible = is_invisible_in_room(state, peer_id, room);

    rit->second.peers.erase(peer_id);

    bool should_notify = !rit->second.peers.empty();

    if (!should_notify) {
        state.ws_rooms.erase(rit);
    }

    auto pit = state.peer_rooms.find(peer_id);
    if (pit != state.peer_rooms.end()) {
        pit->second.erase(room);
    }

    if (should_notify && !leaving_peer_invisible) {
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

// Push-sidecar notifier — a SINGLE persistent worker thread draining a queue,
// instead of spawning a detached std::thread per push. Per-push thread creation
// caused churn during DM/file-sync bursts (each push does a blocking connect/
// send/recv with 2s timeouts); a single worker serializes those off the event
// loop with no spawn overhead. The job is one blocking HTTP POST to localhost.
namespace {

struct PushJob {
    std::string token;
    std::string platform;
    std::string sender;
    // Channel pushes only (empty/false for DM pushes):
    std::string server;   // server room code
    std::string channel;  // channel_id
    bool mention = false;
};

// Cap the backlog so a wedged/slow sidecar can't grow the queue unbounded during
// a flood — drop oldest beyond this (push is best-effort; the DM still delivers).
constexpr size_t PUSH_QUEUE_MAX = 4096;

std::deque<PushJob> g_push_queue;
std::mutex g_push_mtx;
std::condition_variable g_push_cv;
std::atomic<bool> g_push_worker_started{false};

void deliver_push(const PushJob& job) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;

    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(PUSH_SIDECAR_PORT);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(fd);
        return;
    }

    json body = {{"token", job.token}, {"platform", job.platform}, {"sender", job.sender}};
    if (!job.server.empty()) {
        body["server"] = job.server;
        body["channel"] = job.channel;
        body["mention"] = job.mention;
    }
    std::string payload = body.dump();

    std::string req = "POST /push HTTP/1.1\r\n"
                      "Host: 127.0.0.1\r\n"
                      "Content-Type: application/json\r\n"
                      "Content-Length: " + std::to_string(payload.size()) + "\r\n"
                      "Connection: close\r\n\r\n" + payload;

    send(fd, req.data(), req.size(), MSG_NOSIGNAL);
    char buf[128];
    recv(fd, buf, sizeof(buf), 0);
    close(fd);
}

void push_worker_loop() {
    for (;;) {
        PushJob job;
        {
            std::unique_lock<std::mutex> lock(g_push_mtx);
            g_push_cv.wait(lock, [] { return !g_push_queue.empty(); });
            job = std::move(g_push_queue.front());
            g_push_queue.pop_front();
        }
        deliver_push(job);
    }
}

} // namespace

// Enqueue a push for the persistent worker (fire-and-forget, off the event loop).
static void notify_push_sidecar(PushJob job) {
    // Lazily start the single worker thread on first push.
    bool expected = false;
    if (g_push_worker_started.compare_exchange_strong(expected, true)) {
        std::thread(push_worker_loop).detach();
    }
    {
        std::lock_guard<std::mutex> lock(g_push_mtx);
        if (g_push_queue.size() >= PUSH_QUEUE_MAX) {
            g_push_queue.pop_front(); // drop oldest — push is best-effort
        }
        g_push_queue.push_back(std::move(job));
    }
    g_push_cv.notify_one();
}

static void notify_push_sidecar(const std::string& token, const std::string& platform,
                                 const std::string& sender) {
    notify_push_sidecar(PushJob{token, platform, sender, "", "", false});
}

// Build the 0x06 direct-message frame the receiver expects:
// [0x06][room\0][sender\0][payload]
static std::string build_direct_frame(std::string_view room,
                                       std::string_view sender,
                                       std::string_view payload) {
    std::string frame;
    frame.reserve(1 + room.size() + 1 + sender.size() + 1 + payload.size());
    frame.push_back(0x06);
    frame.append(room);
    frame.push_back(0x00);
    frame.append(sender);
    frame.push_back(0x00);
    frame.append(payload);
    return frame;
}

// Buffer an offline DM frame for later replay when the target joins its DM room.
// RAM only, ciphertext only. Capped per-peer (drop oldest on overflow).
static void buffer_offline_msg(const std::string& target_peer_id,
                               const std::string& room,
                               std::string frame, RelayState& state,
                               bool is_image = false, bool is_channel = false) {
    auto& q = state.offline_buffer[target_peer_id];
    q.push_back({room, std::move(frame), std::chrono::steady_clock::now(), is_image, is_channel});
    // Three independent caps: DM text, inlined-image and channel frames evict
    // separately so a chatty server never pushes out buffered DMs (and
    // vice-versa).
    auto count_kind = [&](bool img, bool chan) {
        size_t n = 0;
        for (const auto& m : q) if (m.is_image == img && m.is_channel == chan) n++;
        return n;
    };
    auto drop_oldest_kind = [&](bool img, bool chan) {
        for (auto it = q.begin(); it != q.end(); ++it) {
            if (it->is_image == img && it->is_channel == chan) { q.erase(it); return; }
        }
    };
    while (count_kind(false, false) > MAX_BUFFERED_MSGS_PER_PEER)          drop_oldest_kind(false, false);
    while (count_kind(true, false)  > MAX_BUFFERED_IMAGES_PER_PEER)        drop_oldest_kind(true, false);
    while (count_kind(false, true)  > MAX_BUFFERED_CHANNEL_MSGS_PER_PEER)  drop_oldest_kind(false, true);
    // No per-message logging — the relay must not record who buffers what for whom
    // (peer_id + room = social-graph metadata). Privacy-preserving by design.
}

// Replay any buffered messages for `peer_id` that belong to `room`, sending
// them to `ws`. Delivered entries are removed. If `full_node` is true, ALL
// buffered messages for the peer in this room are dropped afterwards regardless
// (the full node will own durability via DM-sync from here on).
static void replay_buffered_msgs(SSLWebSocket* ws, const std::string& peer_id,
                                 const std::string& room, bool full_node,
                                 RelayState& state) {
    auto it = state.offline_buffer.find(peer_id);
    if (it == state.offline_buffer.end()) return;

    auto& q = it->second;
    std::deque<RelayState::BufferedMsg> remaining;
    size_t delivered = 0;
    for (auto& m : q) {
        if (m.room == room) {
            send_to_peer(ws, m.frame, uWS::OpCode::BINARY);
            delivered++;
        } else {
            remaining.push_back(std::move(m));
        }
    }
    q = std::move(remaining);
    if (q.empty()) {
        state.offline_buffer.erase(it);
    }
    (void)delivered;
    (void)full_node;
}

// Evict offline-buffer entries older than the TTL. Drops empty per-peer queues.
void sweep_offline_buffer(RelayState& state) {
    auto now = std::chrono::steady_clock::now();
    size_t evicted = 0;
    for (auto it = state.offline_buffer.begin(); it != state.offline_buffer.end(); ) {
        auto& q = it->second;
        while (!q.empty()) {
            auto age = std::chrono::duration_cast<std::chrono::seconds>(
                now - q.front().at).count();
            if (age >= OFFLINE_BUFFER_TTL_SECS) {
                q.pop_front();
                evicted++;
            } else {
                break;  // deque is FIFO by insertion time — front is oldest
            }
        }
        if (q.empty()) {
            it = state.offline_buffer.erase(it);
        } else {
            ++it;
        }
    }
    if (evicted > 0) {
        fprintf(stderr, "[push] Swept %zu expired buffered msg(s)\n", evicted);
    }
}

static void try_push_notify(const std::string& target_peer_id,
                            const std::string& sender_peer_id, RelayState& state) {
    auto tok_it = state.push_tokens.find(target_peer_id);
    if (tok_it == state.push_tokens.end()) {
        return;
    }

    auto now = std::chrono::steady_clock::now();
    auto& last = state.last_push_sent[target_peer_id];
    if ((now - last) < std::chrono::seconds(PUSH_DEBOUNCE_SECS)) {
        return;
    }
    last = now;

    // No logging of push routing — target/sender peer_ids are social-graph metadata.
    notify_push_sidecar(tok_it->second.token, tok_it->second.platform, sender_peer_id);
}

static void handle_register_push_token(SSLWebSocket* ws, PerSocketData* data,
                                        const std::string& token, const std::string& platform,
                                        RelayState& state) {
    if (data->is_guest || token.empty()) return;
    state.push_tokens[data->peer_id] = { token, platform };
    send_json(ws, {{"type", "push_token_registered"}});
    // No logging — associating a peer_id with a push token is sensitive.
}

// Store a peer's channel push prefs (RAM only, replaced wholesale). The app
// sends these on connect and whenever notification settings change; filtering
// happens relay-side because iOS alert pushes can't be suppressed on-device.
static void handle_set_push_prefs(PerSocketData* data, const json& j, RelayState& state) {
    if (data->is_guest) return;
    if (!j.contains("prefs") || !j["prefs"].is_object()) return;

    std::unordered_map<std::string, RelayState::ServerPushPref> prefs;
    size_t server_count = 0;
    for (auto& [server, val] : j["prefs"].items()) {
        if (++server_count > 256) break;  // defensive cap
        if (!val.is_object()) continue;
        RelayState::ServerPushPref p;
        p.level = val.value("level", "all");
        if (p.level != "all" && p.level != "mentions" && p.level != "nothing") p.level = "all";
        if (val.contains("channels") && val["channels"].is_object()) {
            size_t chan_count = 0;
            for (auto& [cid, lv] : val["channels"].items()) {
                if (++chan_count > 1024) break;  // defensive cap
                if (!lv.is_string()) continue;
                const std::string& s = lv.get_ref<const std::string&>();
                if (s == "all" || s == "mentions" || s == "nothing") p.channels[cid] = s;
            }
        }
        prefs[server] = std::move(p);
    }
    state.push_prefs[data->peer_id] = std::move(prefs);
    // No logging — peer_id + server set is membership metadata.
}

// Fire a channel push for an offline server member, filtered by their
// registered prefs (default "all") + mention flag, with per-(peer,server)
// debounce and an offline cap so a chatty server can't spam a phone that
// never reconnects.
static void try_channel_push_notify(const std::string& target, const std::string& sender,
                                    const std::string& server, const std::string& channel,
                                    bool mention, RelayState& state) {
    auto tok_it = state.push_tokens.find(target);
    if (tok_it == state.push_tokens.end()) return;

    // Prefs filter. Unregistered peer / unknown server = "all" (older clients
    // keep working); per-channel override beats the server level.
    std::string level = "all";
    auto pit = state.push_prefs.find(target);
    if (pit != state.push_prefs.end()) {
        auto sit = pit->second.find(server);
        if (sit != pit->second.end()) {
            level = sit->second.level;
            auto cit = sit->second.channels.find(channel);
            if (cit != sit->second.channels.end()) level = cit->second;
        }
    }
    if (level == "nothing") return;
    if (level == "mentions" && !mention) return;

    auto now = std::chrono::steady_clock::now();

    // Per-peer floor across ALL channel pushes (multi-server burst guard).
    auto& any_last = state.last_channel_push_any[target];
    if ((now - any_last) < std::chrono::seconds(CHANNEL_PUSH_MIN_GAP_SECS)) return;

    auto& cps = state.channel_push_state[target][server];
    int debounce = mention ? CHANNEL_PUSH_MENTION_DEBOUNCE_SECS : CHANNEL_PUSH_DEBOUNCE_SECS;
    if ((now - cps.last) < std::chrono::seconds(debounce)) return;
    if (!mention && cps.count_since_offline >= CHANNEL_PUSH_MAX_WHILE_OFFLINE) {
        return;  // resets when the full app rejoins the server room
    }

    cps.last = now;
    if (!mention) cps.count_since_offline++;
    any_last = now;

    // No logging — target peer + server + mention flag is membership/social metadata.
    notify_push_sidecar(PushJob{tok_it->second.token, tok_it->second.platform,
                                sender, server, channel, mention});
}

// 0x09: targeted channel-message frame for an OFFLINE server member.
// Layout: [0x09][room\0][target\0][channel\0][flags:1][payload]
// flags bit0 = mention. The SENDER picked the target from its CRDT member list
// (the relay never learns membership). Payload (the same MLS-group/public wire
// bytes the room broadcast carried) is buffered for the member's background
// fetch node; empty payload = push trigger only.
static void handle_binary_channel_direct(PerSocketData* data,
                                          std::string_view raw, RelayState& state) {
    if (raw.size() < 6) return;

    auto room_nul = raw.find('\0', 1);
    if (room_nul == std::string_view::npos) return;
    std::string_view room_code = raw.substr(1, room_nul - 1);

    size_t target_start = room_nul + 1;
    if (target_start >= raw.size()) return;
    auto target_nul = raw.find('\0', target_start);
    if (target_nul == std::string_view::npos) return;
    std::string_view target_peer = raw.substr(target_start, target_nul - target_start);

    size_t channel_start = target_nul + 1;
    if (channel_start >= raw.size()) return;
    auto channel_nul = raw.find('\0', channel_start);
    if (channel_nul == std::string_view::npos) return;
    std::string_view channel = raw.substr(channel_start, channel_nul - channel_start);

    size_t flags_pos = channel_nul + 1;
    if (flags_pos >= raw.size()) return;
    bool mention = (static_cast<uint8_t>(raw[flags_pos]) & 0x01) != 0;

    std::string_view payload = (flags_pos + 1 < raw.size())
        ? raw.substr(flags_pos + 1) : std::string_view{};

    std::string room_str(room_code);
    std::string target_str(target_peer);

    // Sender must actually be in the server room it claims to post to.
    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) return;
    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;

    // Only act for FULLY offline targets — online members already got the room
    // broadcast (and connected-but-elsewhere members recover via channel sync).
    if (state.peer_sockets.find(target_str) != state.peer_sockets.end()) return;

    if (!payload.empty()) {
        buffer_offline_msg(target_str, room_str,
                           build_direct_frame(room_code, data->peer_id, payload), state,
                           /*is_image=*/false, /*is_channel=*/true);
    }
    try_channel_push_notify(target_str, data->peer_id, room_str,
                            std::string(channel), mention, state);
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
    if (tit == rit->second.peers.end()) {
        // Target not in THIS room. Buffer either way (replays on join); only
        // push when fully offline. A connected-but-not-yet-joined target hits a
        // race (first plaintext DM — friend request / key exchange / sync —
        // sent before the recipient joins the DM room); buffering instead of
        // dropping is what lets a fresh device's Olm session actually establish
        // (the "session can't be established with the other device" symptom).
        bool in_sockets = state.peer_sockets.find(target) != state.peer_sockets.end();
        // Buffer as a 0x06 frame so the fetch node's binary parser handles it
        // uniformly with binary DMs.
        buffer_offline_msg(target, room,
                           build_direct_frame(room, data->peer_id, msg_data), state);
        if (!in_sockets) {
            try_push_notify(target, data->peer_id, state);
        }
        return;
    }

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
                                      std::string_view raw, RelayState& state,
                                      bool is_image = false) {
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
    std::string target_str(target_peer);

    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) {
        // Room doesn't exist — target is offline. Buffer the message for replay
        // when they wake up, then fire a push.
        if (state.peer_sockets.find(target_str) == state.peer_sockets.end()) {
            buffer_offline_msg(target_str, room_str,
                               build_direct_frame(room_code, data->peer_id, payload), state,
                               is_image);
            try_push_notify(target_str, data->peer_id, state);
        }
        return;
    }

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;

    auto tit = rit->second.peers.find(target_str);
    if (tit == rit->second.peers.end()) {
        // Target not in THIS room. Two cases:
        //  - fully offline (not in peer_sockets): buffer + push.
        //  - connected but not yet in the room (race: a DM sent in the gap
        //    between the recipient's WS auth and its DM-room join, or during a
        //    reconnect/supersede room flap): buffer WITHOUT a push so it replays
        //    the instant they join the room. Previously this case dropped the
        //    message silently — the "first message is lost, later ones arrive"
        //    symptom. The buffer is per-(peer,room) capped + TTL-swept, and the
        //    full node owns durability via DM-sync, so a redundant buffered copy
        //    is harmless (the receiver dedups by message_id).
        bool fully_offline = state.peer_sockets.find(target_str) == state.peer_sockets.end();
        buffer_offline_msg(target_str, room_str,
                           build_direct_frame(room_code, data->peer_id, payload), state,
                           is_image);
        if (fully_offline) {
            try_push_notify(target_str, data->peer_id, state);
        }
        return;
    }

    send_to_peer(tit->second, build_direct_frame(room_code, data->peer_id, payload),
                 uWS::OpCode::BINARY);
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

// NICKNAME_TTL_SECS: a claimed nickname lives 10 minutes, then is reclaimable.
// (It's a transient friend-request rendezvous, not a persistent identity.)
static constexpr uint64_t NICKNAME_TTL_SECS = 600;

// Erase a nickname binding (both directions + expiry).
static void erase_nickname_binding(RelayState& state, const std::string& nickname,
                                   const std::string& peer_id) {
    state.nickname_to_peer.erase(nickname);
    state.peer_to_nickname.erase(peer_id);
    state.nickname_expiry.erase(nickname);
}

// True iff a nickname's current binding is STALE: expired by TTL, or its holder's
// socket is no longer connected. Such a binding must not block a fresh claim, and
// resolve must treat it as not-found. Erases it as a side effect when stale.
static bool nickname_binding_is_stale(RelayState& state, const std::string& nickname) {
    auto it = state.nickname_to_peer.find(nickname);
    if (it == state.nickname_to_peer.end()) return true; // no binding == free
    const std::string& holder = it->second;
    bool expired = false;
    auto exp = state.nickname_expiry.find(nickname);
    if (exp != state.nickname_expiry.end() && now_unix_secs() > exp->second) expired = true;
    // Dead holder: no live socket authenticated as this peer_id.
    bool dead_holder = state.peer_sockets.find(holder) == state.peer_sockets.end();
    if (expired || dead_holder) {
        erase_nickname_binding(state, nickname, holder);
        return true;
    }
    return false;
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
        erase_nickname_binding(state, old->second, data->peer_id);
    }

    // Check availability — but a STALE binding (expired TTL, or held by a peer whose
    // socket is gone) is evicted here so it can't permanently block a fresh claim.
    // This is the fix for "nickname stayed bound to a dead old identity".
    if (state.nickname_to_peer.count(nickname) && !nickname_binding_is_stale(state, nickname)) {
        send_json(ws, {{"type", "nickname_error"}, {"error", "taken"}});
        return;
    }

    state.nickname_to_peer[nickname] = data->peer_id;
    state.peer_to_nickname[data->peer_id] = nickname;
    state.nickname_expiry[nickname] = now_unix_secs() + NICKNAME_TTL_SECS;
    send_json(ws, {{"type", "nickname_claimed"}, {"nickname", nickname}});
}

static void handle_release_nickname(SSLWebSocket* ws, PerSocketData* data,
                                     RelayState& state) {
    auto it = state.peer_to_nickname.find(data->peer_id);
    if (it != state.peer_to_nickname.end()) {
        erase_nickname_binding(state, it->second, data->peer_id);
    }
    send_json(ws, {{"type", "nickname_released"}});
}

static void handle_resolve_nickname(SSLWebSocket* ws, PerSocketData* /*data*/,
                                     const std::string& raw_nick, RelayState& state) {
    std::string nickname = to_lowercase(raw_nick);
    // A stale binding (expired / dead holder) must resolve as not_found, not return a
    // dead peer_id the requester would then friend-request into the void.
    if (nickname_binding_is_stale(state, nickname)) {
        send_json(ws, {{"type", "nickname_error"}, {"error", "not_found"}, {"nickname", nickname}});
        return;
    }
    auto it = state.nickname_to_peer.find(nickname);
    send_json(ws, {{"type", "nickname_resolved"}, {"nickname", nickname}, {"peer_id", it->second}});
}

// ── Multi-device link codes (Step 4) — mirrors the nickname registry ──────────

static std::string to_uppercase(std::string_view s) {
    std::string out(s);
    for (char& c : out) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    return out;
}

static bool is_valid_link_code(std::string_view code) {
    if (code.size() != 6) return false;
    for (char c : code) {
        if (!std::isupper(static_cast<unsigned char>(c)) &&
            !std::isdigit(static_cast<unsigned char>(c))) {
            return false;
        }
    }
    return true;
}

// LINK_CODE_TTL_SECS: a claimed code lives 5 minutes, then the sweep releases it.
static constexpr uint64_t LINK_CODE_TTL_SECS = 300;

static void handle_claim_link_code(SSLWebSocket* ws, PerSocketData* data,
                                    const std::string& raw_code, RelayState& state) {
    if (data->is_guest) return;

    std::string code = to_uppercase(raw_code);
    if (!is_valid_link_code(code)) {
        send_json(ws, {{"type", "link_code_error"}, {"error", "invalid"}});
        return;
    }

    // Auto-release the peer's previous code if any.
    auto old = state.peer_to_linkcode.find(data->peer_id);
    if (old != state.peer_to_linkcode.end()) {
        state.linkcode_expiry.erase(old->second);
        state.linkcode_to_peer.erase(old->second);
        state.peer_to_linkcode.erase(old);
    }

    if (state.linkcode_to_peer.count(code)) {
        send_json(ws, {{"type", "link_code_error"}, {"error", "taken"}});
        return;
    }

    state.linkcode_to_peer[code] = data->peer_id;
    state.peer_to_linkcode[data->peer_id] = code;
    state.linkcode_expiry[code] = now_unix_secs() + LINK_CODE_TTL_SECS;
    send_json(ws, {{"type", "link_code_claimed"}, {"code", code}});
}

static void handle_release_link_code(SSLWebSocket* ws, PerSocketData* data,
                                      RelayState& state) {
    auto it = state.peer_to_linkcode.find(data->peer_id);
    if (it != state.peer_to_linkcode.end()) {
        state.linkcode_expiry.erase(it->second);
        state.linkcode_to_peer.erase(it->second);
        state.peer_to_linkcode.erase(it);
    }
    send_json(ws, {{"type", "link_code_released"}});
}

static void handle_resolve_link_code(SSLWebSocket* ws, PerSocketData* /*data*/,
                                      const std::string& raw_code, RelayState& state) {
    std::string code = to_uppercase(raw_code);
    auto it = state.linkcode_to_peer.find(code);
    if (it == state.linkcode_to_peer.end()) {
        send_json(ws, {{"type", "link_code_error"}, {"error", "not_found"}, {"code", code}});
        return;
    }
    // Honor TTL even if the sweep hasn't run yet.
    auto exp = state.linkcode_expiry.find(code);
    if (exp != state.linkcode_expiry.end() && now_unix_secs() > exp->second) {
        state.linkcode_expiry.erase(code);
        state.peer_to_linkcode.erase(it->second);
        state.linkcode_to_peer.erase(it);
        send_json(ws, {{"type", "link_code_error"}, {"error", "not_found"}, {"code", code}});
        return;
    }
    std::string peer_id = it->second;
    // One-shot: consume the code on a successful resolve.
    state.linkcode_expiry.erase(code);
    state.peer_to_linkcode.erase(peer_id);
    state.linkcode_to_peer.erase(it);
    send_json(ws, {{"type", "link_code_resolved"}, {"code", code}, {"peer_id", peer_id}});
}

// Release link codes whose 5-minute TTL has elapsed (server-side backstop; the
// live countdown is client-side). Called from the offline-buffer sweep timer.
void sweep_link_codes(RelayState& state) {
    uint64_t now = now_unix_secs();
    std::vector<std::string> expired;
    for (auto& [code, exp] : state.linkcode_expiry) {
        if (now > exp) expired.push_back(code);
    }
    for (auto& code : expired) {
        auto it = state.linkcode_to_peer.find(code);
        if (it != state.linkcode_to_peer.end()) {
            state.peer_to_linkcode.erase(it->second);
            state.linkcode_to_peer.erase(it);
        }
        state.linkcode_expiry.erase(code);
    }
}

static void handle_text_message(SSLWebSocket* ws, PerSocketData* data,
                                 std::string_view message, RelayState& state,
                                 const Config& config) {
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
    } else if (type == "discover_peers") {
        // Peer discovery over the LIVE WS connection (replaces the HTTP /bootstrap
        // poll, which paid a fresh TLS handshake per request and could stall under
        // a WS frame burst on the single event loop). Returns the peers currently
        // connected to the given WS room. Cheap: one map lookup + bounded copy, no
        // new connection, no blocking I/O.
        const std::string room = j.value("room", "");
        json peers = json::array();
        if (!room.empty()) {
            auto rit = state.ws_rooms.find(room);
            if (rit != state.ws_rooms.end()) {
                for (const auto& [pid, sock] : rit->second.peers) {
                    if (pid != data->peer_id) peers.push_back(pid);  // exclude self
                }
            }
        }
        send_json(ws, {{"type", "discovered_peers"}, {"room", room}, {"peers", peers}});
    } else if (type == "subscribe") {
        handle_subscribe(data, j.value("room", ""),
                         j.contains("topics") ? j["topics"] : json::array());
    } else if (type == "claim_nickname") {
        handle_claim_nickname(ws, data, j.value("nickname", ""), state);
    } else if (type == "release_nickname") {
        handle_release_nickname(ws, data, state);
    } else if (type == "resolve_nickname") {
        handle_resolve_nickname(ws, data, j.value("nickname", ""), state);
    } else if (type == "claim_link_code") {
        handle_claim_link_code(ws, data, j.value("code", ""), state);
    } else if (type == "release_link_code") {
        handle_release_link_code(ws, data, state);
    } else if (type == "resolve_link_code") {
        handle_resolve_link_code(ws, data, j.value("code", ""), state);
    } else if (type == "register_push_token") {
        handle_register_push_token(ws, data, j.value("token", ""),
                                   j.value("platform", ""), state);
    } else if (type == "set_push_prefs") {
        handle_set_push_prefs(data, j, state);
    } else if (type == "get_turn_credentials") {
        // TURN credentials over the LIVE authenticated WS connection —
        // replaces the open HTTP /turn-credentials endpoint for current
        // clients: no fresh TLS handshake per refresh, retries ride the
        // client's normal reconnect machinery, and the credentials sit
        // behind relay auth instead of being farmable by anyone. The HTTP
        // endpoint stays for older clients.
        if (data->is_guest) {
            send_json(ws, {{"type", "turn_credentials"}, {"error", "auth required"}});
        } else if (config.turn_secret.empty()) {
            send_json(ws, {{"type", "turn_credentials"}, {"error", "TURN not configured"}});
        } else {
            uint64_t ttl = 3600;
            uint64_t expiry = now_unix_secs() + ttl;
            std::string username = std::to_string(expiry) + ":hollow";
            std::string password = hmac_sha1_base64(config.turn_secret, username);
            send_json(ws, {{"type", "turn_credentials"},
                           {"username", username},
                           {"password", password},
                           {"ttl", ttl},
                           {"uris", {
                               "turn:relay.anonlisten.com:3478",
                               "turn:relay.anonlisten.com:3478?transport=tcp",
                               "turns:relay.anonlisten.com:5349"
                           }}});
        }
    }
}

// DoS protection: per-IP limits (34 conns, 10 new/min), guest rate limiting (10 binary/min),
// Ed25519 auth + license key revocation. IPs tracked in-memory only, never logged.


// Tear down all shared state for `peer_id`, owned by `expected_ws`. Only the
// socket that currently owns the peer's entries does the teardown: if a newer
// socket has already taken over (peer_sockets points elsewhere / room slots
// point at the successor), this is a stale duplicate closing and must NOT evict
// the live successor. `expected_ws` is the closing/evicted socket; room erases
// are gated on it via leave_room so a ghost can't unjoin the live socket.
static void cleanup_peer(RelayState& state, const std::string& peer_id,
                         SSLWebSocket* expected_ws) {
    // If a DIFFERENT socket now owns this peer_id, the closing socket is a stale
    // duplicate that was already replaced — skip the shared cleanup (nickname,
    // push, license, peer_sockets) so we don't tear down the live successor's
    // state. The per-room leave below is always safe to run because leave_room
    // is itself gated on expected_ws.
    // (In the supersede path cleanup_peer is called while peer_sockets still
    // points at the ghost — owns_peer is true there, so the ghost's shared
    // state IS cleared before the new socket registers, exactly as intended.)
    auto sock_it = state.peer_sockets.find(peer_id);
    bool owns_peer = (sock_it == state.peer_sockets.end() || sock_it->second == expected_ws);

    if (owns_peer) {
        // Release temporary nickname (+ its expiry entry)
        auto nit = state.peer_to_nickname.find(peer_id);
        if (nit != state.peer_to_nickname.end()) {
            state.nickname_expiry.erase(nit->second);
            state.nickname_to_peer.erase(nit->second);
            state.peer_to_nickname.erase(nit);
        }

        // Release multi-device link code
        auto lit = state.peer_to_linkcode.find(peer_id);
        if (lit != state.peer_to_linkcode.end()) {
            state.linkcode_expiry.erase(lit->second);
            state.linkcode_to_peer.erase(lit->second);
            state.peer_to_linkcode.erase(lit);
        }

        // Clear push debounce on disconnect (token stays — needed for offline pushes)
        state.last_push_sent.erase(peer_id);

        state.license.release_key(peer_id);
        state.peer_sockets.erase(peer_id);
    }

    auto pit = state.peer_rooms.find(peer_id);
    if (pit == state.peer_rooms.end()) return;

    // Copy the set since leave_room modifies it. leave_room only erases a room
    // slot that still points at expected_ws, so a stale duplicate can't unjoin
    // the live socket's rooms (and won't broadcast a spurious peer_left).
    std::vector<std::string> rooms(pit->second.begin(), pit->second.end());
    for (auto& room : rooms) {
        leave_room(state, peer_id, room, expected_ws);
    }
    if (owns_peer) {
        state.peer_rooms.erase(peer_id);
    }
}

void setup_ws_handler(uWS::SSLApp& app, RelayState& state, const Config& config) {
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

        .message = [&state, &config](SSLWebSocket* ws, std::string_view message, uWS::OpCode opCode) {
            auto* data = ws->getUserData();

            if (!data->authenticated) {
                handle_auth(ws, data, message, state);
                return;
            }

            if (opCode == uWS::OpCode::TEXT) {
                if (message.size() > 1024 * 1024) return;
                handle_text_message(ws, data, message, state, config);
            } else if (opCode == uWS::OpCode::BINARY) {
                // 1-byte 0x00 = guest keepalive, don't process or count
                if (message.size() == 1 && static_cast<uint8_t>(message[0]) == 0x00) {
                    return;
                }
                if (message.size() > 1) {
                    uint8_t opcode = static_cast<uint8_t>(message[0]);

                    // Guest binary restrictions
                    if (data->is_guest) {
                        if (opcode == 0x04 || opcode == 0x08 || opcode == 0x09) return; // no SendDirect for guests
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
                        case 0x08:
                            // Direct message carrying an inlined image —
                            // buffered under the per-peer image cap when offline.
                            handle_binary_direct_msg(data, message, state, /*is_image=*/true);
                            break;
                        case 0x07:
                            handle_binary_topic_msg(data, message, state);
                            break;
                        case 0x09:
                            // Targeted channel message for an offline server
                            // member — buffered + prefs-filtered channel push.
                            handle_binary_channel_direct(data, message, state);
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
            if (data->authenticated && !data->superseded) {
                // privacy: no connection logging
                // Pass the closing socket so cleanup only fires if THIS socket
                // still owns the peer's state — a stale duplicate that was
                // already superseded by a newer connection is a no-op here and
                // must not evict the live socket from its rooms.
                cleanup_peer(state, data->peer_id, ws);
            }
        }
    });
}
