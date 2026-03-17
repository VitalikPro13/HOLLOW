# HAVEN — Project Instructions for Claude Code

## What Is This
Haven is a fully distributed, encrypted Discord alternative. No central servers. Members collectively host the server. See `HAVEN_PLAN.md` for the full architecture.

## Tech Stack
- **UI:** Flutter (Dart) — all platforms (Windows, macOS, Linux, Android, iOS, Web)
- **Backend:** Rust via `flutter_rust_bridge` v2.11.1 FFI
- **Networking:** libp2p 0.56 (QUIC, TCP, WSS, mDNS, Kademlia, relay, DCUtR, AutoNAT)
- **E2EE:** vodozemac (Olm/Double Ratchet) for 1:1, OpenMLS 0.8 for server channels
- **Local DB:** SQLCipher (encrypted SQLite)
- **Identity:** Ed25519 keypairs via BIP-39 mnemonic
- **Org ID:** com.anonlisten
- **Project name:** haven

## Project Structure
```
HAVEN/
├── lib/                  # Dart/Flutter code (UI, app logic, state management)
│   ├── main.dart         # Entry point (ProviderScope + RustLib.init + window_manager init)
│   └── src/
│       ├── core/         # Models, Riverpod providers, service wrappers
│       ├── theme/        # Haven design system (colors, spacing, typography, ThemeExtension)
│       └── ui/
│           ├── shell/    # Layout: haven_shell, server_strip, channel_sidebar, member_panel, user_bar, mobile_nav, window_title_bar
│           ├── chat/     # ChatPane, MessageBubble, ChannelChatPane, ChannelMessageBubble
│           ├── settings/ # ServerSettingsPanel, OverviewTab, ChannelsTab, MembersTab, DangerZoneTab
│           ├── sidebar/  # PeerCard, EmptyPeerList (reusable components)
│           ├── components/ # HavenPressable, HavenButton, HavenTextField, HavenDialog, HavenTooltip, HavenToast, HavenToggle, HavenAvatar, HavenCard, StatusDot
│           ├── dialogs/  # InviteDialog, MnemonicDialog, CreateServerDialog, CreateChannelDialog
│           └── animations/ # HavenCurves, HavenDurations, FadeSlideTransition, ScaleFadeTransition, SelectionShimmer, AmbientBackground, StartupRevealScope, RevealWidgets
├── rust/haven_core/      # Rust library crate (networking, crypto, storage)
│   └── src/
│       ├── api/          # FFI layer (flutter_rust_bridge scans these)
│       ├── node/         # libp2p swarm + signaling client
│       ├── crypto/       # Olm encryption + persistence
│       ├── identity/     # Ed25519 keypair management
│       └── storage/      # SQLCipher message store
├── relay/                # Combined relay + signaling server (standalone binary, deployed on OVH VPS)
├── rust_builder/         # flutter_rust_bridge build system (cargokit)
├── HAVEN_PLAN.md         # Full architecture & design document (~1500 lines)
└── CLAUDE.md             # This file
```

## Build & Run Commands
```bash
# Run on current platform (debug)
flutter run -d windows

# Build release
flutter build windows

# Check Rust code
cd rust/haven_core && cargo check
cd rust/haven_core && cargo clippy

# Regenerate FFI bindings after Rust API changes
flutter_rust_bridge_codegen generate

# Deploy relay server updates to VPS
scp relay/src/*.rs ubuntu@141.227.186.209:/home/ubuntu/relay/src/
ssh ubuntu@141.227.186.209 "cd relay && cargo build --release && sudo systemctl restart haven-relay"
```

## Current Phase
**Phase 4: Shared Vault — IN PROGRESS.** Phases 1-3.75 all COMPLETE.

Phases 1 (LAN E2EE chat), 2 (cross-network E2EE, prekey bundles, connection management, invite links), 2.5 (UI Foundation), 2.75 (Haven Design System v2), UI Polish Pass, 3 (Servers & Channels), 3.5 (Daily Driver), 3.75 (Security Hardening) — all COMPLETE. WSS transport deployed.

**Phase 4 — Shared Vault — Distributed Storage (started Mar 16, 2026):**
Distributed file storage across server members. 14 major items, ~90 sub-tasks. Key design decisions:
- **Vault = files/media only.** Messages, CRDTs, server config use existing sync system.
- **Automatic mode:** <6 members → full replication (every member gets every file). 6+ members → adaptive Reed-Solomon erasure coding.
- **Adaptive k/m:** scales with member count (k=3/m=2 at 6 members → k=20/m=10 at 500+). New content uses current params, existing stays as-is.
- **DMs stay direct P2P.** No vault involvement.
- **Manifests broadcast to all** (like CRDT ops, not erasure-coded — they're tiny).
- **Rat Files consent:** Small servers (<6), file deletion requires unanimous member consent.
- **Rich vault indicators:** per-file progress in chat, channel header health dot, member panel shard info, full storage dashboard.
- Last 2 items (connection subset management, CRDT sharding) deferred until scaling pain.
- **No VPS deployment needed** — vault is entirely client-side.

**Phase 4 completed so far:**
- Reed-Solomon erasure coding engine (`vault/erasure.rs`): encode/decode with ShardMetadata packing. 22 tests. 648 MB/s encode, 1085 MB/s decode.
- Content-addressed storage layer (`vault/content_store.rs`): ContentStore with own SQLCipher connection, `content_id()`/`shard_key()` pure SHA-256 functions, disk CRUD with integrity verification (data_hash), `StorageTier` enum (Standard/Low), `vault_shards` table. 26 tests.
- Storage pledge system: `CrdtPayload::StoragePledgeChanged`, `storage_pledges` field on ServerState (`AdminLwwReg<u64>`), auto-pledge on create+join (512MB default), `SetStoragePledge` NodeCommand + handler, permission check (self or admin), `set_storage_pledge()`/`get_storage_stats()` FFI, `StorageStatsFfi` struct. 3 tests.
- Adaptive k/m engine (`vault/adaptive.rs`): `VaultMode` enum (FullReplication/<6, ErasureCoding/6+), `compute_adaptive_params()` with full adaptive table, `apply_tier_multiplier()` (Standard 1.0x, Low 0.6x), `determine_tier()` (audio→Low, else Standard). 15 tests.
- DHT-based shard placement (`vault/placement.rs`): XOR distance (SHA-256 normalized into 256-bit keyspace), `ShardPlacement` struct, `compute_shard_placements()` with weighted per-member caps (pledge-proportional), `place()` unified entry point, `local_placements()`/`remote_placements()` helpers. `vault_placement` SQLCipher table + 6 CRUD methods in ContentStore. 20 tests. 83 total vault tests.
- Store protocol (first networking checkpoint): 3 MessageEnvelope variants (ShardStore, ShardChunk, ShardStoreAck) inside Olm encryption. `NodeCommand::StoreShardOnPeer` with inline/chunked send logic (≤256KB inline, >256KB chunked via CHUNK_SIZE). Receive handlers: server membership verification, pledge capacity check, ContentStore storage, ShardStoreAck encrypted back to sender. `PendingShardAssembly` for chunked shard reassembly. 3 NetworkEvent variants (ShardStored, ShardStoreAckReceived, ShardStoreFailed) mirrored in api/network.rs. Store coordinator with retry/backoff deferred to upload pipeline.
- Storage tier configuration: `parse_retention_days()`/`retention_for_tier()` in adaptive.rs (defaults: files=365d, voice=90d). `ShardDelete` MessageEnvelope + receive handler (MANAGE_SERVER permission-gated). `NodeCommand::DeleteVaultContent` + handler (permission check, delete local shards+placements, broadcast to members). `delete_vault_content()` FFI. `ShardDeleted` NetworkEvent. 5 new tests, 88 total vault tests.
- Retrieve protocol: 5 MessageEnvelope variants (ShardRequest, ShardResponse, ShardResponseChunk, ShardProbe, ShardProbeResponse) Olm-encrypted. ShardRequest receive handler: membership check, ContentStore lookup, inline/chunked response. ShardResponse receive handler: inline→emit ShardReceived, chunked→PendingShardAssembly, not-found→ShardRequestFailed. ShardProbe handler: list_content_shards→respond with shard indices. `NodeCommand::RequestShardFromPeer` + send handler. 2 NetworkEvent variants (ShardReceived, ShardRequestFailed) mirrored in FFI. Retrieval coordinator deferred to download pipeline.
- File upload pipeline (`vault/pipeline.rs`): VaultManifest struct, AES-256-GCM encrypt/decrypt (`aes-gcm` 0.10), `prepare_upload()` orchestrator (erasure mode + replication mode), UploadPlan struct, `mime_from_ext()`. `vault_manifests` SQLCipher table + 6 CRUD methods in ContentStore. `NodeCommand::VaultUploadFile` + handler (prepare_upload → store local shards → send remote via StoreShardOnPeer → broadcast VaultManifestBroadcast to members). `MessageEnvelope::VaultManifestBroadcast` + receive handler (save manifest to ContentStore). `vault_upload_file()` FFI (AES encrypt + content_id precomputed in FFI thread, returns content_id immediately). 3 NetworkEvent variants (VaultUploadProgress/Complete/Failed) mirrored in FFI. 20 new tests (13 pipeline + 7 manifest DB).
- File download pipeline: `reconstruct_file(manifest, packed_shards)` in pipeline.rs — erasure decode + AES decrypt for both modes. Vault cache (`~/.haven/vault_cache/{content_id}.{ext}`): `check_cache()`, `write_to_cache()`, `cache_path()`, `ext_from_filename()`. `NodeCommand::VaultDownloadFile` + handler (load manifest → check cache → collect local shards → reconstruct if enough → write to cache). `vault_download_file()` FFI (cache-first check, async command dispatch). 3 NetworkEvent variants (VaultDownloadProgress/Complete/Failed) mirrored in FFI. 5 new tests, 113 total vault tests.

**Phase 3.75 — Security Hardening (Mar 16, 2026) — COMPLETE:**
Full security audit of the codebase. 3 critical, 4 high, 6 medium, 8 low vulnerabilities found and fixed. Relay server hardened.
- **Critical:** `ServerDeleteBroadcast`/`MemberKickBroadcast` have no authentication — any peer can delete servers or kick members. CRDT op `author` field not verified against actual sender — peers can forge ops as other users.
- **High:** Unbounded `get_channel_messages()`/`get_messages()` reads (no LIMIT), no rate limiting on incoming messages (DoS vector), `op_log` table grows unbounded (no pruning), file header validation gaps (missing size/name checks before accepting chunks).
- **Medium:** Delete ownership not verified in Rust receive handlers, Ed25519 signature enforcement inconsistent (some paths skip verification), cross-server message injection (server_id not validated on receive), HLC drift not bounded (future timestamps accepted), path traversal possible in file save paths, reaction removal doesn't verify original reactor identity.
- **Low:** No character limit on message content, profile field size limits not enforced in Rust, markdown parser has no recursion depth limit, emoji validation allows arbitrary strings, nickname length unbounded, typing indicator spoofable, channel name length unchecked, search query not sanitized for SQL LIKE wildcards.

**Phase 3.75 — All items COMPLETE:**
- All 3 CRITICAL: `ServerDeleteBroadcast`/`MemberKickBroadcast` permission checks (owner-only verification), CRDT op author verification against actual sender + per-payload permission checks (role-gated ops rejected from unauthorized peers).
- All 4 HIGH: Message size limit (50MB cap on `HavenCodec` frame length), `FileHeader` size validation enforced in both Olm and MLS receive paths (reject if declared size exceeds server max file size setting), per-peer rate limiting (token bucket: 100 burst / 20/sec refill, applied to all incoming messages per peer), `op_log` compaction (capped at 1000 ops, oldest pruned on exceed).
- All 6 MEDIUM: Delete ownership check (Rust verifies sender owns message before applying), signature enforcement (reject messages with invalid Ed25519 signatures instead of logging+continuing), cross-server channel message validation (server_id checked on receive), HLC drift bound (5-minute max future drift, reject outliers), file path sanitization (alphanumeric + dash + underscore + dot only, no path separators), reaction removal already safe (no change needed).
- All 8 LOW: 4K character limit on chat messages (Rust `send_channel_message`/`send_message` reject + Dart UI `maxLength` with counter), profile field truncation (display name 64, status 128, about 512 chars in Rust `handle_profile_update`), markdown parser recursion depth cap (max 10 nesting levels), emoji length validation (max 32 chars, reject non-emoji strings), `height == 0` guard on message hover wrapper (prevents `localToGlobal` crash), event dispatch try-catch (swarm event loop catches panics to prevent crash-on-malformed-event), profile card overlay disposal fix (checks `mounted` before removing overlay entry), `getrandom` expect message improved (descriptive panic message).
- Date separators: "Today", "Yesterday", or full date (e.g., "March 15, 2026") dividers in DM chat, channel chat, and pinned messages popup. Pinned messages sorted chronologically (oldest first).
- `showCounter` param on `HavenTextField` for hiding the character counter on chat input fields.
- Log rotation: `haven_debug.log` now rotates at 10MB (keeps last 2MB, truncates the rest).
- **Relay server hardening (VPS):** SSH key-only auth (password disabled, Ed25519 key + passphrase), Fail2ban installed (sshd jail active), UFW firewall verified (22, 80, 443, 4001 tcp+udp, 8080), signaling server already hardened (Ed25519 sig verification, anti-replay, room caps, stale cleanup), relay systemd resource limits (MemoryMax=1G, CPUQuota=80%, LimitNOFILE=65535). Skipped: change default SSH user (not needed with key-only auth), relay connection rate limiting (libp2p relay already has built-in limits).

Phase 4 plan is fully broken down into 12 major items with ~80 sub-tasks in `HAVEN_PLAN.md`.

**Phase 3.5 completed so far:**
- User profiles: Rust `user_profiles` SQLCipher table, `ProfileUpdate` HavenMessage broadcast, timestamp-gated upsert, auto-exchange on `ConnectionEstablished`, `ProfileNotifier` Dart provider, `displayNameFor()` helper used everywhere (user_bar, member_panel, channel_message_bubble, peer_card, chat_pane)
- User settings dialog: two-column layout (live profile preview card with centered banner/avatar/name/about-me on left, edit fields + dark mode toggle on right), `showHavenDialog` glassmorphism entrance, settings gear icon replaces theme toggle in user bar
- Member panel slide animation: `_MemberPanelSlider` with ClipRect + Align(widthFactor) + FadeTransition (GPU-composited), `ProviderScope` override freezes `selectedServerProvider` during close animation (prevents "No peers online" flash), chat pane crossfade via single AnimatedSwitcher
- Server nicknames: CRDT-based per-server nicknames (`NicknameChanged` payload, `AdminLwwReg<String>` in `ServerState.nicknames`), `set_nickname()` FFI, `serverDisplayNameFor()` (nickname → profile name → short peer ID), `serverNicknamesProvider` derived from members. Overview tab restructured: "SERVER SETTINGS" (admin+) above "YOUR IDENTITY" (all members). Name resolution: server context uses nickname, DM context uses display name only.
- Profile card popup: reusable overlay (`profile_card_popup.dart`), scale+fade entrance animation, centered layout matching settings preview style. Banner, avatar, nickname/name, role badge, status (italic), about me, peer ID footer (copy on tap). User bar → card above, member panel → card to the left (Discord-style). "Edit Profile" button for self.

- Message editing: Full pipeline — Rust storage (`message_id`, `edited_at`, `message_edits` evidence table), wire protocol (`EditMessage` envelope, `mid` field on all message types), command/receive handlers for both MLS and Olm paths, FFI `edit_channel_message()`/`edit_dm_message()`, Dart models with `messageId`/`editedAt`/`copyWith()`, provider `editMessage()`/`applyEdit()` methods.
- Message IDs: Generated in Dart (`generateMessageId()` in `chat_provider.dart`, Random.secure 32-char hex), passed to Rust via FFI. Both `MessageReceived`/`ChannelMessageReceived` events include `message_id`. Messages editable immediately after send.
- Hover action bar: Overlay-based system (`message_action_bar.dart`). `MessageActionBarScope` + `MessageActionBarController` ensure one active bar at a time. `MessageHoverWrapper` uses `RenderBox.localToGlobal` + `OverlayEntry` with `Positioned` (same pattern as profile_card_popup). Highlight overlay (3% white, IgnorePointer) + action bar (edit pencil). 60ms dismiss timer for message↔bar mouse travel. Teal right border stays in bubble widgets permanently. Group spacing padding lives outside the hover wrapper in ListView builders for exact alignment.
- Multi-peer fan-out sync: `SyncCoordinator` in swarm.rs collects connected peers for 500ms, assigns channels round-robin across ALL peers (primary + backup). Lightweight `ChannelSyncProbe`/`ChannelSyncProbeResponse` wire messages compare timestamps before full sync — channels with no new data are skipped entirely. Equal load distribution: more peers = lighter per-peer load. On-demand `RequestChannelSync` still fans out to all peers for immediacy. CRDT state sync and DM sync unchanged.
- Message deletion (hiding): Rat Files philosophy — messages never truly deleted, just hidden from UI. `hidden_at` column on messages/channel_messages, `message_deletions` evidence table. `DeleteMessage` envelope broadcast via MLS/Olm. UI queries filter `WHERE hidden_at IS NULL`; sync queries include hidden messages so all peers get full evidence in their DBs. Hover action bar shows trash icon (red) next to edit pencil for own messages. FFI: `delete_channel_message()`/`delete_dm_message()`. Dart `applyDelete()` removes from in-memory list entirely.
- Reply chains: Full pipeline — `reply_to_mid` column on messages/channel_messages, `reply_to` field on wire protocol (DirectMessage, ChannelMessage, SyncMessageItem, DmSyncItem), all send/receive/sync handlers thread reply_to through. FFI: `send_message()`/`send_channel_message()` accept `reply_to_mid`. Dart models have `replyToMid`, providers pass it through. UI: reply button (LucideIcons.reply) on ALL messages in hover action bar, reply preview bar above input (accent left border, sender name, truncated text, X dismiss), reply context display on messages (thin vertical bar + sender name + quoted text above message content). Both DM and channel paths fully wired.
- Edit permission fix: `onEditStart` now requires `msg.isMe` (was missing, letting anyone edit anyone's messages). Rust receive handlers verify ownership before applying edits — `get_channel_message_sender()` for channels, `get_dm_message_is_mine()` for DMs. Rejects unauthorized edits with log.
- Emoji reactions: Full pipeline — Rust storage (`message_reactions` + `reaction_removals` Rat Files tables), wire protocol (`AddReaction`/`RemoveReaction` envelopes), command/receive handlers for both MLS and Olm paths, FFI `add_channel_reaction()`/`remove_channel_reaction()`/`add_dm_reaction()`/`remove_dm_reaction()`, Dart models with `reactions: Map<String, List<String>>`, provider `addReaction()`/`removeReaction()`/`applyAddReaction()`/`applyRemoveReaction()` methods. UI: curated 30-emoji picker (`emoji_picker.dart`) via smiley button in hover action bar, reaction pills (`reaction_bar.dart`) below messages sorted by count descending, tapping toggles own reaction. Self-react allowed. 3 distinct emoji limit per user per message (enforced in both Dart providers and Rust `add_reaction()`). Reactions JOIN-loaded with messages from DB. Both DM and channel paths fully wired.
- Typing indicators: Ephemeral fire-and-forget — no storage, no encryption, no CRDTs. Rust: `HavenMessage::TypingIndicator` (plaintext, like ProfileUpdate), `SendTypingIndicator` command, `TypingStarted` event. Channels broadcast to server members, DMs to single peer. FFI: `send_typing_indicator()`. Dart: `TypingNotifier` provider with 5s auto-expiry timers per peer per context. 3s throttle on sender side. UI: `TypingIndicatorBar` above input (1-3 names or "Several people are typing..."), `TypingDots` animated bouncing dots. Both DM and channel paths wired. Typing cleared on message receive (no lingering indicator after message arrives).
- Server/DM state management fix: Server strip `onTap` clears `selectedPeerProvider` (hides DM chat on server switch). `lastChannelPerServerProvider` remembers last viewed channel per server. Auto-selects first channel when no prior selection exists. Channel selection saved on click for recall.
- Connection progress bar: `ConnectionProgress` widget (`connection_progress.dart`) with animated 3-stage progress bar — Connecting (33%, gray) → Encrypting (66%, accent) → fills to 100%, fades out, replaced by lock + "Encrypted". Used in both DM headers and channel headers. Channel header: `_ChannelConnectionStatus` replaces static "E2E Encrypted" + old `_ConnectionIndicator`. Checks online members vs encrypted sessions. Sync indicator (Syncing/Synced/Failed) shown alongside after encryption. DM header: watches `peersProvider` directly instead of static `isEncrypted` prop.
- Shader warmup: Added `ImageFilter.blur` pre-compilation for glassmorphism dialog animations (was missing, caused jank on first dialog open).
- Rich text / markdown: Lightweight parser (`message_text_parser.dart`) — **bold**, *italic*, ~~strikethrough~~, `inline code`, ```code blocks```, ||spoilers|| (tap to reveal). Pure Dart, no dependencies. Both DM and channel bubbles use `buildMessageText()`. No HTML, images, or links — secure by design.
- Multiline input: Chat input auto-grows up to 5 lines (`maxLines: 5, minLines: 1`). Enter sends, Shift+Enter inserts newline. `onSubmitted` replaced with `Focus(onKeyEvent:)` wrapper. Inline edit field also multiline with same Enter/Shift+Enter behavior.
- Formatting shortcuts: Ctrl+B (bold), Ctrl+I (italic), Ctrl+E (code), Ctrl+Shift+X (strikethrough), Ctrl+Shift+S (spoiler). Wraps selection or inserts markers at cursor. Shared `handleChatInputKey()` in `chat_input_shortcuts.dart`.
- Avatar alignment fix: 5px top padding on message avatars for proper vertical centering with name/text row.
- Send button hover fix: `HavenPressable` with `backgroundColor` now lightens 15% toward white on hover instead of replacing with dark `elevated` color. Prevents dark-on-dark icon visibility issue.
- Pinned messages: CRDT-based (`MessagePinned`/`MessageUnpinned` ops), `pinned_messages: HashMap<String, Vec<String>>` on ServerState (`#[serde(default)]`). Pin/unpin via NodeCommand, permission-gated (MANAGE_CHANNELS). FFI: `pin_message()`, `unpin_message()`, `get_pinned_messages()`. Dart: `PinnedNotifier` provider, pin button in hover action bar (admin only), pin count + popup in channel header. CrdtOpBroadcast handler emits `MessagePinned`/`MessageUnpinned` events for real-time UI updates on all peers.
- Emoji reaction sync: Reactions now sync on reconnect alongside messages. `SyncReactionItem` struct added to `SyncMessageItem` and `DmSyncItem`. Sync batch builders load reactions from DB, receivers insert them (INSERT OR IGNORE). `reloadReactions()` method on `ChannelChatNotifier` refreshes reactions without triggering sync loop. Fixed infinite sync loop caused by `loadHistory()` always calling `requestChannelSync()`.
- Channel "+" button permission: Only visible to members with MANAGE_CHANNELS permission (Owner, Admin). `canManageChannels` prop threaded through `ChannelSidebar` → `_ServerContent`.
- Channel organization: CRDT-based `ChannelLayoutUpdated` op with `channel_layout: Vec<ChannelLayoutItem>` on ServerState. Three item types: `Category` (collapsible folder), `Channel` (reference), `Separator` (break). Channels tab rewritten with drag-and-drop `ReorderableListView`, tree connectors for nested channels, Save/Discard buttons. Sidebar renders layout with collapsible categories (`AnimatedSize`), separators as dividers. Layout only updates for all members on Save. `channelLayoutProvider` loads from DB. Computed `_dirty` getter compares current vs saved layout. `HavenButton` icon/text alignment fixed (height: 1.0).

**Phase 3.5 completed so far (continued):**
- System tray: minimize to tray on close (configurable toggle, default ON), tray icon appears only when minimized, left-click restores, right-click menu (Show/Quit). `tray_manager` ^0.5.2. `minimizeToTrayProvider` persisted in app_settings.
- Friends system & DM overhaul: `friends` SQLCipher table (peer_id, status, direction, requested_at, updated_at). Wire: `FriendRequest`/`FriendAccept`/`FriendReject`/`FriendRemove` (plaintext). DM room codes via SHA-256 hash for signaling discovery without shared servers. Room codes registered on friend request send, receive, accept, and on startup for all friends. Room system UI removed, replaced with "Add Friend" dialog (paste peer ID). Sidebar shows friends list (online-first sort) with pending section (accept/reject for incoming, clock for outgoing). `PeerCard` has `isOnline` prop. Chat stays open on peer disconnect. `loadHistory` always reloads from DB (removed stale guard). Message ordering uses `ORDER BY id` (insertion order) not timestamp (immune to clock skew).
- Haven logo: custom SVG (H + integrated lock), ICO for Windows app/tray icon.
- Server dialog: two-panel (Join by link/ID on left, Create on right).
- Search: local full-text search over SQLCipher (`LIKE` query). `search_channel_messages()` / `search_dm_messages()` in storage + FFI. Search button in channel header, expandable search bar with live results dropdown (max 20 results, sender name + time + text preview).
- DM sync pagination fix: `get_latest_dm_timestamp()` now filters `is_mine = 0` (received messages only). Previous bug: included sent messages (higher timestamps) causing follow-up sync requests to skip remaining messages. Fixed 200-message cap on DM sync — now correctly paginates through all messages.

- Keyboard shortcuts: Global shortcuts via `HardwareKeyboard.instance.addHandler()` in HavenShell (focus-independent, works even when text fields have focus). Ctrl+, (toggle settings dialog), Ctrl+Shift+M (toggle member panel), Ctrl+K (toggle channel search via `channelSearchOpenProvider`). Chat input shortcuts in `chat_input_shortcuts.dart`: Enter (send), Shift+Enter (newline), Ctrl+B/I/E, Ctrl+Shift+X/S (formatting). All shortcuts listed in Settings > System tab with styled key badges.
- Settings dialog redesign: Left tab rail (Profile, System) + right content area. Profile tab: preview card + edit fields. System tab: Dark Mode, Minimize to Tray, Use Proxy toggles + keyboard shortcuts reference. Fixed height (540px) prevents layout shifts on tab switch. `_settingsDialogOpen` flag makes Ctrl+, a toggle (close if already open, prevents duplicate dialogs).

- Notifications system: `notification_provider.dart` (server-level All/Mentions/Nothing, per-channel override, per-DM toggle), `unread_provider.dart` (last-seen tracking, unread counts, marks seen on navigation + history load), `system_notification_provider.dart` (dual system: in-app overlay when visible+unfocused, native `local_notifier` ^0.1.6 when hidden/tray). UI: red pill badge with count on server strip, accent dots on channel tiles/DM cards, bold text on unread items. Muted sources hide all indicators. Custom overlay (`notification_overlay.dart`): up to 3 stacked mini-chat cards (bottom-right, `AnimatedPositioned` in `Stack`), each accumulates up to 5 messages from same source, slide-in/auto-dismiss/hover-pause/click-navigate. `windowVisibleProvider` tracks tray state — hidden window never counts as "viewing". Server Settings > Notifications tab with server-wide picker + per-channel `PopupMenuButton`. DM header bell icon for per-friend toggle. Single-instance lock (`%APPDATA%/Haven/haven.lock`).

- P2P file sharing: 256KB chunks via Olm encryption (DMs + channels). MLS for text message only (single encrypt), file data via Olm to each member (avoids SecretReuseError). `image` crate for WebP conversion. `files`/`file_chunks` tables, `file_id` on message envelopes. FileHeader/FileChunk/FileRequest wire protocol. Auto-sync: after MessageSyncCompleted, `getMissingFileIds()` finds messages with file_id but no completed file, requests from peers. `NodeCommand::RequestFile` sends `HavenMessage::FileRequest` to remote peer. Max file size CRDT setting (default 34MB) with UI in Server Settings. Image fullscreen overlay, download/save with WebP→PNG/JPEG conversion, `_isPicking` lock, edit disabled on file messages.
- Scrollable positioned list & reply-tap-scroll: Replaced `ListView.builder` with `ScrollablePositionedList.builder` (`scrollable_positioned_list` package) in both DM and channel chat panes. Click reply context to scroll to original message (300ms scroll + 1.5s accent tint fade via `AnimatedContainer`). Sentinel item pattern (`SizedBox.shrink()` at end, `initialScrollIndex` + `initialAlignment: 1.0`) for zero-animation bottom positioning on load. `ScrollOffsetController` for pixel-level new-message scroll, `ItemScrollController` for reply-tap navigation. `_isNearBottom` via `ItemPositionsListener`. Deduplicated reply context lookup. `isHighlighted` + `onReplyTap` props on both bubble widgets.

**Phase 3.5: COMPLETE.** Device linking deferred to Phase 6.

## Haven Design System (Phase 2.75)
All UI interactions go through custom Haven widgets — no Material defaults anywhere. Change behavior in one place, applies everywhere.

- **HavenPressable** (`haven_pressable.dart`): Universal interaction widget. Press: opacity 0.85 + scale 0.98, spring physics reverse. Hover: smooth color transition 150ms + shadow lift. No ripple. `subtle` mode disables press animation (for list items like channel tiles, peer cards).
- **HavenButton** (`haven_button.dart`): 4 variants — `.filled()` (accent bg), `.ghost()` (transparent), `.outline()` (1px border), `.danger()` (error red). Self-contained StatefulWidget with own press/hover animation. Hover glow shadow (20% opacity, 8px blur). Props: `onPressed`, `child`, `icon`, `expand`, `compact`.
- **HavenTextField** (`haven_text_field.dart`): Single `TextField` with `OutlineInputBorder` (no wrapper container). `haven.elevated` fill, border color animates (border→accent on focus, →error on error). Focus glow (teal BoxShadow 15% opacity, 6px blur). Error shake animation. Optional `prefixIcon`, `borderRadius`, `isDense`.
- **HavenDialog** (`haven_dialog.dart`): `showHavenDialog()` uses `showGeneralDialog` with scale 0.95→1.0 + fade entrance (200ms). Full-screen glassmorphism: `BackdropFilter` in `transitionBuilder` blurs entire screen (animated 0→12 sigma). Barrier: 8% black. Dialog bg: 92% opacity, accent border, 24px shadow.
- **HavenTooltip** (`haven_tooltip.dart`): Overlay-based, 400ms hover delay, 100ms fade+slide entrance. Dark style.
- **HavenToast** (`haven_toast.dart`): Slide-up + fade, auto-dismiss. Three types: success/error/info. Only one visible at a time. Replaces SnackBar. Controller disposed only by widget's `dispose()` (prevents double-dispose).
- **HavenToggle** (`haven_toggle.dart`): Spring physics thumb, color crossfade track.
- **StatusDot** (`status_dot.dart`): StatefulWidget with optional `pulse` for breathing glow animation (3s cycle, BoxShadow). Used in peer cards, member tiles, user bar.

## Key Architecture Notes
- **Peer state tracking in swarm.rs:** `connected_peers`, `expected_peers`, `disconnected_peers` HashSets. Bootstrap handler skips disconnected + connected peers. `InboundCircuitEstablished` clears disconnected. `ConnectionEstablished` triggers proactive DHT prekey fetch for auto-encryption. Ping: 5s/5s. Rebootstrap: 60s unconditional.
- **Event streaming:** Rust→Dart via `StreamSink` (flutter_rust_bridge), not polling. `watch_network_events()` in `api/network.rs`, `EventStreamNotifier` in `event_provider.dart`
- **Navigation shell:** Discord-like 4-panel layout — ServerStrip (72px) | ChannelSidebar (240px) | ChatPane | MemberPanel (240px). Responsive: mobile uses bottom nav with single-panel views.
- **Window chrome:** `window_manager` ^0.5.1, `setAsFrameless()`, custom 32px title bar (`window_title_bar.dart`). Native Win32 changes in `windows/runner/` for dark bg brush, DWM compositing, no-flicker resize. Known issue: drag-from-maximized doesn't live-redraw until drop (Flutter engine limitation).
- **Theme:** Dark primary (default) + light secondary. `HavenTheme.dark()`/`.light()` ThemeExtension, `HavenThemeData.dark()`/`.light()` factories. Toggle via `themeModeProvider` (Riverpod StateProvider). No persistence yet (Phase 3). Frutiger Aero theme deferred as future third option.
- **Icons:** `lucide_icons: ^0.257.0`. All `LucideIcons.*` (camelCase). Note: v0.257.0 uses `alertTriangle`/`alertCircle` (not `triangleAlert`/`circleAlert`). No `cloudCheck` — uses `cloud`.
- `haven_log!` macro (`#[macro_export]` in lib.rs) logs to stderr + `haven_debug.log` (works in release builds)
- Relay: OVH VPS 141.227.186.209, Nginx TLS termination on 443 → plain WS on 127.0.0.1:9001
- Domain: relay.anonlisten.com (Hostinger DNS, Let's Encrypt cert)
- Connection priority: LAN (mDNS) → Hole punch (DCUtR) → QUIC relay → TCP relay → WSS relay
- libp2p SwarmBuilder chain: with_tcp → with_quic → with_dns → with_websocket → with_relay_client → with_behaviour

## Coding Conventions
- Dart: follow standard `flutter_lints` / `analysis_options.yaml`
- Rust: follow standard `cargo clippy` recommendations
- File naming: snake_case for Dart and Rust files
- No Electron, no Node.js, no web frameworks — Flutter only for UI
- **NEVER pass `WidgetRef ref` as a constructor parameter** to child widgets. Always use `ConsumerWidget` or `ConsumerStatefulWidget` instead. Passing `ref` causes cascade rebuilds (parent rebuilds ALL children on every provider change).
- Use `AnimatedOpacity` (GPU-composited) for per-item opacity. Never use the `Opacity` widget.
- **Keep Flutter updated:** Windows animation jank (choppy at all refresh rates) was caused by a Flutter engine bug present in 3.38.5, fixed in 3.41.4. No app-side hacks needed — just `flutter upgrade`. `windows/runner/main.cpp` is stock (no timer hacks).
- **CRITICAL — Backward-compatible DB schema:** ALWAYS add `#[serde(default)]` to ANY new field added to a persisted Rust struct (e.g., `ServerState`, any struct stored as JSON in SQLCipher). Without it, old data lacking the new field will fail to deserialize and silently disappear (servers vanish, data lost). This applies to ALL `#[derive(Serialize, Deserialize)]` structs that touch the DB.

## Rules
- Never commit secrets, keys, or credentials
- Rust handles: networking (libp2p), crypto, CRDTs, storage engine
- Dart handles: UI, app logic, state management
- All crypto operations must use constant-time implementations
- Ask before making architectural decisions not covered in HAVEN_PLAN.md
- When updating memory (MEMORY.md), also update this file (CLAUDE.md) if relevant
- **VPS deployment:** Ask user — requires SSH password, never store credentials. User deploys themselves.
- **Local dev commands:** Can run `cargo check/test/clippy`, `flutter_rust_bridge_codegen generate`, `flutter analyze` freely — these are local-only operations.
- **Building/running the app:** User runs `flutter run -d windows` themselves for testing on their two laptops.
