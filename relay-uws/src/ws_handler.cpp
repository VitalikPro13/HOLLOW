#include "ws_handler.h"
#include "auth_frame.h"
#include "client_json.h"
#include "ring_evict.h"
#include "ring_auth.h"
#include "crypto.h"
#include "device_list.h"
#include "fwd_room.h"
#include "kill_order.h"
#include "roster_crypto.h"
#include "validate.h"
#include "turn_uris.h"
#include "push_queue.h"
#include "json.hpp"
#include <cstdio>
#include <cstring>
#include <algorithm>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>

using json = nlohmann::json;

static constexpr uint64_t TIMESTAMP_SKEW_SECS = 60;
static constexpr size_t MAX_ROOMS_PER_PEER = 10000;
static constexpr int PUSH_SIDECAR_PORT = 3001;
static constexpr int PUSH_DEBOUNCE_SECS = 10;
// check_peers bounds (RELAY-3). The client asks about its offline friends, so a
// few dozen ids is the real shape of a query; 256 is generous headroom. The
// scan budget bounds the co-member pass for a peer sitting in many rooms.
static constexpr size_t MAX_CHECK_PEERS_QUERY = 256;
static constexpr size_t MAX_CHECK_PEERS_SCAN = 65536;

// An address with the low bits of a v6 one cleared from byte `keep_bytes` on, and
// `suffix` appended. IPv4 clients on the dual-stack [::] listener arrive
// V4-MAPPED (uWS prints them as uncompressed v6 hex) and MUST be unmapped to
// their dotted quad first, or every v4 client collapses into one "::" bucket.
// Unparseable input falls back to the raw text (per-address).
static std::string address_block(const std::string& ip, size_t keep_bytes, const char* suffix) {
    if (ip.find(':') == std::string::npos) return ip;
    struct in6_addr addr;
    if (inet_pton(AF_INET6, ip.c_str(), &addr) != 1) return ip;
    if (IN6_IS_ADDR_V4MAPPED(&addr)) {
        struct in_addr v4;
        std::memcpy(&v4, addr.s6_addr + 12, 4);
        char buf4[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &v4, buf4, sizeof(buf4))) return ip;
        return std::string(buf4);
    }
    std::memset(addr.s6_addr + keep_bytes, 0, 16 - keep_bytes);
    char buf[INET6_ADDRSTRLEN];
    if (!inet_ntop(AF_INET6, &addr, buf, sizeof(buf))) return ip;
    return std::string(buf) + suffix;
}

// Key for per-IP limiting. IPv6 aggregates by /64: a single host typically owns
// an entire /64, so per-address counting would be trivially bypassed.
static std::string ip_limit_key(const std::string& ip) {
    return address_block(ip, 8, "/64");
}

// The block fair shares are kept by (fair_share.h): a v4 address, or the /48 of
// a v6 one, the block a single site is given. By /64, whoever holds one /48
// would hold 65,536 shares.
static std::string share_block(const std::string& ip) {
    return address_block(ip, 6, "/48");
}

// The share a socket's writes are charged to: its address block hashed under the
// current hour's key.
static uint64_t socket_share(RelayState& state, const PerSocketData* data) {
    auto now = std::chrono::steady_clock::now();
    if (state.share_key.empty() ||
        now - state.share_key_since >= std::chrono::seconds(SHARE_KEY_LIFETIME_SECS)) {
        state.share_key = random_hex(32);
        state.share_key_since = now;
    }
    return share_id(state.share_key, data->share_block);
}

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

static bool is_inbox_room(const std::string& room);

static int64_t steady_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// The newest join lock of a self-certifying server room, or null: a room with one is
// door-locked (door_room.h). A legacy id's chain is kept per owner, which a room
// name does not say, so a legacy room stays open.
static const LockLink* room_lock(const RelayState& state, const std::string& room) {
    if (!join_lock::is_genesis_id(room)) return nullptr;
    auto it = state.join_locks.records.find(room);
    return it == state.join_locks.records.end() || it->second.empty() ? nullptr : &it->second.back();
}

// Who in one room sees it (the roster, presence, broadcasts and rings) and whom a
// direct may reach. An inbox shows its owners only, to each other and to nobody
// else; a door-locked server room shows its provers only, but a direct still reaches
// anyone in it, because a member chooses whom to address. A forwarder's room pairs
// each member with the forwarder alone (fwd_room.h).
struct Audience {
    const WsRoom& room;
    bool inbox = false;
    bool locked = false;
    int64_t now_ms = 0;
    std::string_view name;

    bool sees(const std::string& peer) const {
        if (inbox) return room.owners.count(peer) != 0;
        return !locked || room.doors.sees(peer, now_ms);
    }

    // Whether `pid` sees the room and may know of `other` there: list it, be told it
    // came or went, hear its broadcasts.
    bool shares(const std::string& pid, const std::string& other) const {
        return sees(pid) && fwd_room::paired(name, pid, other);
    }

    bool reachable(const std::string& peer) const { return !inbox || room.owners.count(peer) != 0; }
};

static Audience audience(const RelayState& state, const WsRoom& room, const std::string& name) {
    return Audience{room, is_inbox_room(name), room_lock(state, name) != nullptr, steady_ms(), name};
}

// "Is `x` in one of the same rooms as `caller`" is the only relationship the
// relay can verify between two peers, so it is what gates the answers one peer
// may ask for about another (see check_peers). Answered for a whole query in
// ONE pass rather than per queried id: `peer_rooms` is already the peer -> rooms
// index, so this walks the caller's rooms once and hands back the set of peers
// it may be told about. Per-id membership is then a hash lookup, which keeps a
// 256-id query from turning into 256 room walks on the event loop.
//
// `budget` caps the insertions so a peer sitting in thousands of rooms cannot
// make each query expensive; truncation can only ever WITHHOLD an answer.
static std::unordered_set<std::string> collect_room_co_members(
        const RelayState& state, const std::string& caller, size_t budget) {
    std::unordered_set<std::string> members;
    auto it = state.peer_rooms.find(caller);
    if (it == state.peer_rooms.end()) return members;
    for (const auto& room : it->second) {
        auto rit = state.ws_rooms.find(room);
        if (rit == state.ws_rooms.end()) continue;
        // An inbox makes only its owners co-members of each other, a locked room its provers.
        const Audience aud = audience(state, rit->second, room);
        if (!aud.sees(caller)) continue;
        for (const auto& [pid, sock] : rit->second.peers) {
            (void)sock;
            if (!aud.shares(pid, caller)) continue;
            if (budget == 0) return members;
            budget--;
            members.insert(pid);
        }
    }
    return members;
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

// Delivery diagnostics + forwarder identity, wired up in setup_ws_handler.
// File-scope because send_to_peer is called from a dozen sites that don't
// carry state/config. Counters only — the relay logs nothing.
static DeliveryDiag* g_diag = nullptr;
static std::string g_forwarder_peer_id;

static void send_to_peer(SSLWebSocket* ws, std::string_view data, uWS::OpCode op) {
    // uWS silently returns DROPPED past maxBackpressure — count it or a
    // delivery failure leaves zero trace anywhere (field 2026-08-06: large
    // frames to the forwarder vanished with every hop looking healthy).
    auto status = ws->send(data, op);
    if (g_diag) {
        if (status == SSLWebSocket::SendStatus::DROPPED) g_diag->send_dropped++;
        else if (status == SSLWebSocket::SendStatus::BACKPRESSURE) g_diag->send_backpressure++;
    }
}

// Forward declarations — offline buffer replay is used by handle_join (defined
// earlier than the buffer helpers).
static void replay_buffered_msgs(SSLWebSocket* ws, const std::string& peer_id,
                                 const std::string& room, bool full_node,
                                 RelayState& state);
// cleanup_peer is defined near the close handler but used by handle_auth's
// supersede path (evict a stale duplicate connection's room state).
// `suppress_peer_left` = the peer is NOT actually leaving (a newer socket of
// the same peer_id is taking over): erase the room slots silently.
static void cleanup_peer(RelayState& state, const std::string& peer_id,
                         SSLWebSocket* expected_ws,
                         bool suppress_peer_left = false);

// Pre-0.12 clients sign only `hollow-ws-auth:{peer}:{ts}` and cannot ask for a
// challenge. Turn this off once 0.12 is out: until then a v1 frame captured by
// another relay still replays here, as it always has for 0.11 clients.
// This and the other three release-day switches take a -D override so
// test/run_live.sh can run the relay with them off as well as on.
#ifndef HOLLOW_ACCEPT_AUTH_V1
#define HOLLOW_ACCEPT_AUTH_V1 1
#endif
static constexpr bool ACCEPT_AUTH_V1 = HOLLOW_ACCEPT_AUTH_V1;

// The one frame an unauthenticated socket may send besides `auth`. The nonce is
// minted once per socket; asking again gets the same one. `door_key` is what this
// socket's door proofs are made for.
static void handle_auth_hello(SSLWebSocket* ws, PerSocketData* data, const RelayState& state) {
    if (data->auth_nonce.empty()) {
        data->auth_nonce = random_hex(AUTH_NONCE_HEX_LEN / 2);
    }
    send_json(ws, {{"type", "auth_challenge"}, {"nonce", data->auth_nonce}, {"door_key", state.door_key.text}});
}

static void handle_auth(SSLWebSocket* ws, PerSocketData* data,
                         std::string_view message, RelayState& state,
                         const Config& config) {
    // Neither parser throws: these frames come from anyone on the internet.
    if (is_auth_hello(message)) {
        handle_auth_hello(ws, data, state);
        return;
    }
    std::optional<AuthFrame> frame = parse_auth_frame(message);
    if (!frame) {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }

    std::string peer_id = frame->peer_id;
    std::string public_key = frame->public_key;
    uint64_t timestamp = frame->timestamp;
    std::string signature = frame->signature;
    std::string license_key_val = frame->license_key;
    const std::string* license_key_ptr = license_key_val.empty() ? nullptr : &license_key_val;
    bool guest = frame->guest;
    bool fetch = frame->fetch;

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

    // SECURITY: bind the claimed peer_id to the supplied public key.
    //
    // The signature check below proves only that the sender holds the private
    // half of `public_key` — NOT that they own `peer_id`. Without this binding,
    // anyone could mint a throwaway keypair, sign
    // "hollow-ws-auth:<victim_peer_id>:<now>" with it, and authenticate AS the
    // victim: peer_ids are public (broadcast in peer_joined + room member
    // snapshots), and a newer socket for an existing peer_id EVICTS the
    // incumbent below, so this was a persistent remote deauth of any user, plus
    // delivery of their routed traffic and offline buffer.
    //
    // peer_id is a pure function of the public key, so just recompute it. Every
    // real client already derives it this way (full node, push fetch node, and
    // the web guest viewer's derivePeerId).
    std::string derived_peer_id = derive_peer_id(public_key);
    if (derived_peer_id.empty() || derived_peer_id != peer_id) {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }

    // v2 binds the frame to this socket's challenge, this relay and every flag the
    // relay acts on, so a captured frame opens nothing anywhere else: not another
    // relay, not a second socket here, not an invisible `fetch` socket beside the
    // live device.
    std::string signed_msg;
    if (frame->version == 2) {
        std::optional<std::string> mode = auth_mode(guest, fetch);
        bool challenged = !data->auth_nonce.empty() && frame->nonce == data->auth_nonce;
        if (!mode || !challenged || frame->domain != auth_domain(config.domain)) {
            send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
            ws->end(1008, "bad_auth");
            return;
        }
        std::string license_digest = license_key_val.empty() ? std::string() : sha256_hex(license_key_val);
        signed_msg = auth_v2_message(frame->domain, frame->nonce, peer_id, timestamp, *mode, license_digest);
    } else if (ACCEPT_AUTH_V1) {
        signed_msg = "hollow-ws-auth:" + peer_id + ":" + std::to_string(timestamp);
    } else {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }
    // One challenge, one attempt; door proofs stay bound to the one that logged in.
    const std::string challenge = frame->version == 2 ? data->auth_nonce : std::string();
    data->auth_nonce.clear();
    if (!verify_ed25519(public_key, signature, signed_msg)) {
        send_json(ws, {{"type", "auth_failed"}, {"error", "Authentication failed"}});
        ws->end(1008, "bad_auth");
        return;
    }
    data->door_nonce = challenge;

    // The three license outcomes below are distinguishable to the caller, which
    // makes this a validity oracle for a license key. That is an ACCEPTED,
    // DOCUMENTED tradeoff, not an oversight: the client shows a different,
    // actionable message for each ("Invalid license key" / already in use / one
    // is required — hollow_shell.dart), and collapsing them to one string would
    // trade a user who can fix their own problem for an attacker who learns one
    // bit slower. Keys are high-entropy and every guess costs a full TLS
    // handshake plus a signed auth frame. Do not "fix" this by merging them.
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
            // Evict the ghost's room memberships + socket entry, SILENTLY: the
            // peer is not leaving, it is right here on a newer socket and will
            // re-join immediately (WsEvent::Connected re-join loop). Emitting
            // peer_left for a peer that is demonstrably present is a lie that
            // observers act on — it tore down live media branches after an app
            // restart, which is why both the client and the forwarder engine
            // grew presence-flap tolerance. The successor's join broadcasts
            // peer_joined and a fresh members snapshot, so presence converges
            // without ever claiming a departure that did not happen.
            cleanup_peer(state, peer_id, ghost, /*suppress_peer_left=*/true);
            // Close the dead socket so it stops consuming a connection slot.
            ghost->end(1000, "superseded");
        }
        state.peer_sockets[peer_id] = ws;
        // Reset room bookkeeping for the new socket. MUST stay inside the
        // non-fetch branch: a fetch-mode auth for a peer whose full node is
        // connected used to wipe the FULL NODE's room set, so that node's
        // eventual close found nothing to leave_room — leaving room slots
        // pointing at a freed socket (no peer_left, and a dangling pointer for
        // every later fan-out to that room).
        state.peer_rooms[peer_id] = {};
    }

    send_json(ws, {{"type", "auth_ok"}});

    // Out with the auth, before any join: a device whose identity is gone may
    // never join a room again, and a phone that only wakes for push (a fetch
    // socket) has to act on it too. Every signal waiting: the device judges each,
    // and its ack names the one it turned away by issuer and stamp.
    const auto kills = state.kill_list.waiting(peer_id);
    for (const auto* kill : kills) {
        send_json(ws, {{"type", "kill_signal"},
                       {"blob", kill->blob},
                       {"issued_at_ms", kill->issued_at_ms},
                       {"issuer", kill->issuer}});
    }
    // Operational only: no peer id, no issuer, no blob.
    if (!kills.empty()) fprintf(stderr, "[kill] kill_signal delivered\n");
    // privacy: no connection logging
}

// --- Inbox mailbox (async friending) ---------------------------------------
//
// A friend request addressed to a STRANGER is addressed to their MASTER id, and
// no socket ever authenticates as a master — so the frame lands in
// offline_buffer[master]. A socket owns `inbox:{M}`, and is replayed M's mailbox,
// only while the relay's fold of every roster shown for M counts its device a
// member (design ID-1R, roster_book.h). The relay logs nothing about who
// deposited or read what (feedback_relay_rules).
static constexpr char INBOX_ROOM_PREFIX[] = "inbox:";

// 0.11 clients prove an inbox with a master-signed device list, which anyone
// holding the master key can sign. Turn this off once 0.12 is out; until then
// such a list opens only an inbox whose roster the phrase does not yet root.
#ifndef HOLLOW_ACCEPT_DEVICE_LIST_INBOX_PROOF
#define HOLLOW_ACCEPT_DEVICE_LIST_INBOX_PROOF 1
#endif
static constexpr bool ACCEPT_DEVICE_LIST_INBOX_PROOF = HOLLOW_ACCEPT_DEVICE_LIST_INBOX_PROOF;

static const RosterCrypto& relay_roster_crypto() {
    static const RosterCrypto c = roster_crypto();
    return c;
}

static int64_t wall_now_ms() {
    return static_cast<int64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count());
}

// Parse the optional `inbox_proof` object carried on a join into a
// SignedDeviceList. Strict: every field must be present and the right shape.
// A malformed proof is simply "no proof" — the join still succeeds, the
// mailbox just never opens.
static bool parse_inbox_proof(const json& j, SignedDeviceList& out) {
    if (!j.is_object()) return false;

    auto str_field = [&](const char* key, std::string& dst) {
        auto it = j.find(key);
        if (it == j.end() || !it->is_string()) return false;
        dst = it->get<std::string>();
        return true;
    };
    // Bounded: a join frame may be a megabyte of text, and an unbounded array
    // here would let one join allocate tens of thousands of strings before the
    // signature that governs them is even checked. No real master has anywhere
    // near this many devices or tombstones. Deliberately NOT shape-checked:
    // these ids are covered by the master's signature rather than chosen by the
    // caller, and refusing an unexpected shape would lock a real user out of
    // their own mailbox.
    static constexpr size_t MAX_PROOF_IDS = 1024;
    auto str_array = [&](const char* key, std::vector<std::string>& dst) {
        auto it = j.find(key);
        if (it == j.end() || !it->is_array()) return false;
        if (it->size() > MAX_PROOF_IDS) return false;
        for (const auto& e : *it) {
            if (!e.is_string()) return false;
            dst.push_back(e.get<std::string>());
        }
        return true;
    };

    if (!str_field("master_pubkey_b64", out.master_pubkey_b64)) return false;
    if (!str_field("master_peer_id", out.master_peer_id)) return false;
    if (!str_field("sig_b64", out.sig_b64)) return false;
    if (!str_array("devices", out.devices)) return false;
    if (!str_array("revoked", out.revoked)) return false;

    auto vit = j.find("version");
    // serde serializes the u64 version unsigned; anything else (negative,
    // float, string) is not a list this relay can have the signed bytes for.
    if (vit == j.end() || !vit->is_number_unsigned()) return false;
    out.version = vit->get<uint64_t>();
    return true;
}

// TTL-only mailbox replay: send every buffered frame for `mailbox_peer_id` that
// belongs to `room`, and DO NOT remove it.
//
// This is the one deliberate difference from replay_buffered_msgs (the
// device-keyed DM replay, which deletes on delivery): every sibling device of
// the master must be able to collect the same request on its own next boot, so
// a read cannot consume the mailbox. The receiver dedups on its friends row (a
// request already pending/accepted/declined is a no-op at ingest), and the TTL
// sweep still expires the entry normally. Rejoining the same socket therefore
// re-delivers — that is required, not a bug; do not add per-socket delivery
// tracking to "fix" it.
static void replay_mailbox_no_delete(SSLWebSocket* ws,
                                     const std::string& mailbox_peer_id,
                                     const std::string& room,
                                     RelayState& state) {
    auto it = state.offline_buffer.find(mailbox_peer_id);
    if (it == state.offline_buffer.end()) return;
    for (const auto& m : it->second) {
        if (m.room == room) {
            send_to_peer(ws, m.frame, uWS::OpCode::BINARY);
        }
    }
    // The byte budget is untouched on purpose: nothing left the buffer.
    // No logging — which device read whose mailbox is social-graph metadata.
}

// Ownership check for an `inbox:{M}` join. ALL of these must hold, else replay
// NOTHING — and say nothing: no error frame, no log line. A failed proof is
// indistinguishable from a plain join, so a prober learns neither whether the
// mailbox exists nor whether it holds anything.
//
//   a. the device list signature verifies under master_pubkey_b64;
//   b. derive_peer_id(master_pubkey_b64) == master_peer_id  (inside verify);
//   c. this socket's AUTHENTICATED device id is in `devices` and not `revoked`;
//   d. the joined room string equals "inbox:" + master_peer_id.
//   e. the list's `version` is not older than the newest this relay has seen
//      verify for that master.
//
// (c) is what makes the proof non-transferable: the list is public-ish (it is
// gossiped between devices), but replaying someone else's list only opens the
// mailbox for a socket that already authenticated as one of ITS devices, and
// auth binds peer_id to the key (handle_auth).
//
// (e) is what makes REVOCATION stick. A revoked device keeps the last list that
// named it, that list is master-signed and verifies forever, and (c) passes
// against it — so revocation was a client-side courtesy the relay never
// enforced. `version` is inside the signed payload
// ("hollow-devices:{master}:{version}:{devices}:{revoked}"), so a replayer
// cannot raise it without the master's key, and the newer list that revoked it
// necessarily carries a higher version. The mark is bumped from ANY list that
// verifies for the master, whoever carries it, because only the master can mint
// one — a third party presenting the current list can therefore raise the bar
// but never lower it. The marks survive a restart through the snapshot.
static bool is_inbox_room(const std::string& room) {
    return room.rfind(INBOX_ROOM_PREFIX, 0) == 0;
}

static bool inbox_owner_proved(PerSocketData* data, const std::string& room,
                               const json& proof_json, RelayState& state) {
    // Guests never own an identity, so they can never own a mailbox.
    if (!ACCEPT_DEVICE_LIST_INBOX_PROOF || data->is_guest) return false;
    if (!is_inbox_room(room)) return false;

    SignedDeviceList dl;
    if (!parse_inbox_proof(proof_json, dl)) return false;
    if (!verify_signed_device_list(dl)) return false;                       // a + b
    if (room != std::string(INBOX_ROOM_PREFIX) + dl.master_peer_id) return false;  // d
    // Once the phrase roots the identity's roster, the master key proves nothing,
    // and a device the roster removed never comes back through an old list.
    if (const auto* held = state.roster_book.get(dl.master_peer_id)) {
        auto st = state.roster_book.fold(*held, wall_now_ms(), relay_roster_crypto());
        if (st.is_protected || st.removed.count(data->peer_id)) return false;
    }

    // (e) — before (c), so a current list raises the mark even when the socket
    // carrying it turns out not to be one of its devices. No log line: a
    // rejected replay must look exactly like a plain join.
    auto vit = state.device_list_max_version.find(dl.master_peer_id);
    if (vit != state.device_list_max_version.end()) {
        if (dl.version < vit->second) return false;
        vit->second = dl.version;
    } else {
        state.device_list_max_version[dl.master_peer_id] = dl.version;
    }

    const bool owns = device_list_owns_device(dl, data->peer_id);           // c
    // Once one of the master's own devices proves, the mark is charged to it, so
    // a third party presenting the list first never makes it theirs to lose.
    if (owns || !state.mark_ledger.contains(dl.master_peer_id)) {
        state.mark_ledger.put(dl.master_peer_id, socket_share(state, data), 1);
    } else {
        state.mark_ledger.touch(dl.master_peer_id);
    }
    while (state.mark_ledger.size() > MAX_DEVICE_LIST_VERSIONS) {
        auto victim = state.mark_ledger.victim();
        if (!victim) break;
        state.device_list_max_version.erase(*victim);
        state.mark_ledger.remove(*victim);
    }
    return owns;
}

// Owners of `room` that `state` (the held roster's fold) no longer counts lose the
// inbox at once; the owners left see them go. A stranger with a request pending
// learns neither which devices a person has nor when they are online (Audience).
static void drop_inbox_owners(RelayState& state, const std::string& room, const roster::State& st) {
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return;
    WsRoom& r = rit->second;
    std::vector<std::string> gone;
    for (const auto& owner : r.owners) {
        if (!st.is_member(owner)) gone.push_back(owner);
    }
    for (const auto& peer : gone) {
        r.owners.erase(peer);
        std::string left = json{{"type", "peer_left"}, {"room", room}, {"peer_id", peer}}.dump();
        const Audience aud = audience(state, r, room);
        for (auto& [pid, sock] : r.peers) {
            if (pid != peer && !sock->getUserData()->is_guest && aud.sees(pid)) {
                send_to_peer(sock, left, uWS::OpCode::TEXT);
            }
        }
    }
}

// Whether `proof` opens `door` for this socket in `room`. A socket that never asked
// for a challenge (a 0.11 login) has no nonce to bind a proof to.
static bool door_opens(const RelayState& state, const PerSocketData* data, const std::string& room,
                       const std::string& door, const std::string& proof) {
    if (data->door_nonce.empty() || proof.size() != door_room::PROOF_TEXT_LEN) return false;
    const std::string msg =
        door_room::proof_message(state.door_domain, data->door_nonce, data->peer_id, room, door, state.door_key.text);
    return door_proof_opens(state.door_key, door, msg, proof);
}

// The room as `peer` sees it now that it sees it: the visible peers, itself last.
static std::vector<std::string> roster_for(const WsRoom& room, const Audience& aud, const std::string& peer) {
    std::vector<std::string> out;
    for (const auto& [pid, sock] : room.peers) {
        const auto* pd = sock->getUserData();
        if (pid != peer && !pd->is_guest && !pd->is_fetch && aud.sees(pid)) out.push_back(pid);
    }
    out.push_back(peer);
    return out;
}

// `peer` is now seen in `room`, or no longer is: tell the other provers.
static void announce_door_change(const WsRoom& room, const Audience& aud, const std::string& room_name,
                                 const std::string& peer, const char* type) {
    std::string frame = json{{"type", type}, {"room", room_name}, {"peer_id", peer}}.dump();
    for (const auto& [pid, sock] : room.peers) {
        if (pid != peer && !sock->getUserData()->is_guest && aud.shares(pid, peer)) {
            send_to_peer(sock, frame, uWS::OpCode::TEXT);
        }
    }
}

// Ownership of an `inbox:{M}` join that shows a roster (design ID-1R): the roster is
// folded into the one held for M and this socket owns the inbox only if its device
// is a member of the result. A roster that does not parse, is too big or names
// another master proves nothing, silently, like a plain join.
static bool inbox_owner_by_roster(PerSocketData* data, const std::string& room,
                                  const json& roster_json, RelayState& state) {
    if (data->is_guest || !is_inbox_room(room)) return false;
    std::optional<roster::Roster> shown = roster::from_json(roster_json);
    // Measured as the relay would hold it, never by walking the client's own JSON again.
    if (!shown || roster::to_json(*shown).dump().size() > roster::MAX_ROSTER_BYTES) return false;
    const std::string master = room.substr(sizeof(INBOX_ROOM_PREFIX) - 1);
    RosterBook::Shown r = state.roster_book.show(master, *shown, data->peer_id, socket_share(state, data),
                                                 wall_now_ms(), relay_roster_crypto());
    if (r.changed) drop_inbox_owners(state, room, r.state);
    return r.member;
}

// `inbox_roster` (0.12) or `inbox_proof` (0.11) may be null: a plain JoinRoom
// carries neither. They are only consulted for an `inbox:` room, `door_proof`
// (empty = none) only for a door-locked server room.
static void handle_join(SSLWebSocket* ws, PerSocketData* data,
                         const std::string& room, RelayState& state,
                         const json* inbox_proof = nullptr,
                         const json* inbox_roster = nullptr,
                         const std::string& door_proof = std::string()) {
    if (!is_valid_room_code(room)) {
        send_json(ws, {{"type", "error"}, {"error", "Invalid room code"}});
        return;
    }

    auto pit = state.peer_rooms.find(data->peer_id);
    size_t max_rooms = data->is_guest ? MAX_GUEST_ROOMS : MAX_ROOMS_PER_PEER;
    size_t held_rooms = data->is_fetch ? data->fetch_rooms.size()
                        : (pit != state.peer_rooms.end() ? pit->second.size() : 0);
    if (held_rooms >= max_rooms) {
        send_json(ws, {{"type", "error"}, {"error", data->is_guest ? "Guest room limit reached" : "Too many rooms"}});
        return;
    }

    // A shown roster decides on its own; only a plain re-join keeps an owner an owner.
    const bool shown = inbox_roster != nullptr;
    const bool proved = shown ? inbox_owner_by_roster(data, room, *inbox_roster, state)
                              : (inbox_proof && inbox_owner_proved(data, room, *inbox_proof, state));

    auto& ws_room = state.ws_rooms[room];

    // A fetch socket is the device's own push isolate: it takes delivery for the
    // device only while no full socket of it holds the slot (the full node's slot
    // must survive the isolate's close), and it learns nothing about the room: no
    // roster, no presence, and nobody learns of it.
    if (data->is_fetch) {
        auto held = ws_room.peers.find(data->peer_id);
        bool full_holds = held != ws_room.peers.end() && held->second != ws &&
                          !held->second->getUserData()->is_fetch;
        if (!full_holds) {
            ws_room.peers[data->peer_id] = ws;
            data->fetch_rooms.insert(room);
            replay_buffered_msgs(ws, data->peer_id, room, /*full_node=*/false, state);
        }
        if (proved) {
            replay_mailbox_no_delete(ws, room.substr(sizeof(INBOX_ROOM_PREFIX) - 1), room, state);
        }
        return;
    }

    const bool inbox = is_inbox_room(room);
    // A socket that proved it once stays an owner through a plain re-join (the
    // client refreshes rooms without the proof); a new socket proves again.
    auto held_slot = ws_room.peers.find(data->peer_id);
    const bool already_owner = inbox && !shown && held_slot != ws_room.peers.end() && held_slot->second == ws &&
                               ws_room.owners.count(data->peer_id) != 0;
    const bool owner = inbox && (already_owner || proved);

    // A door-locked room: only a socket that proves the newest door sees it.
    const LockLink* lock = room_lock(state, room);
    const int64_t now_ms = steady_ms();
    const bool same_socket = held_slot != ws_room.peers.end() && held_slot->second == ws;
    bool saw_before = false;
    bool door_ok = true;
    if (lock) {
        saw_before = same_socket && ws_room.doors.sees(data->peer_id, now_ms);
        const std::string proof = data->is_guest ? std::string() : door_proof;
        const bool opens = !proof.empty() && door_opens(state, data, room, lock->door, proof);
        door_ok = ws_room.doors.join(data->peer_id, proof, opens, same_socket, now_ms);
    }
    const bool visible = (!inbox || owner) && door_ok;
    const Audience aud = audience(state, ws_room, room);

    // Collect existing non-guest peer IDs before adding. In an inbox room a
    // non-owner sees nobody and an owner sees only the other owners; in a locked
    // room the same holds for provers.
    std::vector<std::string> existing_peers;
    if (visible) {
        for (auto& [pid, peer_ws] : ws_room.peers) {
            auto* pd = peer_ws->getUserData();
            if (pid != data->peer_id && !pd->is_guest && !pd->is_fetch && aud.shares(pid, data->peer_id)) {
                existing_peers.push_back(pid);
            }
        }
    }

    // Was this peer already in the room BEFORE this join? A client re-joins a
    // room it never left (the PeerLeft "still listed → refreshing membership"
    // path fires a JoinRoom for every still-shared room). Re-broadcasting
    // peer_joined on those redundant joins re-fires the other side's full
    // discovery cascade (profile + key-exchange + sync), which — during a fresh
    // friend handshake's room churn — loops ~10x in seconds. Suppress the
    // broadcast on a redundant join; the joiner still gets its `members` reply
    // below for stale-membership reconciliation.
    // The device's own fetch socket holding the slot is not presence, and neither is
    // a socket the provers could not see until now.
    auto prev = ws_room.peers.find(data->peer_id);
    bool already_present = prev != ws_room.peers.end() && !prev->second->getUserData()->is_fetch &&
                           (!lock || saw_before);

    // Add peer to room
    ws_room.peers[data->peer_id] = ws;
    if (owner) {
        ws_room.owners.insert(data->peer_id);
    } else {
        ws_room.owners.erase(data->peer_id);
    }

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
    if (lock) members_msg["proved"] = door_ok;
    send_json(ws, members_msg);

    // Notify existing non-guest peers (skip if joiner is a guest or fetch-mode,
    // or if this is a redundant re-join — the peer was already in the room).
    if (!data->is_guest && !data->is_fetch && !already_present && visible) {
        announce_door_change(ws_room, aud, room, data->peer_id, "peer_joined");
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

    // ...and, IN ADDITION, the master's mailbox when this join proved it owns
    // one. Device-keyed replay above is unchanged and still deletes on
    // delivery; the mailbox replay is TTL-only.
    if (owner) {
        replay_mailbox_no_delete(ws, room.substr(sizeof(INBOX_ROOM_PREFIX) - 1), room, state);
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
                        SSLWebSocket* expected_ws = nullptr,
                        bool suppress_peer_left = false) {
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
    bool leaving_peer_invisible = is_invisible_in_room(state, peer_id, room) ||
                                  !audience(state, rit->second, room).sees(peer_id);

    rit->second.peers.erase(peer_id);
    rit->second.owners.erase(peer_id);
    rit->second.doors.leave(peer_id);

    bool should_notify = !rit->second.peers.empty();

    if (!should_notify) {
        state.ws_rooms.erase(rit);
    }

    auto pit = state.peer_rooms.find(peer_id);
    if (pit != state.peer_rooms.end()) {
        pit->second.erase(room);
    }

    if (suppress_peer_left && should_notify && !leaving_peer_invisible) {
        // The peer did NOT leave — a newer socket of the SAME peer_id is
        // authenticating right now and will re-join. Broadcasting peer_left
        // here is a lie that observers act on: clients tore down live media
        // branches on it (the ~85 s post-restart "ghost eviction" that the
        // client- and forwarder-side presence-flap tolerance had to defend
        // against). Erase the slot, stay silent; the successor's join
        // broadcasts peer_joined and refreshes the members snapshot.
        if (g_diag) g_diag->ghost_left_suppressed++;
    } else if (should_notify && !leaving_peer_invisible) {
        auto rit2 = state.ws_rooms.find(room);
        if (rit2 != state.ws_rooms.end()) {
            announce_door_change(rit2->second, audience(state, rit2->second, room), room, peer_id, "peer_left");
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

    // Shared secret for the loopback hop to the push sidecar. The sidecar holds
    // the Firebase Admin credential, so binding to 127.0.0.1 is a reachability
    // limit, not an authorization one: any local process could otherwise post
    // arbitrary tokens through it. Read once; empty (unset) sends no header and
    // the sidecar stays open, so either side can be deployed alone.
    static const std::string push_token = [] {
        const char* t = getenv("HOLLOW_PUSH_TOKEN");
        return t ? std::string(t) : std::string();
    }();

    std::string req = "POST /push HTTP/1.1\r\n"
                      "Host: 127.0.0.1\r\n"
                      "Content-Type: application/json\r\n";
    if (!push_token.empty()) {
        req += "X-Push-Token: " + push_token + "\r\n";
    }
    req += "Content-Length: " + std::to_string(payload.size()) + "\r\n"
           "Connection: close\r\n\r\n" + payload;

    send(fd, req.data(), req.size(), MSG_NOSIGNAL);
    char buf[128];
    recv(fd, buf, sizeof(buf), 0);
    close(fd);
}

PushQueue<PushJob> g_push_queue(PUSH_QUEUE_MAX, deliver_push);

} // namespace

// Enqueue a push for the persistent worker (fire-and-forget, off the event loop).
static void notify_push_sidecar(PushJob job) {
    g_push_queue.enqueue(std::move(job));
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

// Drop the frame `seq` wherever it sits, keeping every byte counter in step.
static void drop_frame(RelayState& state, uint64_t seq, const OfflineIndex::Loc& loc) {
    if (loc.is_topic) {
        auto it = state.topic_buffers.find(loc.key);
        if (it != state.topic_buffers.end()) {
            auto& tb = it->second;
            for (auto f = tb.frames.begin(); f != tb.frames.end(); ++f) {
                if (f->seq != seq) continue;
                tb.bytes -= std::min(tb.bytes, f->frame.size());
                tb.frames.erase(f);
                break;
            }
        }
    } else {
        auto it = state.offline_buffer.find(loc.key);
        if (it != state.offline_buffer.end()) {
            auto& q = it->second;
            for (auto m = q.begin(); m != q.end(); ++m) {
                if (m->seq != seq) continue;
                q.erase(m);
                break;
            }
            if (q.empty()) state.offline_buffer.erase(it);
        }
    }
    state.buffer_index.released(seq);
}

// Remove one ring, keeping the byte budget, the ring ledger and the per-server
// count in step. Returns the iterator past it.
static std::unordered_map<std::string, RelayState::TopicBuffer>::iterator
erase_topic_buffer(RelayState& state, std::unordered_map<std::string, RelayState::TopicBuffer>::iterator it) {
    for (const auto& f : it->second.frames) state.buffer_index.released(f.seq);
    auto c = state.topic_buffers_per_room.find(ring_auth::ring_namespace(it->first));
    if (c != state.topic_buffers_per_room.end()) {
        if (c->second <= 1) state.topic_buffers_per_room.erase(c);
        else c->second--;
    }
    state.ring_ledger.remove(it->first);
    return state.topic_buffers.erase(it);
}

// Global-budget eviction: the oldest frame of the address share holding the most,
// so a flood only ever evicts itself.
static void evict_over_budget(RelayState& state) {
    while (state.buffer_index.bytes() > MAX_BUFFER_TOTAL_BYTES) {
        auto victim = state.buffer_index.victim();
        if (!victim) break;
        drop_frame(state, victim->first, victim->second);
    }
}

void enforce_buffer_budget(RelayState& state) {
    evict_over_budget(state);
}

// NOTE: there is deliberately NO per-minute rate limit on the offline-buffer
// deposit paths. Rate limiting the relay silently drops messages and breaks CRDT
// sync — a reconnection burst (key exchange + SyncRequests + profiles to every
// offline friend at once) legitimately exceeds any threshold worth setting, and
// a channel post legitimately fans one frame per offline member. Buffer abuse is
// bounded by fair-share eviction below and in evict_over_budget (a flooder evicts
// only itself) plus the existing push debounce, none of which can drop a
// legitimate message. See feedback_relay_rules.

// Buffer an offline DM frame for later replay when the target joins its DM room.
// RAM only, ciphertext only. Capped per target (the address share holding the
// most slots pays first) and by the global byte budget. The target is a map key
// the sender typed, which is why every frame weighs its overhead too.
static void buffer_offline_msg(const std::string& target_peer_id,
                               const std::string& room,
                               std::string frame, RelayState& state,
                               const std::string& sender, uint64_t share,
                               bool is_image = false, bool is_channel = false) {
    auto& q = state.offline_buffer[target_peer_id];
    uint64_t seq = state.buffer_index.stamp(target_peer_id, false, share, frame.size());
    q.push_back({room, std::move(frame), sender, std::chrono::steady_clock::now(),
                 is_image, is_channel, seq, share});
    // Three independent caps: DM text, inlined-image and channel frames evict
    // separately so a chatty server never pushes out buffered DMs (and
    // vice-versa).
    auto count_kind = [&](bool img, bool chan) {
        size_t n = 0;
        for (const auto& m : q) if (m.is_image == img && m.is_channel == chan) n++;
        return n;
    };
    // FAIR-SHARE eviction: drop the oldest frame of whichever address share
    // occupies the most slots of this kind (among equals, the oldest frame),
    // instead of the globally oldest. With one sender this is plain oldest-first.
    // Under contention a flooder can only ever evict ITSELF, however many
    // throwaway identities it sends from: the defence against junk buffered at a
    // peer_id until every genuine message waiting there has been pushed out.
    //
    // Deliberately NOT a flat per-sender cap: the caps here are legitimately
    // reachable by ONE sender (100 baseline, 500 opted-in), so a fixed share
    // would silently truncate a real conversation with an offline friend.
    auto drop_oldest_kind = [&](bool img, bool chan) {
        std::unordered_map<uint64_t, size_t> counts;
        size_t most = 0;
        for (const auto& m : q) {
            if (m.is_image == img && m.is_channel == chan) most = std::max(most, ++counts[m.share]);
        }
        for (auto it = q.begin(); it != q.end(); ++it) {
            if (it->is_image == img && it->is_channel == chan && counts[it->share] == most) {
                state.buffer_index.released(it->seq);
                q.erase(it);
                return;
            }
        }
    };
    // Opted-in peers get the extended text/FileHeader window and a multi-image
    // window; the channel-push cap stays at the push baseline regardless.
    bool opted_in = state.offline_optin.count(target_peer_id) != 0;
    size_t text_cap = opted_in ? MAX_OPTIN_MSGS_PER_PEER : MAX_BUFFERED_MSGS_PER_PEER;
    size_t image_cap = opted_in ? MAX_OPTIN_IMAGES_PER_PEER : MAX_BUFFERED_IMAGES_PER_PEER;
    while (count_kind(false, false) > text_cap)                             drop_oldest_kind(false, false);
    while (count_kind(true, false)  > image_cap)                            drop_oldest_kind(true, false);
    while (count_kind(false, true)  > MAX_BUFFERED_CHANNEL_MSGS_PER_PEER)   drop_oldest_kind(false, true);
    evict_over_budget(state);
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
            state.buffer_index.released(m.seq);
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
// Opted-in peers keep text/FileHeader frames for their registered retention;
// inlined-image frames always expire at the 24h push baseline (no media bytes
// in the extended tier). Also sweeps topic buffers + idle registrations.
void sweep_offline_buffer(RelayState& state) {
    auto now = std::chrono::steady_clock::now();
    size_t evicted = 0;
    for (auto it = state.offline_buffer.begin(); it != state.offline_buffer.end(); ) {
        auto& q = it->second;
        int64_t retention = OFFLINE_BUFFER_TTL_SECS;
        auto oit = state.offline_optin.find(it->first);
        if (oit != state.offline_optin.end()) retention = oit->second;
        std::deque<RelayState::BufferedMsg> kept;
        for (auto& m : q) {
            auto age = std::chrono::duration_cast<std::chrono::seconds>(now - m.at).count();
            // Images never outlive the push baseline; channel-push copies and
            // text ride the peer's retention (default = baseline).
            int64_t ttl = m.is_image ? std::min<int64_t>(OFFLINE_BUFFER_TTL_SECS, retention) : retention;
            if (age >= ttl) {
                state.buffer_index.released(m.seq);
                evicted++;
            } else {
                kept.push_back(std::move(m));
            }
        }
        q = std::move(kept);
        if (q.empty()) {
            it = state.offline_buffer.erase(it);
        } else {
            ++it;
        }
    }
    // Topic ring buffers: retention expiry, then drop registrations no member has
    // refreshed for TOPIC_BUFFER_IDLE_EXPIRE_SECS. A frame keeps the shorter of the
    // ring's retention now and the one it arrived under, so frames can expire out
    // of order and the whole ring is walked.
    for (auto it = state.topic_buffers.begin(); it != state.topic_buffers.end(); ) {
        auto& tb = it->second;
        for (auto f = tb.frames.begin(); f != tb.frames.end(); ) {
            auto age = std::chrono::duration_cast<std::chrono::seconds>(now - f->at).count();
            int64_t keep = f->retention_secs > 0 ? std::min(tb.retention_secs, f->retention_secs)
                                                 : tb.retention_secs;
            if (age >= keep) {
                tb.bytes -= std::min(tb.bytes, f->frame.size());
                state.buffer_index.released(f->seq);
                f = tb.frames.erase(f);
                evicted++;
            } else {
                ++f;
            }
        }
        // A cleared registration that has finished draining is done — reap it
        // now rather than holding an empty slot until the 7-day idle expiry.
        auto idle = std::chrono::duration_cast<std::chrono::seconds>(
            now - tb.last_registered).count();
        if ((!tb.accepting && tb.frames.empty()) || idle >= TOPIC_BUFFER_IDLE_EXPIRE_SECS) {
            it = erase_topic_buffer(state, it);
        } else {
            ++it;
        }
    }
    if (evicted > 0) {
        fprintf(stderr, "[push] Swept %zu expired buffered msg(s)\n", evicted);
    }
}

void sweep_kill_list(RelayState& state) {
    state.kill_list.sweep(std::chrono::steady_clock::now());
}

void sweep_door_grace(RelayState& state) {
    const int64_t now_ms = steady_ms();
    for (auto it = state.door_grace_rooms.begin(); it != state.door_grace_rooms.end();) {
        auto rit = state.ws_rooms.find(*it);
        if (rit == state.ws_rooms.end()) {
            it = state.door_grace_rooms.erase(it);
            continue;
        }
        const std::string& room = rit->first;
        WsRoom& r = rit->second;
        const Audience aud = audience(state, r, room);
        // A lock gone from the relay leaves the room open: nobody to hide anyone from.
        for (const auto& peer : r.doors.expire(now_ms)) {
            auto pit = r.peers.find(peer);
            if (!aud.locked || pit == r.peers.end()) continue;
            announce_door_change(r, aud, room, peer, "peer_left");
            send_json(pit->second, {{"type", "members"}, {"room", room}, {"peers", json::array({peer})}, {"proved", false}});
        }
        it = r.doors.in_grace() ? std::next(it) : state.door_grace_rooms.erase(it);
    }
}

// Muted DM senders ride the reserved `~dm` server-pref entry (sender device
// id -> "nothing"), so the snapshot codec and set_push_prefs stay unchanged.
static const char* DM_MUTE_PREF_KEY = "~dm";

static bool dm_push_muted(const std::string& target_peer_id,
                          const std::string& sender_peer_id, const RelayState& state) {
    auto pit = state.push_prefs.find(target_peer_id);
    if (pit == state.push_prefs.end()) return false;
    auto dit = pit->second.find(DM_MUTE_PREF_KEY);
    if (dit == pit->second.end()) return false;
    auto sit = dit->second.channels.find(sender_peer_id);
    return sit != dit->second.channels.end() && sit->second == "nothing";
}

static void try_push_notify(const std::string& target_peer_id,
                            const std::string& sender_peer_id, RelayState& state) {
    auto tok_it = state.push_tokens.find(target_peer_id);
    if (tok_it == state.push_tokens.end()) {
        return;
    }
    // Only the wake-up is skipped; the deposit is already buffered.
    if (dm_push_muted(target_peer_id, sender_peer_id, state)) return;

    auto now = std::chrono::steady_clock::now();
    auto& last = state.last_push_sent[target_peer_id];
    if ((now - last) < std::chrono::seconds(PUSH_DEBOUNCE_SECS)) {
        return;
    }

    // Rolling hourly ceiling (RELAY-7). The debounce bounds the rate but not
    // the total, so a sender pacing itself at one frame every ten seconds could
    // keep a phone awake all night. 30 wake-ups an hour is generous for what a
    // push is FOR: the woken device connects and drains everything waiting, so
    // every wake-up after the first says nothing new until it goes offline
    // again — and pushes only fire for a target that is offline to begin with.
    //
    // Over budget the DEPOSIT IS ALREADY BUFFERED (every caller buffers before
    // it pushes); only the wake-up is skipped. Nothing is dropped, it just
    // arrives when the device next connects.
    auto& budget = state.push_budget[target_peer_id];
    if (budget.count == 0 ||
        (now - budget.window_start) >= std::chrono::seconds(PUSH_BUDGET_WINDOW_SECS)) {
        budget.window_start = now;
        budget.count = 0;
    }
    if (budget.count >= MAX_PUSH_WAKEUPS_PER_HOUR) return;
    budget.count++;

    last = now;

    // No logging of push routing — target/sender peer_ids are social-graph metadata.
    notify_push_sidecar(tok_it->second.token, tok_it->second.platform, sender_peer_id);
}

// Charge what `peer` has registered to `share` (fair_share.h), or forget it when
// nothing is left; past the budget the heaviest share's least recently refreshed
// identity loses every registration it holds.
static void charge_registrations(RelayState& state, const std::string& peer, uint64_t share) {
    size_t weight = 0;
    if (auto t = state.push_tokens.find(peer); t != state.push_tokens.end()) {
        weight += t->second.token.size() + t->second.platform.size();
    }
    if (auto p = state.push_prefs.find(peer); p != state.push_prefs.end()) {
        for (const auto& [server, pref] : p->second) {
            weight += 96 + server.size() + pref.level.size();
            for (const auto& [cid, level] : pref.channels) weight += 96 + cid.size() + level.size();
        }
    }
    const bool opted_in = state.offline_optin.count(peer) != 0;
    if (weight == 0 && !opted_in && state.push_tokens.count(peer) == 0 && state.push_prefs.count(peer) == 0) {
        state.registrations.remove(peer);
        return;
    }
    state.registrations.put(peer, share, 256 + weight);
    while (state.registrations.total() > MAX_REGISTRATION_BYTES) {
        auto victim = state.registrations.victim();
        if (!victim) break;
        state.push_tokens.erase(*victim);
        state.push_prefs.erase(*victim);
        state.offline_optin.erase(*victim);
        state.channel_push_state.erase(*victim);
        state.last_channel_push_any.erase(*victim);
        state.registrations.remove(*victim);
    }
}

void restore_registration(RelayState& state, const std::string& peer, uint64_t share) {
    charge_registrations(state, peer, share);
}

static bool is_push_platform(const std::string& platform) {
    return platform == "android" || platform == "ios" || platform == "unifiedpush";
}

static void handle_register_push_token(SSLWebSocket* ws, PerSocketData* data,
                                        const std::string& token, const std::string& platform,
                                        RelayState& state) {
    if (data->is_guest || token.empty() || token.size() > MAX_PUSH_TOKEN_BYTES) return;
    if (!is_push_platform(platform)) return;
    state.push_tokens[data->peer_id] = { token, platform };
    charge_registrations(state, data->peer_id, socket_share(state, data));
    send_json(ws, {{"type", "push_token_registered"}});
    // No logging — associating a peer_id with a push token is sensitive.
}

// Drop a peer's push token (wipe step 5). No reply: the caller is on its way
// out and must not wait on the relay.
static void handle_unregister_push_token(PerSocketData* data, RelayState& state) {
    if (data->is_guest) return;
    state.push_tokens.erase(data->peer_id);
    charge_registrations(state, data->peer_id, socket_share(state, data));
    // No logging - associating a peer_id with a push token is sensitive.
}

// Whether a parked order is the identity's own (kill_order.h), judged once per
// deposit against the roster the relay holds for its master.
struct KillProof {
    std::optional<kill_order::Order> order;
    const roster::Roster* held = nullptr;
    bool authorised = false;
};

static KillProof judge_kill_blob(const std::string& blob, int64_t issued_at_ms, RelayState& state) {
    KillProof p;
    std::string text;
    if (!base64_decode(blob, text)) return p;
    p.order = kill_order::parse(text);
    if (!p.order) return p;
    const auto* held = state.roster_book.get(p.order->master_peer_id);
    if (!held || held->roster.r_pub.empty()) return p;
    p.held = &held->roster;
    roster::State members;
    if (p.order->delegation) members = state.roster_book.fold(*held, wall_now_ms(), relay_roster_crypto());
    p.authorised = kill_order::authorised(*p.order, issued_at_ms, held->roster, members, relay_roster_crypto(),
                                          derive_peer_id);
    return p;
}

// Park a destroy signal for devices that are not connected. An order the target
// identity's phrase stands behind takes the target's proven slot; any other blob
// is opaque, and the target judges it itself, so a forged deposit dies there.
//
// Fields are type-checked rather than read through value(), which throws on a
// type it did not expect.
static void handle_kill_deposit(SSLWebSocket* ws, PerSocketData* data, const json& j,
                                RelayState& state) {
    if (data->is_guest) return;
    // A fetch socket is a push isolate: it receives signals, it never issues.
    if (data->is_fetch) return;

    auto blob_it = j.find("blob");
    if (blob_it == j.end() || !blob_it->is_string()) return;
    const std::string& blob = blob_it->get_ref<const std::string&>();
    if (blob.empty() || blob.size() > KillList::MAX_BLOB_BYTES) return;

    auto issued_it = j.find("issued_at_ms");
    if (issued_it == j.end() || !issued_it->is_number_integer()) return;
    int64_t issued_at_ms = issued_it->get<int64_t>();
    if (issued_at_ms <= 0) return;

    auto targets_it = j.find("targets");
    if (targets_it == j.end() || !targets_it->is_array()) return;

    auto now = std::chrono::steady_clock::now();
    const int64_t now_wall_ms = static_cast<int64_t>(now_unix_secs()) * 1000;
    const uint64_t share = socket_share(state, data);
    const KillProof proof = judge_kill_blob(blob, issued_at_ms, state);
    size_t stored = 0, seen = 0;
    for (const auto& t : *targets_it) {
        if (++seen > KillList::MAX_TARGETS_PER_DEPOSIT) break;
        if (!t.is_string()) continue;
        const std::string& target = t.get_ref<const std::string&>();
        // The target is a map KEY, so it must be a peer id and not free text.
        if (!is_peer_id_shape(target)) continue;
        const bool ok = proof.authorised && kill_order::reaches(*proof.order, target, *proof.held)
                            ? state.kill_list.deposit_proven(target, data->peer_id, share, blob, issued_at_ms, now,
                                                             now_wall_ms)
                            : state.kill_list.deposit(target, data->peer_id, share, blob, issued_at_ms, now,
                                                      now_wall_ms);
        if (ok) stored++;
    }
    send_json(ws, {{"type", "kill_deposited"}, {"stored", stored}});
    // No logging - the targets of a destroy are the social graph of an identity.
}

// The crypto the join lock rules read (join_lock.h), wired to libsodium.
static const LockCrypto& lock_crypto() {
    static const LockCrypto crypto{
        [](const std::string& key, const std::string& sig, const std::string& msg) { return verify_ed25519(key, sig, msg); },
        [](const std::string& key) { return derive_peer_id(key); },
        [](const std::string& owner, const std::string& nonce) { return genesis_server_id(owner, nonce); },
    };
    return crypto;
}

// A (server, owner) pair as a record key: an id of the server shape, and an owner
// that is a peer id (or none, for an id that names its owner itself).
static bool lock_key_shape(const std::string& server, const std::string& owner) {
    return join_lock::is_server_id_shape(server) && (owner.empty() || is_peer_id_shape(owner));
}

static std::string json_text(const json& j, const char* field) {
    auto it = j.find(field);
    return it != j.end() && it->is_string() ? it->get<std::string>() : std::string();
}

// The chains of up to 256 servers, one `lock_chain` each (empty when none). Anyone
// authenticated may read one: a joiner is not a member yet, and a chain holds
// nothing but public halves the server's invites already imply.
static void handle_lock_get(SSLWebSocket* ws, PerSocketData* data, const json& j, RelayState& state) {
    if (data->is_guest) return;
    auto locks = j.find("locks");
    if (locks == j.end() || !locks->is_array()) return;
    size_t seen = 0;
    for (const auto& e : *locks) {
        if (++seen > 256) break;
        if (!e.is_object()) continue;
        std::string server = json_text(e, "server");
        std::string owner = json_text(e, "owner");
        if (!lock_key_shape(server, owner)) continue;
        const auto* chain = state.join_locks.get(join_lock::record_key(server, owner));
        send_json(ws, {{"type", "lock_chain"},
                       {"server", server},
                       {"owner", owner},
                       {"links", join_lock::links_to_json(chain ? *chain : std::vector<LockLink>{})}});
    }
}

// The newest door of `room` changed, or the room just became locked. A socket whose
// stored proof opens the new door proves at once; everyone else who could see keeps
// seeing for the grace, so the op handing out the new door still reaches them.
static void relock_room(RelayState& state, const std::string& room, bool was_locked) {
    auto rit = state.ws_rooms.find(room);
    const LockLink* lock = room_lock(state, room);
    if (rit == state.ws_rooms.end() || !lock) return;
    WsRoom& r = rit->second;
    std::vector<std::string> peers;
    for (const auto& [pid, sock] : r.peers) {
        const auto* pd = sock->getUserData();
        if (!pd->is_guest && !pd->is_fetch) peers.push_back(pid);
    }
    const std::string door = lock->door;
    auto opens = [&](const std::string& peer, const std::string& proof) {
        auto pit = r.peers.find(peer);
        return pit != r.peers.end() && door_opens(state, pit->second->getUserData(), room, door, proof);
    };
    auto newly = r.doors.relock(peers, was_locked, opens, steady_ms());
    if (r.doors.in_grace()) state.door_grace_rooms.insert(room);
    const Audience aud = audience(state, r, room);
    for (const auto& peer : newly) {
        send_json(r.peers[peer], {{"type", "members"}, {"room", room}, {"peers", roster_for(r, aud, peer)}, {"proved", true}});
        announce_door_change(r, aud, room, peer, "peer_joined");
    }
}

// Offer a chain, or the next links of one. The relay takes it only by the rules in
// join_lock.h, charged to this socket's address share, and answers with the chain
// it holds either way.
static void handle_lock_put(SSLWebSocket* ws, PerSocketData* data, const json& j, RelayState& state) {
    if (data->is_guest || data->is_fetch) return;
    std::string server = json_text(j, "server");
    std::string owner = json_text(j, "owner");
    if (!lock_key_shape(server, owner)) return;
    auto links_it = j.find("links");
    if (links_it == j.end()) return;
    auto links = join_lock::links_from_json(*links_it);
    if (!links) return;
    const LockLink* before = room_lock(state, server);
    const std::string old_door = before ? before->door : std::string();
    std::vector<LockLink> current;
    bool accepted = state.join_locks.put(server, owner, *links, lock_crypto(), current, socket_share(state, data));
    const LockLink* after = room_lock(state, server);
    if (after && (!before || after->door != old_door)) relock_room(state, server, before != nullptr);
    send_json(ws, {{"type", "lock_chain"},
                   {"server", server},
                   {"owner", owner},
                   {"links", join_lock::links_to_json(current)},
                   {"put", accepted}});
}

// The only removal a client can ask for, and always its own: the one signal it
// turned away, named by issuer and stamp, or every one after its wipe (a bare ack,
// which 0.11 clients also send). An ack naming half a signal answers nothing, since
// a stamp alone cannot tell junk from the order sharing it.
static void handle_kill_ack(PerSocketData* data, const json& j, RelayState& state) {
    auto issued_it = j.find("issued_at_ms");
    auto issuer_it = j.find("issuer");
    if (issued_it == j.end() && issuer_it == j.end()) {
        state.kill_list.ack(data->peer_id);
        return;
    }
    if (issued_it == j.end() || issuer_it == j.end() || !issued_it->is_number_integer() || !issuer_it->is_string()) {
        return;
    }
    state.kill_list.ack(data->peer_id, issuer_it->get_ref<const std::string&>(), issued_it->get<int64_t>());
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
        // `~dm` is the reserved entry for muted DM senders (DM_MUTE_PREF_KEY).
        if (server != "~dm" && !is_valid_room_code(server)) continue;
        RelayState::ServerPushPref p;
        p.level = val.value("level", "all");
        if (p.level != "all" && p.level != "mentions" && p.level != "nothing") p.level = "all";
        if (val.contains("channels") && val["channels"].is_object()) {
            size_t chan_count = 0;
            for (auto& [cid, lv] : val["channels"].items()) {
                if (++chan_count > 1024) break;  // defensive cap
                if (!lv.is_string() || cid.empty() || cid.size() > 128) continue;
                const std::string& s = lv.get_ref<const std::string&>();
                if (s == "all" || s == "mentions" || s == "nothing") p.channels[cid] = s;
            }
        }
        prefs[server] = std::move(p);
    }
    state.push_prefs[data->peer_id] = std::move(prefs);
    charge_registrations(state, data->peer_id, socket_share(state, data));
    // No logging — peer_id + server set is membership metadata.
}

// Opt-in offline delivery registration (RAM only — the app re-sends this on
// every connect, like push prefs). Presence in offline_optin = opted in:
// bigger DM text/FileHeader window + user-chosen retention.
static void handle_set_offline_buffer(PerSocketData* data, const json& j, RelayState& state) {
    if (data->is_guest) return;
    if (!j.value("enabled", false)) {
        state.offline_optin.erase(data->peer_id);
        charge_registrations(state, data->peer_id, socket_share(state, data));
        return;
    }
    int64_t retention = j.value("retention_secs", OFFLINE_BUFFER_TTL_SECS);
    retention = std::max(OFFLINE_RETENTION_MIN_SECS,
                         std::min(OFFLINE_RETENTION_MAX_SECS, retention));
    state.offline_optin[data->peer_id] = retention;
    charge_registrations(state, data->peer_id, socket_share(state, data));
    // No logging — opt-in status per peer_id is user metadata.
}

// User report: one per (reporter, target, category), deduped via fingerprints
// keyed by a relay secret kept outside the reports file, so the file alone
// cannot confirm who reported whom; only per-target category totals are
// readable (e.g. for restricting relay access).
// Ack is sent even on dedup: from the client's view the report "is filed".
static void handle_report(SSLWebSocket* ws, PerSocketData* data, const json& j,
                          RelayState& state) {
    if (data->is_guest) return;
    std::string target = j.value("target", "");
    std::string category = j.value("category", "");
    // The target is persisted (hashed for dedup, in the clear for the per-target
    // counts), so it must be a peer id and not free-form text.
    if (!is_peer_id_shape(target) || target == data->peer_id) return;
    if (category != "spam" && category != "harassment" &&
        category != "illegal_content" && category != "impersonation") return;
    state.reports.add(data->peer_id, target, category);
    send_json(ws, {{"type", "report_ack"}});
    // No logging — reporter/target peer ids are user-identifying.
}

// Pre-0.12 members register rings unsigned. Turn this off once 0.12 is out: from
// then on only the server's authority (ring_auth.h) creates, extends or stops a ring,
// and an unsigned request only keeps existing rings from idling out.
#ifndef HOLLOW_ACCEPT_UNSIGNED_RING_CONTROL
#define HOLLOW_ACCEPT_UNSIGNED_RING_CONTROL 1
#endif
static constexpr bool ACCEPT_UNSIGNED_RING_CONTROL = HOLLOW_ACCEPT_UNSIGNED_RING_CONTROL;

// A new ring for `key` charged to `share`, within its server's cap. Past the
// relay-wide cap the share that created the most rings loses its least recently
// used one: refusing would let whoever filled the table first keep every new
// server from getting a ring.
static RelayState::TopicBuffer* create_topic_buffer(RelayState& state, const std::string& key, uint64_t share) {
    const std::string ns = ring_auth::ring_namespace(key);
    auto count = state.topic_buffers_per_room.find(ns);
    if (count != state.topic_buffers_per_room.end() && count->second >= MAX_TOPIC_BUFFERS_PER_ROOM) return nullptr;
    while (state.topic_buffers.size() >= MAX_TOPIC_BUFFERS_TOTAL) {
        auto victim = state.ring_ledger.victim();
        if (!victim) break;
        auto it = state.topic_buffers.find(*victim);
        if (it == state.topic_buffers.end()) {
            state.ring_ledger.remove(*victim);
            continue;
        }
        erase_topic_buffer(state, it);
    }
    auto& tb = state.topic_buffers[key];
    state.ring_ledger.put(key, share, 1);
    state.topic_buffers_per_room[ns]++;
    return &tb;
}

// Apply a control the caller is entitled to: stop every ring whose key starts with
// `scope` (the room, or in a legacy room the signing owner's topics), or create and
// set the listed ones.
static void apply_ring_control(RelayState& state, const ring_auth::Control& c, const std::string& scope,
                               uint64_t share) {
    if (c.clear) {
        // Turning catch-up off STOPS retention; what is held ages out on the normal
        // sweep within OFFLINE_RETENTION_MIN_SECS rather than vanishing on demand.
        for (auto& [key, tb] : state.topic_buffers) {
            if (key.rfind(scope, 0) == 0) {
                tb.accepting = false;
                tb.retention_secs = OFFLINE_RETENTION_MIN_SECS;
            }
        }
        return;
    }
    std::string prefix = c.room;
    prefix.push_back('\0');
    int64_t retention = std::max(OFFLINE_RETENTION_MIN_SECS, std::min(OFFLINE_RETENTION_MAX_SECS, c.retention_secs));
    auto now = std::chrono::steady_clock::now();
    size_t n = 0;
    for (const auto& cid : c.channels) {
        if (++n > MAX_TOPIC_CHANNELS_PER_CALL) break;
        if (!ring_auth::is_channel_shape(cid)) continue;
        std::string key = prefix + cid;
        auto it = state.topic_buffers.find(key);
        RelayState::TopicBuffer* tb = it != state.topic_buffers.end() ? &it->second
                                                                      : create_topic_buffer(state, key, share);
        if (!tb) continue;
        // A longer retention applies to frames from now on (TopicFrame::retention_secs).
        tb->retention_secs = retention;
        tb->last_registered = now;
        tb->accepting = true;
        state.ring_ledger.touch(key);
    }
}

// Register, set or stop a server room's catch-up rings (ring_auth.h), or, unsigned,
// keep the room's existing rings from idling out.
// {"type":"set_topic_buffer","room":..,"owner":..,"channels":[..],"retention_secs":N,
//  "clear":bool,"ts":ms,"sig":..}
static void handle_set_topic_buffer(PerSocketData* data, const json& j, RelayState& state) {
    if (data->is_guest || data->is_fetch) return;
    ring_auth::Control c;
    bool is_signed = false;
    if (!ring_auth::parse(j, c, is_signed)) return;
    if (!is_valid_room_code(c.room)) return;
    // Must actually be in the room.
    auto rit = state.ws_rooms.find(c.room);
    if (rit == state.ws_rooms.end() || !rit->second.peers.count(data->peer_id)) return;
    std::string prefix = c.room;
    prefix.push_back('\0');

    if (is_signed) {
        if (!join_lock::is_server_id_shape(c.room)) return;
        const bool genesis = join_lock::is_genesis_id(c.room);
        if (!genesis && !is_peer_id_shape(c.owner)) return;
        const auto* chain = state.join_locks.get(join_lock::record_key(c.room, c.owner));
        const int64_t now_ms = static_cast<int64_t>(
            std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count());
        if (!ring_auth::authorized(c, chain, now_ms, lock_crypto())) return;
        apply_ring_control(state, c, prefix + ring_auth::topic_prefix(c.room, c.owner), socket_share(state, data));
        return;
    }

    if (ACCEPT_UNSIGNED_RING_CONTROL) {
        apply_ring_control(state, c, prefix, socket_share(state, data));
        return;
    }
    auto now = std::chrono::steady_clock::now();
    size_t n = 0;
    for (const auto& cid : c.channels) {
        if (++n > MAX_TOPIC_CHANNELS_PER_CALL) break;
        auto it = state.topic_buffers.find(prefix + cid);
        if (it != state.topic_buffers.end() && it->second.accepting) {
            it->second.last_registered = now;
            state.ring_ledger.touch(it->first);
        }
    }
    // No logging — room + channel set is membership metadata.
}

// Replay one channel's buffered ring to the requesting room member. Frames
// are the same 0x08 fan-out frames a live subscriber would have received —
// the client runs its normal verify/dedup/merge path, so replay is
// idempotent with peer sync. Nothing is deleted here: retention owns
// deletion, and the next late joiner needs the same frames.
static void handle_topic_catchup(SSLWebSocket* ws, PerSocketData* data,
                                 const json& j, RelayState& state) {
    if (data->is_guest) return;
    std::string room = j.value("room", "");
    std::string channel = j.value("channel", "");
    if (room.empty() || channel.empty()) return;
    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end() || !rit->second.peers.count(data->peer_id)) return;
    // A ring names who wrote what, when: only for those who see the room.
    if (!audience(state, rit->second, room).sees(data->peer_id)) return;
    std::string key = room;
    key.push_back('\0');
    key += channel;
    auto it = state.topic_buffers.find(key);
    if (it != state.topic_buffers.end()) {
        // Age filter: the client passes its channel watermark age (+lookback) so
        // frames it already holds aren't re-replayed every session. 0 = all.
        int64_t max_age = j.value("max_age_secs", (int64_t)0);
        auto now = std::chrono::steady_clock::now();
        for (const auto& f : it->second.frames) {
            if (f.sender == data->peer_id) continue;  // never echo own frames
            if (max_age > 0) {
                auto age = std::chrono::duration_cast<std::chrono::seconds>(now - f.at).count();
                if (age > max_age) continue;
            }
            send_to_peer(ws, f.frame, uWS::OpCode::BINARY);
        }
    }
    // Asked for, the end of the replay is marked behind its last frame, an empty or
    // missing ring included; a client that never asks never sees this frame type.
    auto end = j.find("end");
    if (end != j.end() && end->is_boolean() && end->get<bool>()) {
        send_json(ws, {{"type", "topic_catchup_done"}, {"room", room}, {"channel", channel}});
    }
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

    auto& per_server = state.channel_push_state[target];
    if (per_server.size() >= MAX_PUSH_SERVERS_PER_TARGET && per_server.count(server) == 0) {
        auto oldest = per_server.begin();
        for (auto it = per_server.begin(); it != per_server.end(); ++it) {
            if (it->second.last < oldest->second.last) oldest = it;
        }
        per_server.erase(oldest);
    }
    auto& cps = per_server[server];
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

    // The target becomes an offline_buffer KEY below, so it must be a real
    // peer id and not whatever the sender felt like typing (RELAY-1). Dropped
    // in silence: a well-formed client never sends one of these.
    if (!is_peer_id_shape(target_str)) return;
    if (!fwd_room::paired(room_str, data->peer_id, target_str)) return;

    // Sender must actually be in the server room it claims to post to, and see it: a
    // socket a locked room hides may be anyone holding the server id.
    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) return;
    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;
    const Audience aud = audience(state, rit->second, room_str);
    if (!aud.sees(data->peer_id)) return;

    // Buffer whenever the target is NOT in the server room — a member who IS
    // in the room already got the topic broadcast. Mirrors the 0x04 DM fix for
    // the auth→join race (and the ghost-socket window after a hard quit):
    // "connected" per peer_sockets does NOT mean the member received the room
    // broadcast, and the old full-return here silently dropped the copy.
    // A member hidden by a locked room missed the broadcast too.
    bool in_room = rit->second.peers.find(target_str) != rit->second.peers.end() && aud.sees(target_str);
    bool fully_offline = state.peer_sockets.find(target_str) == state.peer_sockets.end();
    if (in_room) return;

    // No per-minute gate here on purpose: one channel post legitimately fans
    // one 0x09 frame per OFFLINE member, so a flat cap would silently drop
    // delivery for large servers. Abuse is bounded per target instead — the
    // channel cap in buffer_offline_msg, which evicts from the heaviest hashed
    // address share (socket_share), plus the channel push debounce below.
    if (!payload.empty()) {
        buffer_offline_msg(target_str, room_str,
                           build_direct_frame(room_code, data->peer_id, payload), state,
                           data->peer_id, socket_share(state, data),
                           /*is_image=*/false, /*is_channel=*/true);
    }
    // Push only for FULLY offline targets (a live socket needs no wake).
    if (fully_offline) {
        try_channel_push_notify(target_str, data->peer_id, room_str,
                                std::string(channel), mention, state);
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
    const Audience aud = audience(state, rit->second, room);
    for (auto& [pid, peer_ws] : rit->second.peers) {
        if (pid != data->peer_id && aud.shares(pid, data->peer_id)) {
            send_to_peer(peer_ws, broadcast_str, uWS::OpCode::TEXT);
        }
    }
}

static void handle_direct(PerSocketData* data, const std::string& room,
                           const std::string& target, const std::string& msg_data,
                           RelayState& state) {
    // The JSON twin of 0x04, refused to guests like the binary form: a deposit
    // wakes the target's phone.
    if (data->is_guest) return;
    // The target becomes an offline_buffer KEY on the miss path below.
    if (!is_peer_id_shape(target)) return;
    if (!fwd_room::paired(room, data->peer_id, target)) return;

    auto rit = state.ws_rooms.find(room);
    if (rit == state.ws_rooms.end()) return;

    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) {
        // privacy: no connection logging
        return;
    }

    auto tit = rit->second.peers.find(target);
    if (tit != rit->second.peers.end() && !audience(state, rit->second, room).reachable(target)) return;
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
                           build_direct_frame(room, data->peer_id, msg_data), state,
                           data->peer_id, socket_share(state, data));
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

// NOTE: opcode 0x01 (legacy raw 32-byte-room binary broadcast) was REMOVED.
// It forwarded an attacker-chosen frame to every peer of any room whose code
// the sender knew, with NO membership check at all — the only handler here
// that never verified the sender belonged to the room it posted to. No client
// has sent 0x01 since room codes became strings; live room broadcast is 0x03
// (handle_binary_msg) and topic fan-out is 0x07, both membership-gated.

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

    std::string room_str(room_code);
    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) return;

    // The sender must be in the room it claims to send through. Without this
    // any authenticated peer who learned a room code could push binary directs
    // at that room's members without ever joining — the same gate 0x03/0x04/
    // 0x07/0x09 already apply. privacy: no rejection logging.
    if (rit->second.peers.find(data->peer_id) == rit->second.peers.end()) return;

    std::string target_str(target_peer);
    // Nothing is stored on this path, but the id is still attacker-supplied and
    // names who the frame is forwarded to — hold it to the same shape.
    if (!is_peer_id_shape(target_str)) return;
    if (!fwd_room::paired(room_str, data->peer_id, target_str)) return;
    auto tit = rit->second.peers.find(target_str);
    if (tit == rit->second.peers.end()) return;
    if (!audience(state, rit->second, room_str).reachable(target_str)) return;

    // Build forwarded frame: replace target with sender
    std::string forwarded;
    forwarded.reserve(1 + room_code.size() + 1 + data->peer_id.size() + 1 + payload.size());
    forwarded.push_back(0x02);
    forwarded.append(room_code);
    forwarded.push_back(0x00);
    forwarded.append(data->peer_id);
    forwarded.push_back(0x00);
    forwarded.append(payload);

    send_to_peer(tit->second, forwarded, uWS::OpCode::BINARY);
}

// 0x03 reaches whoever sees the room; 0x0A (`to_all`) is a public frame, which a
// prover's send also hands to everyone a locked room hides (guests reading public
// channels). Both arrive as 0x05.
static void handle_binary_msg(PerSocketData* data,
                               std::string_view raw, RelayState& state, bool to_all = false) {
    // Parse: [0x03 or 0x0A][room\0][payload]
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

    const Audience aud = audience(state, rit->second, room_str);
    const bool public_frame = to_all && aud.locked && aud.sees(data->peer_id);
    for (auto& [pid, peer_ws] : rit->second.peers) {
        if (pid != data->peer_id && (public_frame || aud.shares(pid, data->peer_id))) {
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

    // This is the widest deposit primitive on the relay (see the branch below:
    // an empty room means there is no membership to check the sender against),
    // and the target string becomes the offline_buffer KEY verbatim. Before
    // this, that key space was "anything an authenticated peer cares to type" —
    // the RELAY-1 memory-growth primitive. Silent drop, no reply, no log.
    if (!is_peer_id_shape(target_str)) return;
    // In a forwarder's room, live or deposited, only the forwarder and one member.
    if (!fwd_room::paired(room_str, data->peer_id, target_str)) return;

    auto rit = state.ws_rooms.find(room_str);
    if (rit == state.ws_rooms.end()) {
        // Room doesn't exist — target is offline. Buffer the message for replay
        // when they wake up, then fire a push.
        //
        // Nobody is in this room, INCLUDING the sender, so there is no
        // membership to verify against: any authenticated peer can reach this
        // branch with any room code and any target peer_id. That is deliberate
        // (a first DM to an offline peer legitimately has no live room), but it
        // makes this the widest deposit primitive on the relay. It carries the
        // per-target caps, which evict from the heaviest hashed address share
        // (socket_share), and the push budget, no rate limit (see
        // buffer_offline_msg). The frame itself is ciphertext the target's
        // client verifies and drops if unwanted.
        if (state.peer_sockets.find(target_str) == state.peer_sockets.end()) {
            buffer_offline_msg(target_str, room_str,
                               build_direct_frame(room_code, data->peer_id, payload), state,
                               data->peer_id, socket_share(state, data), is_image);
            try_push_notify(target_str, data->peer_id, state);
            if (!g_forwarder_peer_id.empty() && target_str == g_forwarder_peer_id) {
                state.diag.fwd_buffered++;
            }
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
                           data->peer_id, socket_share(state, data), is_image);
        if (fully_offline) {
            try_push_notify(target_str, data->peer_id, state);
        }
        // A CONNECTED forwarder missing from its own fwd room = the silent
        // blackhole shape (frames buffer, the long-lived socket never
        // re-joins, nothing replays). The counter is the smoking gun.
        if (!g_forwarder_peer_id.empty() && target_str == g_forwarder_peer_id) {
            state.diag.fwd_buffered++;
        }
        // A deposit for the inbox's own master also reaches its owners online
        // now: nobody else learns which devices those are, so the depositor
        // cannot address them itself.
        if (room_str == std::string(INBOX_ROOM_PREFIX) + target_str) {
            std::string live = build_direct_frame(room_code, data->peer_id, payload);
            for (const auto& owner_id : rit->second.owners) {
                auto oit = rit->second.peers.find(owner_id);
                if (owner_id != data->peer_id && oit != rit->second.peers.end()) {
                    send_to_peer(oit->second, live, uWS::OpCode::BINARY);
                }
            }
        }
        return;
    }
    if (!audience(state, rit->second, room_str).reachable(target_str)) return;

    if (!g_forwarder_peer_id.empty() && target_str == g_forwarder_peer_id) {
        state.diag.fwd_delivered++;
    }
    send_to_peer(tit->second, build_direct_frame(room_code, data->peer_id, payload),
                 uWS::OpCode::BINARY);
}

// Replace a room's topic filter. A set that would pass either per-socket cap is
// dropped instead, leaving the room unfiltered: more frames, never fewer.
static void handle_subscribe(PerSocketData* data, const std::string& room,
                              const json& topics_arr) {
    if (!data->authenticated || !is_valid_room_code(room)) return;
    if (auto old = data->subscriptions.find(room); old != data->subscriptions.end()) {
        data->subscription_topics -= std::min(data->subscription_topics, old->second.size());
        data->subscriptions.erase(old);
    }
    if (!topics_arr.is_array() || topics_arr.empty()) return;
    if (data->subscriptions.size() >= MAX_SUBSCRIPTION_ROOMS) return;
    if (data->subscription_topics + topics_arr.size() > MAX_SUBSCRIPTION_TOPICS) return;
    std::unordered_set<std::string> subs;
    for (const auto& t : topics_arr) {
        if (!t.is_string()) continue;
        const std::string& topic = t.get_ref<const std::string&>();
        // No real topic is longer; one that is would never match a frame's.
        if (topic.empty() || topic.size() > 128) return;
        subs.insert(topic);
    }
    data->subscription_topics += subs.size();
    data->subscriptions.emplace(room, std::move(subs));
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

    // Tee into the channel's ring buffer when registered (server owner opted
    // into relay catch-up). Ciphertext only; per-channel caps + retention +
    // the global budget bound RAM. One stored copy serves every late joiner, so
    // a forwarder's room, whose members never meet, keeps none.
    {
        std::string key = room_str;
        key.push_back('\0');
        key += topic_str;
        auto tit = state.topic_buffers.find(key);
        if (tit != state.topic_buffers.end() && tit->second.accepting &&
            forwarded.size() <= MAX_RING_FRAME_BYTES && !fwd_room::forwarder_of(room_str)) {
            auto& tb = tit->second;
            const uint64_t share = socket_share(state, data);
            uint64_t seq = state.buffer_index.stamp(key, true, share, forwarded.size());
            tb.frames.push_back({forwarded, data->peer_id,
                                 std::chrono::steady_clock::now(), seq, tb.retention_secs, share});
            tb.bytes += forwarded.size();
            state.ring_ledger.touch(key);
            // A full ring drops the oldest frame of the address share holding the
            // most bytes in it.
            while (!tb.frames.empty() &&
                   (tb.frames.size() > MAX_TOPIC_BUFFER_MSGS || tb.bytes > MAX_TOPIC_BUFFER_BYTES)) {
                auto victim = tb.frames.begin() +
                              ring_victim(tb.frames, [](const RelayState::TopicFrame& f) { return f.frame.size(); });
                tb.bytes -= std::min(tb.bytes, victim->frame.size());
                state.buffer_index.released(victim->seq);
                tb.frames.erase(victim);
            }
            evict_over_budget(state);
        }
    }

    const Audience aud = audience(state, rit->second, room_str);
    for (auto& [pid, peer_ws] : rit->second.peers) {
        if (pid == data->peer_id) continue;
        if (!aud.shares(pid, data->peer_id)) continue;

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
    state.nickname_to_master.erase(nickname);
    state.nickname_proof.erase(nickname);
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

// Pre-0.12 clients claim a nickname with a self-reported master and no signature.
// Turn this off once 0.12 is out: from then on a claim counts only when the master
// it names signed it for the claiming device.
#ifndef HOLLOW_ACCEPT_UNSIGNED_NICKNAME_CLAIMS
#define HOLLOW_ACCEPT_UNSIGNED_NICKNAME_CLAIMS 1
#endif
static constexpr bool ACCEPT_UNSIGNED_NICKNAME_CLAIMS = HOLLOW_ACCEPT_UNSIGNED_NICKNAME_CLAIMS;
static constexpr int64_t NICKNAME_CLAIM_SKEW_MS = 300 * 1000;

static void handle_claim_nickname(SSLWebSocket* ws, PerSocketData* data, const json& j,
                                   RelayState& state) {
    if (data->is_guest || data->is_fetch) return;

    std::string nickname = to_lowercase(json_text(j, "nickname"));
    const std::string raw_master = json_text(j, "master");
    if (!is_valid_nickname(nickname)) {
        send_json(ws, {{"type", "nickname_error"}, {"error", "invalid"}});
        return;
    }

    // A signed claim must be the named master's, for this socket's device, now.
    RelayState::NicknameProof proof;
    const bool is_signed = j.contains("sig");
    if (is_signed) {
        proof.master_key = json_text(j, "master_key");
        proof.sig = json_text(j, "sig");
        auto ts = j.find("ts");
        proof.ts_ms = (ts != j.end() && ts->is_number_integer()) ? ts->get<int64_t>() : 0;
        const int64_t now_ms = static_cast<int64_t>(now_unix_secs()) * 1000;
        const int64_t skew = now_ms > proof.ts_ms ? now_ms - proof.ts_ms : proof.ts_ms - now_ms;
        const bool ok = is_peer_id_shape(raw_master) && derive_peer_id(proof.master_key) == raw_master &&
                        skew <= NICKNAME_CLAIM_SKEW_MS &&
                        verify_ed25519(proof.master_key, proof.sig,
                                       nickname_claim_message(nickname, data->peer_id, raw_master, proof.ts_ms));
        if (!ok) {
            send_json(ws, {{"type", "nickname_error"}, {"error", "invalid_claim"}, {"nickname", nickname}});
            return;
        }
    } else if (!ACCEPT_UNSIGNED_NICKNAME_CLAIMS) {
        send_json(ws, {{"type", "nickname_error"}, {"error", "invalid_claim"}, {"nickname", nickname}});
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
    // Self-reported MASTER id, shape-checked (old clients send none). Stored
    // and handed back verbatim on resolve, so it is a client-supplied peer id
    // the relay keeps: it gets the same shape gate as every other one, plus the
    // Ed25519-identity prefix real ids carry. Never used for relay-side routing.
    if (is_peer_id_shape(raw_master) && raw_master.rfind("12D3KooW", 0) == 0) {
        state.nickname_to_master[nickname] = raw_master;
    }
    if (is_signed) state.nickname_proof[nickname] = proof;
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
    json reply = {{"type", "nickname_resolved"}, {"nickname", nickname},
                  {"peer_id", it->second}};
    auto mit = state.nickname_to_master.find(nickname);
    if (mit != state.nickname_to_master.end()) reply["master_id"] = mit->second;
    auto pit = state.nickname_proof.find(nickname);
    if (pit != state.nickname_proof.end()) {
        reply["master_key"] = pit->second.master_key;
        reply["ts"] = pit->second.ts_ms;
        reply["sig"] = pit->second.sig;
    }
    send_json(ws, reply);
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

// How long a connection (or an IP) is refused after `failures` failed guesses:
// nothing for the first LINK_RESOLVE_FREE_ATTEMPTS, then 60 s doubling per
// further failure to a 15-minute ceiling.
static std::chrono::seconds link_block_duration(uint32_t failures) {
    if (failures < LINK_RESOLVE_FREE_ATTEMPTS) return std::chrono::seconds(0);
    uint32_t steps = failures - LINK_RESOLVE_FREE_ATTEMPTS;
    if (steps > 8) steps = 8;  // 60 << 8 already exceeds the ceiling
    int64_t secs = static_cast<int64_t>(LINK_RESOLVE_BLOCK_BASE_SECS) << steps;
    if (secs > LINK_RESOLVE_BLOCK_MAX_SECS) secs = LINK_RESOLVE_BLOCK_MAX_SECS;
    return std::chrono::seconds(secs);
}

// Record one failed guess against this connection AND its IP, and arm the
// matching block on both.
static void note_link_resolve_failure(PerSocketData* data, RelayState& state) {
    auto now = std::chrono::steady_clock::now();

    data->link_resolve_failures++;
    auto per_conn = link_block_duration(data->link_resolve_failures);
    if (per_conn.count() > 0) data->link_resolve_block_until = now + per_conn;

    if (data->ip_key.empty()) return;
    auto it = state.link_guesses.find(data->ip_key);
    if (it == state.link_guesses.end()) {
        // Oldest-inserted first. The loop (rather than a single pop) covers a
        // fifo entry whose map row a successful resolve already cleared.
        while (state.link_guesses.size() >= MAX_LINK_GUESS_KEYS &&
               !state.link_guess_fifo.empty()) {
            state.link_guesses.erase(state.link_guess_fifo.front());
            state.link_guess_fifo.pop_front();
        }
        it = state.link_guesses.emplace(data->ip_key, RelayState::LinkGuessState{}).first;
        state.link_guess_fifo.push_back(data->ip_key);
    }
    it->second.failures++;
    it->second.last_failure = now;
    auto per_ip = link_block_duration(it->second.failures);
    if (per_ip.count() > 0) it->second.block_until = now + per_ip;
}

// True while either the connection or its IP is inside a guessing block.
static bool link_resolve_blocked(const PerSocketData* data, const RelayState& state) {
    auto now = std::chrono::steady_clock::now();
    if (now < data->link_resolve_block_until) return true;
    if (data->ip_key.empty()) return false;
    auto it = state.link_guesses.find(data->ip_key);
    return it != state.link_guesses.end() && now < it->second.block_until;
}

// Resolving a link code is a GUESS AT A SECRET, not a message.
//
// The code is six characters over a 36^6 keyspace and it is the passphrase of a
// full `.hollow` identity backup: the sibling device hands it the whole
// identity. Unthrottled, that is a remote brute force of somebody's entire
// account at line rate, and the endpoint used to require nothing but
// authentication — guests included, with the socket's own data ignored.
//
// So: guests are refused (they never link a device), then five free attempts
// per connection, then 60 s doubling to a 15-minute cap. Per-connection alone
// is worth nothing because reconnecting resets it, so the same budget is kept
// per ip_limit_key (see RelayState::link_guesses for why that per-IP state is a
// deliberate exception to the relay's "connection caps only" rule). A correct
// guess clears both — a real linking device never sees any of this.
static void handle_resolve_link_code(SSLWebSocket* ws, PerSocketData* data,
                                      const std::string& raw_code, RelayState& state) {
    // Mirrors handle_claim_link_code: a guest has no identity to link to.
    if (data->is_guest) return;

    if (link_resolve_blocked(data, state)) {
        // Attempting while blocked is itself an attempt, so it extends the
        // block — otherwise a prober just keeps hammering through the window.
        note_link_resolve_failure(data, state);
        send_json(ws, {{"type", "link_code_error"}, {"error", "too_many_attempts"}});
        return;
    }

    std::string code = to_uppercase(raw_code);
    auto it = state.linkcode_to_peer.find(code);
    if (it == state.linkcode_to_peer.end()) {
        note_link_resolve_failure(data, state);
        send_json(ws, {{"type", "link_code_error"}, {"error", "not_found"}, {"code", code}});
        return;
    }
    // Honor TTL even if the sweep hasn't run yet.
    auto exp = state.linkcode_expiry.find(code);
    if (exp != state.linkcode_expiry.end() && now_unix_secs() > exp->second) {
        state.linkcode_expiry.erase(code);
        state.peer_to_linkcode.erase(it->second);
        state.linkcode_to_peer.erase(it);
        note_link_resolve_failure(data, state);
        send_json(ws, {{"type", "link_code_error"}, {"error", "not_found"}, {"code", code}});
        return;
    }
    std::string peer_id = it->second;
    // One-shot: consume the code on a successful resolve.
    state.linkcode_expiry.erase(code);
    state.peer_to_linkcode.erase(peer_id);
    state.linkcode_to_peer.erase(it);
    // A hit clears the budget on both counters: whoever this is, they had the
    // secret. A user who fat-fingered the code four times is back to zero.
    data->link_resolve_failures = 0;
    data->link_resolve_block_until = {};
    if (!data->ip_key.empty()) state.link_guesses.erase(data->ip_key);
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

// Drop per-IP link-guess records that have gone quiet, so the map only ever
// holds addresses that are actively guessing. An entry survives its idle window
// while a block is still running, or a prober could sit out the sweep and get a
// clean slate. Called from the offline-buffer sweep timer.
void sweep_link_guesses(RelayState& state) {
    auto now = std::chrono::steady_clock::now();
    for (auto it = state.link_guesses.begin(); it != state.link_guesses.end(); ) {
        auto idle = std::chrono::duration_cast<std::chrono::seconds>(
            now - it->second.last_failure).count();
        if (idle >= LINK_GUESS_EXPIRE_SECS && now >= it->second.block_until) {
            it = state.link_guesses.erase(it);
        } else {
            ++it;
        }
    }
    // Keep the eviction order in step with the map (and free of duplicates a
    // cleared-then-re-armed key would leave behind).
    if (state.link_guess_fifo.size() > state.link_guesses.size()) {
        std::deque<std::string> kept;
        std::unordered_set<std::string> seen;
        for (auto& k : state.link_guess_fifo) {
            if (state.link_guesses.count(k) && seen.insert(k).second) {
                kept.push_back(std::move(k));
            }
        }
        state.link_guess_fifo.swap(kept);
    }
}

static void handle_text_message(SSLWebSocket* ws, PerSocketData* data,
                                 std::string_view message, RelayState& state,
                                 const Config& config) {
    json j = client_json::parse(message);
    if (j.is_discarded()) return;

    std::string type = j.value("type", "");

    if (type == "join") {
        // An `inbox:{master}` join may show the device's roster (0.12) or a
        // master-signed list (0.11); an ordinary join shows neither.
        auto pit = j.find("inbox_proof");
        const json* inbox_proof =
            (pit != j.end() && pit->is_object()) ? &(*pit) : nullptr;
        auto rit = j.find("inbox_roster");
        const json* inbox_roster =
            (rit != j.end() && rit->is_object()) ? &(*rit) : nullptr;
        handle_join(ws, data, j.value("room", ""), state, inbox_proof, inbox_roster, json_text(j, "door_proof"));
    } else if (type == "leave") {
        // Only this socket's own slot: a fetch socket's leave must not unjoin the
        // device's full node.
        std::string room = j.value("room", "");
        leave_room(state, data->peer_id, room, ws);
        data->fetch_rooms.erase(room);
    } else if (type == "msg") {
        handle_msg(data, j.value("room", ""), j.value("data", ""), state);
    } else if (type == "direct") {
        handle_direct(data, j.value("room", ""), j.value("target", ""),
                      j.value("data", ""), state);
    } else if (type == "check_peers") {
        // Lightweight liveness check: the client names peer ids, the relay says
        // which are up. Still deliberately unthrottled — throttling it would
        // silently degrade the heal that brings an "offline" friend back — but
        // it is no longer an oracle for ARBITRARY ids.
        //
        // It used to answer for any peer_id at all, which made the relay a
        // presence lookup service: hand it an id off a profile card and it told
        // you whether that person was online, right now, with no relationship of
        // any kind required. Now an id is reported only when the caller and that
        // peer are in at least one of the SAME rooms — the one relationship the
        // relay can actually verify, and the same gate `discover_peers` already
        // applies. That costs the real caller nothing: the client auto-joins
        // dm_room_code(me, friend) for EVERY accepted friend on connect
        // (swarm.rs, WsEvent::Connected), so an online friend it has lost track
        // of is always a co-member, which is exactly the case the heal exists
        // for. A stranger's id shares no room and simply never appears.
        //
        // Guests are refused outright: a browser viewer has no friends to heal.
        json online_peers = json::array();
        if (!data->is_guest && j.contains("peers") && j["peers"].is_array()) {
            const auto co_members = collect_room_co_members(
                state, data->peer_id, MAX_CHECK_PEERS_SCAN);
            size_t asked = 0;
            for (auto& pid : j["peers"]) {
                if (++asked > MAX_CHECK_PEERS_QUERY) break;
                if (!pid.is_string()) continue;
                const std::string& peer_id = pid.get_ref<const std::string&>();
                if (!is_peer_id_shape(peer_id)) continue;
                if (!co_members.count(peer_id)) continue;
                if (state.peer_sockets.count(peer_id)) {
                    online_peers.push_back(peer_id);
                }
            }
        }
        // `active_rooms` is answered as a constant empty array and the room
        // probe behind it is GONE. It reported whether an arbitrary room code
        // held any peers, and DM room codes are a deterministic function of the
        // two master peer_ids — so anyone holding two peer_ids could ask the
        // relay whether those two people were talking. No client has ever used
        // the reply (swarm.rs discards it), but the field stays on the wire
        // because ServerMsg::PeerStatus can't deserialize without it.
        send_json(ws, {{"type", "peer_status"},
                       {"online", online_peers},
                       {"active_rooms", json::array()}});
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
            // Members only. Without this the reply was a roster dump for ANY
            // room whose code the caller knew: hand it a deterministic DM room
            // code and it returned exactly which peers were in that DM. Clients
            // only ever discover in rooms they have already joined
            // (`active_room` + their own server ids), so requiring membership
            // costs nothing legitimate.
            // Guests and fetch sockets are never listed: a push isolate in a DM
            // room says when that phone was woken.
            if (rit != state.ws_rooms.end() &&
                rit->second.peers.count(data->peer_id)) {
                const Audience aud = audience(state, rit->second, room);
                const bool sees = aud.sees(data->peer_id);
                for (const auto& [pid, sock] : rit->second.peers) {
                    const auto* pd = sock->getUserData();
                    if (sees && pid != data->peer_id && !pd->is_guest && !pd->is_fetch &&
                        aud.shares(pid, data->peer_id)) {
                        peers.push_back(pid);
                    }
                }
            }
        }
        send_json(ws, {{"type", "discovered_peers"}, {"room", room}, {"peers", peers}});
    } else if (type == "subscribe") {
        handle_subscribe(data, j.value("room", ""),
                         j.contains("topics") ? j["topics"] : json::array());
    } else if (type == "claim_nickname") {
        handle_claim_nickname(ws, data, j, state);
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
    } else if (type == "unregister_push_token") {
        handle_unregister_push_token(data, state);
    } else if (type == "kill_deposit") {
        handle_kill_deposit(ws, data, j, state);
    } else if (type == "kill_ack") {
        handle_kill_ack(data, j, state);
    } else if (type == "lock_get") {
        handle_lock_get(ws, data, j, state);
    } else if (type == "lock_put") {
        handle_lock_put(ws, data, j, state);
    } else if (type == "set_push_prefs") {
        handle_set_push_prefs(data, j, state);
    } else if (type == "set_offline_buffer") {
        handle_set_offline_buffer(data, j, state);
    } else if (type == "report") {
        handle_report(ws, data, j, state);
    } else if (type == "set_topic_buffer") {
        handle_set_topic_buffer(data, j, state);
    } else if (type == "topic_catchup") {
        handle_topic_catchup(ws, data, j, state);
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
                           {"uris", turn_uris(config.domain)}});
        }
    } else if (type == "get_media_forwarder") {
        // Media forwarder discovery (media forwarding step 3) — mirrors
        // get_turn_credentials: authenticated WS only, NEVER an HTTP variant
        // (no caller identity at the HTTP layer — same reasoning as the
        // removed /turn-credentials endpoint). Zero-knowledge preserved: one
        // static peer_id from startup config plus a liveness bit from
        // peer_sockets; no per-stream metadata exists on the relay.
        if (data->is_guest) {
            send_json(ws, {{"type", "media_forwarder"}, {"error", "auth required"}});
        } else if (config.forwarder_peer_id.empty()) {
            send_json(ws, {{"type", "media_forwarder"}, {"error", "not configured"}});
        } else {
            send_json(ws, {{"type", "media_forwarder"},
                           {"peer_id", config.forwarder_peer_id},
                           {"online", state.peer_sockets.count(config.forwarder_peer_id) > 0}});
        }
    }
    // `get_bandwidth` (older clients still poll it every 30 s) is an unknown
    // command now and falls through silently, like any other.
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
                         SSLWebSocket* expected_ws,
                         bool suppress_peer_left) {
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
        // Release temporary nickname (+ its expiry/master entries)
        auto nit = state.peer_to_nickname.find(peer_id);
        if (nit != state.peer_to_nickname.end()) {
            state.nickname_expiry.erase(nit->second);
            state.nickname_to_peer.erase(nit->second);
            state.nickname_to_master.erase(nit->second);
            state.nickname_proof.erase(nit->second);
            state.peer_to_nickname.erase(nit);
        }

        // Release multi-device link code
        auto lit = state.peer_to_linkcode.find(peer_id);
        if (lit != state.peer_to_linkcode.end()) {
            state.linkcode_expiry.erase(lit->second);
            state.linkcode_to_peer.erase(lit->second);
            state.peer_to_linkcode.erase(lit);
        }

        // Clear push debounce on disconnect (token stays — needed for offline
        // pushes). The hourly wake-up budget goes with it: the budget exists to
        // bound how often an OFFLINE device is woken, so each offline stretch
        // starts fresh, and the map never outlives the peer's push token.
        state.last_push_sent.erase(peer_id);
        state.push_budget.erase(peer_id);

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
        leave_room(state, peer_id, room, expected_ws, suppress_peer_left);
    }
    if (owns_peer) {
        state.peer_rooms.erase(peer_id);
    }
}

void setup_ws_handler(uWS::SSLApp& app, RelayState& state, const Config& config) {
    g_diag = &state.diag;
    g_forwarder_peer_id = config.forwarder_peer_id;
    door_key_mint(state.door_key);
    state.door_domain = auth_domain(config.domain);
    app.ws<PerSocketData>("/ws", {
        .compression = uWS::DISABLED,
        .maxPayloadLength = 64 * 1024 * 1024,
        .idleTimeout = 120,
        .maxBackpressure = 64 * 1024 * 1024,
        .sendPingsAutomatically = true,

        .open = [&state](SSLWebSocket* ws) {
            auto* data = ws->getUserData();

            // Per-IP connection limiting (in-memory only, never logged)
            const std::string remote(ws->getRemoteAddressAsText());
            std::string ip = ip_limit_key(remote);
            data->ip_key = ip;
            data->share_block = share_block(remote);
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

            // Nothing a client sends may unwind into uSockets' C frames: that ends
            // the process, and an abnormal exit takes no snapshot.
            if (!data->authenticated) {
                try {
                    handle_auth(ws, data, message, state, config);
                } catch (const std::exception&) {
                    ws->end(1008, "bad_auth");
                }
                return;
            }

            if (opCode == uWS::OpCode::TEXT) {
                if (message.size() > 1024 * 1024) return;
                // A field of the wrong JSON type makes value() throw, and an
                // exception unwinding into uSockets' C frames would end the
                // process on one malformed frame from any client.
                try {
                    handle_text_message(ws, data, message, state, config);
                } catch (const std::exception&) {
                    return;
                }
            } else if (opCode == uWS::OpCode::BINARY) {
                // 1-byte 0x00 = guest keepalive, don't process or count
                if (message.size() == 1 && static_cast<uint8_t>(message[0]) == 0x00) {
                    return;
                }
                if (message.size() > 1) {
                    uint8_t opcode = static_cast<uint8_t>(message[0]);

                    // Guest binary restrictions
                    if (data->is_guest) {
                        // No SendDirect and no channel topic for guests: the web
                        // viewer only reads, and 0x07 feeds the catch-up rings.
                        if (opcode == 0x04 || opcode == 0x07 || opcode == 0x08 || opcode == 0x09) return;
                        if (opcode == 0x03 || opcode == 0x0A) {
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

                    try {
                    switch (opcode) {
                        // 0x01 intentionally unhandled — see the note above
                        // handle_binary_direct. It was an unauthorized
                        // cross-room broadcast primitive with no live callers.
                        case 0x02:
                            handle_binary_direct(data, message, state);
                            break;
                        case 0x03:
                            handle_binary_msg(data, message, state);
                            break;
                        case 0x0A:
                            handle_binary_msg(data, message, state, /*to_all=*/true);
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
                    } catch (const std::exception&) {
                        return;
                    }
                }
            }
        },

        .drain = [](SSLWebSocket* /*ws*/) {},

        .close = [&state](SSLWebSocket* ws, int /*code*/, std::string_view /*reason*/) {
            auto* data = ws->getUserData();

            // IP tracking cleanup (in-memory only).
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
            if (data->authenticated && data->is_fetch) {
                // A fetch socket leaves only the slots it still holds, and frees the
                // peer's license seat only when no full socket of it is connected.
                for (const auto& room : data->fetch_rooms) {
                    leave_room(state, data->peer_id, room, ws);
                }
                if (!state.peer_sockets.count(data->peer_id)) {
                    state.license.release_key(data->peer_id);
                }
            } else if (data->authenticated && !data->superseded) {
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
