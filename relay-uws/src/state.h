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
#include "offline_index.h"
#include "reports.h"

// No soft backpressure — let uWebSockets buffer handle delivery.
// Hard limit (.maxBackpressure = 64MB) catches truly dead connections.

static constexpr size_t MAX_CONNS_PER_IP = 34;
static constexpr size_t MAX_NEW_CONNS_PER_MIN_PER_IP = 10;
// No byte quotas of any kind (the 10 GB/day per-IP budget was removed
// 2026-08-28). Volume fairness lives BELOW the relay: the host shapes egress
// with CAKE per destination host, so a saturated line is shared equally and
// an idle line is free to anyone. Abuse is bounded by fair share, never a cap.
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

// Offline-buffer eviction is FAIR-SHARE, not per-sender-capped and not rate
// limited (see buffer_offline_msg in ws_handler.cpp). When a per-peer cap is hit
// the relay drops the oldest frame belonging to whichever sender occupies the
// most slots, so a peer flooding someone else's buffer can only evict itself.
// A flat per-sender cap would silently truncate a real conversation, and a
// per-minute limit would silently drop reconnection bursts — both are the
// message-loss class of bug the relay refuses to introduce (feedback_relay_rules).

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

// Offline-buffer KEY caps (RELAY-1). The 512 MB budget above bounds the bytes;
// these bound the number of distinct keys, which nothing bounded before: the
// buffer is keyed by the target string a 0x04/0x09 frame carries, so one
// authenticated peer could mint an unbounded number of map entries by naming a
// fresh "target" per frame. Shape validation (is_peer_id_shape) narrows the key
// space to real peer ids; these two caps bound it outright.
//
// Per SENDER: how many distinct offline targets it may hold deposits for at
// once. Crossing it never refuses the deposit — it frees that sender's OWN
// oldest target, so a flooder evicts only itself, exactly like the per-peer
// fair-share eviction below.
//
// CAUTION, this is the one number here that can cost a real message. A channel
// post fans one 0x09 frame per OFFLINE member, and a sender's targets clear
// only on delivery or TTL, so they accumulate across every server and DM it
// touches for up to a day. A member of a few large servers whose offline
// members total more than this WILL start evicting its own earliest deposits —
// which are somebody's real messages, not junk. The offline buffer is an
// availability cache and peer sync remains the correctness floor, so the cost
// is a slower first delivery rather than a lost message. 4096 sits well above
// any real member's offline fan-out (a few large servers) while still bounding
// a flooder to 4096 keys of its own; raise it again before a real member ever
// reaches it, not after.
static constexpr size_t MAX_OFFLINE_TARGETS_PER_SENDER = 4096;
// Global backstop, mirroring MAX_TOPIC_BUFFERS_TOTAL. Reaching this means
// 65,536 distinct peers have mail waiting at once.
static constexpr size_t MAX_OFFLINE_BUFFER_KEYS = 65536;
// How many oldest deposits the backstop may pop looking for a key to free
// before it admits the new deposit anyway. The cap is a memory backstop, not an
// invariant worth losing a message over.
static constexpr size_t MAX_BACKSTOP_EVICTIONS = 1024;
// Anti-spam: non-mention channel pushes are heavily throttled — the banner has
// no content until the device fetches, so repeats add nothing. Mentions are
// urgent and bypass the long window.
static constexpr int CHANNEL_PUSH_DEBOUNCE_SECS = 120;         // non-mention, per (peer, server)
static constexpr int CHANNEL_PUSH_MENTION_DEBOUNCE_SECS = 10;  // mention, per (peer, server)
static constexpr int CHANNEL_PUSH_MIN_GAP_SECS = 5;            // any channel push, per peer
static constexpr uint32_t CHANNEL_PUSH_MAX_WHILE_OFFLINE = 3;  // non-mention cap until app reconnects

// Rolling per-target ceiling on DM push wake-ups (RELAY-7). The 10-second
// debounce bounds the RATE but not the TOTAL: a sender willing to wait ten
// seconds between frames could keep a phone waking all night. 30 an hour is
// generous for the thing a push actually does — a woken device connects and
// drains everything waiting, so the wake-ups after the first carry no new
// information until it goes offline again, and pushes only fire for targets
// that are offline in the first place. Over budget the deposit STILL buffers;
// only the wake-up is skipped, so nothing is ever lost, it just arrives when
// the device next connects.
static constexpr uint32_t MAX_PUSH_WAKEUPS_PER_HOUR = 30;
static constexpr int PUSH_BUDGET_WINDOW_SECS = 3600;

// Link-code guessing defence (RELAY-5). A link code is the passphrase of a full
// identity backup over a 36^6 keyspace, so a failed resolve is a guess at a
// secret, not traffic.
static constexpr uint32_t LINK_RESOLVE_FREE_ATTEMPTS = 5;   // before any block
static constexpr int LINK_RESOLVE_BLOCK_BASE_SECS = 60;     // doubling per further failure
static constexpr int LINK_RESOLVE_BLOCK_MAX_SECS = 900;     // 15 minutes
static constexpr size_t MAX_LINK_GUESS_KEYS = 65536;
static constexpr int LINK_GUESS_EXPIRE_SECS = 900;          // idle entries swept after 15 min

// Per-master high-water mark on inbox-proof device-list versions (RELAY-6).
// Bounded with FIFO eviction of the oldest-inserted master.
static constexpr size_t MAX_DEVICE_LIST_VERSIONS = 262144;

using SSLWebSocket = uWS::WebSocket<true, true, struct PerSocketData>;

struct PerSocketData {
    std::string peer_id;
    bool authenticated = false;
    struct us_timer_t* auth_timer = nullptr;
    std::string license_key;
    bool is_guest = false;
    std::string ip_key;
    bool is_fetch = false;  // Invisible background fetch mode (FCM wake-up)
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

    // Link-code guessing, per connection (RELAY-5). Counts FAILED resolves of a
    // 36^6 code that is the passphrase of a full identity backup; a successful
    // resolve clears both. See handle_resolve_link_code.
    uint32_t link_resolve_failures = 0;
    std::chrono::steady_clock::time_point link_resolve_block_until{};
};

struct WsRoom {
    std::unordered_map<std::string, SSLWebSocket*> peers;
};

struct IpState {
    uint32_t active_count = 0;
    std::deque<std::chrono::steady_clock::time_point> recent_connects;
};

// Delivery diagnostics (counters ONLY — the relay logs nothing, and these
// carry no identities). Added 2026-08-07 for the vanished-fwd-frame
// investigation: uWS send() silently returns DROPPED past maxBackpressure and
// send_to_peer used to ignore the status entirely, so a delivery failure left
// zero trace anywhere. Exposed via /server-stats.
struct DeliveryDiag {
    uint64_t send_backpressure = 0;  // sends that increased user-space backpressure
    uint64_t send_dropped = 0;       // sends uWS discarded (buffered > maxBackpressure)
    uint64_t fwd_delivered = 0;      // 0x04/0x08 directs delivered live to the configured media forwarder
    uint64_t fwd_buffered = 0;       // ...that fell into the offline buffer instead (membership loss!)
    uint64_t ghost_left_suppressed = 0; // peer_left broadcasts withheld because a newer socket of the same peer took over
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
    // The HTTP signaling table (`signaling_rooms`, `PeerEntry`) is GONE along
    // with /register, /unregister and /bootstrap — see the note in
    // http_handlers.cpp. It was the one place the relay held a peer_id next to
    // a caller-supplied address list, and no client has used it since July 2026.

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
    DeliveryDiag diag;

    // Temporary nickname registry (RAM only, released on disconnect, 10-min TTL).
    // The TTL + a dead-holder live-check on claim/resolve prevent a stale binding
    // (an old identity that never cleanly released) from permanently blocking the
    // nickname for a new claimer — the bug where "123" stayed bound to a dead peer.
    std::unordered_map<std::string, std::string> nickname_to_peer;  // nickname -> peer_id
    std::unordered_map<std::string, std::string> peer_to_nickname;  // peer_id -> nickname
    std::unordered_map<std::string, uint64_t>    nickname_expiry;   // nickname -> expiry unix secs
    // nickname -> claimer's self-reported MASTER identity ("" never stored).
    // Returned on resolve so a stranger's friend request targets inbox:{master}
    // — the claimer's WS-auth peer_id is a DEVICE id whose inbox nobody joins.
    std::unordered_map<std::string, std::string> nickname_to_master;

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
    // Rolling hourly wake-up budget per target (RELAY-7). Keys are a subset of
    // push_tokens (no token, no push, no budget entry), and cleanup_peer drops
    // a peer's entry on disconnect so every offline stretch starts fresh.
    struct PushBudget {
        std::chrono::steady_clock::time_point window_start{};
        uint32_t count = 0;
    };
    std::unordered_map<std::string, PushBudget> push_budget;

    // Offline message buffer (RAM only). Key = target peer_id.
    // Each entry is the fully-formed 0x06 direct-message frame to replay when
    // the target joins the matching DM room. Capped per-peer + TTL-swept.
    struct BufferedMsg {
        std::string room;              // DM/server room code the frame belongs to
        std::string frame;             // ready-to-send 0x06 binary frame
        std::string sender;            // authenticated peer that buffered it
        std::chrono::steady_clock::time_point at;
        bool is_image = false;         // inlined-image frame (separate cap)
        bool is_channel = false;       // channel message frame (separate cap)
        uint64_t seq = 0;              // eviction-index stamp (OfflineIndex)
    };
    std::unordered_map<std::string, std::deque<BufferedMsg>> offline_buffer;

    // Insertion-order index + per-sender key accounting over BOTH buffers
    // (RELAY-1). Must stay exact: every path that removes a frame calls
    // released_dm()/released_topic(). See the enumeration in ws_handler.cpp.
    OfflineIndex buffer_index;

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
        uint64_t seq = 0;    // eviction-index stamp (OfflineIndex)
    };
    struct TopicBuffer {
        std::deque<TopicFrame> frames;
        size_t bytes = 0;
        // Cleared registrations stop taking new frames but keep the ones they
        // already hold until retention expires them. `clear` is authorized only
        // by room membership, so it must not be an instant-destruction verb.
        bool accepting = true;
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

    // Failed link-code guesses per ip_limit_key (RELAY-5).
    //
    // This is a DELIBERATE, DOCUMENTED EXCEPTION to "per-IP RAM = connection
    // caps only": it counts FAILED guesses of a secret, never traffic. A link
    // code is six characters over a 36^6 keyspace and it is the passphrase of a
    // full identity backup, so an unthrottled resolve is a remote brute force
    // of somebody's whole identity; the per-connection counter alone is worth
    // nothing because reconnecting resets it. Nothing here counts, delays or
    // drops a message, and a correct guess clears the entry.
    struct LinkGuessState {
        uint32_t failures = 0;
        std::chrono::steady_clock::time_point block_until{};
        std::chrono::steady_clock::time_point last_failure{};
    };
    std::unordered_map<std::string, LinkGuessState> link_guesses;
    // Insertion order, for O(1) eviction at MAX_LINK_GUESS_KEYS.
    std::deque<std::string> link_guess_fifo;

    // Highest device-list version this relay has seen verify for each master
    // (RELAY-6). A revoked device keeps its last master-signed list forever and
    // that list still verifies, so without a high-water mark it can replay it
    // to read the master's inbox mailbox for as long as it likes. RAM only: a
    // restart forgets the marks, which is the known limit of this defence.
    std::unordered_map<std::string, uint64_t> device_list_max_version;
    std::deque<std::string> device_list_version_fifo;  // FIFO eviction order

    size_t online_users() const { return peer_sockets.size() - guest_count; }
};
