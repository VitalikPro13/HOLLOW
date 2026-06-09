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

`run_fetch(relay_domain, peer_id, keypair_proto, pub_key_b64, license, sender,
timeout, &mut olm, &crypto_store, db_path, db_passphrase) -> Vec<FetchedDm>`.

- Connects to the relay in **fetch-peer mode** (`is_fetch=true` in `ClientMsg::Auth`
  → excluded from `peer_sockets`, no `PeerJoined`, invisible to member lists).
- Joins exactly one DM room (`dm_room_code(peer_id, sender)`), parses binary `0x06`
  (text) + `0x08` (image) frames + `EditMessage`.
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
- `get_push_profile(peer_id) -> PushProfile` — opens its OWN SQLCipher connection,
  reads `load_profile_light` + `load_avatar`. Tier 1 (name + avatar, no node).
- `start_fetch_node(sender, timeout_secs) -> Vec<FetchedMessage>` — the Dart-facing
  Tier 2 fetch. `FETCH_ACTIVE` AtomicBool guards against concurrency; refuses to
  run while the full node is up. Uses `load_existing_identity()` (NEVER generate).

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

## Related
- `relay_uws_server.md` — relay offline buffer details.
- `rust_ffi_network.md` — FFI signatures.
- `rust_networking.md` — fetch.rs / ws_client.rs.
- Memory: `project_ios_push_tier_b_disposable_nse.md`,
  `project_push_notification_implementation.md`, `feedback_app_group_path_match.md`,
  `feedback_ios_appgroup_sqlite_wal_crash.md`, `feedback_no_ios_build_command.md`,
  `feedback_fcm_image_invisible_bubble.md`, `feedback_rustlib_init_not_idempotent.md`.
```
