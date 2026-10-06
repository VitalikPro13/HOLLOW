# Resumable relay sessions: a connection that survives phones, sleep and bad networks

Status: planned 2026-10-06, nothing built. Written after the mixed iPhone/Android fleet run that
found a nickname dying with the socket and an accept lost to a dead connection. Research digest
and code map from that session are folded in below; every claim about other apps carries its
source.

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
2 needs 1. Step 5 ships only together with 2 and 3.

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
