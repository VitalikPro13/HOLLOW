# HOLLOW — Project Instructions for Claude Code

## What Is This
Hollow is a fully distributed, encrypted Discord alternative. No central servers. Members collectively host the server. See `HOLLOW_PLAN.md` for the full architecture.

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
│       ├── node/         # WS relay client, signaling, event loop (swarm.rs)
│       ├── crypto/       # Olm encryption + MLS + persistence
│       ├── identity/     # Ed25519 keypair management (native_identity.rs, keys.rs)
│       └── storage/      # SQLCipher message store
├── relay/                # Signaling HTTP + WebSocket room router (standalone binary, deployed on OVH VPS)
├── rust_builder/         # flutter_rust_bridge build system (cargokit)
├── vendor/ffmpeg/        # Bundled native binaries (gitignored, see fetch_ffmpeg.ps1)
├── HOLLOW_PLAN.md         # Full architecture & design document
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

## Current Phase — Phase 6.75: Polish & Launch Prep
Most items shipped (see memory topic files for details). Remaining TODO:
- **Archive tab + `.hollow-archive` format (NEXT)** — personal DB viewer for historical data (left servers, ex-friend DMs, kicked channels) + signed cryptographically-verifiable export format, part of "The RAT Files" protocol. No PDF/EPUB support (security theater — trivially editable). Two sub-tabs: "My Data" (read-only browser over own DB) + "Imported Archives" (drag-drop `.hollow-archive` loader). POV viewer renders imported archives in full fidelity with shield icons on every message/edit/delete. Web viewer (`archive.hollow.app`) deferred but architecturally committed (Flutter Web-compatible from day one). See `HOLLOW_PLAN.md:1661` for the full spec — Rust `archive_exporter.rs`/`archive_loader.rs` + Flutter tab with icon on server strip.
- **6+ server vault video testing** — blocked (no 6-peer testbed).
- **FFmpeg binary strip/minimize** — deferred to Phase 7.

See `HOLLOW_PLAN.md` Phase 6.75 section for the full checklist.

## Completed Phases (summary)
- **1–3.75:** LAN E2EE → internet → servers/channels (CRDT + OpenMLS) → daily driver (profiles, reactions, replies, typing, search, shortcuts, notifications, P2P files, friends/DMs, tray) → security hardening (21 vulns fixed, relay hardened). Feb–Mar 16, 2026.
- **4 — Shared Vault:** Reed-Solomon erasure coding, adaptive k/m, DHT shard placement, vault pipeline (upload/download/reconstruct), rebalancer, storage dashboard. `<6 members = full replication, 6+ = erasure-coded`. 122 vault tests. See `phase4-decisions.md`.
- **4.5 — Account Recovery:** Mnemonic-based identity restore.
- **5/6/7 (old):** WSS relay migration + pure MLS for servers + libp2p full removal. Mar 25–28.
- **5A — WebRTC data channels:** P2P file/shard streaming, ~9 MB/s, 85–90% direct, WSS fallback. Mar 29.
- **5B — Voice & Video:** 1:1 calls, voice channels (full-mesh 2–5 + gossip partial-mesh 6+), screen sharing, camera, SFrame E2EE (AES-128-GCM, MLS epoch export for VCs), device selection, audio presets, per-peer volume, gossip relay tree for file broadcast. TURN deployed. Mar 30–Apr 4. See `voice-channels.md`, `vc-screen-sharing.md`, `gossip-relay-tree.md`.
- **6.25 — Security & Optimization Audit:** 21 findings all fixed, TURN ICE bug fixed, VPS hardened. Apr 5. See `phase625-audit.md`.
- **6.75 (in progress):** Chat list rework (reversed ListView.builder, 200-msg cap), unread count persistence, DM sync fix, MLS recovery, distributed MLS committer, vault self-healing, channel sync fix (plaintext), MLS/encryption audit (15 sites), CPU optimization (SharedTickers), RTCVideoView RepaintBoundary, clipboard image paste/copy, drag-drop files, DM camera bug resolved, DM source switcher pill, video preview in chats (inline player + ffmpeg-extracted WebP thumbs), HAVEN→HOLLOW rename cleanup, link previews (sender-side OG fetch + Q=50 WebP thumbs + clickable URLs in chat text), image quality tiers (user-configurable WebP Lossless/Balanced50%/Small30%, Balanced default, applies to all user-uploaded images), cryptographic message verification ("The RAT Files" — Message Proof dialog + Export Proof JSON + in-app proof verifier in Security tab + file-message signature bug fix), favourites for friends strip (star toggle + reorder + `app_settings` persistence), VC screen share self-preview (local RTCVideoRenderer + stop button), WebRTC memory leak fixes (awaited dispose on renderers/PCs/streams in call + VC providers), screen share quality label (local+remote pill on all screen share views, quality field threaded through Rust HavenMessage/MessageEnvelope), EXIF/metadata stripping for GIF+WebP passthrough, channel auto-selection fix (first text channel in layout order, VC leave restores pre-VC channel, removed dead join prompt), DM file Save button (request missing files from peer like servers do), data export with downloaded files (include_files option + "Include downloaded files" checkbox in Security tab), passphrase dialog fix (showHollowDialog layering), server template export/import (JSON template with channels/layout/settings/icon, diff-based import with confirmation dialog, Dart-only via existing CRDT FFI), camera device selection in User Settings (flutter_webrtc enumerateDevices, persisted preference, wired to VoiceService + VoiceChannelService), VC remote stream ownership fix in voice_channel_service (added `_remoteVideoStreamSynthetic` tracking map), download manager popup (manually-saved files log keyed by user-chosen save path, click-to-reveal in Explorer with Win32 foreground lock bypass, active shard rebalance entries), Message Proof edit/delete signing fix (canonical `message_signing_payload()` for edits + deletes with distinct `ch-delete`/`dm-delete` msg_types, `edit_*_message` main-row sig/pk overwrite, sig/pk threaded through all receive/send/edit events + chat providers, Proof dialog uses `editedAt` timestamp for edited messages, optimistic-send timestamp hydrated from Rust's signed value to fix VM timer-drift verification failures).

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
- **Event streaming:** Rust→Dart via `StreamSink` (flutter_rust_bridge). `watch_network_events()` in `api/network.rs`, `EventStreamNotifier` in `event_provider.dart`.
- **Navigation shell:** Two layout modes (persisted via `layoutModeProvider`):
  - **Dock mode (default):** FriendsBar (top) | ChannelSidebar + ChatPane + MemberPanel | BottomBar (bottom). Split view support. Home dashboard.
  - **Classic mode:** Discord-like 4-panel — ServerStrip (72px) | ChannelSidebar (240px) | ChatPane | MemberPanel (240px).
  - Responsive: mobile uses bottom nav with single-panel views.
- **Window chrome:** `window_manager` ^0.5.1, `setAsFrameless()`, custom 32px title bar. Known issue: drag-from-maximized doesn't live-redraw until drop (Flutter engine limitation).
- **Theme:** Dark primary + light secondary. `HollowTheme.dark()`/`.light()` + `darkWithHue()`/`lightWithHue()` for custom accent.
- **Icons:** `lucide_icons: ^0.257.0`. All `LucideIcons.*` (camelCase). v0.257.0 uses `alertTriangle`/`alertCircle`. No `cloudCheck` — uses `cloud`.
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
- **Keep Flutter updated:** Windows animation jank was a Flutter engine bug (3.38.5), fixed in 3.41.4. `windows/runner/main.cpp` is stock.
- **CRITICAL — Backward-compatible DB schema:** ALWAYS add `#[serde(default)]` to ANY new field added to a persisted Rust struct (e.g., `ServerState`, any struct stored as JSON in SQLCipher). Without it, old data lacking the new field fails to deserialize and silently disappears (servers vanish, data lost).
- **HollowTooltip: always use `_dismiss()` pattern** — tooltip hide must remove the overlay entry immediately (no reverse animation). Animated hide causes orphaned tooltips when parent widgets rebuild or leave the tree. `_dismiss()`: set `_hovering = false`, stop + reset the animation controller, then `_entry?.remove()` + null. Applies to ALL `HollowTooltip` usages.
- **CRITICAL — flutter_webrtc native: use `sourceId` for ALL input device selection (audio AND video).** The native C++ `GetUserVideo()` and `GetUserAudio()` read device IDs from `getSourceIdConstraint()` which only looks for `sourceId` inside an `optional` array. Passing `{'deviceId': {'exact': id}}` or `{'deviceId': id}` is silently ignored — the first device (index 0) is always used. Correct pattern: `{'optional': [{'sourceId': deviceId}], 'width': ..., 'height': ...}`. This applies to both microphone and camera selection. Camera enumeration via `enumerateDevices()` is reliable; no external package needed for cameras (unlike audio which uses `win32audio`). Confirmed in flutter_webrtc's `device_enumeration_sample.dart`.
- **CRITICAL — server switching must batch provider writes atomically.** When switching servers, `channelListProvider`, `channelLayoutProvider`, `selectedServerProvider`, and `selectedChannelProvider` must all update in a single synchronous block. If `loadForServer()` fires first (which sets `state` and triggers a rebuild), the shell sees the new server's channels but the old server's `selectedChannel` — the channel lookup returns `null` and a "Welcome to #general" placeholder flashes for one frame. **Pattern:** use `ChannelListNotifier.fetchChannels()` / `ChannelLayoutNotifier.fetchLayout()` to pre-fetch data without touching state, then call `setChannels()` / `setLayout()` + set server/channel providers all synchronously. See `server_strip.dart:_selectServer` and `bottom_bar.dart` for the canonical pattern.
- **CRITICAL — TURN ICE config: split URIs into separate entries.** flutter_webrtc's native C++ `CreateIceServers` has a single `uri` field per `IceServer` struct. Passing `urls: [list]` overwrites to only the last URI — other TURN transports never get tried. Always map each TURN URI to its own `{'urls': singleUri, 'username': ..., 'credential': ...}` entry in `ice_config_provider.dart`.
- **CRITICAL — MLS epoch staleness after reconnection.** MLS-encrypted coordination messages (sync probes, shard requests, voice state) silently fail when the receiver's MLS epoch is stale after going offline. Sender encrypts successfully, receiver can't decrypt → message vanishes → operation hangs silently. **Rule:** Any message that MUST work immediately after reconnection should use plaintext `HavenMessage` (not MLS `MessageEnvelope`). The response can still use MLS/Olm encryption. Applies to: sync requests, shard coordination, voice channel state changes.
- **MLS coordinator model:** `is_mls_coordinator()` — deterministic election (lowest online peer_id in MLS group). Used for: KeyPackage processing, vault rebalance, shard migration. Only MLS group members participate — OpenMLS cryptographically enforces this.
- **CRITICAL — flutter_webrtc Windows: never use `replaceTrack` reuse for mid-call media.** When toggling a media track mid-call, ALWAYS use `pc.addTrack(track, stream)` to enable and `pc.removeTrack(sender)` to disable. NEVER use the `replaceTrack(null)` / `replaceTrack(realTrack)` reuse pattern on an existing transceiver. libwebrtc Windows does NOT fire `onTrack` on the remote peer when a transceiver is reused — receiver's renderer stays bound to a stale "muted" track that never recovers when sender RTP resumes. `voice_channel_service.dart` is the canonical reference. See memory `feedback_webrtc_addtrack_pattern.md`.
- **CRITICAL — flutter_webrtc remote stream ownership.** Streams from `event.streams.first` in `pc.onTrack` are owned by libwebrtc — calling `dispose()` on them from Dart throws `MediaStreamDisposeFailed`. Track ownership with a `_remoteStreamIsSynthetic` flag (true only when you created the stream via `createLocalMediaStream`), and only dispose streams you own. Use a stash-build-commit-dispose pattern: build the new renderer FIRST, commit state, THEN best-effort dispose the old in try/catch. Never null state in a catch handler.
- **CRITICAL — always `await` WebRTC resource disposal.** `RTCVideoRenderer.dispose()`, `RTCPeerConnection.close()`/`.dispose()`, and `MediaStream.dispose()` are async operations that free native C++ memory (libwebrtc encoder buffers, GPU textures, SRTP state). Calling them without `await` drops the Dart reference but the native side never frees — causes ~200 MB memory leak per call/screen-share session. **Rule:** every cleanup path (`_cleanup()`, `closePeer()`, `leaveChannel()`, `stopScreenShare()`, `endCall()`) must be `async` and `await` every `.dispose()` and `.close()`. Fixed Apr 9 2026 in `call_provider.dart` and `voice_channel_provider.dart`.
- **DM call architecture:** Video calls connect audio-only initially, then auto-toggle camera 300ms after `onConnected`. The side without a camera no-ops via `enabled == wasEnabled` short-circuit in `CallNotifier.toggleVideo`. Do NOT preset `state.isVideoEnabled: withVideo` in `startCall` — the auto-toggle's `!state.isVideoEnabled` guard would skip. `_handleAccept` and `_handleSdpOffer` (initial setup branch) always pass `withVideo: false` to the service.
- **CRITICAL — sender side needs `FileCompleted` emit too.** The receive path emits `NetworkEvent::FileCompleted` after `mark_file_complete` which triggers DB reload → fresh `FileAttachment`. The send path historically called `mark_file_complete` but never emitted FileCompleted — sender's optimistic `addFileMessage` stub was stuck forever without width/height/videoThumb/mimeType. Fixed in `swarm.rs:4805`. **Rule:** any new field added to `FileHeader` or `StoredFile` will be missing from the sender's UI unless the chat reloads from DB.
- **CRITICAL — bundled native binaries on Windows.** Pattern (first used for `vendor/ffmpeg/ffmpeg-win-x64.exe`): (1) `install(PROGRAMS ... DESTINATION ${INSTALL_BUNDLE_LIB_DIR} RENAME ffmpeg.exe COMPONENT Runtime)` in `windows/CMakeLists.txt` for `flutter build windows`, (2) `add_custom_command(TARGET ${BINARY_NAME} POST_BUILD COMMAND ${CMAKE_COMMAND} -E copy_if_different ...)` in `windows/runner/CMakeLists.txt` for `flutter run` dev mode. Dart side locates via `Platform.resolvedExecutable.parent`. macOS: Xcode Run Script phase + ad-hoc codesign. Linux: `install(PROGRAMS ...)`. **Mobile is OUT** — iOS/Android sandbox subprocess execution; use platform-native APIs (`video_thumbnail` package) instead.
- **`Resolve-Path` on missing paths in PowerShell:** use `[System.IO.Path]::GetFullPath((Join-Path ... ".."))` instead — `Resolve-Path` validates existence. See `scripts/fetch_ffmpeg.ps1`.
- **CRITICAL — `flutter_rust_bridge` codegen:** run from project root with explicit args (see Build commands above). Hollow has no `flutter_rust_bridge.yaml`. Codegen errors with "Fail to canonicalize path" if you `cd` into `rust/hollow_core/` first.
- **`showHollowDialog` overlays need a `Material` ancestor for `Text` widgets.** Otherwise text renders with the yellow debug double-underline. Wrap dialog content in `Material(type: MaterialType.transparency, child: ...)`.
- **`VideoPlayerController.file()` `dataSource` on Windows is `file:///C:/...` not `C:\...`.** Don't round-trip via string manipulation — stash the original file path as state when initializing the controller.
- **Lossless WebP for video thumbnails:** ffmpeg `-vf scale=-2:480 -frames:v 1 -c:v libwebp -lossless 1 -compression_level 6 -pred mixed`. WebP bypasses Rust re-encoding (`should_convert_to_webp` only triggers for png/jpg/bmp/tiff). `-2` rounds width to nearest even for codec compat.
- **Image quality pipeline:** ALL user-uploaded images go through `image_convert::convert_to_webp_with_quality(bytes, quality)` in `swarm.rs`'s SendFile handler. Quality comes from the `image_quality` key in `app_settings` (`WebpQuality::from_setting()` with `Balanced` default). `Lossless` path delegates to `convert_to_webp_lossless` (image crate, no Q param); `Balanced`/`Small` use the `webp` crate at Q=50 / Q=30. Link preview thumbs use their own `convert_to_webp_preview(bytes, 400)` at a fixed Q=50 and aren't affected by the user's setting (different use case — thumbnails, not user-uploaded content). No size-based bypass — even a 21 KB PNG drops to ~2 KB at Q=50, and "tiny × millions of messages" is real bandwidth. GIFs and existing WebP inputs still pass through untouched.
- **CRITICAL — sender-side link previews (privacy).** `node::link_preview::fetch_link_preview` is ONLY called on the sender side. Receivers render `LinkPreviewRef` from embedded message data — they MUST NEVER make HTTP requests to previewed URLs. Routing fetches through receivers turns Hollow into an IP-harvesting amplifier. The privacy property is testable by blocking a URL in `/etc/hosts` on the receiver → card still renders. HTML body cap: 2 MB (YouTube ships ~1.2 MB of inline JSON, the 1 MB initial cap was cutting off OG tags at byte ~617K). Image cap: 4 MB. 3s total timeout.
- **CRITICAL — message signing must use `message_signing_payload()` + timestamp parity.** ALL message-state-change signing sites (send, edit, delete, file) MUST sign the canonical payload from `message_signing_payload("dm"|"ch"|"dm-delete"|"ch-delete", context, sender, ts, text)`, not an ad-hoc format. Historical bugs: `SendFile` once signed raw text `"[file:abc123]"` (fixed Apr 9 2026); `EditChannelMessage`/`EditDmMessage` signed `"edit:{mid}:{new_text}:{ts}"` and `DeleteChannelMessage`/`DeleteDmMessage` signed `"delete:{mid}:{ts}"` — non-canonical (fixed Apr 11 2026). Edit signing uses the **new edit_timestamp** (not the original send ts) + **new_text**. Delete signing uses the **delete_timestamp** + **current text at delete time** (fetch via `get_channel_message_text()` / `get_dm_message_text()` in `storage/messages.rs`) + distinct `"ch-delete"`/`"dm-delete"` msg_type so a delete signature can never be replayed as a send. `edit_channel_message()`/`edit_dm_message()` UPDATE statements must also overwrite the main-row `signature`/`public_key` columns so cold DB loads produce a verifiable pair. **Timestamp parity rule:** the Dart `MessageProofData.canonicalPayload` reconstructs `haven-msg:{type}:{ctx}:{sender}:{ts}:{text}` from the in-memory message — so the in-memory `timestamp`/`editedAt` MUST equal whatever Rust used when signing. Never let Dart invent its own timestamp for a signed message. Optimistic send adds that use `DateTime.now()` MUST hydrate from `NetworkEvent::MessageSent { timestamp }` / `ChannelMessageSent { timestamp }` (Rust's actual `SystemTime::now()` value), otherwise VMs with coarse OS timer resolution drift a few ms and verification silently fails. For edited messages the Proof dialog must use `editedAt.millisecondsSinceEpoch ?? timestamp.millisecondsSinceEpoch`, not plain `timestamp`.
- **`MessageText` widget owns its URL tap recognizers.** `message_text_parser.dart` is a `StatefulWidget` because `TapGestureRecognizer` instances need explicit dispose. URL detection runs BEFORE markdown markers so URLs containing `_` or `*` (e.g. `https://en.wikipedia.org/wiki/Rick_Astley`) don't get mis-parsed as italic/bold. `buildMessageText` kept as a compat shim.
- **Windows foreground lock bypass for "reveal in Explorer" (and any programmatic focus steal).** `explorer.exe /select,path` opens/navigates a window but Windows' foreground lock blocks `SetForegroundWindow` from background processes — you get a yellow taskbar flash instead of real focus. The bulletproof workaround is a PowerShell snippet that: (1) simulates an `Alt` key tap via `keybd_event(0x12, ...)` so Windows treats recent input as user intent, (2) attaches our input queue to the current foreground window's thread via `AttachThreadInput`, (3) calls `ShowWindow(SW_RESTORE=9)` + `BringWindowToTop` + `SetForegroundWindow` while attached, (4) detaches cleanly. Reference impl: `_SavedFileTile._revealInFolder` in `download_manager_popup.dart`. Apply this pattern any time you need to programmatically raise another app's window.
- **VPS SSH:** `ssh ubuntu@141.227.186.209` — key-only, no passphrase. Can be used freely for config checks, log inspection, deployments.

## Rules
- Never commit secrets, keys, or credentials.
- Rust handles: networking, crypto, CRDTs, storage engine. Dart handles: UI, app logic, state management.
- All crypto operations must use constant-time implementations.
- Ask before making architectural decisions not covered in HOLLOW_PLAN.md.
- When updating MEMORY.md, also update this file (CLAUDE.md) if relevant.
- **VPS deployment:** Ask user — never store credentials.
- **Local dev commands:** Can run `cargo check/test/clippy`, `flutter_rust_bridge_codegen generate`, `flutter analyze` freely.
- **Building/running the app:** User runs `flutter run -d windows` themselves for testing on their two laptops.
