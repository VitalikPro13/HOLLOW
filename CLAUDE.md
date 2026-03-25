# HOLLOW — Project Instructions for Claude Code

## What Is This
Hollow is a fully distributed, encrypted Discord alternative. No central servers. Members collectively host the server. See `HOLLOW_PLAN.md` for the full architecture.

## Tech Stack
- **UI:** Flutter (Dart) — all platforms (Windows, macOS, Linux, Android, iOS, Web)
- **Backend:** Rust via `flutter_rust_bridge` v2.11.1 FFI
- **Networking:** libp2p 0.56 (QUIC, TCP, WSS, mDNS, Kademlia, relay, DCUtR, AutoNAT)
- **E2EE:** vodozemac (Olm/Double Ratchet) for 1:1, OpenMLS 0.8 for server channels
- **Local DB:** SQLCipher (encrypted SQLite)
- **Identity:** Ed25519 keypairs via BIP-39 mnemonic
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
│           ├── sidebar/  # PeerCard, EmptyPeerList (reusable components)
│           ├── components/ # HollowPressable, HollowButton, HollowTextField, HollowDialog, HollowTooltip, HollowToast, HollowToggle, HollowAvatar, HollowCard, StatusDot
│           ├── dialogs/  # InviteDialog, MnemonicDialog, CreateServerDialog, CreateChannelDialog
│           └── animations/ # HollowCurves, HollowDurations, FadeSlideTransition, ScaleFadeTransition, SelectionShimmer, AmbientBackground, StartupRevealScope, RevealWidgets
├── rust/hollow_core/      # Rust library crate (networking, crypto, storage)
│   └── src/
│       ├── api/          # FFI layer (flutter_rust_bridge scans these)
│       ├── node/         # libp2p swarm + signaling client
│       ├── crypto/       # Olm encryption + persistence
│       ├── identity/     # Ed25519 keypair management
│       └── storage/      # SQLCipher message store
├── relay/                # Combined relay + signaling server (standalone binary, deployed on OVH VPS)
├── rust_builder/         # flutter_rust_bridge build system (cargokit)
├── HOLLOW_PLAN.md         # Full architecture & design document (~1500 lines)
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

# Regenerate FFI bindings after Rust API changes
flutter_rust_bridge_codegen generate

# Deploy relay server updates to VPS
scp relay/src/*.rs ubuntu@141.227.186.209:/home/ubuntu/relay/src/
ssh ubuntu@141.227.186.209 "cd relay && cargo build --release && sudo systemctl restart hollow-relay"
```

## Current Phase
**Phase 4: Shared Vault — IN PROGRESS.** Phases 1-3.75 all COMPLETE.

**Phase 4 — Shared Vault — Distributed Storage (started Mar 16, 2026):**
Distributed file storage across server members. 14 major items, ~90 sub-tasks. Key design decisions:
- **Vault = files/media only.** Messages, CRDTs, server config use existing sync system.
- **Automatic mode:** <6 members → full replication. 6+ members → adaptive Reed-Solomon erasure coding.
- **Adaptive k/m:** scales with member count (k=3/m=2 at 6 → k=20/m=10 at 500+). New content uses current params.
- **DMs stay direct P2P.** No vault involvement.
- **Manifests broadcast to all** (like CRDT ops, not erasure-coded).
- **Rat Files consent:** Small servers (<6), file deletion requires unanimous consent.
- Last 2 items (connection subset management, CRDT sharding) deferred until scaling pain.
- **No VPS deployment needed** — vault is entirely client-side.

**Phase 4 completed (Rust backend + Dart UI wired):**
1. Reed-Solomon erasure coding engine (`vault/erasure.rs`) — 22 tests
2. Content-addressed storage layer (`vault/content_store.rs`) — SHA-256 content_id, StorageTier, vault_shards table. 26 tests
3. Storage pledge system — CRDT `StoragePledgeChanged`, auto-pledge 512MB, `set_storage_pledge()`/`get_storage_stats()` FFI
4. Adaptive k/m engine (`vault/adaptive.rs`) — VaultMode enum, compute_adaptive_params, tier multipliers
5. DHT-based shard placement (`vault/placement.rs`) — XOR distance, weighted per-member caps, vault_placement table
6. Store protocol — ShardStore/ShardStoreAck via Olm metadata + `/hollow/stream/1.0.0` for shard bytes
7. Storage tier config — retention days (files=365d, voice=90d), ShardDelete envelope (MANAGE_SERVER gated)
8. Retrieve protocol — ShardRequest/Response via Olm + stream. Non-uploaders recompute placements via same XOR algorithm
9. File upload pipeline (`vault/pipeline.rs`) — VaultManifest, AES-256-GCM encrypt, prepare_upload (both modes), VaultManifestBroadcast. `vault_upload_file()` FFI
10. File download pipeline — reconstruct_file (erasure decode + AES decrypt), vault cache (`~/.hollow/vault_cache/`). Remote shard fetching: requests missing shards from peers, waits, reconstructs. `vault_download_file()` FFI
11. Vault status indicators — `vault_status_provider.dart`, `_VaultHealthIndicator` in channel header (6+ members only)
12. Rebalancing (`vault/rebalancer.rs`) — departure detection, repair/migration plans, 30-min timer (retention enforcement, LRU cache eviction 1GB)
13. Storage dashboard UI (`storage_dashboard_dialog.dart`) — pledge editor, retention editor, animated progress bars, disk space indicator, member pledges (6+ only)
14. Streaming file transfer — `/hollow/stream/1.0.0` Yamux/QUIC substream (replaced Olm chunks), tested 355MB

**Dart UI integration done:**
- `file_transfer_provider.dart` calls `vaultUploadFile()` for 6+ member servers alongside P2P streaming
- Per-file vault phase text on file cards during vault downloads
- Member panel "Contributing" label for 6+ servers
- Real-time download progress (500ms polling, determinate bar + byte counter)
- File card shows immediately on FileHeaderReceived (not after completion)

**Phase 4 still TODO:**
- Erasure coding not yet tested end-to-end across 6 real peers
- Per-member shard counts in member panel (currently just "Contributing" label)
- Custom shimmer animation for vault file placeholders

122 total vault tests. See `HOLLOW_PLAN.md` for full checklist.

## Completed Phases Summary
- **Phases 1-2:** LAN E2EE, internet connectivity, relay, DHT prekeys, invite links
- **Phase 2.5+2.75:** UI Foundation + Hollow Design System v2
- **Phase 3:** Servers, Channels, CRDT sync, OpenMLS group encryption
- **Phase 3.5 (Daily Driver):** User profiles, message editing/deletion/replies, emoji reactions, typing indicators, rich text/markdown, pinned messages, channel organization (categories/separators), system tray, friends system & DM overhaul, search, keyboard shortcuts (Ctrl+B/I/E, Ctrl+Shift+X/S), notifications (in-app overlay + native), P2P file sharing (streaming transfer, 64KB chunks), reply-tap-scroll (ScrollablePositionedList)
- **Phase 3.75 (Security Hardening):** All 21 vulnerabilities fixed (3 critical, 4 high, 6 medium, 8 low). Relay server hardened (SSH key-only, Fail2ban, UFW, systemd limits). Date separators, log rotation (10MB)
- **Dock Layout:** Bottom bar (dock-style servers), top friends bar, split view (50/50 draggable), home dashboard (profile + recent convos + network monitor). Classic layout preserved as option
- **Avatars/Banners/Server Icons:** Rust image processing (WebP), crop dialog, BLOB storage, base64 wire protocol, `"CLEAR"` sentinel for removal
- **Server Folders:** Drag-and-drop `StripItem` sealed class, 2x2 mini-grid preview, folder popup, `LongPressDraggable` + `DragTarget`
- **Customization:** Local peer nicknames (static ref in `displayNameFor()`), custom accent color (`darkWithHue()`/`lightWithHue()`), custom background image (theme-level alpha, darken slider)
- **DM Profile Panel:** 240px sidebar with slide animation, banner/avatar/status/about/nickname/friend status
- **GIF Support:** Preserved in file sharing, `AnimatedGifImage` widget (multi-frame codec + Ticker), animate prop on HollowAvatar
- **Connection Status:** Granular 5-stage tracking, unread message pill, channel msg count health check, sync UI fixes

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
- **Peer state tracking in swarm.rs:** `connected_peers`, `expected_peers`, `disconnected_peers` HashSets. `ConnectionEstablished` triggers DHT prekey fetch. Ping: 5s/5s. Rebootstrap: 60s.
- **Event streaming:** Rust→Dart via `StreamSink` (flutter_rust_bridge). `watch_network_events()` in `api/network.rs`, `EventStreamNotifier` in `event_provider.dart`
- **Navigation shell:** Two layout modes (persisted via `layoutModeProvider`):
  - **Dock mode (default):** FriendsBar (top) | ChannelSidebar + ChatPane + MemberPanel | BottomBar (bottom). Split view support. Home dashboard.
  - **Classic mode:** Discord-like 4-panel — ServerStrip (72px) | ChannelSidebar (240px) | ChatPane | MemberPanel (240px).
  - Responsive: mobile uses bottom nav with single-panel views.
- **Window chrome:** `window_manager` ^0.5.1, `setAsFrameless()`, custom 32px title bar. Known issue: drag-from-maximized doesn't live-redraw until drop (Flutter engine limitation).
- **Theme:** Dark primary + light secondary. `HollowTheme.dark()`/`.light()` + `darkWithHue()`/`lightWithHue()` for custom accent. Toggle via `themeModeProvider`.
- **Icons:** `lucide_icons: ^0.257.0`. All `LucideIcons.*` (camelCase). v0.257.0 uses `alertTriangle`/`alertCircle`. No `cloudCheck` — uses `cloud`.
- `hollow_log!` macro logs to stderr + `hollow_debug.log` (works in release builds, rotates at 10MB)
- Relay: OVH VPS 141.227.186.209, Nginx TLS on 443 → WS 127.0.0.1:9001. Domain: relay.anonlisten.com
- Connection priority: LAN (mDNS) → Hole punch (DCUtR) → QUIC relay → TCP relay → WSS relay

## Coding Conventions
- Dart: follow standard `flutter_lints` / `analysis_options.yaml`
- Rust: follow standard `cargo clippy` recommendations
- File naming: snake_case for Dart and Rust files
- No Electron, no Node.js, no web frameworks — Flutter only for UI
- **NEVER pass `WidgetRef ref` as a constructor parameter** to child widgets. Always use `ConsumerWidget` or `ConsumerStatefulWidget` instead. Passing `ref` causes cascade rebuilds.
- Use `AnimatedOpacity` (GPU-composited) for per-item opacity. Never use the `Opacity` widget.
- **Keep Flutter updated:** Windows animation jank was a Flutter engine bug (3.38.5), fixed in 3.41.4. `windows/runner/main.cpp` is stock.
- **CRITICAL — Backward-compatible DB schema:** ALWAYS add `#[serde(default)]` to ANY new field added to a persisted Rust struct (e.g., `ServerState`, any struct stored as JSON in SQLCipher). Without it, old data lacking the new field will fail to deserialize and silently disappear (servers vanish, data lost).

## Rules
- Never commit secrets, keys, or credentials
- Rust handles: networking (libp2p), crypto, CRDTs, storage engine
- Dart handles: UI, app logic, state management
- All crypto operations must use constant-time implementations
- Ask before making architectural decisions not covered in HOLLOW_PLAN.md
- When updating memory (MEMORY.md), also update this file (CLAUDE.md) if relevant
- **VPS deployment:** Ask user — requires SSH password, never store credentials. User deploys themselves.
- **Local dev commands:** Can run `cargo check/test/clippy`, `flutter_rust_bridge_codegen generate`, `flutter analyze` freely — these are local-only operations.
- **Building/running the app:** User runs `flutter run -d windows` themselves for testing on their two laptops.
