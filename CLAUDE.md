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
- **Org ID:** com.anonlisten
- **Project name:** hollow

## Project Structure
```
HOLLOW/
├── lib/                  # Dart/Flutter code (UI, app logic, state management)
│   ├── main.dart         # Entry point (ProviderScope + RustLib.init + window_manager init)
│   └── src/
│       ├── core/         # Models, Riverpod providers, service wrappers
│       ├── theme/        # Hollow design system (colors, spacing, typography, ThemeExtension)
│       └── ui/
│           ├── shell/    # Layout: hollow_shell, server_strip, channel_sidebar, member_panel, user_bar, mobile_nav, window_title_bar
│           ├── chat/     # ChatPane, MessageBubble, ChannelChatPane, ChannelMessageBubble
│           ├── settings/ # ServerSettingsPanel, OverviewTab, ChannelsTab, MembersTab, DangerZoneTab
│           ├── sidebar/  # PeerCard, EmptyPeerList
│           ├── components/ # HollowPressable, HollowButton, HollowTextField, HollowDialog, HollowTooltip, HollowToast, HollowToggle, HollowAvatar, HollowCard, StatusDot
│           ├── dialogs/  # InviteDialog, MnemonicDialog, CreateServerDialog, CreateChannelDialog, TwitchJoinDialog
│           └── animations/ # HollowCurves, HollowDurations, FadeSlideTransition, ScaleFadeTransition, SelectionShimmer, AmbientBackground, StartupRevealScope, RevealWidgets
├── rust/hollow_core/      # Rust library crate (networking, crypto, storage)
│   └── src/
│       ├── api/          # FFI layer (flutter_rust_bridge scans these)
│       ├── node/         # Networking modules (modularized from swarm.rs monolith)
│       │   ├── swarm.rs         # Event loop dispatcher + handle_incoming_request (~6.2k lines, envelope dispatch fully extracted)
│       │   ├── types.rs         # NetworkEvent, NodeCommand, HavenMessage, MessageEnvelope, helper structs
│       │   ├── crypto_handler.rs # Signing, Olm/MLS encryption, key exchange, coordinator election
│       │   ├── sync_handler.rs  # CRDT ops, server/channel CRUD, member management, sync
│       │   ├── message_ops.rs   # Send/edit/delete messages, emoji reactions (DMs + channels)
│       │   ├── social.rs        # Friends, profiles, typing indicators
│       │   ├── vault_ops.rs     # Vault shard storage, upload/download, recovery pool
│       │   ├── file_handler.rs  # File send/receive, stream handling, WebRTC transfers
│       │   ├── voice_handler.rs # Voice channels, 1:1 calls, WebRTC signaling
│       │   ├── gossip_relay.rs  # Gossip broadcast, peer exchange, timer handlers
│       │   ├── gossip.rs        # GossipOverlay, PeerScore, neighbor selection
│       │   ├── ws_client.rs     # WebSocket relay client
│       │   ├── ws_stream_transfer.rs # Binary stream reassembly
│       │   ├── signaling.rs     # Bootstrap peer discovery
│       │   ├── file_transfer.rs # File chunking utilities
│       │   ├── recovery_pool.rs # Recovery pool state management
│       │   ├── twitch.rs         # Twitch OAuth (Device Code Grant), follow/sub checks, proof validation
│       │   ├── image_convert.rs # WebP conversion
│       │   └── link_preview.rs  # URL link preview fetching
│       ├── crypto/       # Olm encryption + MLS + persistence
│       ├── identity/     # Ed25519 keypair management (native_identity.rs, keys.rs)
│       └── storage/      # SQLCipher message store
├── relay/                # Signaling HTTP + WS room router (Rust, legacy — superseded by relay-uws)
├── relay-uws/            # Production relay (uWebSockets C++, native TLS, deployed on OVH VPS)
├── packages/flutter_webrtc/ # Forked flutter_webrtc 1.4.1 (WASAPI loopback, native screen recording, macOS ScreenCaptureKit screen share)
├── rust_builder/         # flutter_rust_bridge build system (cargokit)
├── vendor/ffmpeg/        # Bundled native binaries (gitignored, see fetch_ffmpeg.ps1)
├── legal/                # Privacy Policy, Terms of Use, version manifest (manifest.json)
├── HOLLOW_PLAN.md         # Full architecture & design document (authoritative for all phase details)
└── CLAUDE.md             # This file
```

## Build & Run Commands
```bash
# Run on current platform (debug)
flutter run -d windows

# Build release
flutter build windows

# Run widget tests (no device needed, ~1s)
flutter test test/

# Check Rust code
cd rust/hollow_core && cargo check
cd rust/hollow_core && cargo clippy

# Regenerate FFI bindings after Rust API changes (run from project root)
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"

# Deploy relay server updates to VPS (uWebSockets C++ relay)
scp relay-uws/src/*.cpp relay-uws/src/*.h relay-uws/CMakeLists.txt ubuntu@141.227.186.209:/home/ubuntu/relay-uws/src/
ssh ubuntu@141.227.186.209 "cd /home/ubuntu/relay-uws/build && cmake .. -DCMAKE_BUILD_TYPE=Release && make -j2 && sudo setcap cap_net_bind_service=+ep hollow-relay && sudo systemctl restart hollow-relay"
```

## Hollow Design System (Phase 2.75)
All UI uses custom Hollow widgets — no Material defaults.

- **HollowPressable:** Press: opacity 0.85 + scale 0.98 (spring). Hover: color transition 150ms + shadow lift. `subtle` mode for list items.
- **HollowButton:** 4 variants: `.filled()`, `.ghost()`, `.outline()`, `.danger()`. Props: `onPressed`, `child`, `icon`, `expand`, `compact`.
- **HollowTextField:** `OutlineInputBorder`, animated border (→accent on focus, →error on error), focus glow. Optional `prefixIcon`, `borderRadius`, `isDense`, `showCounter`.
- **HollowDialog:** `showHollowDialog()` — scale 0.95→1.0 + fade, full-screen glassmorphism blur (0→12 sigma).
- **HollowTooltip:** Overlay-based, 400ms delay, fade+slide entrance.
- **HollowToast:** Slide-up + fade, auto-dismiss. Three types: success/error/info. One visible at a time.
- **HollowToggle:** Spring physics thumb, color crossfade track.
- **StatusDot:** Optional `pulse` for breathing glow (3s cycle).

## Key Architecture Notes
- **Node module structure:** `swarm.rs` is the event loop dispatcher; domain logic lives in focused modules (`crypto_handler`, `sync_handler`, `message_ops`, `social`, `vault_ops`, `file_handler`, `voice_handler`, `gossip_relay`). Types/enums are in `types.rs`. Each module exports `pub(crate) async fn handle_*()` functions called from swarm.rs match arms. Functions take individual state variables as parameters (no SwarmContext struct — deferred due to borrow checker constraints with crypto helpers).
- **Persistence actors:** `CrdtStore` (`node/crdt_store.rs`) and `CryptoStore` (`crypto/store.rs`) own long-lived SQLCipher connections in `spawn_blocking` threads. Fire-and-forget via mpsc channels. CrdtStore uses batch-drain (blocking_recv + try_recv loop) to coalesce multiple CRDT ops into one DB write per server. All sync_handler save sites use CrdtStore. MLS state persistence uses CryptoStore. Never open `MessageStore::open()` in sync handlers.
- **Peer state tracking in swarm.rs:** `ws_room_peers` (room → peer set), `synced_peers` (HashSet<String>). WS PeerJoined triggers key exchange + sync. 30s keepalive ping in ws_client.rs.
- **Relay domain (self-hosting):** Configurable via `relayDomainProvider` (Dart) + `set_relay_url()` FFI (Rust). Persisted in SQLCipher. Default: `relay.anonlisten.com`. All WS/signaling/STUN/TURN URLs derive from this domain.
- **Event streaming:** Rust→Dart via `StreamSink` (flutter_rust_bridge). `watch_network_events()` in `api/network.rs`, `EventStreamNotifier` in `event_provider.dart`.
- **Profile/avatar loading:** Profiles load WITHOUT blobs at startup (`getAllProfilesLight()`). Avatar bytes lazy-load on-demand via `AvatarNotifier` in `avatar_provider.dart` (same pattern as `ServerAvatarNotifier`). Banner bytes via `bannerProvider` (FutureProvider.family). `HollowAvatar` is a `ConsumerWidget` that auto-fetches from avatar cache — don't pass `imageBytes:` from profile data. `ProfileUpdated` event invalidates both caches.
- **Navigation shell:** Two layout modes (persisted via `layoutModeProvider`): Dock mode (default, FriendsBar + BottomBar) and Classic mode (Discord-like 4-panel). Mobile: bottom nav with single-panel views. Vitalik uses Dock mode — put new UI in `bottom_bar.dart`.
- **Window chrome:** `window_manager` ^0.5.1, `setAsFrameless()`, custom 32px title bar.
- **Theme:** `HollowTheme.dark()`/`.light()` + `darkWithHue()`/`lightWithHue()`. `themeModeProvider` persisted to SQLCipher.
- **Icons:** `lucide_icons_flutter: ^3.1.14`. All `LucideIcons.*` (camelCase). Uses `alertTriangle`/`alertCircle`. No `cloudCheck` — uses `cloud`. Brand icons use vendored `lib/src/core/brand_icons.dart` (`BrandIcons.*`, `BrandIconColors.*`) with `assets/fonts/SimpleIcons.ttf`.
- **Identity at-rest protection:** Two opt-in modes (Settings > Security): password (Argon2id + AES-256-GCM, blocks app launch) or OS keychain (Windows Credential Manager + DPAPI fallback / macOS Keychain, silent unlock). `unlock_identity()` must be called before any identity/DB operation. Recovery: 24-word mnemonic. See `project_identity_protection_v2.md` for byte format and implementation details.
- **License key system:** Relay loads `keys.json` (enabled toggle + key list), validates during WS auth, hot-reloads every 30s with active connection revocation. App checks `/relay-status` on startup, shows key dialog if required, caches key in SQLCipher via `set_license_key()` FFI.
- **Temporary nicknames:** Ephemeral relay-scoped nicknames for friend requests. RAM only (`nickname_to_peer`/`peer_to_nickname` maps in `RelayState`), released on disconnect. Relay handles `claim_nickname`/`release_nickname`/`resolve_nickname` text messages. Rust does two-step resolution (resolve → normal friend request). UI auto-detects peer ID (`12D3KooW` prefix) vs nickname in a unified input. Provider: `temporaryNicknameProvider`, resets on `RelayDisconnected`.
- **Window title bar:** `WindowTitleBar` lives in `MaterialApp.builder` (above Navigator), NOT inside `HollowShell`. Navigator child wrapped in `ClipRect` to prevent `BackdropFilter` blur bleed. Never move the title bar back inside the shell.
- **Logging:** `hollow_log!` macro → stderr + `hollow_debug.log` (release-safe, 10MB rotation). `hollow_crash.log` captures Flutter/platform errors (5MB rotation).
- **Relay:** uWebSockets C++ relay (`relay-uws/`) on OVH VPS, native OpenSSL TLS, port 443. Domain: `relay.anonlisten.com`. **No backpressure soft limit, no binary rate limit** — removed because they silently dropped messages. `maxPayloadLength`=64MB — NEVER lower (silently kills connections). `maxBackpressure`=64MB (hard). DoS protection: Ed25519 auth + license key revocation + per-IP limits. Topic routing: `0x07` frame with channel_id, `0x03` universal broadcast. See `feedback_relay_rules.md` for details.
- **Storage layout:** `~/.hollow/files/` (full-replication), `~/.hollow/vault/` (erasure-coded shards), `~/.hollow/vault_cache/` (LRU-evicted, 1GB cap).

## Coding Conventions
- Dart: follow `flutter_lints` / `analysis_options.yaml`. Rust: follow `cargo clippy`.
- File naming: snake_case for Dart and Rust files.
- No Electron, no Node.js, no web frameworks — Flutter only for UI.
- **NEVER pass `WidgetRef ref` as a constructor parameter** to child widgets. Always use `ConsumerWidget` or `ConsumerStatefulWidget` instead. Passing `ref` causes cascade rebuilds.
- Use `AnimatedOpacity` (GPU-composited) for per-item opacity. Never use the `Opacity` widget.
- **CRITICAL — Backward-compatible DB schema:** ALWAYS add `#[serde(default)]` to ANY new field added to a persisted Rust struct (e.g., `ServerState`, any struct stored as JSON in SQLCipher). Without it, old data lacking the new field fails to deserialize and silently disappears (servers vanish, data lost).
- **CRITICAL — flutter_webrtc native: use `sourceId` for ALL input device selection (audio AND video).** Correct pattern: `{'optional': [{'sourceId': deviceId}], 'width': ..., 'height': ...}`. `{'deviceId': ...}` is silently ignored.
- **CRITICAL — server switching must batch provider writes atomically.** `channelListProvider`, `channelLayoutProvider`, `selectedServerProvider`, and `selectedChannelProvider` must all update in a single synchronous block. See `server_strip.dart:_selectServer` for the canonical pattern.
- **CRITICAL — TURN ICE config: split URIs into separate entries.** flutter_webrtc's native `CreateIceServers` has a single `uri` field per `IceServer` struct. Always map each TURN URI to its own entry.
- **CRITICAL — MLS epoch staleness after reconnection.** Sync requests must use plaintext `HavenMessage`. CRDT broadcast must fall back to plaintext on MLS failure. See `feedback_mls_patterns.md` for all 8 MLS rules.
- **CRITICAL — WS send failures must trigger reconnection.** `send_command()` in `ws_client.rs` returns `bool`. If false (TCP write failed), the main loop must break, push the failed command to `pending_commands`, and reconnect. Never silently discard send errors.
- **CRITICAL — mobile selection providers cleared in `.then()`, not `dispose()`.** See `feedback_mobile_ui_patterns.md` for full pattern.
- **CRITICAL — in-memory message lists must dedup by `message_id`.** `chat_provider`/`channel_chat_provider` `_addMessage`/`receiveMessage` skip when a non-null `message_id` already exists — the same message arrives via both `loadHistory` (DB, possibly written by the FCM push-fetch node) AND a live network event. Naive append shows it twice even when the DB is correct. See `feedback_ui_dedup_by_message_id.md`.
- **CRITICAL — push notifications (FCM Tier 1/2).** Relay buffers offline DMs in RAM (`offline_buffer`, 100/peer, 24h TTL) and replays on DM-room join — Tier 2 fetch can't get the triggering message otherwise (relay is a dumb pipe). `fetch.rs` parses binary `0x06` frames (not text). Background isolates: NEVER trust `RustLib.init()` to be idempotent (reused isolate throws "twice" → treat as ready) and NEVER call `load_or_create_identity()` (use `load_existing_identity()` — generating yields wrong peer_id/DB passphrase). `log_path()` honors `set_data_dir()` so mobile `hollow_debug.log` writes. See `project_push_notification_implementation.md`, `feedback_rustlib_init_not_idempotent.md`. Firebase config files (`google-services.json`, `GoogleService-Info.plist`) are gitignored — public repo, contributors bring their own project.
- **CRITICAL — flutter_webrtc Windows: never use `replaceTrack` reuse for mid-call media.** ALWAYS use `pc.addTrack(track, stream)` / `pc.removeTrack(sender)`. See `voice_channel_service.dart`.
- **CRITICAL — SFrame key index must be set on every new cryptor.** Call `setKeyIndexForPeer` after enabling. Use `rotateKey` (not `setSharedKey`) in `setSframeKey`.
- **CRITICAL — Share WebRTC reconnection: receiver-initiates, sender-catches.** See `feedback_webrtc_patterns.md`.
- **CRITICAL — always `await` WebRTC resource disposal.** `RTCVideoRenderer.dispose()`, `RTCPeerConnection.close()`/`.dispose()`, and `MediaStream.dispose()` are async — unawaited calls leak ~200 MB per session.
- **CRITICAL — sender side needs `FileCompleted` emit too.** Any new field added to `FileHeader`/`StoredFile` will be missing from sender's UI unless the send path also emits `FileCompleted`.
- **CRITICAL — `flutter_rust_bridge` codegen:** run from project root with explicit args. Codegen errors if you `cd` into `rust/hollow_core/` first.
- **CRITICAL — message signing must use `message_signing_payload()` + timestamp parity.** ALL signing sites must use the canonical payload. Dart timestamps MUST be hydrated from Rust's signed value (not `DateTime.now()`).
- **CRITICAL — HollowAvatar: never pass `imageBytes:` from profileProvider.** `profileProvider` loads light profiles (no blobs). HollowAvatar auto-fetches from `avatarProvider`. Only pass `imageBytes:` for non-profile data (archive exports, explicit overrides).
- **CRITICAL — sender-side link previews (privacy).** Receivers MUST NEVER make HTTP requests to previewed URLs.
- **CRITICAL — sync batch receivers must check `message_id` existence before INSERT.** Edited messages bypass text-based UNIQUE dedup. See `feedback_sync_patterns.md`.
- **CRITICAL — `WsEvent::Disconnected` must clear ALL sync-gating state.** `synced_peers`, `key_request_in_flight`, `mls_bootstrap_requested`, `pending_messages` — all cleared alongside `ws_room_peers`.
- **CRITICAL — never use raw `OverlayEntry` inside `SelectionArea`.** Use `showDialog` with `barrierColor: Colors.transparent` instead.
- **CRITICAL — Share-backed large files (>34 MB):** `FileHeader.share_ref` bypasses size checks in 3 places. Skip `PendingFileStream` when `share_ref.is_some()`. STUN-only. See `feedback_share_backed_files.md`.
- **MLS coordinator model:** `is_mls_coordinator()` — deterministic election (lowest online peer_id). Recovery targets coordinator, NOT owner. All MLS correctness rules (persist on encrypt, decrypt-fail sync, recovery, coordinator exclusion, rejoin cleanup) in `feedback_mls_patterns.md`.
- **CRITICAL — `get_missing_file_ids()` checks disk, not just DB.** Files may exist without valid `completed_at` — reads directory into HashSet to prevent redundant transfers.
- **Public channels:** Per-channel `is_public: bool` in `ChannelInfo` CRDT. Public channels skip MLS — plaintext `HavenMessage::PublicChannelMessage` via `SendToRoom`, still Ed25519-signed. Send handlers in `message_ops.rs` branch on `server.is_channel_public()`. Toggle via globe icon (MANAGE_CHANNELS permission). Broadcast channels = public + "Admin+" posting mode. Public Channel Browser in `bottom_bar.dart`. See `project_public_channels.md` for guest sync, sender profiles, and browser implementation details.
- **CRITICAL — channels_tab auto-save must guard against empty channelListProvider.** Check `channels.isNotEmpty` before auto-saving derived layout state.
- **CRITICAL — CRDT property changes need optimistic UI updates.** Update `channelListProvider` BEFORE the FFI call — `CrdtStore` is fire-and-forget, DB may be stale when `ServerUpdated` fires.
- **Roles & permissions:** 4 power roles (Owner/Admin/Moderator/Member) + cosmetic labels. `role_permissions` overrides `default_permissions()`. Tier-gated editing. Channel visibility/posting is UI-filtered only (server-wide MLS group). See `project_roles_design.md`.
- **CRITICAL — new CrdtPayload variants must emit `ServerUpdated` in both match blocks.** Don't fall into `_ =>` wildcard (emits `SyncCompleted`, no provider invalidation). Explicitly list in both `handle_envelope_crdt_op` and `handle_incoming_request`.
- **HollowTooltip: always use `_dismiss()` pattern** — immediate overlay removal, no reverse animation.
- **`scrollable_positioned_list: ^0.3.8`** — sentinel pattern with `itemCount: messages.length + 1`. Do not remove this package.
- **`showHollowDialog` overlays need a `Material` ancestor** for `Text` widgets, otherwise yellow debug underline.
- **Android cross-compilation:** SQLCipher needs prebuilt OpenSSL 1.1.1w per-arch (vendored). Target-prefixed env vars must be **system env vars** (Cargo `[env]` doesn't reach cargokit). See `feedback_android_platform.md`.
- **CRITICAL — Android TLS: Rust crates must use `webpki-roots`, never `native-roots`.** Switching to `native-roots` silently breaks all WSS connections on Android.
- **Android/iOS data directory:** `hollowDataDir` from `hollow_data_dir.dart`. Mobile uses `getApplicationDocumentsDirectory()/hollow`. Rust: `set_data_dir()` FFI before `start_node()`.
- **Mobile app lifecycle:** `WidgetsBindingObserver` on Android/iOS — resume: WiFi lock + rejoin WS rooms, pause: release WiFi lock.
- **Mobile UI architecture:** `lib/src/ui/mobile/`. `MobileShell` (4-tab) replaces desktop below 600px breakpoint. Chat views push onto root navigator. All mobile code gated behind platform check — desktop unaffected. See `feedback_mobile_ui_patterns.md` for all mobile-specific rules (selection providers, pill layering, bottom sheets, background image, etc.).
- **CRITICAL — mobile floating pills must NOT go in `app.dart` builder.** Pills in MobileShell + MobileChatRoute stacks. Only `IncomingCallOverlay` in builder. See `feedback_mobile_ui_patterns.md`.
- **Widget tests:** `test/helpers/test_app.dart` — `pumpHollowMobile()` mocks FFI providers. Tests run in ~1s without device.
- **Feature matrix:** `reports/FEATURE_MATRIX.md` — mobile port punch list.
- **Forked `flutter_webrtc` at `packages/flutter_webrtc/`** — pubspec `path:` reference. Adds WASAPI loopback, native screen recording, native screen share. When iterating on fork's native C++, delete `build/windows/x64/plugins/flutter_webrtc/` before rebuilding, and **always build `--release` if testing from the Release folder**.
- **Screen recording/share/audio:** Native capture (no ffmpeg) on Windows (Graphics Capture API) and macOS (ScreenCaptureKit). Screen share audio uses out-of-process data channel on Windows (ADM interference workaround), Process Tap on macOS. See `project_screen_capture.md` for full architecture.
- **CRITICAL — Linux window close: minimize to taskbar, not tray.** Never add tray logic for Linux (AppIndicator broken). Second close while minimized = quit.
- **CRITICAL — Linux `record` package needs `parecord`.** Not on PipeWire systems. Mic test crashes; voice calls work fine (libwebrtc). Needs WebRTC path for Linux mic testing.
- **Flatpak packaging:** `flatpak/` directory. `build-flatpak.sh`. Requires `--socket=x11` (not `fallback-x11`). Data dir: `~/.var/app/com.anonlisten.Hollow/`.
- **CRITICAL — Windows annotation mode: use `window_manager` maximize/unmaximize.** Never raw Win32 or `setFullScreen`. See `feedback_annotation_window_management.md` for enter/exit sequence.

## Semantic Memory Search (hollow-memory MCP)
- **Tool:** `memory_search(query, limit=5)` — semantic vector search across all memory files, HOLLOW_PLAN.md, WHITEPAPER.md, CLAUDE.md. Use it proactively when you need to recall decisions, patterns, or context by meaning rather than exact filename.
- **When to use:** Fuzzy recall ("what was that thing about..."), cross-referencing decisions, finding relevant memories before making architectural choices, or when you're unsure which memory file contains the answer.
- **Reindex:** Run `memory_reindex()` after modifying memory files, HOLLOW_PLAN.md, or CLAUDE.md (automatic during `/compush`).
- **Save liberally:** Discovery is by meaning now, not by scanning an index. Save granular patterns, decision rationale, subtle bug causes, non-obvious code behaviors — anything useful to recall later. The threshold is "would finding this by meaning help a future session?" not "is this important enough for the index?"
- **Location:** `tools/hollow-memory/` — local ONNX embeddings, sqlite-vec, zero API costs.
- **Wiki:** `tools/hollow-memory/wiki/` contains ~40 machine-optimized markdown files covering every UI panel, data flow, background system, provider, and Rust module. Each is chunked by `## ` heading and indexed. Search queries like "voice channel WebRTC flow" or "CRDT sync handler" return precise wiki results with file paths and function references. Update relevant wiki files during `/compush` when features change.

## Rules
- Never commit secrets, keys, or credentials.
- Rust handles: networking, crypto, CRDTs, storage engine. Dart handles: UI, app logic, state management.
- All crypto operations must use constant-time implementations.
- Ask before making architectural decisions not covered in HOLLOW_PLAN.md.
- **HOLLOW_PLAN.md is the authoritative source** for all phase details, feature checklists, and completion status. Don't duplicate that information here or in memory files.
- **VPS deployment:** Ask user — never store credentials.
- **Local dev commands:** Can run `cargo check/test/clippy`, `flutter_rust_bridge_codegen generate`, `flutter analyze` freely.
- **Building/running the app:** User runs `flutter run -d windows` themselves for testing on their two laptops.
- **VPS SSH:** `ssh ubuntu@141.227.186.209` — key-only, no passphrase. Can be used freely for config checks, log inspection, deployments.
