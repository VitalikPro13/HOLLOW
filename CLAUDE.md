# HOLLOW — Project Instructions for Claude Code

## What Is This
Hollow is a fully distributed, encrypted Discord alternative. No central servers. Members collectively host the server. See `HOLLOW_PLAN.md` for the full architecture, phase history, and current TODO checklist.

## Tech Stack
- **UI:** Flutter (Dart) — all platforms (Windows, macOS, Linux, Android, iOS, Web)
- **Backend:** Rust via `flutter_rust_bridge` v2.11.1 FFI
- **Networking:** WSS relay (signaling + text/CRDT/MLS) + WebRTC data channels (files/shards P2P) + WebRTC media (voice/video P2P). libp2p fully removed.
- **E2EE:** vodozemac (Olm/Double Ratchet) for DMs, OpenMLS 0.8 for servers, SFrame (AES-128-GCM) for voice/video
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
│           ├── dialogs/  # InviteDialog, MnemonicDialog, CreateServerDialog, CreateChannelDialog
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
│       │   ├── image_convert.rs # WebP conversion
│       │   └── link_preview.rs  # URL link preview fetching
│       ├── crypto/       # Olm encryption + MLS + persistence
│       ├── identity/     # Ed25519 keypair management (native_identity.rs, keys.rs)
│       └── storage/      # SQLCipher message store
├── relay/                # Signaling HTTP + WebSocket room router (standalone binary, deployed on OVH VPS)
├── rust_builder/         # flutter_rust_bridge build system (cargokit)
├── vendor/ffmpeg/        # Bundled native binaries (gitignored, see fetch_ffmpeg.ps1)
├── HOLLOW_PLAN.md         # Full architecture & design document (authoritative for all phase details)
└── CLAUDE.md             # This file
```

## Build & Run Commands
```bash
# Run on current platform (debug)
flutter run -d windows

# Build release
flutter build windows

# Check Rust code
cd rust/hollow_core && cargo check
cd rust/hollow_core && cargo clippy

# Regenerate FFI bindings after Rust API changes (run from project root)
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"

# Deploy relay server updates to VPS
scp relay/src/*.rs ubuntu@141.227.186.209:/home/ubuntu/relay/src/
ssh ubuntu@141.227.186.209 "cd relay && cargo build --release && sudo systemctl restart hollow-relay"
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
- **Peer state tracking in swarm.rs:** `ws_room_peers` (room → peer set), `synced_peers` (HashSet<String>). WS PeerJoined triggers key exchange + sync. 30s keepalive ping in ws_client.rs.
- **Event streaming:** Rust→Dart via `StreamSink` (flutter_rust_bridge). `watch_network_events()` in `api/network.rs`, `EventStreamNotifier` in `event_provider.dart`.
- **Navigation shell:** Two layout modes (persisted via `layoutModeProvider`):
  - **Dock mode (default):** FriendsBar (top) | ChannelSidebar + ChatPane + MemberPanel | BottomBar (bottom). Split view support. Home dashboard.
  - **Classic mode:** Discord-like 4-panel — ServerStrip (72px) | ChannelSidebar (240px) | ChatPane | MemberPanel (240px).
  - Responsive: mobile uses bottom nav with single-panel views.
- **Window chrome:** `window_manager` ^0.5.1, `setAsFrameless()`, custom 32px title bar. Known issue: drag-from-maximized doesn't live-redraw until drop (Flutter engine limitation).
- **Theme:** Dark primary + light secondary. `HollowTheme.dark()`/`.light()` + `darkWithHue()`/`lightWithHue()` for custom accent.
- **Icons:** `lucide_icons: ^0.257.0`. All `LucideIcons.*` (camelCase). v0.257.0 uses `alertTriangle`/`alertCircle`. No `cloudCheck` — uses `cloud`. Brand icons use `simple_icons: ^14.6.1` (`SimpleIcons.*`, `SimpleIconColors.*`).
- **License key system:** Relay loads `keys.json` (enabled toggle + key list), validates during WS auth, hot-reloads every 30s with active connection revocation. App checks `/relay-status` on startup, shows key dialog if required, caches key in SQLCipher via `set_license_key()` FFI.
- **Window title bar:** `WindowTitleBar` lives in `MaterialApp.builder` (above Navigator), NOT inside `HollowShell`. Navigator child wrapped in `ClipRect` to prevent `BackdropFilter` blur bleed. Never move the title bar back inside the shell.
- **Logging:** `hollow_log!` macro → stderr + `hollow_debug.log` (release-safe, 10MB rotation). `hollow_crash.log` captures Flutter/platform errors (5MB rotation).
- **Relay:** OVH VPS 141.227.186.209, Nginx TLS on 443 → Axum HTTP+WS on 127.0.0.1:8080. Domain: `relay.anonlisten.com`.
- **TURN:** Coturn on VPS (141.227.186.209:3478 UDP/TCP + 5349 TLS). Relay `/turn-credentials` generates HMAC-SHA1 creds. `IceConfigProvider` in Dart fetches + auto-refreshes every 50 min.
- **Storage layout:**
  - `~/.hollow/files/{file_id}.{ext}` — full-replication pool (DMs, <6 servers, all images). Persistent.
  - `~/.hollow/vault/{server_id}/{shard_key}.shard` — erasure-coded shards (6+ servers). Retention: Standard 365d, Low 90d, Permanent ∞.
  - `~/.hollow/vault_cache/{content_id}.{ext}` — LRU-evicted decrypted cache (1GB hard cap, every 30min).

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
- **CRITICAL — MLS epoch staleness after reconnection.** Any message that MUST work immediately after reconnection should use plaintext `HavenMessage` (not MLS `MessageEnvelope`). Applies to: sync requests, shard coordination, voice channel state changes.
- **CRITICAL — flutter_webrtc Windows: never use `replaceTrack` reuse for mid-call media.** ALWAYS use `pc.addTrack(track, stream)` / `pc.removeTrack(sender)`. See `voice_channel_service.dart`.
- **CRITICAL — Share WebRTC reconnection: receiver-initiates, sender-catches.** The downloader drives reconnection via the share tick's `ShareNeedWebRtc`; the seeder only accepts incoming offers. `connectToPeer` has a 10s stale-offer timeout to prevent dead connections from blocking all future attempts (glare rejection). `forget_peer` keeps `peer_have` intact — only clears `inflight`.
- **CRITICAL — always `await` WebRTC resource disposal.** `RTCVideoRenderer.dispose()`, `RTCPeerConnection.close()`/`.dispose()`, and `MediaStream.dispose()` are async — unawaited calls leak ~200 MB per session.
- **CRITICAL — sender side needs `FileCompleted` emit too.** Any new field added to `FileHeader`/`StoredFile` will be missing from sender's UI unless the send path also emits `FileCompleted`.
- **CRITICAL — `flutter_rust_bridge` codegen:** run from project root with explicit args. Codegen errors if you `cd` into `rust/hollow_core/` first.
- **CRITICAL — message signing must use `message_signing_payload()` + timestamp parity.** ALL signing sites must use the canonical payload. Dart timestamps MUST be hydrated from Rust's signed value (not `DateTime.now()`).
- **CRITICAL — sender-side link previews (privacy).** Receivers MUST NEVER make HTTP requests to previewed URLs.
- **CRITICAL — never use raw `OverlayEntry` inside `SelectionArea`.** Use `showDialog` with `barrierColor: Colors.transparent` instead.
- **MLS coordinator model:** `is_mls_coordinator()` — deterministic election (lowest online peer_id in MLS group).
- **HollowTooltip: always use `_dismiss()` pattern** — immediate overlay removal, no reverse animation.
- **`scrollable_positioned_list: ^0.3.8`** — sentinel pattern with `itemCount: messages.length + 1`. Do not remove this package.
- **`showHollowDialog` overlays need a `Material` ancestor** for `Text` widgets, otherwise yellow debug underline.
- **Forked `flutter_webrtc` at `../flutter-webrtc-1.4.1/`** — pubspec points at the sibling folder via `path:`. The fork adds WASAPI loopback capture inside `getDisplayMedia({audio: true})` on Windows. The captured audio track must NOT be attached to the returned MediaStream (`stream->AddTrack` crashes libwebrtc's sender iteration); Dart calls `pc.addTrack(audioTrack, stream)` on the screen-share PC instead. When iterating on the fork's native C++, delete `build/windows/x64/plugins/flutter_webrtc/` before rebuilding, and **always build `--release` if testing from the Release folder** (Vitalik does).

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
