# Push Notifications — FCM/APNs Wake-Up, Offline Buffer, Tier 1/2, iOS NSE Tier B

End-to-end push notification system for mobile (Android + iOS). The guiding
principle is **Signal-style empty wake-up**: the push payload carries ZERO
message content — only `{type:'wake', sender:<peer_id>}`. Apple/Google never see
who said what, the message size, or the text. All real content is resolved
on-device by fetching the ciphertext from OUR relay (E2EE) and decrypting locally.

Why pushes at all: mobile OSes kill background processes, so no persistent WS is
possible when the app is closed. FCM (Android) / APNs (iOS) are the only way to
wake a killed app.

---

## Components & data flow

```
sender app ──DM──> relay (target offline) ──buffers ciphertext in RAM──┐
                         │                                              │
                         └─ HTTP /push {token, platform, sender} ─> push-sidecar
                                                                        │
                                                          FCM / APNs (empty wake)
                                                                        │
                                                                   recipient device
                                                                        │
                  ┌──────────── Android ────────────┐   ┌──────────── iOS ───────────┐
                  │ Dart onBackgroundMessage handler │   │ Notification Service Ext.  │
                  │  (runs even when killed)         │   │  (runs; Dart bg does NOT   │
                  │                                  │   │   run when force-killed)   │
                  └───────────────┬──────────────────┘   └─────────────┬──────────────┘
                                  │                                     │
                       start_fetch_node() FFI            hollow_push_fetch_and_decrypt() C-ABI
                                  │                                     │
                                  └──────── both join the DM room on the relay,
                                            drain the replayed buffered ciphertext,
                                            decrypt via Olm, persist to SQLCipher,
                                            post a populated local notification ─────┘
```

---

## Relay — offline buffer (state-and-forward)

`relay-uws/src/{state.h,ws_handler.cpp}`. The relay is normally a dumb pipe, but
to make push content deliver it briefly buffers offline DMs in RAM (ciphertext
ONLY — E2EE preserved).

- `RelayState::offline_buffer`: `target_peer_id -> deque<BufferedMsg>`, **100 text
  + 1 image per peer**, **24h TTL**, swept every 5 min (`sweep_offline_buffer`).
- `handle_binary_direct_msg` / `handle_direct`: when the target peer is offline,
  buffer the raw `0x06` (text) / `0x08` (image) frame.
- `handle_join`: on DM-room join (full node OR fetch peer), **replay + drain** the
  buffer back-to-back. This is why one fetch usually returns the whole unread
  burst as an array.
- `try_push_notify` → `notify_push_sidecar`: fires the push (debounced
  `PUSH_DEBOUNCE_SECS`). Only has peer IDs — **does NOT include ciphertext** (that
  would leak metadata; see iOS section). `push_tokens: peer_id -> {token,platform}`.
- The buffer is **latency glue, not durability** — DM-sync owns durability.

## push-sidecar — FCM/APNs sender

`push-sidecar/index.js` (Node, on the VPS, `hollow-push` systemd service, port
3001 localhost). Receives `POST /push {token, platform, sender}`.

- Data block is always `{type:'wake', sender}` — **no content**.
- **Android:** `android: {priority:'high'}`.
- **iOS:** a VISIBLE ALERT push (NOT a pure silent/background push — Apple
  throttles those to ~2-3/hr). Headers: `apns-priority:10`, `apns-push-type:alert`,
  `apns-collapse-id: iosCollapseId(sender)`. Payload aps: generic
  `alert:{title:'Hollow', body:'New message'}`, `sound:'default'`,
  `mutable-content:1` (triggers the NSE), `content-available:1`.
- `iosCollapseId(peerId)`: deterministic FNV-1a 31-bit hash → used as the APNs
  notification identifier so a new push REPLACES the peer's banner. **Must match
  the Dart `_iosCollapseId` byte-for-byte** (push_notification_service.dart).

## Rust fetch — node/fetch.rs

`run_fetch(relay_domain, peer_id, local_master, keypair_proto, pub_key_b64, license,
sender, server_room, timeout, &mut olm, &mut mls, &crypto_store, db_path,
db_passphrase) -> Vec<FetchedDm>`.

- Connects to the relay in **fetch-peer mode** (`is_fetch=true` in `ClientMsg::Auth`
  → excluded from `peer_sockets`, no `PeerJoined`, invisible to member lists).
- **Multi-device (Step 9A): auths as the DEVICE, rooms by the MASTER.** `peer_id` /
  `keypair_proto` / `pub_key_b64` are the **device** key — the relay keyed this
  device's push token + offline buffer by its device id, and replays a buffered
  frame ONLY to a socket presenting that exact device id (so the fetch MUST auth as
  the device, not the master, or it joins as a different id and finds nothing). The
  DM room is `dm_room_code(local_master, resolve(sender))` — master-paired (rooms
  are derived from masters; `dm_room_code` is pure). The DB passphrase stays
  MASTER-derived (a device-derived one opens an empty DB). The callers
  (`start_fetch_node`, NSE `fetch_and_decrypt`) warm the resolver from the persisted
  device links + `seed_self` before calling, so `resolve(sender)`→master works; the
  decrypted DM is stored under `resolve(sender)` (the master) so a multi-device
  sender lands in the one shared thread. Single-device → every resolve is identity.
- Joins exactly one DM room (DM wake) or the server room (`server_room` Some =
  channel wake), parses binary `0x06` (text) + `0x08` (image) frames + `EditMessage`
  (DM) / MLS + public channel messages (channel).
- `IDLE_AFTER_FIRST = 1200ms`: after the first message, wait only this between
  frames to drain the replayed burst, then return PROMPTLY (the banner can't
  render until this returns). `outstanding_image` holds to the full deadline when
  a referenced image's bytes haven't arrived yet.
- **Persists the advanced Olm session + inserts message rows after each decrypt**
  (`persist_olm_session` / `persist_crypto_state`). On Android the bg isolate, and
  on iOS the NSE when force-killed, are the SOLE DB writer — single-writer-safe.

## FFI surface — api/network.rs

- `register_push_token(token, platform)` — stored on the relay; re-sent on every
  WS reconnect (`swarm.rs`).
- `set_push_prefs(prefs_json)` — channel push filters
  (`{server: {level, channels{cid: level}}}`) registered with the relay; cached
  in swarm.rs and re-sent on every reconnect like the token.
- `get_push_profile(peer_id) -> PushProfile` — opens its OWN SQLCipher connection,
  reads `load_profile_light` + `load_avatar`. Tier 1 (name + avatar, no node).
- `get_push_channel_meta(server_id, channel_id) -> PushChannelMeta` — server +
  channel names and the effective LOCAL notification level, straight from
  SQLCipher (no node). Used by the Android channel-wake handler.
- `start_fetch_node(sender, timeout_secs, server_room) -> Vec<FetchedMessage>` —
  the Dart-facing Tier 2 fetch. `server_room = null` → DM wake (Olm);
  `server_room = server_id` → channel wake (MLS, joins the server room).
  `FetchedMessage` carries `server_id`/`channel_id` for channel entries.
  `FETCH_ACTIVE` AtomicBool guards against concurrency; refuses to run while the
  full node is up. Uses `load_existing_identity()` (NEVER generate).

---

## Android — Dart background handler

`lib/src/core/services/push_notification_service.dart`,
`_firebaseBackgroundHandler` (`@pragma('vm:entry-point')`). Runs even when the app
is force-killed (Android relaunches the isolate for a high-priority data message).

Order (happy path): init Rust → `getPushProfile` (name+avatar, don't post yet) →
`startFetchNode` → post ONE already-populated banner (no generic flash). Fallback
to name+avatar/generic only on empty/error/locked-identity.

Notification UX: per-peer card (`sender.hashCode`), InboxStyle last-3 +
"+N more · X new messages", Android-painted count, `groupKey:'hollow_dm_group'` +
silent group summary (`GroupAlertBehavior.children`) bundling multiple peers,
`dismissPeerNotification()` clears the summary when no children remain. Status-bar
icon MUST be the monochrome `@drawable/ic_stat_hollow`.

Background-isolate gotchas: `RustLib.init()` is NOT idempotent (reused isolate
throws "twice" → treat as ready); NEVER `load_or_create_identity()` (use
`load_existing_identity()`); `log_path()` honors `set_data_dir()`. Lines
accumulate across separate pushes via `_accumulateLines` (keyed by message_id so
edits replace; cleared on chat open via `clearNotificationLines`).

---

## iOS — Notification Service Extension (Tier B, LIVE)

**The crux:** iOS does NOT run the Dart `content-available` background handler when
the app is **force-killed** (Apple won't relaunch a user-terminated app). Only the
**NSE** (a separate process iOS always spawns for `mutable-content:1`) runs. So all
iOS content resolution happens in the NSE.

### Files
- `ios/NotificationService/NotificationService.swift` — the NSE.
- `ios/NotificationService/HollowPushBridge.h` — bridging header exposing the C-ABI.
- `rust/hollow_core/src/push_enrich.rs` — the Rust C-ABI (OUTSIDE `crate::api` so
  flutter_rust_bridge codegen never scans it; `pub mod push_enrich;` in lib.rs).

### NSE flow (`didReceive`)
1. Set `content.threadIdentifier = sender` (native per-peer grouping).
2. **Tier A (instant):** read the App Group `push_hints/hints.json` cache (written
   by `lib/src/core/services/push_hints_cache.dart`) → set title=name, attach
   avatar, body="Sent you a message". Writer & reader paths MUST match
   (`push_hints/`, NO `hollow/` prefix).
3. **App-active heartbeat check:** if `<AppGroup>/push_diag/app_active.txt` is
   fresh (<12s), the live node already has the message → skip fetch, deliver Tier A.
4. **Tier B (force-killed):** call
   `hollow_push_fetch_and_decrypt(data_dir, relay, sender, license, timeout)`
   pointing at `<AppGroup>/hollow_data`. Returns JSON
   `[{text,message_id,timestamp,has_image}]`.
5. `bannerContent`: render the LAST 3 messages as a multi-line body + "N new
   messages" subtitle. Image/sentinel texts → "📷 Image".
6. Sample `task_vm_info.phys_footprint`, log to `<AppGroup>/push_diag/nse_metrics.log`
   (capped 64KB). Deliver. `serviceExtensionTimeWillExpire` delivers best attempt.

### Rust C-ABI — push_enrich.rs
- `hollow_push_fetch_and_decrypt(...) -> *mut c_char` (JSON; free with
  `hollow_push_string_free`). Wraps `node::fetch::run_fetch` with its OWN
  `current_thread` tokio runtime (no Dart isolate / global runtime in the NSE).
  `set_data_dir(data_dir)` first so identity + DB resolve to the App Group copy.
- `hollow_push_decrypt(...)` — an offline fork-decrypt variant (decrypts a single
  supplied ciphertext on a THROWAWAY session copy via `Session::from_pickle`,
  never writes back). Kept as a proven alternative; the fetch path is the one used.
- Edition 2024: `#[unsafe(no_mangle)]` + explicit `unsafe {}` inside `unsafe fn`.

### Data-dir migration & shared DB
`lib/src/core/services/ios_data_dir_migration.dart` MOVES the data dir from the
private sandbox to `<AppGroup>/hollow_data` (copy-verify-delete, idempotent, falls
back on failure) so app + NSE share ONE SQLCipher DB. Runs in `main.dart` BEFORE
RustLib opens the DB. The App Group container path is also stable across reinstalls.

**CRITICAL — shared DB MUST use `journal_mode=TRUNCATE` on iOS, not WAL.** WAL's
persistent `-shm` lock in a shared container makes RunningBoard kill the suspended
app with `EXC_CRASH 0xdead10cc`. `busy_timeout=4000` lets app+NSE coexist. Set in
`storage/messages.rs` behind `#[cfg(target_os="ios")]`.

Heartbeat: `hollow_shell.dart` lifecycle touches `app_active.txt` on resume /
clears on pause so the NSE knows whether the live node is handling messages.

### Build wiring (no manual Build Phases)
The Rust lib ships as `hollow_core.framework` via CocoaPods. The NSE links it via a
Podfile `target 'NotificationService'` block declaring ONLY
`pod 'hollow_core', :path => '.symlinks/plugins/hollow_core/ios'` (NOT
`flutter_install_all_ios_pods` — Firebase/WebRTC would blow the ~24MB NSE cap).
`pod install` (needs `LANG/LC_ALL=en_US.UTF-8` over SSH or it crashes) generates
`Pods-NotificationService.*.xcconfig` with `-framework "hollow_core"`. Bridging
header set via `SWIFT_OBJC_BRIDGING_HEADER` on all 3 NSE configs.

NSE measured footprint **~3MB vs the 24MB cap** — the whole networking+SQLCipher+
vodozemac stack fits (phys_footprint counts touched pages + dead-strip).

### Diagnostics
Security settings tab (iOS) → "Export Push Diagnostics"
(`lib/src/ui/mobile/tabs/mobile_settings_tab.dart`) bundles
`push_diag/nse_metrics.log` + `app_active.txt` + `push_debug.log` +
`hollow_debug.log` via `FilePicker.saveFile(bytes:)`. There's no debugger on
TestFlight, so this is how NSE footprint + fetch success are read off-device.

### Other iOS facts
- Classic non-UIScene AppDelegate (`register(with: self)`); firebase pinned below
  the iOS-SDK-v12 break (`firebase_core ^3.15.2`, `firebase_messaging ^15.2.10`)
  to keep the iOS 13 floor.
- `aps-environment=production` for TestFlight (release-signed).
- **Vitalik builds iOS via Xcode Archive himself — NEVER run `flutter build ios`.**

---

## Channel push notifications (server channels, 2026-06-10)

DM push extended to server channels. Same privacy invariants: push payload =
opaque IDs only (`{type:'channel_wake', sender, server, channel, mention:'1'/'0'}`),
relay never learns server membership, content decrypted on-device.

### Sender fan-out (message_ops.rs `handle_send_channel_message`)
After the room/topic broadcast, the sender filters `server.members` by
`!same_identity(self)` + `!peer_is_reachable` (offline members, excluding our own
siblings) and **expands each offline MASTER member to its real DEVICE ids** —
`devices_for(master)` ∩ has-session ∩ not-in-room (the same offline-real predicate
as DM fan-out; falls back to the master id for a single-device member). The relay
keys the push token + buffer by DEVICE id, so targeting the bare master would buffer
under an id no device authenticates as → no push reaches any device (Step 9A fix).
Each target device gets a **0x09 frame**:
`[0x09][room\0][target\0][channel\0][flags:1][payload]` (flags bit0 = mention; the
mention is computed once per master and applied to all its device frames).
Payload = the SAME wire bytes the room broadcast carried — MLS group ciphertext
is decryptable by every member, so one encryption serves both paths
(`send_mls_broadcast_topic` now returns the serialized `MlsChannelMessage` bytes;
public channels reuse the `PublicChannelMessage` JSON). The legacy Olm fan-out
path sends an EMPTY payload (push trigger only — pairwise Olm can't pre-encrypt
for offline peers without burning ratchet slots).

Per-target mention flag computed by the sender (only it has plaintext):
`@everyone` | `@display_name` | `@server_nickname` (case-insensitive vs
`server.members[].display_name` + `server.nicknames[].read()`) | reply-to-author
(`get_channel_message_sender(reply_to_mid)`).

### Relay (`handle_binary_channel_direct`, ws_handler.cpp)
Only acts when the target is FULLY offline (online members got the broadcast):
buffers the payload (separate cap `MAX_BUFFERED_CHANNEL_MSGS_PER_PEER=30`,
replayed as 0x06 on room join exactly like DMs) and calls
`try_channel_push_notify`, which filters by:
1. **Push prefs registry** (`set_push_prefs` text msg → `RelayState::push_prefs`,
   `peer → server → {level, channels{cid→level}}`, RAM only, replaced wholesale).
   Channel override beats server level; unregistered peer/server = "all"
   (backward compatible). Filtering MUST be relay-side: iOS alert pushes cannot
   be suppressed after delivery. The app syncs prefs via
   `notification_provider._syncPushPrefsToRelay()` on loadAll/setServerLevel/
   setChannelOverride — **MOBILE-ONLY** (desktop sync would overwrite the
   phone's filters); swarm.rs caches + re-sends on every reconnect like the token.
2. **Anti-spam throttles** (state.h): non-mention = 120s per (peer,server) +
   max 3 pushes while continuously offline (`channel_push_state`, reset when the
   full non-fetch app rejoins that server room in `handle_join`; deliberately NOT
   cleared on disconnect); mention = 10s per (peer,server); 5s per-peer floor
   across all servers (`last_channel_push_any`). Mentions bypass the long window.

Sidecar: `channel_wake` data type (FCM data values must be STRINGS — mention is
'1'/'0'); iOS `apns-collapse-id = iosCollapseId("server:channel")` → one
replaceable banner per channel; same generic alert body.

### Fetch + MLS decrypt (fetch.rs)
`run_fetch` gained `server_room: Option<&str>` + `mls: &mut Option<MlsManager>`.
Channel wake joins the SERVER room (fetch=true, invisible), parses 0x06 replays
+ live 0x05/0x08 frames, decrypts `MlsChannelMessage` via
`MlsManager::from_persisted(signer, cred, storage, &[server_id])`, inserts
channel rows (dedup `channel_message_exists`), persists MLS state after the loop
(single-writer-safe — same heartbeat/FETCH_ACTIVE guards as Olm).
`PublicChannelMessage` plaintext is verified-by-signature and inserted directly
(sender = relay-attested frame author). **Stale MLS epoch (missed a commit while
offline) = graceful**: decrypt fails → content-free banner → app self-heals via
channel sync + MLS recovery on next open. `FetchedDm`/`FetchedMessage` carry
`server_id`/`channel_id` (None for DMs).

### Android (`_handleChannelWake`)
Local re-check via `get_push_channel_meta(server_id, channel_id)` (new FFI: opens
its own SQLCipher like get_push_profile, returns server/channel names + the
effective LOCAL level resolved from `notif:` keys — catches stale relay prefs).
Fetch → group the replay burst by channel (it spans the whole server room; the
push's mention flag only applies to its channel, other channels need level
"all") → per-channel banner "ServerName • #channel" / "Name: text", InboxStyle,
own group `hollow_channel_group` + silent summary (id 0x40000002), notif id =
`_iosCollapseId('$server:$channel')` (shared FNV impl). Tap payload
`channel:<sid>:<cid>` → `registerOpenChannelHandler` (MobileShell, cold-start
buffered). `dismissChannelNotification(server, channel)` wired in
MobileChatRoute's channel branch.

### iOS NSE (`handleChannelWake`)
`hollow_push_fetch_and_decrypt` gained a **6th param `server_room`** ("" = DM
mode) — bridging header + BOTH call sites updated. Channel entries additionally
carry `server_name/channel_name/sender_name` resolved in Rust
(`push_enrich.rs`: parses `load_server_state` JSON + `load_profile_light`) — NOT
via PushHintsCache. `threadIdentifier = server`; renders "Server • #channel" +
last-3 "Name: text" lines; app-active heartbeat skips the fetch as with DMs.

Scope: TEXT channel messages only in v1 — channel files/images and
edits/deletes/reactions don't push (reconciled by channel sync).

Observed latency (Pixel, 2026-06-10): handler start → populated banner ~2.5s
(0.4s Rust init when cold + ~1s relay TLS connect + 1.2s `IDLE_AFTER_FIRST`
drain window); plus 1-3s FCM delivery upstream.

---

## Related
- `relay_uws_server.md` — relay offline buffer details.
- `rust_ffi_network.md` — FFI signatures.
- `rust_networking.md` — fetch.rs / ws_client.rs.
- Memory: `project_channel_push_notifications.md` (channel push),
  `project_ios_push_tier_b_disposable_nse.md`,
  `project_push_notification_implementation.md`, `feedback_app_group_path_match.md`,
  `feedback_ios_appgroup_sqlite_wal_crash.md`, `feedback_no_ios_build_command.md`,
  `feedback_fcm_image_invisible_bubble.md`, `feedback_rustlib_init_not_idempotent.md`.
```

## Notification tap → chat navigation (2026-06)

Tapping any Hollow notification opens the sender's DM chat. Three entry points, ALL required (push_notification_service.dart):
1. `FirebaseMessaging.onMessageOpenedApp` — system/APNs banner tapped while backgrounded (covers iOS NSE banners; payload `data['sender']`).
2. `FirebaseMessaging.instance.getInitialMessage()` — app COLD-STARTED by a push tap.
3. flutter_local_notifications (Android bg-fetch banners): `onDidReceiveNotificationResponse` (app alive) + `getNotificationAppLaunchDetails()` (cold start). Every per-peer `plugin.show()` must pass `payload: sender` or the tap carries no target (the group summary intentionally has none → just opens the app).

Routing: `PushNotificationService.registerOpenChatHandler` (and `registerOpenChannelHandler` for channel pushes) is called from `_MobileShellState.initState`. Taps arriving BEFORE registration (cold start: push init runs in node start, shell mounts after identity unlock) are buffered (`_pendingOpenChatPeer`) and delivered on registration. The handler `_openChatFromPush` (mobile_shell.dart) mirrors the in-app banner: set `selectedPeerProvider`, null `selectedServerProvider`, `markDmSeen`, push `MobileChatRoute` via rootNavigator, clear selection in `.then()`.

**Multi-device device→master resolution + KNOWN iOS GAP (2026-06-20).** A DM push `sender` can be the friend's DEVICE id, but every DM thread/provider keys on the MASTER. `_openChatFromPush` resolves device→master via the Rust `identityFor` FFI (live node resolver, warmed at startup) with a `deviceLinkProvider` mirror fallback, then `peerId.isEmpty?peerId`. Android works (it taps the Dart-posted local banner whose payload is already the resolved master `personKey`). **iOS DM tap is STILL broken** — a force-killed iOS tap arrives via FCM `data['sender']` (raw device id) through `onMessageOpenedApp`/`getInitialMessage`, and the resolve didn't fix it (resolver/links likely still cold on the freshly-woken node at tap time). Channels are fine (key on `server:channel`, identity-independent). Open in HOLLOW_PLAN.md; next: log the actual id reaching the handler, resolve inside `MobileChatRoute` after links settle, or carry the master in the push payload.

**iOS hints-cache device aliasing (push_hints_cache.dart, 2026-06-20).** The NSE does a raw `map[sender]` lookup against `hints.json` to show name/avatar, with no resolver. Since a sender can be a device id, `writeNow` keys each friend's hint under the MASTER **and every device id** that resolves to it (`getDeviceLinks()`), so `map[sender]` hits regardless of which device sent — else the banner degrades to a content-free "New message". Avatar file stays one-per-person (master-keyed); alias entries point at it.
