# Resumable relay sessions: a connection that survives phones, sleep and bad networks

Status: planned 2026-10-06; wave 0 (the wire spec in section 9, shared stubs, the relay's ring
core) done the same day, waves 1 and 2 by parallel worktree agents (section 10). Written after the
mixed iPhone/Android fleet run that found a nickname dying with the socket and an accept lost to a
dead connection. Research digest and code map from that session are folded in below; every claim
about other apps carries its source. Section 9 binds every implementer; where it is more precise
than sections 3 to 5, section 9 wins.

## 0. TL;DR

The relay connection is fragile because **a session is a socket**. Nothing on the wire says what
arrived, so every frame written into a connection that has quietly died is lost in either
direction, and every reconnect starts from zero: log in, rejoin every room, rebuild presence, run
the catch-ups. On top of that the client notices a dead connection only after 70 to 100 seconds
of silence, the relay after 120, nothing reacts to the app coming back, a network change or a
laptop waking, and the Android app fights the OS (a battery-exemption prompt at every launch, a
Wi-Fi lock) instead of working with it.

uWebSockets is not the problem. The fix is the one every large realtime system converged on
(Discord resume, XMPP stream management, MQTT persistent sessions, Telegram's MTProto sessions):

1. **A session outlives the socket.** The relay keeps a device's rooms, subscriptions and a short
   queue of undelivered frames for a grace window after the socket dies.
2. **Both sides count what they handled and acknowledge it.** On reconnect each side resends
   exactly what the other did not get. A frame written into a dead socket is no longer lost.
3. **Liveness is active.** A heartbeat with a deadline, so a dead connection is found in seconds,
   not minutes.
4. **Events drive recovery.** App foreground, network change and wake from sleep probe the
   connection at once and resume with no backoff.
5. **Phones stop fighting the OS.** Close cleanly when backgrounded, let push wake the app, resume
   in about a second on return. No battery-exemption prompt, no Wi-Fi lock.

When resume is impossible (relay restarted without a snapshot, grace expired, the queue
overflowed), the existing gap repair (`GapDigest`, topic catch-up, sync) is the backstop, exactly
as Matrix and Telegram fall back to `/messages` and `getDifference`.

## 1. What is wrong today

Code references are `ws_client.rs` (WC), `swarm.rs` (SW), `relay-uws/src/ws_handler.cpp` (WH).

### 1.1 Nothing says what arrived (the root cause)

No sequence numbers and no acks exist in either direction. The relay's buffer `seq` (WH:1096) is
eviction bookkeeping and never goes on the wire. The consequences:

- **Client writes into a dead path.** A dropped path still accepts writes into the OS buffer,
  `bounded_send` returns Ok, and the frames vanish (WC:629-643, 1050-1059). Linux keeps such a
  socket "writable" for roughly 15 to 30 minutes of TCP retransmits before erroring
  (`tcp_retries2`, https://man7.org/linux/man-pages/man7/tcp.7.html,
  https://blog.cloudflare.com/when-tcp-sockets-refuse-to-die/).
- **The relay writes into a dead socket.** Every live send goes to the ghost until uWS gives up,
  and nothing is buffered behind it (WH:1994, 2057, 2097, 2209, 2322). This is how the friend
  accept got lost on 2026-10-06.
- **Buffered frames replayed into a socket that then dies** are deleted on send, so they are lost
  too (WH:1148-1172).
- **0x02 binary directs** (file and shard chunks) are never buffered for an absent target
  (WH:2043-2045), and in-flight stream transfers are deleted on Disconnected (SW:3664-3670).

### 1.2 A session is a socket

- Rooms, topic subscriptions, the nickname, the link code and the relay's idea of presence all
  die with the socket (WH:2885-2916). A relay restart loses rooms and subscriptions for everyone
  (snapshot covers buffers and rings only, VERSION 8).
- Every reconnect re-authenticates and rejoins every room, and rejoins them **twice**: ws_client
  replays `joined_rooms` (WC:559-573) and then the swarm's Connected handler queues the same
  joins again (SW:3453-3617).
- The node purges about twenty state sets on Disconnected (`ws_room_peers`, `synced_peers`,
  sibling calls, voice participants, conference knockers, gossip, Olm and MLS throttles, file ask
  holders: SW:3619-3689) and rebuilds all of it on the next connect.
- `WsEvent::Connected` is emitted before any room is rejoined (WC:554), so the UI says
  "Connected" while nothing works yet.

### 1.3 Liveness is passive and slow

- The client pings every 30 s and declares the socket dead after 70 s with nothing received
  (WC:624-648), so detection takes 70 to 100 s.
- The relay uses uWS `idleTimeout` 120 with automatic pings (WH:2938-2943). uWS pings only after
  104 s of receive silence and closes 16 s later; any received data resets the timer, sends do
  not (https://github.com/uNetworking/uWebSockets/blob/master/src/App.h,
  WebSocketContextData.h). A vanished phone therefore looks online for up to two minutes, and
  frames for it are sent into the void the whole time.
- tokio's `Instant` stops during suspend on Linux and macOS
  (https://doc.rust-lang.org/std/time/struct.Instant.html), so after a laptop wakes the 70 s
  detector fires even later.

### 1.4 Nothing reacts to the moments that matter

- App resume only re-sends room joins over whatever socket exists, possibly a dead one
  (`hollow_shell.dart` `_rejoinRoomsOnResume`). It does not probe, does not reset backoff, does
  not touch DM or inbox rooms. Desktop has no lifecycle hook at all.
- No network-change listener exists on any platform. No sleep/wake hook exists.
- Backoff is 1, 2, 4, 8, 16, 30 s with no jitter (WC:815-819). An app that sat in the background
  for a minute while Android blocked its network returns mid-way through a 30 s sleep and waits
  it out.

### 1.5 The mobile model fights the OS

- Android 14+ freezes a cached app 10 s after it becomes cached, and then "the system terminates
  any active TCP sockets" (https://source.android.com/docs/core/perf/cached-apps-freezer). We
  measured the abort 3 s after HOME on an emulator.
- iOS defuncts an app's connections when it is suspended
  (https://developer.apple.com/forums/thread/840808); a background task gets about 30 s shared
  across the app (https://developer.apple.com/forums/thread/85066).
- Hollow asks for a battery-optimization exemption **at every launch** while optimized
  (`hollow_shell.dart:1175-1177`, `MainActivity.kt:60`) and declares
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`. Google Play lists exactly our case, a chat app that can
  use high-priority FCM, as **Not Acceptable**
  (https://developer.android.com/training/monitoring-device-state/doze-standby). Telegram does not
  declare the permission and shows its own hint only when the user picked "Restricted", at most
  once a day, three times total (LaunchActivity.java in DrKLO/Telegram). Signal asks only after
  measuring slow notifications over at least 3 days (SlowNotificationHeuristics.kt).
- The app holds a `WIFI_MODE_FULL_HIGH_PERF` lock "hollow:ws" while open (`MainActivity.kt:87`).
  A Wi-Fi lock does nothing for a background socket: Doze ignores wakelocks and suspends the
  network, and the low-latency lock works only in the foreground with the screen on
  (https://source.android.com/docs/core/connect/wifi-low-latency).

### 1.6 Smaller bugs found on the way

- **Replay flush drops the tail.** If one queued command fails during the post-reconnect flush,
  every command after it in that batch is dropped (WC:613-619: `cmds` is consumed by value and
  the loop breaks). Verified by reading.
- Join replay ignores send errors and a failed re-subscribe stops the rest (WC:570, 585-588).
- `pending_commands` is unbounded with no TTL; live-only frames older than 300 s are then refused
  by the receiver anyway (frame_auth.rs:295-297).
- Requests in flight on a dead socket (`check_peers`, `discover_peers`, lock reads, TURN,
  nickname resolve) are retried only by timers.

## 2. What the large systems do

| System | Session outlives socket | Counting and acks | Liveness | On resume failure |
|---|---|---|---|---|
| Discord Gateway | `session_id` + `seq`, RESUME to `resume_gateway_url`, missed events replayed in order then `RESUMED` | server `seq` on every dispatch, client sends last seen | heartbeat at `heartbeat_interval` (example 45 s) with jitter; no ACK before the next beat = zombie, reconnect | op 9 Invalid Session, fresh Identify |
| XMPP XEP-0198 | `<enable resume/>`, `<resume previd h/>` | each side counts handled stanzas `h`, `<r/>` asks, `<a h/>` answers, batched | whitespace or `<r/>` | unacked stanzas go to offline storage |
| MQTT 5 | Session Expiry, Session Present flag | QoS1 packet ids, resend unacked with DUP on reconnect | Keep Alive, server closes after 1.5x silence | Clean Start, new session |
| Telegram MTProto | session = app instance (64-bit id), server resends unacked to a new connection | `msgs_ack` piggybacked, standalone after 16 pending or 60-120 s | ping every 19 s, server disconnect delay 35 s (Android client) | `pts` gap: wait 0.5 s, then `getDifference` |
| Matrix | stateless sync token `since=next_batch` | the token is the cursor | long poll timeout | `limited` + `prev_batch`, backfill with `/messages` |
| Signal Android | socket kept 2 min after backgrounding, push otherwise | server queue, client acks each envelope | keepalive; one unanswered keepalive = new socket | server queue persists |

Sources: https://docs.discord.com/developers/events/gateway ,
https://docs.discord.com/developers/topics/opcodes-and-status-codes ,
https://xmpp.org/extensions/xep-0198.html , https://prosody.im/doc/modules/mod_smacks (Prosody
keeps a dropped session 600 s, 500 unacked stanzas),
https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html ,
https://core.telegram.org/mtproto/description ,
https://core.telegram.org/mtproto/service_messages_about_messages ,
https://core.telegram.org/api/updates , https://spec.matrix.org/latest/client-server-api/#syncing ,
Signal-Android `IncomingMessageObserver.kt` and `SignalWebSocketHealthMonitor.kt`.

The lessons, in the order they matter for us:

1. Session and socket are separate objects. Resume re-authenticates (Discord resends the token)
   and costs no rejoins.
2. Cumulative counters, acked in batches, piggybacked on traffic. The sender keeps a frame until
   it is acked and resends the tail on resume. Our message-id dedup already makes a resend safe.
3. Active liveness with a short deadline. The server's own pings are too slow; the client
   supplies the heartbeat.
4. Events, not timers, trigger recovery: foreground, network change, wake. Reset backoff on each.
   Open the new connection before closing the old one when a better network appears
   (https://developer.apple.com/videos/play/wwdc2018/715/).
5. Gap repair is the backstop, not the main path.
6. Spread the herd: full-jitter backoff
   (https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/), a relay that
   tells clients to move before a restart (Discord op 7, Slack's 10 s warning), and a cheap
   resume so a reconnect wave costs no rejoins. Bound what a stalled session may hold: Discord
   once ran servers out of RAM buffering for stalled sessions
   (https://discordstatus.com/incidents/dj3l6lw926kl).
7. On phones, do not fight the OS: accept death on suspend, let push wake the app, resume fast.

## 3. Design

### 3.1 The session

On `auth_ok` the relay mints a **session** for a full (non-fetch) socket that announced the
capability. It is keyed by the device peer id, one per device per relay, and holds:

- `sid`: 128 random bits, sent to the client in `auth_ok`, never logged, never written to disk.
- The socket's rooms with their door-proof standing, inbox ownership and roster as last proven,
  topic subscriptions, the offline-delivery opt-in, the nickname binding and the push
  registration that today die in `cleanup_peer`.
- `out_h`: how many stream frames the relay has sent to this device; `in_h`: how many it has
  handled from it.
- The **unacked ring**: the stream frames sent but not yet acknowledged, bytes and count capped.

A session has three states: **live** (socket attached), **grace** (socket gone, session kept),
**gone**.

### 3.2 Counting and acks

Modelled on XEP-0198 so the existing frame formats stay as they are:

- Each side counts the **stream frames** it handles: every application frame in either direction
  (directs, broadcasts, topic frames, JSON control the node acts on). Not counted: auth,
  heartbeat, ack and resume frames, and WS ping/pong.
- Acks are a new control frame carrying the receiver's count, `{"type":"ack","h":N}` (a fixed
  binary opcode if the JSON parse shows up in profiles). They are cumulative and batched: sent
  after 16 unacked frames, after 2 s of quiet following a receipt, and always inside every
  heartbeat and heartbeat answer.
- Each side keeps what it sent until the other acks it. The relay's copy is the session ring; the
  client's is an **outbound queue** that replaces today's unbounded `pending_commands`. Frames are
  kept byte for byte (already sealed by `frame_auth`), so a resent frame is the identical frame.
- The client's outbound queue is bounded (count, bytes) and drops live-only frames older than the
  receiver's 300 s window instead of sending something that will be refused.

### 3.3 Resume

Reconnect always runs auth v2 again: a fresh nonce, the device signature over the relay's domain,
the nonce and every flag (`auth_frame.h` / `ws_client::auth_v2_message`). The signed message
gains the `sid` and the client's `in_h`, so a resume cannot be grafted onto someone else's
handshake and a stolen `sid` is useless without the device key. Both sides of the pinned KAT
change together (Rust and C++).

The relay checks the session exists, belongs to this peer id and is not gone, then answers
`resumed{h}` with its `in_h` and:

1. resends ring frames after the client's `in_h`, in order;
2. sends one fresh members snapshot per room (presence is state, not history, so it is
   re-read, never replayed);
3. re-checks what may have changed during grace: a door that moved (the room drops out of the
   session and the client re-proves through `DoorAsk`), an inbox the relay's roster fold no longer
   lets this device own (refused, as today), a kill order waiting for this device (sent first).

The client resends its outbound queue after the relay's `h`. Nothing is rejoined and nothing is
resubscribed.

If resume is impossible the relay answers `resume_failed{reason}` (unknown or gone, gapped,
refused) and the client opens a fresh session, which is today's full path, followed by gap
repair.

**Gapped instead of failed.** If the ring overflowed during grace, the session keeps its rooms
and subscriptions and answers `resumed{h, gap:true}`; the client then runs the existing catch-ups
(`GapDigest`, topic catch-up, sync) for what fell out. Overflow costs a catch-up, never a rejoin.

### 3.4 Grace, presence and delivery during grace

- When the socket closes or is declared dead, the session enters **grace** for a fixed window.
  Proposal: **120 s** on the official relay, a setting on self-hosted relays. Prosody uses 600 s,
  Signal keeps its socket 2 min after backgrounding.
- **Presence follows the socket, delivery follows the session.** Peers get `peer_left` as soon as
  the socket is known dead, so friends see you offline within the liveness deadline (section
  3.6). The session keeps receiving: frames addressed to the device go into its ring. A resume
  sends `peer_joined` again. Presence is honest and nothing is lost.
- A short trip out of the app does not flap presence: a socket that is resumed before the
  liveness deadline was never declared dead.
- During grace, a frame that would wake a fully offline device today (DM, channel mention, call)
  still triggers the push path, debounced as now.
- **Grace expiry.** Ring frames that are bufferable today move into `offline_buffer` under their
  room, so the existing replay on join and push take over. The session's rooms are left. This is
  XEP-0198's rule: unacked stanzas become offline messages.
- 0x02 binary directs ride the ring during grace like everything else, so a file transfer
  survives a short drop. They do not move to `offline_buffer` on expiry (too big, and the pull
  resumes through `file_asks`).

### 3.5 Bounds, fairness and restarts (relay rules)

- The ring is charged to the **sender's** hashed address share (`fair_share.h`, `socket_share`),
  like `offline_buffer`. A full ring evicts by the heaviest share. Per-session caps (proposal
  4 MB and 2,000 frames) and the existing 512 MB global buffer budget, shared with
  `offline_buffer` and the topic rings.
- A session in grace counts against the per-IP connection caps (`ip_limit_key`), so a stranger
  cannot pile up sessions by connecting and dropping. Sessions are evicted heaviest share first
  when the session table is full.
- No rate limit, no refusal: overflow marks the session gapped (3.3), it never drops a socket.
- **Restart without loss.** Sessions and rings join `snapshot_codec.h` (VERSION 9) and ride the
  systemd fd store as a memfd on SIGTERM, never a file. On restart they come back in grace, so a
  relay deploy is a resume for every client, not a reconnect storm.
- **Drain before restart.** Before SIGTERM the relay sends every socket a `reconnect{after_ms}`
  hint with a spread (Discord op 7, Slack's warning), then snapshots.
- Nothing about sessions is logged (`feedback_relay_no_metadata_logging`).

### 3.6 Liveness

- **Client heartbeat** `{"type":"hb","h":N}` every **15 s** in the foreground, answered at once by
  `{"type":"hb_ack","h":M}`. One unanswered heartbeat (deadline **10 s**) means dead: close and
  resume immediately. Detection worst case drops from 100 s to 25 s, and on any send we notice
  within 10 s.
- **Relay** `idleTimeout` **45 s**: healthy clients beat every 15 s, so uWS never needs to ping
  them; a silent socket is closed within about 45 s instead of 120. (uWS timer granularity is
  4 s.)
- `TCP_USER_TIMEOUT` (Linux, Android) on the client socket so the kernel stops hiding a dead
  path behind retransmits.
- Time that keeps counting across sleep: compare wall clock against the monotonic tick each beat;
  a jump means the machine slept, which is a wake trigger (3.7).
- Background on a phone while the process still runs: beat every 60 s (Signal's cadence) until
  the app closes the socket (3.8).

### 3.7 Triggers: probe now, never sleep through a change

One entry point, `relay_nudge(reason)` in the FFI and an internal `Notify` in ws_client:

| Trigger | Source |
|---|---|
| App to foreground | Dart `AppLifecycleState.resumed` (phones), window focus after a long gap (desktop) |
| Network change | Android `registerDefaultNetworkCallback` (`onAvailable`, `NET_CAPABILITY_VALIDATED`); iOS and macOS `NWPathMonitor`; Windows `NotifyIpInterfaceChange` / `INetworkListManagerEvents::ConnectivityChanged`; Linux NetworkManager `StateChanged` over D-Bus |
| Wake from sleep | Windows `WM_POWERBROADCAST` `PBT_APMRESUMEAUTOMATIC`; macOS `NSWorkspaceDidWakeNotification`; Linux logind `PrepareForSleep(false)`; the wall-clock jump everywhere |
| Send failure | `bounded_send` error |

On a nudge: if a frame arrived in the last 2 s, do nothing. Otherwise send a heartbeat and, if
it is not answered within **1 s**, open a new socket and resume on it **in parallel** while the old
one is still being judged (make before break); whichever answers first wins. No socket at all:
cancel any backoff sleep and reconnect now with resume. **Coming back never waits on an old
connection**: on phones the socket was closed on purpose when the app went to the background
(3.8), so the foreground opens a fresh socket and resumes at once.

The resume itself is one round trip after TLS: TLS session resumption (the relay's session cache
already holds 20,000) plus auth v2 with the `sid`, then the ring replay. No room joins, no
subscriptions, no catch-ups on the happy path.

- **Backoff** becomes full jitter, `random(0, min(30 s, 0.5 s * 2^attempt))`, reset to zero by
  every nudge. The `realtime_active` 1 s retry during calls stays.
- **Better path, make before break.** When a new default network appears while the old socket
  still works (Wi-Fi joins while on cellular), open the new socket and resume on it; the relay
  moves the session to the new socket and closes the old one. Today's supersede becomes this
  transfer.
- Status in the UI reads the session: **Connected** only after `resumed` or a fresh session's
  rooms are confirmed, **Reconnecting** while the session is in grace (nothing is lost),
  **Offline** when there is no network or the session is gone. No flicker between attempts.

### 3.8 Phones: work with the OS

- **Remove** the launch-time battery-exemption prompt, the
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission and the Wi-Fi lock. If measured delivery
  delays later justify it, add a Signal-style hint (several days of data, shown at most weekly)
  that opens the settings list, which needs no permission.
- **Going to the background:** flush the outbound queue and acks inside a background task (iOS
  `beginBackgroundTask`), send `{"type":"inactive"}` so the relay holds presence-only chatter
  (XEP-0352's idea), then close cleanly after **10 s** on Android (Telegram's
  `CONNECTION_BACKGROUND_KEEP_TIME`) and when the background task ends on iOS. The session goes
  into grace. While away, push wakes the app (FCM high priority or UnifiedPush) and the existing
  fetch path collects (iOS NSE, Android fetch node).
- **Coming back:** the foreground nudge resumes the session, typically one round trip plus the
  ring replay. Target under 1.5 s to "Connected" on a normal network.
- A foreground service stays out of the default build. Play wants a declared type, a
  user-visible notification and justification for it
  (https://support.google.com/googleplay/android-developer/answer/13392821); UnifiedPush users
  already have a distributor holding the one connection (https://unifiedpush.org/).
- FCM high priority must lead to a visible notification or Google deprioritizes it
  (https://firebase.google.com/docs/cloud-messaging/android-message-priority); the push payload
  stays `{wake, sender}` as today.

### 3.9 The node: suspend is not loss

`WsEvent::Disconnected` splits in two:

- **`Suspended`**: the socket is gone, the session can resume. The node keeps `ws_room_peers`,
  `synced_peers`, call state, throttles and file asks. Sends keep going into the outbound queue.
  Presence comes back from the fresh members snapshots on resume (RoomMembers is already the
  authoritative diff, `feedback_ws_presence_stale_rooms`).
- **`SessionLost`**: the relay refused or forgot the session. Today's purge and full rebuild, then
  gap repair.

The swarm's Connected handler stops re-queueing joins that ws_client already replays (the double
join), and the reconnect-time work it does (pending friend request re-deposit, server joins,
DM rooms, push token, nickname, profile announce) runs only on a fresh session. The once per
connection gates (`answer_resent`, `relay_catchup_done` and the rest) become once per session.

Multi-relay (`MULTI_RELAY_CLIENT_PLAN.md`) needs nothing extra: one session per ws_client, so
one per relay.

### 3.10 Desktop

The same session and triggers. Sleep/wake and network change are the two that matter: a laptop
lid close becomes a grace period instead of a lost minute, and a Wi-Fi to Ethernet switch a make
before break transfer. Windows already has a message loop for `WM_POWERBROADCAST`; macOS and
Linux get small platform listeners, or a Rust crate if one fits.

## 4. Security and privacy

- Resume always re-runs auth v2 with the `sid` inside the signed message. The relay learns nothing
  new: it already sees which device is connected and which rooms it is in.
- The ring holds sealed frames the relay already forwarded. Lanes (`HavenMessage::lane()`), frame
  sealing and the Olm and MLS layers are unchanged. A resent frame is byte-identical, so a receiver
  that did get the first copy drops the second through the nonce cache or message-id dedup, and
  live-only frames still die after 300 s.
- Door-proof rooms, inbox ownership and kill orders are re-checked on resume (3.3); a session
  never carries an authority past a change made during grace.
- Fetch sockets (push fetch, iOS NSE) never get sessions.
- Bounded and fair by construction (3.5), RAM and memfd only, never logged.
- A security review of the resume handshake goes through the audit method in
  `reports/planned/security/SECURITY_AUDIT_PLAN.md` before the relay deploys, with hostile harness
  tests: a resume with another device's `sid`, a replayed resume frame, a resume after removal, a
  stranger filling rings, a session flood from one address.

## 5. Compatibility and rollout

- The relay advertises the capability in `auth_challenge`; a client asks for a session in its
  Auth frame. A 0.12 client never asks and works exactly as today. A new client on an older
  self-hosted relay falls back to today's protocol but keeps the faster liveness and the
  triggers.
- Order, per the relay rules: relay first (tests on the VPS, then `SANITIZE=1`, canary before
  prod), then the client release. The mobile model change (3.8) ships only with client resume,
  since closing on background without resume would make things worse.
- `SELF_HOSTING.md` gains the grace setting.

## 6. Tests

- **Relay C++** (`relay-uws/test`): counting and acks, resume in order, resume with a gap, resume
  refused (wrong peer, unknown `sid`, removed device), grace expiry into `offline_buffer`, ring
  overflow by share, session table eviction, snapshot round trip with sessions (VERSION 9), the
  drain hint, the new KAT in both languages. Run under ASan and UBSan.
- **Harness** (`node/test_harness.rs`): MockRelay gains sessions and a **zombie mode** that
  swallows frames both ways for a set time. Tests: no frame lost across a zombie window in either
  direction (DM, channel post, CRDT op, friend accept, 0x02 file chunk); resume rejoins nothing;
  presence goes offline at the deadline and back on resume; a relay restart resumes; gap repair
  runs after `gap:true` and after `resume_failed`.
- **Fleet**: lifecycle ops so these runs are scripted, not done by hand: `background`,
  `foreground`, `net_off`, `net_on` (Android `svc wifi`/`svc data`, iOS Simulator and macOS
  through the Network Link Conditioner, Linux and Windows by blocking the relay address), plus
  process pause for sleep. A metric step reports **time to healthy** (foreground to Connected and
  a DM round trip).
- **Targets**: zero lost frames across 5 s, 30 s, 2 min and 10 min away; Connected within 1.5 s
  (p50) and 3 s (p95) after foreground on a good network; a hard drop shows offline to friends
  within 45 s; no presence flap on a trip away under 10 s; a relay restart costs no rejoin.
- A one-hour churn soak on the mixed fleet (random background, network cuts, relay restart on
  the canary) with the loss counter at zero.

## 7. Build order

| Step | What | Where | Rough size |
|---|---|---|---|
| 1 | Session object, counting, acks, ring, resume, grace, expiry into `offline_buffer`, fair-share, snapshot VERSION 9, drain hint, C++ tests | relay | 3 sessions |
| 2 | Outbound queue with acks, resume handshake, heartbeat with deadline, full-jitter backoff, nudge entry point, `TCP_USER_TIMEOUT`, flush bug | ws_client | 2 sessions |
| 3 | `Suspended` vs `SessionLost`, no double joins, once per session gates, status from the session | swarm, Dart | 1 to 2 sessions |
| 4 | Triggers on all five platforms (foreground, network, wake) | Dart, Kotlin, Swift, Rust | 2 sessions |
| 5 | Phone model: close on background, inactive hint, remove prompt, permission and Wi-Fi lock | Dart, Kotlin, Swift | 1 session |
| 6 | MockRelay sessions and zombie mode, harness tests, fleet lifecycle ops and metric, soak | tests | 2 sessions |
| 7 | Security review of the handshake, canary relay, deploy, release | all | 1 session |

Steps 1 and 6 start together (the MockRelay model is the spec the relay is tested against). Step
2 needs 1. Step 5 ships only together with 2 and 3. Superseded by the waves in section 10: the
wire spec of section 9 lets steps 1 to 4 and 6 run at once.

## 8. Decisions (Vitalik, 2026-10-06)

1. **Grace length: at least 120 s.** "It should keep the sessions alive for at least 120
   seconds."
2. **Presence: offline as soon as the socket is known dead**, delivery continuing through the
   session. Notifications do not depend on the live socket: while away, the relay's push wakes
   the phone (FCM, APNs, UnifiedPush) as it does today, during grace too.
3. **Android: close 10 s after backgrounding** (Telegram).
4. **The battery prompt goes**, with its permission and the Wi-Fi lock. No measured hint for now.
5. **Reconnect must be instant.** "When you get back to the app and reestablish the connection
   once again, it needs to be blazingly fast without any stupid stallings with waiting on dead
   connection... literally like all big apps do." Hence 3.7: never wait on an old socket, race a
   new one after 1 s, resume in one round trip, target Connected within 1.5 s p50 and 3 s p95.

## 9. Wire specification (wave 0, 2026-10-06)

Binding for the relay and the client alike. Both ends test against one file,
`relay-uws/test/session_vectors.json` (the auth KATs and the counted-frame classification), the
way `roster_vectors.json` and `kill_vectors.json` already pin both languages. Change the vectors
and both sides change with them.

### 9.1 Capability and the v3 auth frame

- The relay advertises sessions in its challenge: `auth_challenge` gains `"session":1`.
- A client sends the v3 frame only to a relay that advertised it, and today's v2 frame otherwise
  (no session; it keeps the faster liveness and the triggers). The relay keeps accepting v2
  exactly as today, so a 0.12 client never notices.
- The v3 frame is the v2 frame with `"v":3` and two more fields: `"session"` is `"new"`, `"none"`
  or a sid to resume, and `"in_h"` is the client's count of stream frames received in that
  session (0 for `"new"` and `"none"`).
- Shape rules, any other combination is `bad_auth`: mode `full` takes `"new"` or a sid; modes
  `fetch` and `guest` take `"none"` (fetch sockets never get sessions). A sid is 32 lowercase hex
  characters (128 random bits).
- The signed bytes, pinned in both languages:

  ```
  hollow-ws-auth3\n{domain}\n{nonce}\n{peer_id}\n{timestamp}\n{mode}\n{license_digest}\n{session}\n{in_h}
  ```

  `in_h` is decimal. Known answer (also in the vectors file): domain `relay.example.com`, nonce
  `0123456789abcdef` four times, peer `12D3KooWPeer`, timestamp `1790000000`, mode `full`, no
  license, session `00112233445566778899aabbccddeeff`, in_h `42` sign exactly
  `hollow-ws-auth3\nrelay.example.com\n0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n12D3KooWPeer\n1790000000\nfull\n\n00112233445566778899aabbccddeeff\n42`.

### 9.2 The relay's answers

| Case | Answer (all uncounted) |
|---|---|
| fresh session (`"new"`) | `{"type":"auth_ok","sid":S,"grace_secs":120,"hb_secs":15}` |
| resume works | `{"type":"resumed","h":R,"gap":G,"reprove":P,"grace_secs":120,"hb_secs":15}` |
| resume impossible | `{"type":"auth_ok","sid":S2,"grace_secs":120,"hb_secs":15,"resume_failed":"unknown"}` or `"bad_h"` |
| v2 frame, or `"none"` | `{"type":"auth_ok"}` as today |

- `R` is the relay's count of stream frames it has received from the client in this session.
  `G` is true when the replay below holds a `gap` frame. `P` is true when the session came back
  from a relay restart (section 9.7): door standing is gone and the client proves its doors again.
- A resume is impossible when no session has that sid **for this peer id** (`unknown`; a sid that
  belongs to another peer id is answered the same way, never revealed), or when the client's
  `in_h` is below what it already acked or above what the relay sent (`bad_h`). The same socket
  then carries a fresh session `S2`: no second round trip.
- A sid whose session is still live on another socket moves to the new socket: the old socket is
  marked superseded and closed with 1000 `moved`, silently (no `peer_left`), like today's
  supersede.
- A `"new"` request from a peer that still holds a session ends that session first: its ring
  hands off as on grace expiry (9.7), its rooms are left silently.
- After `resumed`, in this order: every waiting `kill_signal`, then one `members` per session room
  (with `proved` for locked rooms), then the ring replay of every stream frame after the client's
  `in_h`, then `peer_joined` to whoever sees the device in each room. Nothing is rejoined and
  nothing is resubscribed. After a fresh `auth_ok`, the kill signals as today.

### 9.3 Counting

A **stream frame** is a WebSocket data message (TEXT or BINARY) on a session socket, after
`auth_ok` or `resumed`, that is not in the uncounted set:

- Relay to client, uncounted JSON types: `auth_challenge`, `auth_ok`, `auth_failed`, `resumed`,
  `hb_ack`, `ack`, `reconnect`, `members`, `peer_joined`, `peer_left`, `kill_signal`.
- Client to relay, uncounted JSON types: `auth_hello`, `auth`, `hb`, `ack`, `inactive`, `active`,
  `end`.
- Everything else counts: every binary frame, every other JSON type, and text that does not parse.
  A `{"type":"gap","n":N}` frame counts as N.

Presence (`members`, `peer_joined`, `peer_left`) and kill signals are state: never ringed, re-read
on resume. Both counters start at 0 in a fresh session and the first stream frame is number 1.
The relay counts a client frame when it **arrives**, before any handler decides to drop it; a
frame refused by a membership gate was still handled.

### 9.4 Acks and what each side keeps

- `{"type":"ack","h":N}` both ways, N being the sender's own receive count. Sent once 16 stream
  frames arrived since the last ack, or 2 s after the first unacked one, and `h` also rides every
  `hb` and `hb_ack`. Cumulative and monotonic; an `h` above what the other side sent, or below its
  previous ack, is ignored.
- **Relay ring.** Every stream frame to a session, live or in grace, enters its ring before the
  socket write, and leaves only by ack. Caps per session: 8 MiB and 4096 real frames; all rings
  also count toward the global 512 MB buffer budget (OfflineIndex). Over a cap, the oldest real
  frame of the sender share holding the most bytes in that ring becomes a **tombstone**, adjacent
  tombstones merge, and a tombstone replays as one counted `{"type":"gap","n":N}`. A frame larger
  than the ring cap is still written live but enters the ring as a tombstone. Fan-out frames share
  one buffer across rings. A replay that starts inside a tombstone run sends `gap` for the part
  after the client's `in_h` only. The ring core is `relay-uws/src/session.h`.
- **Client outbound queue** (replaces `pending_commands`). An entry gets its sequence number when
  it is first written; from then it is kept byte for byte (already sealed by `frame_auth`) until
  acked, and is never dropped while the session lives. Flow control, never loss: at 8 MiB or 4096
  written-but-unacked frames the client stops writing until an ack. Unwritten entries stay
  `WsCommand`s, so a join's door proof is made for the session current at write time; they are
  bounded (32 MiB, 20,000 entries), and past that the oldest unwritten entry goes, a live-only
  frame older than the receiver's 300 s window first (`frame_auth` classes it; parse only when
  pruning).
- **On resume** the client drops what `h` covers, resends every written frame after `h` in order
  and byte-identical, then the unwritten queue. An `h` above what the client wrote means the
  relay is not talking about our session: `SessionLost`.

### 9.5 Liveness

- `{"type":"hb","h":N}` every 15 s in the foreground and every 60 s when backgrounded but still
  connected; the relay answers at once with `{"type":"hb_ack","h":M}`.
- Dead = no inbound data at all for 10 s after a heartbeat went out. Any frame counts, so a busy
  download never trips it.
- Relay `idleTimeout` 45; `sendPingsAutomatically` stays, and the client keeps answering pings.
- `TCP_USER_TIMEOUT` 20 s on the client socket (Linux, Android).
- Sleep: every heartbeat tick compares the wall-clock delta with the monotonic delta; more than
  5 s apart means the machine slept, which is a `wake` nudge.

### 9.6 Triggers and the FFI

Three FFI entry points (`api/network.rs`, stubbed in wave 0, codegen done):

- `relay_nudge(reason)`: reasons `foreground`, `focus`, `network`, `wake`. If a frame arrived in
  the last 2 s, nothing. Otherwise a heartbeat with a 1 s deadline; on a miss, open a new socket
  and resume on it while the old one is still judged (make before break), the first to answer
  wins. With no socket, cancel the backoff sleep and connect now. Every nudge resets the backoff.
- `relay_set_background(background)`: true sends `inactive` and slows the heartbeat to 60 s; false
  sends `active`, restores 15 s and nudges `foreground`.
- `relay_suspend()`: flush the queue and the ack, wait up to 2 s for the relay to ack everything
  written, close with 1000 `suspend`, and stay closed until the next nudge. The session goes to
  grace. Async, so iOS ends its background task only after it returns.
- Backoff: full jitter, `random(0, min(30 s, 0.5 s * 2^attempt))`; the attempt resets on success
  and on every nudge. The 1 s retry while `realtime_active` stays.
- `bounded_send` failure is an internal `send_failed` nudge.

### 9.7 Relay session rules

- **States** live, grace, gone. Grace lasts 120 s (`--session-grace-secs`, 30 to 600).
- **Presence follows the socket.** On close or idle timeout the device leaves room presence
  (`peer_left` to whoever saw it, as today) and `peer_sockets`. The session keeps its rooms with
  inbox owner flags and, within this process, door standing; its subscriptions; its nickname and
  link code; its inactive flag.
- **Delivery follows the session.** Fan-out and directs reach live room slots and grace sessions
  alike; a grace session's frames go into its ring only. A device whose fetch socket holds a room
  slot while its full session is in grace gets both copies (the receiver dedups by message id).
- **Push during grace.** A device in grace is offline for push (it is not in `peer_sockets`): a
  direct into its ring also calls `try_push_notify`, debounced as today; `0x09` is unchanged.
- **Nickname.** A binding held by a session, live or in grace, is not stale.
- **Grace expiry** (and `end`, and eviction): the ring's direct frames that `offline_buffer`
  would take today (0x06 frames: DM text, inlined image, channel copy, each under its own cap)
  move there under their room, so the replay on join and the push path take over. Broadcasts,
  topic frames, `0x02` chunks and JSON answers do not (topic rings, sync and `file_asks` cover
  them). Then the session's rooms are left (presence already went at socket death) and it is gone.
- **Re-checks on resume.** Inbox ownership against the roster book's fold (an owner it no longer
  counts loses the inbox, as `drop_inbox_owners`); kill signals first; door standing as below.
- **`inactive` / `active`.** While inactive the relay withholds presence frames from the session;
  `active` (and every resume) sends one fresh `members` per room.
- **`end`.** The session is gone now: the expiry hand-off runs at once, then the normal close.
- **Bounds.** A grace session holds its slot in the per-IP connection cap (`ip_limit_key`) until
  gone. The session table holds at most 262,144 sessions; past it, the session of the address
  share holding the most goes (handing off as on expiry). No rate limit, no refusal: ring
  overflow becomes a gap, never a dropped socket.
- **Restart.** Snapshot VERSION 9 carries every session (as grace, the timer restarting at load):
  sid, peer id, rooms with owner flags, subscriptions, the nickname binding, both counters, the
  ring with its tombstones and each direct frame's room and kind. Door standing and the session's
  door nonce are **not** carried: the door key is per process by design (`crypto.h`), so a
  restored session answers `reprove:true`, its locked rooms come back unproved, and the client
  re-sends a join with a fresh proof for every room it holds a door for.
- **Door nonce.** Within one relay process a session keeps the nonce it was minted with as its
  door nonce, so proofs it showed stay valid across resumes; a socket that resumes a session
  takes the session's door nonce.
- **Drain.** On SIGTERM, before the snapshot, every session socket gets
  `{"type":"reconnect","after_ms":N}`, N uniform in [2000, 10000]. The snapshot and the close run
  in the same loop tick; nothing counted is written after the snapshot. The client waits N, then
  reconnects with resume.
- **Logging.** Nothing about sessions, ever.

### 9.8 Client events and the node

- `WsEvent::Connected` = a fresh session: the first connect, after `SessionLost`, or every connect
  to a relay without sessions. `WsEvent::Suspended` = the socket is gone, the session is held.
  `WsEvent::Resumed { gap }` = the session is back on a new socket. `WsEvent::SessionLost` (was
  `Disconnected`) = the relay refused or forgot the session, or there never was one. Orders: a
  drop with a session gives `Suspended`, then `Resumed` or `SessionLost` + `Connected`; a drop
  without one gives `SessionLost`, then `Connected`.
- `NetworkEvent::RelaySuspended` is new (Dart shows Reconnecting, nothing is lost).
  `RelayConnected` follows `Resumed`, or a fresh session once its rooms are confirmed (the inbox
  join answered), never before. `RelayDisconnected` follows `SessionLost`.
- The node on `Suspended` keeps everything (`ws_room_peers`, `synced_peers`, calls, throttles,
  file asks); sends keep going into the queue. `Resumed { gap: true }` runs the catch-ups
  (DM `GapDigest` syncs, topic catch-up, server syncs) without a single join. `SessionLost` is
  today's purge. `Connected` is today's fresh-session work, and each room has ONE owner of its
  join (no double joins). Once-per-connection gates become once per session.
- On `reprove:true` the client proves its doors again (9.7) with the new socket's
  `RelaySession`; otherwise door proofs keep using the session's original one.

### 9.9 Numbers

| Constant | Value | Side |
|---|---|---|
| Grace | 120 s (30 to 600) | relay |
| Ring caps per session | 8 MiB, 4096 real frames | relay |
| Session table | 262,144 | relay |
| `idleTimeout` | 45 s | relay |
| Drain spread | 2 to 10 s | relay |
| Heartbeat | 15 s foreground, 60 s background | client |
| Heartbeat deadline | 10 s with no inbound data | client |
| Nudge probe | skip if a frame in the last 2 s, else 1 s deadline | client |
| Ack | every 16 frames or 2 s | both |
| In-flight cap | 8 MiB or 4096 written-unacked frames | client |
| Unwritten queue | 32 MiB or 20,000 entries | client |
| Backoff | full jitter, 0.5 s base, 30 s cap | client |
| `TCP_USER_TIMEOUT` | 20 s | client |
| Sleep jump | more than 5 s | client |
| Android close after background | 10 s | client |
| Suspend flush wait | 2 s | client |

## 10. Waves and who owns what

Wave 0 (lead, done): sections 9 and 10, `session_vectors.json`, the relay ring core
(`relay-uws/src/session.h` + `test/test_session.cpp`), the shared stubs (`WsEvent::Suspended`,
`WsEvent::Resumed`, `WsEvent::SessionLost`, `NetworkEvent::RelaySuspended`, the three FFI entry
points with codegen run), and `scripts/mini_sync.sh` for agent folders on the Mac mini. Every
worktree starts from that base.

Wave 1, six agents in parallel, each in its own worktree on D:, test first, mutation-checked, one
final report:

| Agent | Owns | Must not touch |
|---|---|---|
| relay-session | `ws_handler.cpp` session paths (mint, resume, transfer, counting, every send site classified, grace delivery, presence split, push in grace, expiry hand-off, re-checks, inactive/active/end, hb answers, `idleTimeout`), auth v3 in `auth_frame.h` + its C++ KAT, `test_relay_live.cpp` cases | snapshot codec, drain, budget eviction |
| relay-bounds | snapshot VERSION 9 (`snapshot_codec.h`, `snapshot.cpp`), drain hint (`main.cpp`), OfflineIndex charging of rings and global eviction into tombstones, session table cap and per-IP accounting, `--session-grace-secs`, `SELF_HOSTING.md` | handshake and send-site code |
| client-wire | `ws_client.rs` + a new `node/relay_session.rs` (pure protocol state machine): outbound queue, acks, v3 auth + Rust KAT, resume, heartbeat, nudge/background/suspend bodies, make before break, full jitter, `TCP_USER_TIMEOUT`, sleep jump, the flush-tail and join-replay bugs, the vectors test | `swarm.rs`, Dart |
| node-split | `swarm.rs` Suspended/Resumed/SessionLost/Connected handling, one owner per join, once-per-session gates, `RelayConnected` timing, MockRelay sessions and zombie mode, the harness loss tests, Dart connection status | `ws_client.rs` internals |
| triggers | foreground, focus, network change and wake on Windows, macOS, Linux, Android and iOS, all into `relay_nudge` (Dart lifecycle, Kotlin, Swift, Windows runner, Linux) | background close and the battery prompt (wave 2) |
| test-infra | fleet `background`, `foreground`, `net_off`, `net_on`, `pause` ops on every backend, the time-to-healthy metric, the zombie TCP proxy, the end-to-end resume test of the real client against the real relay on the VM, the soak script | product code |

Wave 2 after the merge: mobile-model (step 5), two hostile reviewers of the merged handshake,
the end-to-end runs at 5 s, 30 s, 2 min and 10 min away, the mixed-fleet check. Then the soak,
the canaries, the relay deploy and the release.

Rules every agent follows: read `CLAUDE.md`, the area rule books its work touches and this plan
whole; the wire is section 9 and nothing else (a needed change goes in the final report, never
silently into code); Rust tests in its worktree with its own `CARGO_TARGET_DIR`; relay C++ in its
own folder on the Linux VM; every phone check on the Mac mini (iOS Simulators and Android
emulators, as many as the test needs) through `scripts/mini_sync.sh`, in its own folder there;
never `git checkout`, `reset` or `stash` in a shared tree; no commits.

Fleet peer letters are owned, because fixtures and devices are shared per letter on Windows
and on the mini alike, and `fleet.ps1 -Stop` stops only the `-Peers` it is given: the lead
`a`, `b`; triggers `c`, `d`; test-infra `e`, `f`; node-split `g`, `h`; mobile-model (wave 2)
`i`, `j`; the end-to-end runs `k`, `l`. Every fleet command passes `-Peers` with its own letters.
