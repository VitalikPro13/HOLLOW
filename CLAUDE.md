# HOLLOW — Project Instructions for Claude Code

## What Is This
Hollow is a fully distributed, encrypted Discord alternative. No central servers. Members collectively host the server. See `HOLLOW_PLAN.md` for the full architecture.

## Tech Stack
- **UI:** Flutter (Dart) — all platforms (Windows, macOS, Linux, Android, iOS, Web)
- **Backend:** Rust via `flutter_rust_bridge` v2.11.1 FFI
- **Networking:** WebSocket relay (sole transport) — libp2p fully removed
- **E2EE:** vodozemac (Olm/Double Ratchet) for 1:1, OpenMLS 0.8 for server channels
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
│           ├── sidebar/  # PeerCard, EmptyPeerList (reusable components)
│           ├── components/ # HollowPressable, HollowButton, HollowTextField, HollowDialog, HollowTooltip, HollowToast, HollowToggle, HollowAvatar, HollowCard, StatusDot
│           ├── dialogs/  # InviteDialog, MnemonicDialog, CreateServerDialog, CreateChannelDialog
│           └── animations/ # HollowCurves, HollowDurations, FadeSlideTransition, ScaleFadeTransition, SelectionShimmer, AmbientBackground, StartupRevealScope, RevealWidgets
├── rust/hollow_core/      # Rust library crate (networking, crypto, storage)
│   └── src/
│       ├── api/          # FFI layer (flutter_rust_bridge scans these)
│       ├── node/         # WS relay client, signaling, event loop (swarm.rs)
│       ├── crypto/       # Olm encryption + MLS + persistence
│       ├── identity/     # Ed25519 keypair management (native_identity.rs, keys.rs)
│       └── storage/      # SQLCipher message store
├── relay/                # Signaling HTTP + WebSocket room router (standalone binary, deployed on OVH VPS)
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
**Phase 6.25: Security & Optimization Audit — COMPLETE (Apr 5, 2026).** 21 findings all fixed. VPS hardened. TURN ICE config bug fixed (split URIs into separate entries). Voice calls confirmed working cross-internet via STUN P2P.

**Phase 6.75: Polish & Launch Prep — IN PROGRESS.**
- **Chat list rework: DONE (Apr 5).** Replaced `ScrollablePositionedList` with reversed `ListView.builder` in both `channel_chat_pane.dart` and `chat_pane.dart`. `scrollable_positioned_list` dependency removed. Reply-tap-scroll uses `GlobalKey` + `Scrollable.ensureVisible()`. In-memory message cap: 200 per conversation. DB load limit: 200.
- **Unread count persistence: DONE (Apr 5).** Rust FFI functions for counting unread. `loadAll` at startup. DM unread badges (red, numbered) working on friends bar + home dashboard. Server unread badges work for real-time messages; startup count still inconsistent (TODO).
- **DM sync fix: DONE (Apr 5).** 3 critical bugs in offline DM delivery, all in `swarm.rs`: (1) `send_encrypted_message` silently dropped messages when peer offline — now queues to `pending_messages`; (2) `RoomMembers` handler had no Olm key exchange or DM sync — sync was one-directional; (3) `PeerJoined` didn't drain `pending_messages` when Olm session existed. Dart-side: `DmSyncCompleted` no longer wipes in-memory messages when `newMessageCount == 0`. Tested and confirmed working cross-internet.
- **MLS recovery: DONE (Apr 5).** Owner auto-cleans stale MLS members not in CRDT. Owner removes+re-adds peers for recovery (same peer_id, corrupted state). `remove_group` now properly clears OpenMLS provider storage (`group.delete`). Welcome handler removes stale local group before joining. Fixes identity reset + leave/rejoin MLS desync.
- **Unread UI: DONE (Apr 5).** Friends bar: teal dot → red numbered pill badge. Home dashboard: teal → red badge, repositioned next to time (vertically centered). Server badges already red.
- **Server unread on startup: TODO.** Infrastructure in place (`RoomMembers` now registers channel sync, `SyncCompleted` recomputes unreads, MLS batch handler always emits `MessageSyncCompleted`), but startup badge display still inconsistent. Real-time server unreads work fine.
- **Distributed MLS committer: DONE (Apr 6).** Removed owner-only KeyPackage gate. `is_mls_coordinator()` = lowest online peer_id in MLS group. Falls back to owner for initial group creation. Any MLS member can onboard new members when owner is offline.
- **Vault self-healing: DONE (Apr 6).** Fixed broken repair logic (disjoint set intersection → always false). Event-driven rebalance (PeerJoined/Left + 10s debounce). Coordinator-gated. `compute_migration_plan()` wired up for shard redistribution to new members.
- **Channel sync fix: DONE (Apr 6).** MLS `ChannelProbe` silently failed after reconnection (stale epoch → decrypt fails → no response). Replaced with plaintext `ChannelSyncRequest` in sync coordinator. Sync response still uses MLS/Olm encryption. 217 tests.
- **CRITICAL LESSON:** Sync/coordination requests that must work after reconnection MUST use plaintext, not MLS. MLS epoch staleness causes silent failures. Only the response payload needs encryption.
- **MLS/Encryption audit fix: DONE (Apr 6).** All 11 CRITICAL + 4 HIGH sites fixed. 3 patterns: (A) plaintext `HavenMessage` for requests (Post-Welcome ChannelSyncReq, ChannelSyncReq in ChannelProbeResp handler), (B) Olm fallback for responses/sensitive data (SyncResp, ChannelProbeResp, ShardResponse, ShardMigrate, ShardProbeResponse), (C) plaintext broadcast for voice state (5 new `HavenMessage` variants: VoiceChannelJoin/Leave/AudioState/ScreenState/CameraState + receive handlers with security checks). Voice SDP/ICE uses MLS→Olm fallback (IPs are sensitive). Olm receive handlers added for 8 voice SDP/ICE `MessageEnvelope` variants.
- **Server unread on startup: DONE (Apr 6).** Auto-fixed by MLS audit (sync responses now reach peers). Also fixed unread not clearing on first channel entrance (_loadHistory cache-hit early return skipped markChannelSeen).
- **Message text selection + copy: DONE (Apr 6).** `SelectionArea` wraps chat ListView (both DM + channel). Copy button in message hover action bar. Image-only messages hide copy button.
- **Attachment preview + text with file: DONE (Apr 6).** Paperclip stages file, preview card above input bar (thumbnail or file icon + name + X to remove). User can type text alongside file. `addFileMessage` accepts optional text param.
- **File sync delays reduced: DONE (Apr 6).** 2-3s → 1-1.5s, 500ms → 100ms between files. Safe because file bytes go via WebRTC P2P.
- **Background CPU optimization: DONE (Apr 6).** `SharedTickers` singleton — 1 ticker drives all decorative anims (shimmer, pulse, typing dots). Ambient background → ~15fps Timer. Auto-pause on window hide/minimize/tray, resume on restore/focus. 6 StatefulWidgets → StatelessWidgets. N per-widget AnimationControllers → 3 shared ValueNotifiers.
- **RTCVideoView RepaintBoundary: DONE (Apr 6).** All 15 RTCVideoView instances wrapped in RepaintBoundary (call_video_view.dart: 2, voice_channel_pane.dart: 5, chat_pane.dart: 8). Isolates video frame updates from parent tree repaints.
- **Clipboard image paste/copy: DONE (Apr 7).** `super_clipboard ^0.9.1`. Ctrl+V pastes images as staged attachments. Copy-image button on message hover bar for image messages. Both DM + channel panes. See `chat_input_shortcuts.dart` `_tryPasteImage()` and `copyImageToClipboard()`.
- **Drag-and-drop files: DONE (Apr 7).** `desktop_drop ^0.7.0`. New `chat_drop_zone.dart` reusable widget wraps both chat panes with accent-bordered drag overlay. Reuses existing `_stagedFile*` flow + size validation (DM 34MB cap, server per-config cap).
- **DM 1:1 video call camera bug: DONE (Apr 7).** Three layered root causes fixed: (1) `replaceTrack` reuse silently fails on libwebrtc Windows — `onTrack` never fires on the receiver, even after a full SDP renegotiation cycle. Switched `voice_service.dart` to `addTrack`/`removeTrack` pattern matching `voice_channel_service.dart`. Every camera enable creates a fresh transceiver with a fresh ssrc. (2) `startCall` was presetting `state.isVideoEnabled: withVideo` → made the auto-toggle skip its `!state.isVideoEnabled` guard → camera never auto-enabled. Removed the preset. (3) `_handleRemoteVideoTrack` was disposing event-owned `_remoteStream` before building the new renderer; on `MediaStreamDisposeFailed` the catch handler nulled `_remoteRenderer`, killing the new one. Added stash-build-commit-dispose pattern + `_remoteStreamIsSynthetic` ownership flag (only dispose synthetic streams; event.streams.first is owned by libwebrtc). Final architecture: video calls connect audio-only, then auto-toggleVideo() 300ms after `onConnected`. Side without a camera no-ops via `enabled == wasEnabled` short-circuit. See memory `dm-camera-bug.md` and `feedback_webrtc_addtrack_pattern.md`.
- **DM source switcher pill: DONE (Apr 7).** Modeled after `voice_channel_pane.dart::_buildSharerSwitcher`. New `focusedDmSourceProvider: StateProvider<DmFocusedSource>` (peerId + type pair). `_buildScreenShareSourcePill` in `_ChatPaneState` now uses `HollowPressable` with all tabs clickable. `_ScreenShareFullView` rewritten with `_resolveBig()` helper that picks the big-tile renderer based on focus + active sources, with fallback (remote screen → local screen → remote camera → local camera). New `_renderTile()` handles mirror logic (cameras mirrored when local, screens never). PiP tile shows the OTHER screen when both peers sharing. `ScreenShareService` exposes `localRenderer` for self-preview (initialized in `createOffer` and `createOfferFromStream`, disposed in `close`). `CallNotifier.localScreenShareRenderer` getter. Pill scope: only shows when ≥1 screen share active (camera-only DMs don't need it). Auto-focus-on-build was tried then reverted — caused issues during the screen-share toggle dance. Pill stays unhighlighted until user explicitly taps a tab.
- **Video preview in chats: PLANNED (detailed sub-tasks in HOLLOW_PLAN.md).** Architecture decision recorded inline: in 6+ servers the sender extracts a small JPEG thumbnail (first frame) which goes through the **image** path (full P2P streamed → instant scroll), the actual video bytes go through the **vault** path only. Universal `vault_cache/` model — even the uploader plays from cache. Confirmed by reading `swarm.rs:4697-4708`: existing `store_full_file = is_image || member_count < 6 || dm` gate already routes correctly — non-image files in 6+ servers don't get streamed/stored to receivers' `files/` (only metadata flows for the FileHeader). New "Save" button design: works for ALL non-image vault files via native Save As dialog, copies from `vault_cache/` to user-chosen location. No upload pipeline changes needed.
- Next up: Implement video preview plan (next session), remaining Phase 6.75 items.
- flutter_chat_ui package evaluated and rejected (too opinionated for Hollow's custom UI).

**Phase 5B: Voice & Video — COMPLETE (Apr 4, 2026).**
- **1:1 voice calls: DONE.** Separate RTCPeerConnection for voice. Full call flow + signaling. Tested cross-internet.
- **Device selection: DONE.** Input: `sourceId` constraint. Output: `win32audio` + `Helper.selectAudioOutput()`.
- **1:1 video calls: DONE.** Side-by-side + fullscreen. Tested cross-internet.
- **Screen sharing: DONE.** Separate `RTCPeerConnection` per direction (`ScreenShareService`). `getDisplayMedia()` + `addTrack()` on fresh PC. Quality picker (360p-4K, 5-60 FPS, default 1080p60). Camera independent (stays on voice PC). Bidirectional sharing works. 3 Rust signal types: `screen_offer/answer/ice`.
- **Screen share layout: DONE.** Full-bleed screen fills entire chat pane. Chat overlay (360px right, toggleable) + controls pill (bottom center) auto-fade after 1s inactivity. Pinned while hovering/typing.
- **TURN server: DEPLOYED.** Coturn on VPS. HMAC-SHA1 credentials via relay `/turn-credentials`. IceConfigProvider refreshes every 50 min.
- **ICE config:** Own coturn STUN + Cloudflare + Google STUN + TURN (UDP/TCP/TLS).
- **Custom ringtone: DONE.** `audioplayers`, file path in SQLCipher, volume slider, trim editor.
- **Audio quality presets: DONE.** Voice (32k mono), Music (128k stereo), Hi-Fi (256k stereo). SDP Opus fmtp munging.
- **Per-peer volume: DONE.** `Helper.setVolume()` on remote receiver track. Right-click popup (0-200%).
- **Voice channels: DONE.** Channel type system (text/voice). Full-mesh WebRTC (2-5 users). MLS-encrypted join/leave broadcast + targeted SDP/ICE. Sidebar tiles with participant list + mute/deafen indicators (stacked). Vertical shimmer for connected channels. Voice control panel (mute/deafen/disconnect). Audio state broadcast to peers. VAD speaking indicator (local via `record` package, remote via getStats). Join/leave fade animations. Per-peer volume (right-click compact overlay). Compact overlay popup also replaces old DM volume popup.
- **Gossip relay tree: DONE.** Unified gossip overlay for file broadcasting + voice channel scaling. `gossip.rs` module: `GossipOverlay` (6-12 neighbors per server, 50 total cap), `PeerScore` (latency/uptime/bandwidth/shard overlap), 5-min rotation, broadcast dedup (60s TTL), `PendingRelay` for file relay flow. File broadcast: 6+ member channel files sent to gossip neighbors → auto-relay with TTL decrement → 1000+ members in ~3 hops. 30s fallback to direct `FileProbe`. Voice gossip: partial-mesh audio PCs to gossip neighbors only (not all participants), `onTrack` forwarding with `_forwardedSources` dedup, hysteresis (6 up / 4 down). `PeerExchange` every 2 min for topology discovery. <6 members keep current eager behavior. 26 Rust tests.
- **Profile sync: FIXED.** 6 fixes: restored empty plaintext broadcast (DM peers), profile re-send on reconnect (PeerJoined/RoomMembers), `ProfileRequest` message type, startup broadcast, timestamp tolerance (24h clock skew), member display_name update. Server avatar CRDT now emits `ServerUpdated` (was `SyncCompleted`).
- **SFrame E2EE: DONE.** Full end-to-end encryption on all voice audio frames. `FrameCryptorService` wraps flutter_webrtc's `FrameCryptor`+`KeyProvider` (AES-128-GCM). DM calls: caller generates 32-byte key, sends in Olm-encrypted `CallInvite`. Server voice channels: key derived from MLS epoch secret via `export_secret("sframe")`. Key auto-rotates on MLS membership changes via `MlsEpochChanged` event. Both tested cross-internet, `FrameCryptorStateOk` on both sides. 2 new MLS tests (export + rotation).
- **Voice channel screen sharing: DONE.** Separate `ScreenShareService` per direction per peer. `createOfferFromStream()` shares one capture across N outgoing PCs. 4 new Rust `MessageEnvelope` variants (`vc_screen_offer/answer/ice/state`) via MLS. `role` field on ICE candidates routes to correct PC (outgoing vs incoming). Full-bleed layout: chat overlay (360px right, toggleable) + floating controls pill (auto-fade 1s). Late joiner support (screen_state + screen_offer on PeerJoined, early ICE queue). Voice channels selectable in sidebar (click joined VC → main pane shows ChannelChatPane). Screen share button in VoiceChannelPanel. Auto-select first text channel on leave.
- **Voice channel camera video: DONE.** Camera toggle in VC, per-peer video grid (1-5 tiles), click-to-fullscreen with PiP thumbnails, mixed mode switcher (screen+camera sources with icons), chat overlay, SFrame E2EE on video tracks. 3 new Rust `MessageEnvelope` variants (`vc_reneg_offer/answer`, `vc_camera_state`). Key fixes: leave-first-then-cleanup ordering prevents disconnect blocking, renderer kept alive across camera off/on cycles (onTrack doesn't fire on transceiver reuse), screen share offer deferred to onPeerConnected callback.
- **Crash logging: DONE.** `hollow_crash.log` captures Flutter framework errors (`FlutterError.onError`) and platform/async errors (`PlatformDispatcher.onError`). 5MB rotation. Located alongside `hollow_debug.log` in data dir.
- **Next:** Phase 6.25 (security & optimization audit), then Phase 6.75 polish.

**Phase 5A: WebRTC Data Channels — COMPLETE (Mar 29, 2026).** P2P file/shard streaming via WebRTC data channels. flutter_webrtc 1.4.1 (libwebrtc m144). ~9 MB/s throughput, tested up to 131MB. 85-90% of heavy transfers bypass relay. STUN only (no TURN yet). WSS relay fallback for symmetric NAT. Keepalive pings (30s), auto-reconnect, early-arrival handling, `getBufferedAmount()` backpressure.

**Phase 7: libp2p Full Removal — COMPLETE (Mar 27-28, 2026).** libp2p fully removed. WSS relay is sole transport. ed25519-dalek replaces libp2p identity. Relay server simplified (signaling + WS only). 184 tests pass.
**Phase 5 (old): WebSocket Relay — COMPLETE (Mar 25-26).** All messages + file streaming via WSS.
**Phase 6 (old): Pure MLS for Servers — COMPLETE (Mar 26-27).** Servers = MLS, DMs = Olm, transport = WS.

**Phase 4: Shared Vault — COMPLETE.** Phases 1-3.75 all COMPLETE.

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
- **Peer state tracking in swarm.rs:** `ws_room_peers` (room → peer set), `synced_peers` (HashSet<String>). WS PeerJoined triggers key exchange + sync. 30s keepalive ping in ws_client.rs.
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
- **Transport:** WSS connection to relay (signaling + text/CRDT/MLS) + WebRTC data channels for files/shards (85-90% P2P, WSS fallback) + WebRTC audio for voice calls (separate RTCPeerConnection per call).
- **TURN:** Coturn on VPS (141.227.186.209:3478). Relay `/turn-credentials` generates HMAC-SHA1 creds. `IceConfigProvider` in Dart fetches + auto-refreshes.

## Coding Conventions
- Dart: follow standard `flutter_lints` / `analysis_options.yaml`
- Rust: follow standard `cargo clippy` recommendations
- File naming: snake_case for Dart and Rust files
- No Electron, no Node.js, no web frameworks — Flutter only for UI
- **NEVER pass `WidgetRef ref` as a constructor parameter** to child widgets. Always use `ConsumerWidget` or `ConsumerStatefulWidget` instead. Passing `ref` causes cascade rebuilds.
- Use `AnimatedOpacity` (GPU-composited) for per-item opacity. Never use the `Opacity` widget.
- **Keep Flutter updated:** Windows animation jank was a Flutter engine bug (3.38.5), fixed in 3.41.4. `windows/runner/main.cpp` is stock.
- **CRITICAL — Backward-compatible DB schema:** ALWAYS add `#[serde(default)]` to ANY new field added to a persisted Rust struct (e.g., `ServerState`, any struct stored as JSON in SQLCipher). Without it, old data lacking the new field will fail to deserialize and silently disappear (servers vanish, data lost).
- **HollowTooltip: always use `_dismiss()` pattern** — tooltip hide must remove the overlay entry immediately (no reverse animation). Animated hide causes orphaned tooltips when parent widgets rebuild or leave the tree (e.g., call bar buttons disappearing on call end). The `_dismiss()` method must: set `_hovering = false`, stop + reset the animation controller, then `_entry?.remove()` + null. This applies to ALL `HollowTooltip` usages across the app.
- **CRITICAL — TURN ICE config: split URIs into separate entries.** flutter_webrtc's native C++ `CreateIceServers` has a single `uri` field per `IceServer` struct. Passing `urls: [list]` overwrites to only the last URI — other TURN transports are never tried. Always map each TURN URI to its own `{'urls': singleUri, 'username': ..., 'credential': ...}` entry in `ice_config_provider.dart`.
- **CRITICAL — MLS epoch staleness after reconnection.** MLS-encrypted coordination messages (sync probes, shard requests, voice state) silently fail when the receiver's MLS epoch is stale after going offline. The sender encrypts successfully, but the receiver can't decrypt → message vanishes → operation hangs silently. **Rule:** Any message that MUST work immediately after reconnection should use plaintext `HavenMessage` (not MLS `MessageEnvelope`). The response can still use MLS/Olm encryption. Applies to: sync requests, shard coordination, voice channel state changes. See HOLLOW_PLAN.md Phase 6.75 "MLS/Encryption Audit" section for full list of affected call sites (~11 CRITICAL + ~4 HIGH).
- **MLS coordinator model:** `is_mls_coordinator()` — deterministic election (lowest online peer_id in MLS group). Used for: KeyPackage processing (distributed MLS committer), vault rebalance, shard migration. Only MLS group members participate — OpenMLS cryptographically enforces this.
- **CRITICAL — flutter_webrtc Windows: never use `replaceTrack` reuse for mid-call media.** When toggling a media track (camera, mic) mid-call, ALWAYS use `pc.addTrack(track, stream)` to enable and `pc.removeTrack(sender)` to disable. NEVER use the `replaceTrack(null)` / `replaceTrack(realTrack)` reuse pattern on an existing transceiver. libwebrtc Windows does NOT fire `onTrack` on the remote peer when a transceiver is reused — the receiver's renderer stays bound to a stale "muted" track that never recovers when sender RTP resumes. SDP renegotiation completes successfully but no media flows. `voice_channel_service.dart` is the canonical reference. `voice_service.dart` was rewritten Apr 7 to match. See memory `feedback_webrtc_addtrack_pattern.md`.
- **CRITICAL — flutter_webrtc remote stream ownership.** Streams from `event.streams.first` in `pc.onTrack` are owned by libwebrtc — calling `dispose()` on them from Dart throws `MediaStreamDisposeFailed` because libwebrtc has already cleaned them up during renegotiation. Track ownership with a `_remoteStreamIsSynthetic` flag (true only when you created the stream via `createLocalMediaStream`), and only dispose streams you own. Use a stash-build-commit-dispose pattern: build the new renderer FIRST, commit `_remoteRenderer`/`_remoteStream`, THEN best-effort dispose the old in try/catch blocks. Never null state in a catch handler — bad data is better than no data.
- **DM call architecture (Apr 7):** Video calls connect audio-only initially, then auto-toggle camera 300ms after `onConnected`. The side without a camera no-ops via `enabled == wasEnabled` short-circuit in `CallNotifier.toggleVideo`. Do NOT preset `state.isVideoEnabled: withVideo` in `startCall` — the auto-toggle's `!state.isVideoEnabled` guard would skip and the camera would never turn on. The `_handleAccept` and `_handleSdpOffer` (initial setup branch) always pass `withVideo: false` to the service.
- **VPS SSH:** `ssh ubuntu@141.227.186.209` — key-only, no passphrase. Can be used freely for config checks, log inspection, deployments.

## Rules
- Never commit secrets, keys, or credentials
- Rust handles: networking (libp2p), crypto, CRDTs, storage engine
- Dart handles: UI, app logic, state management
- All crypto operations must use constant-time implementations
- Ask before making architectural decisions not covered in HOLLOW_PLAN.md
- When updating memory (MEMORY.md), also update this file (CLAUDE.md) if relevant
- **VPS deployment:** Ask user — never store credentials.
- **Local dev commands:** Can run `cargo check/test/clippy`, `flutter_rust_bridge_codegen generate`, `flutter analyze` freely — these are local-only operations.
- **Building/running the app:** User runs `flutter run -d windows` themselves for testing on their two laptops.
