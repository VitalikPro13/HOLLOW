# HOLLOW — Project Instructions for Claude Code

## What Is This
Hollow is a fully distributed, encrypted Discord alternative. No central servers. Members collectively host the server. See `HOLLOW_PLAN.md` for the full architecture, phase history, and current TODO checklist.

## Tech Stack
- **UI:** Flutter (Dart) — all platforms (Windows, macOS, Linux, Android, iOS, Web)
- **Backend:** Rust via `flutter_rust_bridge` v2.11.1 FFI
- **Networking:** WSS relay (signaling + text/CRDT/MLS) + WebRTC data channels (files/shards P2P) + WebRTC media (voice/video P2P). libp2p fully removed.
- **E2EE:** vodozemac (Olm/Double Ratchet) for DMs, OpenMLS 0.8 for servers, SFrame (AES-128-GCM) for voice/video/screen share
- **Local DB:** SQLCipher (encrypted SQLite)
- **Identity:** Ed25519 keypairs via BIP-39 mnemonic (ed25519-dalek, NativeKeypair)
- **Org ID:** com.anonlisten · **Project name:** hollow

## Project Structure
```
HOLLOW/
├── lib/                  # Dart/Flutter (UI, app logic, state)
│   ├── main.dart         # Entry point (ProviderScope + RustLib.init + window_manager)
│   └── src/
│       ├── core/         # Models, Riverpod providers, service wrappers
│       ├── theme/        # Hollow design system (colors, spacing, typography)
│       └── ui/           # shell/ chat/ settings/ sidebar/ components/ dialogs/ animations/ mobile/
├── rust/hollow_core/      # Rust crate (networking, crypto, storage)
│   └── src/
│       ├── api/          # FFI layer (flutter_rust_bridge scans these)
│       ├── node/         # swarm.rs (event-loop dispatcher) + focused modules: types, crypto_handler,
│       │                 # sync_handler, message_ops, social, vault_ops, file_handler, voice_handler,
│       │                 # gossip_relay, gossip, ws_client, ws_stream_transfer, file_transfer,
│       │                 # recovery_pool, twitch, image_convert, link_preview, link_handler, crdt_store,
│       │                 # test_harness (cfg(test))
│       ├── crypto/       # Olm + MLS + persistence (store.rs = CryptoStore)
│       ├── identity/     # Ed25519 keypair management
│       └── storage/      # SQLCipher message store
├── relay/                # Legacy Rust relay (superseded by relay-uws)
├── relay-uws/            # Production relay (uWebSockets C++, native TLS, OVH VPS)
├── packages/flutter_webrtc/ # FORK 1.5.2, stock libwebrtc m144 (WASAPI loopback, native recording/share);
│                         # screen_audio_capturer.exe = SEPARATE target. See project_flutter_webrtc_152_upgrade
├── rust_builder/         # flutter_rust_bridge build system (cargokit)
├── vendor/ffmpeg/        # Bundled native binaries (gitignored, fetch_ffmpeg.ps1)
├── legal/                # Privacy Policy, Terms, version manifest
├── HOLLOW_PLAN.md         # Architecture & design doc (authoritative for phases)
└── CLAUDE.md             # This file (HARD budget: 40,000 chars — rule + memory pointer, never the war story)
```

## Build & Run Commands
```bash
flutter run -d windows                         # run debug on current platform
flutter build windows                          # release build
flutter test test/                             # widget tests (~1s, no device)
cd rust/hollow_core && cargo check             # (also cargo clippy)

# Multi-node integration harness — PRIMARY verification for distributed-logic changes
cargo test --lib test_harness -- --nocapture   # N real nodes over in-process MockRelay
cargo test --lib                               # full Rust suite

# Regenerate FFI bindings after Rust API changes (MUST run from project root)
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"

# Deploy relay to VPS
scp relay-uws/src/*.cpp relay-uws/src/*.h relay-uws/CMakeLists.txt ubuntu@141.227.186.209:/home/ubuntu/relay-uws/src/
ssh ubuntu@141.227.186.209 "cd /home/ubuntu/relay-uws/build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j2 && sudo setcap cap_net_bind_service=+ep hollow-relay && sudo systemctl restart hollow-relay"

# Windows release pipeline (build → code-sign → Inno installer → sign → zip; prompts for Certum PIN)
pwsh scripts\build_release.ps1                 # full pipeline (-SkipBuild to repackage)
pwsh scripts\sign_release.ps1                  # sign every .exe/.dll in the Release folder
```
**Windows code signing (Certum):** USB card, minidriver; scripts self-heal the CNG binding; output `installer\Output\` (gitignored). See `reference_certum_signing_procedure`.

## Hollow Design System
All UI uses custom Hollow widgets — no Material defaults: **HollowPressable** (`subtle` mode), **HollowButton** (`.filled()/.ghost()/.outline()/.danger()`), **HollowTextField**, **HollowDialog** (`showHollowDialog()`), **HollowTooltip** (dismiss via `_dismiss()` — immediate, no reverse anim), **HollowToast**, **HollowToggle**, **StatusDot** (presence by SHAPE — pass `filled: isOnline`), **StatBar/DailyUsageMeter**.
- **CRITICAL — hover states:** NEVER animate a color from `Colors.transparent` (lerps via black); HollowPressable callers pass `backgroundColor: null`, never `Colors.transparent`; hover must never paint outside the control (spacing outside, selection bg ON the pressable). Dialog pairs = ghost Cancel + filled confirm; `.danger` ONLY for destructive; selection state = chips, never `.filled` — `feedback_hover_state_patterns`.

## Key Architecture Notes
- **Multi-node test harness = PRIMARY testing for distributed logic.** `node/test_harness.rs` (cfg(test)): N real `spawn_node` loops over an in-process `MockRelay`, two-layer inspectors (UI = master-collapsed, raw = device-keyed). ALWAYS verify ring-1/ring-2 changes before declaring done. NOT covered: media/pixels/FFI/native/relay C++. See wiki `rust_test_harness`, `feedback_harness_first_testing`.
- **Node modules:** `swarm.rs` = event-loop dispatcher; domain logic lives in focused modules as `pub(crate) async fn handle_*()` called from swarm match arms; types/enums in `types.rs`. No SwarmContext struct — pass state vars individually (`feedback_swarmcontext_borrow`). New envelope variants go in the right module's `handle_envelope_*()` (`feedback_envelope_dispatch_pattern`).
- **Persistence actors:** `CrdtStore` (`node/crdt_store.rs`) + `CryptoStore` (`crypto/store.rs`) own long-lived SQLCipher conns in spawn_blocking threads, fire-and-forget mpsc; CrdtStore batch-drains (blocking_recv + try_recv) into one DB write per server. All sync_handler saves use CrdtStore; MLS persistence uses CryptoStore. NEVER open `MessageStore::open()` in a sync handler (`feedback_sqlcipher_open_hygiene`).
- **Peer state in swarm.rs:** `ws_room_peers` + `synced_peers`; PeerJoined → key exchange + sync; 30s keepalive in ws_client.rs.
- **Relay domain (self-hosting):** `relayDomainProvider` + `set_relay_url()` FFI, default `relay.anonlisten.com`; ALL WS/signaling/STUN/TURN URLs derive from it.
- **Event streaming:** Rust→Dart via `StreamSink` — `watch_network_events()` (`api/network.rs`) → `EventStreamNotifier` (`event_provider.dart`).
- **Profiles/avatars:** profiles load light (`getAllProfilesLight()`, no blobs); `HollowAvatar` auto-fetches from `avatarProvider` — never pass `imageBytes:` from profile data (only for archive exports / explicit overrides); banners via `bannerProvider`; `ProfileUpdated` invalidates BOTH caches. See `feedback_lazy_avatar_pattern`.
- **CRITICAL — profile announces are LIGHT:** `send_own_profile_to_peer` sends NO blobs — empty b64 + SHA-256 hashes; stale receivers pull once via `ProfileRequest`. Blobs ride ONLY the ProfileRequest response + `handle_update_profile`; blobs on an announce path = budget leak. File sweeps: per-conversation, ONE source, throttled — `feedback_profile_light_announce_bandwidth_leak`.
- **CRITICAL — Profile Showcase Board:** wire field `Option<String>` (absent = old client → PRESERVE; `""` = clear); NO relational blocks (VETOED); IGDB authoring-only via `igdb/search.php` POST-only (deprecated enums return NOTHING silently); images LOSSY WebP; fetchers refuse non-Hollow-CDN URLs. See `project_showcase_board_impl`.
- **CRITICAL — custom emotes:** content-addressed WebP, wire token `[e:name:hash]` (grammar dual-defined: `node/emotes.rs` + `emote_image.dart`); bytes NEVER ride CRDT/envelopes/relay — pull via verified `EmoteRequest`→`EmoteAssets`. FFZ = AUTHORING-ONLY (`ffz/` proxy). Composer: 1 PUA ↔ 1 WidgetSpan; send sites read `expandedText()`, NEVER `.text`; notif previews via `emotePreviewSpans`/`emoteTokensToShortcodes` — `project_custom_emotes_ffz`, wiki `emotes`.
- **Emoji rendering:** bundled NotoColorEmoji (Win/Linux) MUST stay emoji-only subset (`scripts/subset_emoji_font.py`) — unsubset hijacks space/digits. See wiki `emotes`.
- **CRITICAL — CRDT sync batches parse tolerantly:** always `parse_ops_tolerant`, never `from_str::<Vec<CrdtOp>>` — one unknown NEWER-client variant poisons the batch and wedges older clients' sync. See `project_custom_emotes_ffz`.
- **CRITICAL — `CrossAxisAlignment.stretch` Row needs bounded height**: the subtree dies INVISIBLY (still occupies space) — wrap in `IntrinsicHeight`. srcIn tints need TRANSPARENT ink. `ref.listen` ONLY in build() (initState registration silently no-ops). Never `Flexible` beside `Expanded` (splits free space 50/50). See `feedback_dart_patterns`.
- **CRITICAL — blocking & Saved messages:** block list = MASTER-keyed, process-global (`node/blocklist.rs`, warmed at startup) — new inbound DM-surface handlers drop via `blocklist::is_blocked(sender)` BEFORE store+emit (harness caveat: shared set). `reports.json` = the relay's ONE persisted peer artifact (hashed, anonymous). Saved messages = self-DM (fan-out skips the recipient branch on self) — `project_saved_messages_block_report`.
- **Navigation shell:** two persisted layout modes (`layoutModeProvider`): Dock (default — FriendsBar + BottomBar) and Classic (Discord-like 4-panel); mobile = single-panel bottom nav. Vitalik uses Dock — put new UI in `bottom_bar.dart`.
- **Window chrome:** `window_manager ^0.5.1`, `setAsFrameless()`, 32px title bar.
- **Theme:** `HollowTheme.dark()/.light()` + hue variants; `themeModeProvider` persisted. Contrast: `accentText` for accent-colored TEXT (raw `accent` = fills only), `textTertiary` for faded metadata — both 4.5:1 (`contrast.dart`, CI guard `test/contrast_test.dart`). Old window-chrome icons hardcode white — grep `Colors.white` for light theme.
- **Accessibility (epic CLOSED).** Iron rules: (1) icon-only controls need a PURPOSE label + (2) focus rides `HollowFocusRing` — both CI-guarded. (3) Reduce motion only via `ReduceMotionController`; mobile routes via `hollowMobileRoute()`. (4) Larger text: only the 3 safe bar-fix patterns. (5) StatusDot = presence by SHAPE (`filled:`). (6) Never `dart format` mid-edit — `project_accessibility_*`.
- **Icons:** `lucide_icons_flutter ^3.1.14` (camelCase; no `cloudCheck` — use `cloud`); brand icons in `brand_icons.dart`; `atlas_icons ^0.0.12` (snake_case; NSFW = `Atlas.adult_18`).
- **Identity at-rest protection:** two opt-in modes (Settings > Security): password (Argon2id + AES-256-GCM, blocks launch) or OS keychain (Windows Credential Manager + DPAPI fallback / macOS Keychain, silent). `unlock_identity()` before any identity/DB op; recovery = 24-word mnemonic. Byte format (HKEYV1) + design rules in `project_identity_protection`.
- **License keys:** relay `keys.json` gates WS auth, hot-reloads 30s with live revocation; app checks `/relay-status` on startup, caches via `set_license_key()` FFI.
- **Temporary nicknames:** relay-scoped RAM claims; resets on `RelayDisconnected`. See `project_temporary_nicknames`.
- **Deep links:** `hollow://` on all 6 platforms via `DeepLinkService` (init pre-runApp, buffers until shell ready). Invites COPY `webServerInviteLink()` (`…/join#server=ID` — FRAGMENT, id never hits server logs); ALL link input bars parse via `inviteIdFromInput`/`classifyHollowLink`; Windows forward = NO-ARG `SendAppLinkToInstance()` in main.cpp. See `project_deep_linking`.
- **Window title bar:** `WindowTitleBar` lives in `MaterialApp.builder` ABOVE the Navigator, never inside HollowShell; Navigator child wrapped in `ClipRect` against `BackdropFilter` blur bleed.
- **Logging:** `hollow_log!` → stderr + `hollow_debug.log` (release-safe, 10MB rotation); `hollow_crash.log` = Flutter/platform errors (5MB rotation).
- **Relay:** uWebSockets C++ (`relay-uws/`) on OVH VPS, TLS 443, dual-stack. NO rate limits/soft backpressure; NEVER lower `maxPayloadLength` (64MB). Topic routing `0x07` (channel_id), broadcast `0x03`. See `feedback_relay_rules`, `feedback_relay_no_metadata_logging`.
- **CRITICAL — relay per-IP accounting goes through `ip_limit_key()`** (v4 addr / v6 **/64**; unmap v4-MAPPED `::ffff:…` FIRST — naive /64 truncation collapses ALL v4 clients into ONE bucket). 10 GB/day byte budget counts binary BOTH directions; exhaustion = explicit `1008 "bandwidth_limit"` close, never a silent drop. See `project_relay_bandwidth_enforcement`, `project_relay_ipv6`.
- **CRITICAL — relay offline delivery (availability cache, default ON 3d):** anything that must reach OFFLINE channel members MUST ride `0x07` topic frames — `0x03` broadcasts and targeted direct sends are invisible to the TTL rings. MLS groups need `hollow_join_config`. OPEN BUG: channel files don't render post-catchup. See `project_relay_availability_cache`.
- **Storage layout:** data root = `dirs::data_dir()/hollow` (`keys.rs::data_dir`; override via `set_data_dir()`/`HOLLOW_DATA_DIR`; NOT `~/.hollow`); mobile = sandboxed app documents (iOS in the App Group). Subfolders: `files/` (full replication), `vault/` (shards), `vault_cache/` (LRU 1GB) + `identity.key`/`identity.device` + `messages.db`.

## Coding Conventions
- Dart: `flutter_lints`/`analysis_options.yaml`. Rust: `cargo clippy`. snake_case filenames. Flutter only for UI — no Electron/Node/web frameworks.
- **NEVER pass `WidgetRef ref` as a constructor parameter** — use `ConsumerWidget`/`ConsumerStatefulWidget` (passing `ref` causes cascade rebuilds).
- Use `AnimatedOpacity` (GPU-composited) for per-item opacity, never the `Opacity` widget.
- **CRITICAL — backward-compatible DB schema:** ALWAYS add `#[serde(default)]` to ANY new field on a persisted Rust struct — else old data fails to deserialize and silently vanishes (servers disappear).
- **CRITICAL — flutter_webrtc native input selection (audio AND video) uses `sourceId`:** `{'optional': [{'sourceId': deviceId}], ...}` — `{'deviceId': ...}` is silently ignored.
- **CRITICAL — server switching batches provider writes atomically:** `channelListProvider`, `channelLayoutProvider`, `selectedServerProvider`, `selectedChannelProvider` update in ONE synchronous block (canonical: `server_strip.dart:_selectServer`).
- **CRITICAL — TURN ICE config:** each TURN URI = its OWN `IceServer` entry (native has one `uri` per struct). Credentials arrive via the authed WS (`NetworkEvent::TurnCredentials` → `iceConfigProvider`) — never re-add a Dart HTTP fetch. HTTP signaling is RETIRED; WS `discover_peers` is discovery.
- **CRITICAL — VAD/speaking state lives in `speaking_provider.dart`**, NEVER in CallState/VoiceChannelState (rebuilds the shell); consumers select membership. MLS send-path encrypts persist IMMEDIATELY — never debounce (`feedback_mls_patterns`).
- **CRITICAL — MLS epoch staleness:** sync requests use plaintext `HavenMessage`; CRDT broadcast falls back to plaintext on MLS failure. All 8 MLS rules in `feedback_mls_patterns`.
- **CRITICAL — WS send failures trigger reconnection:** `send_command()` (ws_client.rs) returns `bool`; on false the main loop breaks, pushes the command to `pending_commands`, reconnects. Never silently discard send errors.
- **CRITICAL — mobile selection providers cleared in `.then()`, not `dispose()`.** See `feedback_mobile_ui_patterns` for all mobile rules.
- **CRITICAL — in-memory message lists dedup by `message_id`** before append (`chat_provider`/`channel_chat_provider`) — the same message arrives via DB-load AND live event. See `feedback_ui_dedup_by_message_id`.
- **CRITICAL — multi-device device-vs-master routing.** One MASTER = many DEVICE peer_ids. Iron rules: (1) per-person UI/lookups collapse device→master (Rust `resolver::resolve`; Dart `identityOf`); (2) SENDS target a DEVICE, never the bare master (authenticates NO socket → silently dropped) — fan via `devices_for(master)`. `dm_room_code` is PURE — never resolve inside it. Fresh installs ALWAYS have device≠master. See `feedback_multidevice_targeting_sweep`.
- **CRITICAL — multi-device audit fixes (2026-07):** sends route via `send_raw_to_identity` / `preferred_online_device` / `friend_device_targets` (raw master send drops). LEAVE tears down durably on all 3 apply paths; remote-op ingest gates via shared `ServerState::op_allowed`. Resolver-touching tests hold `resolver::test_lock()`. See `feedback_peer_is_reachable_master_early_return`, `project_multidevice_audit_2026_07`.
- **CRITICAL — DM sends route to the DETERMINISTIC `dm_room_code`, never `ws_room_for_peer`** (first-match can pick a LEFT room → silent one-way DM loss). Online recipient DM + typing use `dm_room`; sibling self-echo keeps the flexible lookup (siblings meet in `inbox:{master}`). Friend requests queued on a COLD resolver drain on device-list ingest, not just presence. See `feedback_dm_friend_establishment_bugs_2026_07`.
- **CRITICAL — multi-device data channels (`webrtc_service.dart`, hollow-data):** glare tiebreaker compares MASTER identities; answer/ICE match by `conn_id`, never peer_id; sends/sockets/map keys stay DEVICE-keyed. `sendScreenAudio` DROPS packets when `bufferedAmount` >256KB — desktop polls every 12 sends (`feedback_screen_audio_datachannel_backpressure`). VC mesh glare is the OPPOSITE: ROUTABLE DEVICE ids, never master (`feedback_vc_join_double_announce_race`).
- **CRITICAL — multi-device servers/MLS (Step 6):** MLS leaf credential = bare `device_peer_id`; CRDT `ServerState.members` is MASTER-keyed — bridge EVERY MLS↔CRDT compare through the resolver. A linked sibling MUST regenerate its own MLS signer/credential (never re-key a sole owner). Post-join MLS bootstrap targets the SyncResponse responder. See `project_multidevice_step6_mls_leaves`, `feedback_mls_sibling_identity_collision`.
- **CRITICAL — multi-device server sync (Step 9D):** lifecycle ops converge the actor's OWN siblings (`fan_to_own_siblings`) AND offline members. Server DELETE = replicable `ServerDeleted` tombstone (owner-author validated at EVERY ingest). RE-ANNOUNCE all servers on sibling reconnect (`ServerJoined` is the ONLY reliable list-refresh). See `feedback_server_lifecycle_sibling_sync`.
- **CRITICAL — multi-device push (Step 9A):** fetch node auths as its DEVICE (DB passphrase MASTER-derived); sender targets `devices_for(master)` ∩ has-session ∩ not-in-room; push tap resolves sender→master. See `project_multidevice_9a_push`, wiki `push_notifications`.
- **CRITICAL — multi-device revocation + ghost fan-out (Steps 7/8):** device list carries a master-signed `revoked` tombstone array (max-version-wins); tombstone goes to the REVOKED device FIRST → `SelfRevoked` → `_selfNuke`. DM/file fan-out targets only devices CURRENTLY IN A ROOM (`has_session` is NOT liveness). See `feedback_ghost_device_fanout`, `feedback_reset_device_list_real_revocation`.
- **CRITICAL — device linking (Step 4):** REUSES the `.hollow` backup pipeline end-to-end (6-char code = passphrase; `link:{code}` relay room, 5-min TTL, one-shot); receiver stashes `pending_link.hollow` + RESTARTS; import runs pre-node-start (`_bootstrap` checks `has_pending_link()` BEFORE `hasIdentity()`) — NEVER import in-place while the node runs. See `feedback_link_import_identity_device`, `project_multidevice_step4_link_design`.
- **CRITICAL — channel device→master collapse + self-heal:** channel messages are SIGNED by + attributed to the sender's MASTER. Every Rust receive handler + `fetch.rs` resolves sender→master; every Dart display site via `identityOf`; file-request stays RAW. Wedged device-keyed rows self-heal via `repair_channel_message_sender` when the synced sig VERIFIES. See `feedback_channel_display_device_master_collapse`, `feedback_channel_sync_self_heal`.
- **CRITICAL — FCM push (Tier 1/2):** payload stays `{wake, sender}` — NEVER ciphertext; relay buffers offline DMs in RAM, replays on DM-room join. Background isolates: `RustLib.init()` throws on 2nd call (treat as ready). Android backgrounded → nudge the LIVE node; iOS NSE decrypts on-device (`push_enrich.rs`, OUTSIDE `crate::api`). Full rules: `project_push_notification_implementation`, wiki `push_notifications`.
- **CRITICAL — channel push:** sender fans one `0x09` frame per OFFLINE member (picks targets + per-target mention flag from its CRDT — relay never learns membership); relay filters by `set_push_prefs` (MUST be relay-side — iOS can't suppress post-delivery) + debounce; fetch node MLS-decrypts via `from_persisted` (stale epoch → content-free). Prefs sync MOBILE-ONLY. Text only (v1). See `project_channel_push_notifications`.
- **CRITICAL — local notifications (distinct from FCM):** ONE surface per message — desktop toast when hidden/unfocused, in-app card only when visible AND focused; Windows toasts get a FRESH id per message; mobile foreground = `MobileInChatBanner` only. See `project_local_notifications_desktop_mobile`.
- **Push tap → chat:** all 3 entry points required (onMessageOpenedApp / getInitialMessage / local-notif payload + launch details); per-peer `plugin.show()` MUST set `payload: sender`; cold-start taps buffered. See `feedback_push_tap_navigation`.
- **CRITICAL — Windows mid-call media:** `pc.addTrack(track, stream)` / `pc.removeTrack(sender)` + renegotiate — NEVER `replaceTrack` reuse. See `feedback_webrtc_patterns`.
- **CRITICAL — mic gain/loudness:** WebRTC APM AGC DISABLED (`autoGainControl:false`, AEC+NS kept) — NEVER re-enable. Loudness owned by Voice Enhancement via `Helper.setCaptureGain()`/`setVoiceEnhance()` (`setVolume()`=NO-OP on capture): chain+servo → −16 dBFS + gate/upward stage + de-esser, 3 ports IN SYNC, tune ONLY via the g++ harness. NEVER a per-sample adaptive leveler (crackles), NEVER bypass iOS VPIO. See `project_voice_agc_loudness_rvox`, `project_voice_upward_compression`.
- **CRITICAL — SFrame:** call `setKeyIndexForPeer` after every enable; use `rotateKey` (not `setSharedKey`) in `setSframeKey`. Cryptors are idempotent per (peer,kind) — any reneg that REPLACES a sender must drop+re-enable BOTH ends (`disableSender` at the swap, `disableReceiver`+rebind in onTrack) else ciphertext gibberish. See `project_live_device_switching`.
- **CRITICAL — Share WebRTC reconnection: receiver-initiates, sender-catches.** See `feedback_webrtc_patterns`.
- **CRITICAL — call/VC signal types are WHITELISTED in Rust** (voice_handler.rs) — unknown types silently dropped. A new signal type needs 3 Rust touches: types.rs variant (`#[serde(default)]` fields), the send match arm, the swarm.rs dispatch arm. No codegen. See `feedback_mobile_call_audio_route`.
- **CRITICAL — renegotiation glare:** never drop an inbound `sdp_offer` — queue while busy + retry (`_queueRenegOffer`); camera auto-enable is STAGGERED (polite 300ms / other 1500ms). Any new reneg trigger must consider both sides acting simultaneously. See `feedback_renegotiation_glare`.
- **CRITICAL — DM/VC camera codecs are VP8-ONLY** (`_constrainCameraCodecs` — H.265/AV1/H264/VP9 all kill the iOS answerer); a failed inbound reneg ROLLS BACK to stable; route inbound `sdp_offer` by CALL IDENTITY, never `status == active`. See `project_ios_camera_black_screen_debug`.
- **CRITICAL — always `await` WebRTC disposal** (`RTCVideoRenderer.dispose()`, `RTCPeerConnection.close()`/`.dispose()`, `MediaStream.dispose()`) — unawaited calls leak ~200 MB per session. Fork native: per-PC EventChannel handler teardown belongs in Dispose (after Dart cancels), NEVER Close. See `feedback_webrtc_close_dispose_eventchannel`.
- **Screen capture:** native (WGC / ScreenCaptureKit); desktop share audio = out-of-process `screen_audio_capturer` exe over `0x03`; macOS SCK audio-only needs an ignored `.screen` output. See `project_screen_capture`.
- **Per-app share audio + anti-echo (Win+Linux):** window shares pass the SOURCE ID (`windowHwnd`/`--window-xid`), NEVER `pid`; per-app NEVER falls back to system; entire-screen EXCLUDEs Hollow's tree. Win: `AddSink`+`SetVolume(0)` taps upstream; STOP capturer first. See `project_windows_per_app_screen_audio`, `project_linux_screen_audio`.
- **Mobile screen share send+receive (SHIPPED):** same `0x03` Opus pipeline both ways (`api/screen_audio.rs`); realtime Rust crates REQUIRE `[profile.dev.package.*] opt-level=3` (else fake "jitter bug"); iOS: NEVER add message types to the `rtc_SSFD` broadcast socket. FGS order, anti-echo, NSExtension keys, MixWithOthers: `project_mobile_screen_share_send`, `project_mobile_screen_audio_receive`.
- **CRITICAL — dialogs are keyboard-aware globally:** `showHollowDialog` pads every dialog by `viewInsets` — NEVER add viewInsets padding inside a dialog builder (double-pad). See `feedback_dialog_keyboard_insets`.
- **App Lock (mobile):** PIN = numeric secret through the Rust Argon2id flow; biometric secret in flutter_secure_storage released after `local_auth` (3.x named params, no AuthenticationOptions); lock-type marker readable BEFORE identity unlock; MainActivity MUST extend `FlutterFragmentActivity`. See `project_app_lock_pin_biometric`, `feedback_mobile_call_audio_route`.
- **CRITICAL — message signing uses the canonical `message_signing_payload()`** at ALL signing sites; Dart timestamps hydrate from Rust's signed value, never `DateTime.now()`. Chat send stamps come from `chat_clock::next_send_stamp_us()` (Lamport; ts = stamp/1000) — NEVER raw SystemTime, else clock skew sorts replies above what they answer. See `feedback_chat_clock_lamport`.
- **CRITICAL — sender-side link previews (privacy):** receivers MUST NEVER make HTTP requests to previewed URLs.
- **CRITICAL — message dedup is by message_id, NEVER content:** every insert pre-checks `dm/channel_message_exists(mid)`; content UNIQUE indexes are partial LEGACY-only (`WHERE message_id IS NULL`). `MessageReceived`/`ChannelMessageReceived` ALWAYS emit with a `duplicate` flag (Dart skips unread/notify) — never suppress emission on "row exists". Sync `since` = watermark − `SYNC_LOOKBACK_MS`. See `feedback_sync_dedup_watermark_events`.
- **CRITICAL — `WsEvent::Disconnected` clears ALL sync-gating state:** `synced_peers`, `key_request_in_flight`, `mls_bootstrap_requested`, `pending_messages` — alongside `ws_room_peers`.
- **CRITICAL — never use raw `OverlayEntry` inside `SelectionArea`** — use `showDialog` with `barrierColor: Colors.transparent` instead.
- **CRITICAL — never construct `TextSelectionControls` in `build()`** (identity churn recreates selection overlays → app-wide crash inside raw OverlayEntries); raw-OverlayEntry teardown needs a `removed` guard. See `feedback_textfield_overlay_selectioncontrols`.
- **CRITICAL — `HollowToast` from non-widget code passes `overlayState:`** (`hollowNavigatorKey.currentState?.overlay`) — `Overlay.of(navKey.currentContext)` throws; run critical teardown BEFORE the toast. See `feedback_toast_from_nonwidget_overlaystate`.
- **CRITICAL — sender side needs `FileCompleted` emit too:** any new `FileHeader`/`StoredFile` field is missing from the sender's UI unless the send path also emits it. See `feedback_sender_file_completed`.
- **CRITICAL — Share-backed large files (>34 MB):** `FileHeader.share_ref` bypasses size checks in 3 places; skip `PendingFileStream` when `share_ref.is_some()`; STUN-only; >34 MB (DM + channel) prompts `confirmLargeFileShare`. See `feedback_share_backed_files`, `project_storage_manager`.
- **CRITICAL — sender stream temps (`.stream_send_*.tmp`) deleted after WS-relay sends** unless `pending_webrtc_sends` owns them; boot-time sweep mops orphans. See `feedback_stream_send_temp_cleanup`.
- **Storage Manager:** "Files & Storage" settings dashboard (`storage_section.dart` + `storage_provider.dart` + `api/storage.rs`); caps ENFORCED via `enforce_storage_caps` on `FileCompleted`; clearing bytes keeps signed FileHeader rows (re-downloadable). See `project_storage_manager`.
- **MLS coordinator model:** deterministic election (lowest online peer_id), server-group ops PREFER the OWNER; recovery targets the coordinator (`feedback_mls_patterns`, `feedback_owner_coordinator_mls_recovery`). **Commits broadcast via `broadcast_mls_commit`** (ONE SendToRoom + wire epoch guard), NEVER per-device loops; plaintext CRDT twin via `broadcast_crdt_op_to_members` (mesh 0x04 first, relay fallback). See `project_large_server_mls_scaling`.
- **CRITICAL — `get_missing_file_ids()` checks DISK, not just DB** (directory→HashSet) — files can exist without a valid `completed_at`.
- **Public channels:** per-channel `is_public` in the CRDT; skip MLS — plaintext `PublicChannelMessage` via SendToRoom, still Ed25519-signed; send handlers branch on `is_channel_public()`; broadcast = public + "Admin+" posting; browser in `bottom_bar.dart`. See `project_public_channels`.
- **CRITICAL — conferences are VIRTUAL SERVERS:** `conf:{id}` = WS room = MLS group = server_id for the VC machinery (channel `"main"`); admission IS the MLS add; chat = RAM-only MLS app messages, NEVER persisted; guards branch on `is_conference_sid`, plaintext paths stay strict. See `project_conferences_design`, wiki `conferences`.
- **CRITICAL — unread counts compare MILLISECOND timestamps only** (never rowid, never the order_us tuple — Dart marks seen from a ms-sorted `.last`); `recomputeServerUnread` gated on `newMessageCount > 0`. See `feedback_unread_ghost_ms_seen`.
- **CRITICAL — relay topic subscriptions are PER-SOCKET:** ws_client replays them on every reconnect; `MobileChatRoute.initState` subscribes on every channel open; desktop's subscribe-listener microtask-defers past the selection batch (channel is written BEFORE server). See `feedback_channel_topic_subscriptions`.
- **CRITICAL — fire-and-forget FFI needs `.catchError((_) {})`:** sync try/catch around an un-awaited Future catches NOTHING — rejections hit the zone crash handler (startup "Node is not running"). Calls that REGISTER state need a retry helper — subscribes ALWAYS via `subscribeChannelTopics()`, never bare `subscribeChannels`. See `feedback_ffi_fire_and_forget_catcherror`.
- **CRITICAL — channels_tab auto-save guards against empty `channelListProvider`** (`channels.isNotEmpty` before saving derived layout state).
- **CRITICAL — CRDT property changes: optimistic UI update BEFORE the fire-and-forget FFI, and NEVER a read-back right after the write returns** (set_* only queues — the read sees the PREVIOUS value; server-icon off-by-one; seed the cache via `applyLocalWrite`). See `feedback_crdt_optimistic_update`, `feedback_crdt_read_after_write_race`.
- **CRITICAL — user actions visibly succeed, fail, or show busy:** mutating wrappers RETHROW (`friendsProvider.*`, `localNicknameProvider.*`, `updateMyProfile`) — call sites await + toast failure (bare call = zone crash); slow FFI behind a button = `_busy` + spinner; success toast only AFTER the await. See `feedback_ux_feedback_sweep_2026_07`.
- **Roles & permissions:** `AdminLwwReg::merge` = pure HLC LWW (authority ONLY in op_allowed/author gates); Dart loads role defaults via `default_role_permissions()` FFI, never a mirror — `project_roles_design`, `project_crdt_hlc_lww_merge`. **Moderation trio:** enforce at send + LIVE ingest, never sync backfill; mute gates EDIT + ADD-REACTION on both crypto paths — `project_moderation_trio`.
- **CRITICAL — call audio:** Android mic survives backgrounding ONLY via `CallForegroundService` (mic FGS, hooked in `AudioSwitchManager.start/stop` — never remove); adaptive capture stages must respect `setCaptureMuted` + `setCaptureServoHold`; voice-QUALITY bugs only count from a REMOTE peer (same-room tests = phantom AEC bugs). See `project_android_background_mic_fgs`, `feedback_capture_servo_mute_freeze`.
- **CRITICAL — per-channel MLS subgroups (Option B):** restricted channels encrypt under their OWN MLS group keyed `"{server}#{channel}"`. Membership via coordinator-gated `reconcile_subgroups_for_server`; voice derives SFrame from the subgroup `export_secret`; auto-leave on lost visibility runs on BOTH CrdtOp apply paths; VC participants key on the ROUTABLE WS sender, NEVER the MLS leaf (display collapses via `identityOf`). See `project_per_channel_mls_subgroups`, `vc_participant_display_master_collapse`.
- **CRITICAL — server-group MLS recovery:** owner-preferred coordinator + CRDT-mutating handlers ALWAYS also broadcast the op as plaintext `CrdtOpBroadcast` (idempotent; op_log dedups) — an MLS-only op silently drops at a skewed epoch with no recovery. `WrongEpoch` decrypt-fail fires a server-group `SyncRequest`. See `feedback_owner_coordinator_mls_recovery`.
- **CRITICAL — channel visibility/posting UI reactivity:** `_refreshServerState` reloads `channelListProvider` + invalidates `serverChannelsProvider(id)` on a 0/120/400/1000ms ramp; eviction listeners on `visibleChannelsProvider` (desktop shell + mobile chat route); mobile chat route must `loadForServer` on open (Chats tab has no selected server). NEVER `ref.invalidate` in `initState` — defer to post-frame. See `feedback_channel_visibility_posting_ui_reactivity`.
- **CRITICAL — new `CrdtPayload` variants emit `ServerUpdated` in BOTH match blocks** (`handle_envelope_crdt_op` + `handle_incoming_request`) — never fall into `_ =>` (emits `SyncCompleted`, no provider invalidation).
- **CRITICAL — received CRDT ops persisted via `insert_crdt_op` at EVERY apply site** (op_log is `skip_serializing` — state JSON alone loses history); joins send `ServerStateSnapshot` BEFORE the op log; permission checks validate `op.author`, never the transport sender. See `feedback_crdt_sync_persistence`.
- **CRITICAL — `RoomMembers` is the authoritative presence snapshot:** diff old vs new sets, emit `PeerDisconnected` for vanished peers; `PeerLeft` refreshes rooms still listing the leaver; caches keyed on room membership must tolerate missed `PeerLeft`. See `feedback_ws_presence_stale_rooms`.
- **CRITICAL — list rows with per-item loaded state need `ValueKey(item id)`** + a `didUpdateWidget` reload — else Flutter re-parents State across different conversations. See `feedback_listview_state_reuse_keys`.
- **CRITICAL — chat lists are `reverse: true`** via shared `reversedChatList()` (`chat_pane_shared.dart`; mobile passes `selectionArea:false` — SelectionArea fights touch long-press): newest = index 0 bottom-pinned, instant post-frame `jumpTo(0,0)` ONLY, scrolled-up reading FREEZES the display, `findChildIndexCallback` mandatory (CI-guarded); popped MobileChatRoute callbacks bail on `_routeDeactivated`. Extend the shared module, never copy. See `feedback_reverse_chat_lists`.
- **`showHollowDialog` overlays need a `Material` ancestor** for `Text` widgets (else yellow debug underline).
- **Android:** SQLCipher needs vendored prebuilt OpenSSL 1.1.1w per-arch; target-prefixed env vars must be SYSTEM env vars (Cargo `[env]` doesn't reach cargokit); Rust TLS uses `webpki-roots`, NEVER `native-roots` (silently breaks all WSS). See `feedback_android_platform`.
- **Mobile data dir:** `hollowDataDir` (`hollow_data_dir.dart`) = `getApplicationDocumentsDirectory()/hollow`, passed via `set_data_dir()` FFI before `start_node()`.
- **Mobile lifecycle:** `WidgetsBindingObserver` — resume: WiFi lock + rejoin WS rooms; pause: release lock.
- **Mobile UI:** `lib/src/ui/mobile/`; `MobileShell` (4-tab) replaces desktop below 600px; chat views push onto the root navigator; all mobile code platform-gated. Floating pills go in MobileShell + MobileChatRoute stacks, NEVER in `app.dart` builder (only `IncomingCallOverlay` there). See `feedback_mobile_ui_patterns`.
- **Widget tests:** `test/helpers/test_app.dart` — `pumpHollowMobile()` mocks FFI providers (~1s, no device). **Feature matrix:** `reports/FEATURE_MATRIX.md`.
- **Forked `flutter_webrtc`** at `packages/flutter_webrtc/` (pubspec `path:`). When iterating its native C++, delete `build/windows/x64/plugins/flutter_webrtc/` before rebuilding, and ALWAYS build `--release` if testing from the Release folder.
- **CRITICAL — Linux window close: minimize to taskbar, never tray** (AppIndicator broken); second close while minimized = quit.
- **CRITICAL — Linux `record` needs `parecord`** (absent on PipeWire) — mic test crashes; calls fine (libwebrtc).
- **Linux audio enumeration:** prebuilt libwebrtc ADM reports 0 devices on pipewire-pulse → native libpulse shim (`hollowLinuxAudioDevices`, dep `libpulse-dev`). A distorted Linux mic is HARDWARE first — check `amixer sget Capture` for a maxed analog gain. See `feedback_linux_audio_libpulse_enum_shim`, `feedback_linux_agc_clipping_distortion`.
- **CRITICAL — Linux window transparency:** set the RGBA visual at window creation in `my_application.cc` (before realize, guarded on `is_composited`) + FlView bg `#00000000` — an X11 visual can't swap at runtime; Dart skips `setBackgroundColor` on Linux. See `feedback_linux_window_transparency_annotate`.
- **CRITICAL — Linux call stability:** keep every WebRTC teardown fully awaited with ownership flags (no shared-stream double-free); on Linux open V4L2 ONCE per call and toggle via `track.enabled` (never stop/dispose mid-call). See `feedback_linux_thread_leak_heap_corruption`, `feedback_ws_signaling_restart_task_leak`.
- **Flatpak:** `flatpak/` + `build-flatpak.sh`; requires `--socket=x11` (NOT `fallback-x11`); data dir `~/.var/app/com.anonlisten.Hollow/`. Must bundle libsecret (`feedback_flatpak_libsecret_and_vm_no_gui`).
- **CRITICAL — Windows annotation mode:** `window_manager` maximize/unmaximize only — never raw Win32 or `setFullScreen`. See `feedback_annotation_window_management`.

## Semantic Memory Search (hollow-memory MCP)
- **Tool:** `memory_search(query, limit=5)` — semantic search across memory, wiki, plan/whitepaper docs. ALWAYS search before arguing, designing, or re-investigating.
- **Wiki:** `tools/hollow-memory/wiki/` — ~40 machine-optimized files (UI panels, data flows, providers, Rust modules). Keep in sync during `/compush`.
- **Reindex:** run `memory_reindex()` after modifying any indexed file.
- **Save liberally:** threshold is "would finding this by meaning help a future session?". Location: `tools/hollow-memory/`.

## Rules
- Never commit secrets, keys, or credentials.
- Rust handles networking/crypto/CRDTs/storage; Dart handles UI/app logic/state.
- All crypto operations must use constant-time implementations.
- Ask before making architectural decisions not covered in HOLLOW_PLAN.md.
- **HOLLOW_PLAN.md is the authoritative source** for phase details, feature checklists, completion status — don't duplicate it here or in memory files.
- **This file has a HARD budget of 40,000 characters.** New entries are 1–3 lines: the actionable rule + a memory-file pointer. War stories, fix histories, and investigation narratives go in memory files.
- **VPS deployment:** ask user — never store credentials. **VPS SSH:** `ssh ubuntu@141.227.186.209` (key-only) — free to use for config checks, logs, deployments.
- **Local dev commands:** `cargo check/test/clippy`, codegen, `flutter analyze` — run freely. **Building/running the app:** Vitalik runs `flutter run -d windows` himself.
