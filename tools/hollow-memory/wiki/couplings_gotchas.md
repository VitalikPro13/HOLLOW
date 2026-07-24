# Couplings and Gotchas -- What Breaks When

Comprehensive reference of every known non-obvious coupling, critical rule, and hidden dependency in the HOLLOW project. Organized by subsystem. For each entry: the rule, why it exists (what breaks), where it applies, and the correct approach.

---

## Provider Atomicity and Invalidation Chains

### Server switching must batch four provider writes atomically

**Rule:** When switching servers, `channelListProvider`, `channelLayoutProvider`, `selectedServerProvider`, and `selectedChannelProvider` must all update in a single synchronous block.

**Why:** These four providers have downstream watchers (`visibleChannelsProvider`, `canPostInChannelProvider`, the chat pane, the channel sidebar). If written across multiple frames, intermediate rebuilds see inconsistent state -- for example, old channels with the new server ID, or the old channel selected while the new channel list is already loaded. This causes flash-of-wrong-content, null errors in chat pane, and broken sidebar filtering.

**Where:** Canonical implementation is in `lib/src/ui/shell/server_strip.dart:_selectServer`. Any code that triggers a server switch must follow this exact pattern.

**Correct approach:**
1. Prefetch channels and layout via static methods (async, before touching state): `ChannelListNotifier.fetchChannels(serverId)` and `ChannelLayoutNotifier.fetchLayout(serverId)`.
2. Batch write all four providers synchronously in one frame:
   ```dart
   ref.read(channelListProvider.notifier).setChannels(channels);
   ref.read(channelLayoutProvider.notifier).setLayout(layout);
   ref.read(selectedServerProvider.notifier).state = serverId;
   ref.read(selectedChannelProvider.notifier).state = channelId;
   ```
3. Channel selection: check `lastChannelPerServerProvider` for remembered channel; fall back to `firstTextChannelInLayout()`.

### ServerUpdated must trigger correct provider invalidation

**Rule:** The Dart event handler for `NetworkEvent::ServerUpdated` must invalidate `myPermissionsProvider(serverId)`, `myRoleProvider(serverId)`, and `serverMembersProvider(serverId)`. This is the ONLY event that invalidates these three providers for general CRDT changes.

**Why:** These are `FutureProvider.family` instances that cache their result until explicitly invalidated. If `ServerUpdated` is not emitted (e.g., a new CRDT variant falls into the `_ =>` wildcard on the Rust side, which emits `SyncCompleted` instead), the Dart side never re-fetches permissions/roles/members. The UI shows stale data: wrong permission state, outdated member list, incorrect role badges.

**Where:** `lib/src/core/providers/event_provider.dart` -- the `_dispatch()` method's `ServerUpdated` case. On the Rust side: `sync_handler.rs:handle_envelope_crdt_op()` and `swarm.rs:handle_incoming_request()`.

**Correct approach:** See the CRDT section below for the Rust-side requirement. On the Dart side, ensure the `ServerUpdated` handler always calls `ref.invalidate()` on all three family providers for the affected server ID.

### Never pass WidgetRef ref as a constructor parameter

**Rule:** Child widgets must never receive `WidgetRef ref` through their constructor. Use `ConsumerWidget` or `ConsumerStatefulWidget` instead.

**Why:** Passing `ref` as a constructor parameter makes the child rebuild every time the parent rebuilds, regardless of whether the child's own providers changed. This creates cascade rebuilds that destroy performance -- every parent rebuild propagates to all children that hold the ref parameter.

**Where:** All widget classes in `lib/src/ui/`. No exceptions.

**Correct approach:** Extend `ConsumerWidget` or `ConsumerStatefulWidget` to get a local `ref` in `build()` or `build(context, ref)`.

---

## MLS Gotchas

### Epoch staleness after reconnection

**Rule:** Any message that MUST work immediately after WS reconnection must use plaintext `HavenMessage` (not MLS `MessageEnvelope`).

**Why:** After a WebSocket disconnect/reconnect, the local MLS group state may be stale (behind by one or more epochs). MLS-encrypted messages fail to decrypt until the local node processes the pending commits from missed epochs. Messages that need to work immediately -- sync requests, shard coordination, voice channel state changes -- would silently fail or be rejected if sent via MLS.

**Where:** Applies to these message types:
- `HavenMessage::ChannelSyncRequest` -- must always be plaintext
- `HavenMessage::CrdtOpBroadcast` -- certain handlers use plaintext broadcast intentionally: `handle_change_role()`, `handle_set_nickname()`, `handle_set_twitch_username()`, `handle_set_storage_pledge()`, `handle_update_channel_layout()`, `handle_pin_message()`, `handle_unpin_message()`
- Voice channel join/leave/state messages
- Shard coordination messages

**Correct approach:** Use `HavenMessage` (plaintext, Olm-encrypted per peer or sent via WS relay) for anything that must succeed on first attempt after reconnection. Reserve `MessageEnvelope` (MLS-encrypted) for messages where delivery can tolerate a brief delay while MLS state catches up.

### MLS coordinator election is deterministic

**Rule:** `is_mls_coordinator()` in `crypto_handler.rs` elects the coordinator as the peer with the lowest `peer_id` string (lexicographic) among all online peers in the MLS group.

**Why:** The coordinator is responsible for adding new members to the MLS group (processing KeyPackages, creating commits). All peers must agree on who the coordinator is without communication, so the algorithm must be deterministic and based only on information all peers share (the set of online peers).

**Where:** `rust/hollow_core/src/node/crypto_handler.rs:is_mls_coordinator()`. Called from `swarm.rs` when processing `ServerJoinRequest` and MLS key package handling.

**Correct approach:** Never change the coordinator election algorithm without ensuring all peers converge on the same result. The "lowest peer_id" rule is simple and deterministic. When adding new coordinator responsibilities, verify they are idempotent (safe if multiple peers mistakenly believe they are coordinator during a race).

### MLS decrypt failure recovery

**Rule:** After 3 consecutive MLS decrypt failures for a server, recovery is triggered: drop the broken MLS group, send a fresh KeyPackage to the coordinator (lowest online CRDT member). Recovery skips if local peer is no longer a server member (banned/removed).

**Where:** `swarm.rs` -- `mls_decrypt_failures` HashMap tracks per-server consecutive failure count. Incremented on each decrypt error, reset on any successful decrypt.

**Why:** MLS state can become permanently desynchronized if a commit is missed (network partition, relay outage). Without recovery, the node would permanently lose the ability to decrypt messages for that server.

### Server rejoin drops stale MLS group

**Rule:** When a server join completes (`pending_server_joins.remove`), any existing MLS group for that server is dropped and a fresh KeyPackage is sent to the coordinator.

**Why:** After ban/unban cycles, the rejoining peer retains a stale MLS group from before the ban. Messages encrypted with the old epoch cause `TooDistantInThePast` or `WrongEpoch` errors on other peers. The coordinator also rejects recovery KeyPackages because `is_mls_coordinator()` disagrees between stale and current group state.

**Where:** `swarm.rs` -- in the `pending_server_joins.remove()` block, before WS room join. Also: post-join KeyPackage now targets coordinator (lowest online CRDT member), not owner.

### KeyPackage membership check (L6)

**Rule:** `MlsKeyPackage` handler rejects KeyPackages from peers not in the server's CRDT member list. Logged as `[HOLLOW-SECURITY] REJECTED`.

**Why:** Prevents unauthorized peers from joining the MLS group by sending a valid KeyPackage without being a CRDT member first.

---

## CRDT Gotchas

### New CrdtPayload variants must emit ServerUpdated in BOTH match blocks

**Rule:** In `sync_handler.rs:handle_envelope_crdt_op()` and `swarm.rs:handle_incoming_request()`, new CrdtPayload variants that affect permissions, channels, labels, bans, or any server state visible in the UI MUST be explicitly listed in the match arms that emit `NetworkEvent::ServerUpdated`. They must NOT fall into the `_ =>` wildcard.

**Why:** The `_ =>` wildcard emits `NetworkEvent::SyncCompleted` (in the MLS path) or nothing useful. `SyncCompleted` does NOT trigger Dart-side provider invalidation for `myPermissionsProvider`, `myRoleProvider`, or `serverMembersProvider`. If a new variant falls into the wildcard, the UI never updates -- roles stay stale, permissions are wrong, member lists are outdated, labels do not appear.

**Where:**
- `rust/hollow_core/src/node/sync_handler.rs:handle_envelope_crdt_op()` -- the match on `op.payload` near the event emission section
- `rust/hollow_core/src/node/swarm.rs:handle_incoming_request()` -- the match on incoming CRDT op payloads in the plaintext path

**Correct approach:** When adding a new `CrdtPayload` variant:
1. Add an explicit match arm in `handle_envelope_crdt_op()` that emits `NetworkEvent::ServerUpdated { server_id }`.
2. Add an explicit match arm in `handle_incoming_request()` (swarm.rs plaintext CRDT handler) that also emits `ServerUpdated`.
3. Verify in the Dart `_dispatch()` method that `ServerUpdated` invalidates the relevant providers.

Current variants that correctly emit `ServerUpdated`: `ServerSettingChanged`, `ServerRenamed`, `RolePermissionsChanged`, `MemberBanned`, `MemberUnbanned`, `ChannelVisibilityChanged`, `ChannelPostingChanged`, `ChannelPublicChanged`, all Label variants (`LabelCreated`, `LabelDeleted`, `LabelUpdated`, `LabelAssigned`, `LabelUnassigned`).

### Channel property changes require optimistic UI updates

**Rule:** Channel property changes (visibility, posting, is_public) must apply optimistic updates via `channelListProvider.updateChannel()` BEFORE the FFI call, not after.

**Why:** CrdtStore is a fire-and-forget actor that batches writes via mpsc. When the `ServerUpdated` event fires (triggered by the CRDT broadcast), the DB write may not be flushed yet. The `_refreshServerState()` handler in `event_provider.dart` calls `loadForServer()` which reads from the DB -- if the write hasn't landed, it reads stale data and the UI reverts briefly. The 50ms delay on `loadForServer` in `_refreshServerState()` mitigates this but optimistic update is the primary fix.

**Where:** `lib/src/ui/settings/channels_tab.dart` -- `_ChannelRow` visibility/posting `_AccessChip` and the globe (is_public) toggle. Mobile twin (2026-06-21): `mobile_server_settings_route.dart` `_ChannelLayoutEditor` ChannelItem row -- `_MobileAccessChip` (visibility eye + posting message-square popups, shown only for private/non-public text channels) + the globe toggle. Also `event_provider.dart:_refreshServerState()`.

**Correct approach:** Call `channelListProvider.updateChannel()` with the new property value immediately, then fire the FFI call. The 50ms delay in `_refreshServerState` lets CrdtStore flush before the server-state reload.

### serde(default) is mandatory on all new persisted fields

**Rule:** ALWAYS add `#[serde(default)]` to ANY new field added to `ServerState` or any struct stored as JSON in SQLCipher.

**Why:** Existing data in the database was serialized without the new field. Without `#[serde(default)]`, deserialization fails with a missing-field error. The failure is silent from the user's perspective -- servers simply vanish from the UI because the entire `ServerState` fails to load.

**Where:** `rust/hollow_core/src/crdt/server_state.rs:ServerState` and any nested struct that gets serialized to the `server_states` or `app_settings` SQLCipher tables.

**Correct approach:** Every new field on a persisted struct gets `#[serde(default)]`. Use appropriate default values (empty HashMap, empty Vec, false, 0, None). Test by verifying that a DB created before the change still loads correctly after the change.

Fields that already have `#[serde(default)]` in ServerState: `nicknames`, `twitch_usernames`, `pinned_messages`, `channel_layout`, `storage_pledges`, `settings` (actually required), `role_permissions`, `banned_members`, `labels`, `label_assignments`. Also `ChannelInfo.is_public` has `#[serde(default)]` (defaults to `false` = private/MLS-encrypted).

---

## WebRTC Gotchas

### Never use replaceTrack on Windows

**Rule:** ALWAYS use `pc.addTrack(track, stream)` / `pc.removeTrack(sender)` for all media changes. NEVER use `sender.replaceTrack(newTrack)`.

**Why:** On Windows, `replaceTrack` silently fails in libwebrtc -- the receiver's renderer stays bound to a stale muted track. The `onTrack` callback does not fire on the remote peer because the transceiver is reused. This means the remote peer never renders the new video/audio.

**Where:**
- `lib/src/core/services/voice_channel_service.dart` -- `startCamera()`, `stopCamera()`, `_addLocalVideoTracks()`
- `lib/src/core/services/voice_service.dart` -- `toggleVideo()`
- Any code that adds/removes media tracks on an existing RTCPeerConnection

**Correct approach:** To add media: `pc.addTrack(track, stream)` followed by a renegotiation offer. To remove media: find the sender via `pc.getSenders()`, call `pc.removeTrack(sender)`, then renegotiate. This creates fresh transceivers which reliably fires `onTrack` on the remote peer.

### Data channel buffer overflow kills the connection

**Rule:** Maximum 4 in-flight chunks (~256 KB) on a WebRTC data channel. The SCTP buffer limit is ~16 MB; exceeding it kills the data channel silently.

**Why:** WebRTC data channels use SCTP transport with a finite send buffer. If the application writes faster than the network drains, the buffer fills up. Once the ~16 MB buffer limit is exceeded, the data channel becomes unusable -- it silently drops data or closes the connection.

**Where:** `lib/src/core/services/webrtc_service.dart` -- `sendFile()` method. Constants: `_kChunkSize = 64 KB`, `_kMaxBufferedAmount = 256 KB`.

**Correct approach:** After each `dc.send()`, check `dc.getBufferedAmount()`. While the buffer exceeds `_kMaxBufferedAmount` (256 KB), wait 1ms and re-check. This backpressure loop keeps approximately 4 chunks in flight at most, well below the 16 MB catastrophic limit.

### Always await WebRTC resource disposal

**Rule:** `RTCVideoRenderer.dispose()`, `RTCPeerConnection.close()`/`.dispose()`, and `MediaStream.dispose()` are async and MUST be awaited.

**Why:** Unawaited disposal calls leak native resources. Measured at ~200 MB per session of leaked GPU textures, native buffers, and system handles. Over time this causes out-of-memory crashes, especially during voice channel sessions where peers join and leave frequently.

**Where:** Every `dispose()`, `close()`, or `stop()` call in:
- `lib/src/core/services/voice_channel_service.dart` -- `closePeer()`, `closeAll()`
- `lib/src/core/services/voice_service.dart` -- `endCall()`, `toggleVideo()`
- `lib/src/core/services/screen_share_service.dart` -- `close()`
- `lib/src/core/services/webrtc_service.dart` -- `_cleanupConnection()`

**Correct approach:** Always `await` every dispose/close/stop call. When disposing multiple resources, await each individually. Exception: in `closeAll()` where many peers are cleaned up, use `Future.wait()` or sequential awaits.

### TURN ICE config must split URIs into separate entries

**Rule:** Each TURN URI must be its own `IceServer` entry in the ICE configuration. Never pass multiple URIs in a single entry's `urls` array.

**Why:** flutter_webrtc's native `CreateIceServers` implementation has a single `uri` field per `IceServer` struct (not `urls` plural). If you pass multiple URIs in a single entry, only the first is used. This silently drops TURN-over-TCP or TURN-over-TLS fallback URIs, causing connectivity failures for users behind strict firewalls.

**Where:** `lib/src/core/services/ice_config_provider.dart` -- where TURN credentials from the relay are mapped to the ICE configuration passed to `createPeerConnection()`.

**Correct approach:** Map each URI to its own entry:
```dart
final iceServers = turnUris.map((uri) => {
  'urls': [uri],
  'username': username,
  'credential': credential,
}).toList();
```

### flutter_webrtc device selection uses sourceId, not deviceId

**Rule:** For ALL input device selection (audio AND video), use `sourceId` in the optional constraints array. The `deviceId` constraint key is silently ignored by flutter_webrtc native.

**Why:** The native flutter_webrtc implementation on desktop reads `optional[].sourceId` for device selection. The `deviceId` key (which is standard in the WebRTC spec for browsers) is not mapped in the native code. Using `deviceId` silently falls back to the system default device.

**Where:** Every `navigator.mediaDevices.getUserMedia()` call:
- `voice_channel_service.dart:startAudio()` -- microphone capture
- `voice_channel_service.dart:startCamera()` -- camera capture
- `voice_service.dart:_startLocalAudio()` -- DM call mic
- `voice_service.dart:_startCamera()` / `toggleVideo()` -- DM call camera

**Correct approach:**
```dart
{'audio': {'optional': [{'sourceId': deviceId}]}}
{'video': {'optional': [{'sourceId': deviceId}], 'width': 640, 'height': 480}}
```

### Share WebRTC reconnection: receiver-initiates, sender-catches

**Rule:** For Share (file sharing) WebRTC connections, the downloader (receiver) drives reconnection. The seeder (sender) only accepts incoming offers passively.

**Why:** Without a single reconnection driver, both peers could attempt reconnection simultaneously, causing glare (duplicate offers). The `connectToPeer` call has a 10-second stale-offer timeout specifically to prevent dead connections from blocking all future attempts. If the seeder drove reconnection, it would need to track download state it does not own.

**Where:**
- Receiver side: Share tick's `ShareNeedWebRtc` signal in `share_handler.rs`
- Sender side: `swarm.rs` accepts incoming SDP offers from Share peers
- `lib/src/core/services/webrtc_service.dart:connectToPeer()` -- 10s timeout

**Correct approach:** Receiver requests reconnection via `ShareNeedWebRtc`. Sender passively accepts offers. `forget_peer` in Share state keeps `peer_have` intact (which peers have which chunks) but clears `inflight` (active transfers). This lets reconnection resume from where it left off without re-discovering chunk availability.

### Forked flutter_webrtc: WASAPI audio track must NOT attach to returned stream

**Rule:** When using `getDisplayMedia({audio: true})` on the forked flutter_webrtc (Windows), the WASAPI loopback audio track must NOT be attached to the returned MediaStream at the native C++ level. Dart adds it via `pc.addTrack(audioTrack, stream)` on the screen-share PC.

**Why:** Calling `stream->AddTrack(audioTrack)` at the native level crashes libwebrtc's sender iteration. The crash is inside libwebrtc's internal transceiver management when it tries to enumerate senders after the track is added natively to the stream.

**Where:**
- Native C++: `../flutter-webrtc-1.4.1/` -- the WASAPI loopback capture in `getDisplayMedia`
- Dart: `lib/src/core/services/screen_share_service.dart:createOffer()` -- adds audio tracks via `pc.addTrack()` after video

**Correct approach:** At the C++ level, capture the WASAPI audio but return it as a separate track (not added to the stream). In Dart, iterate `getDisplayMedia` result's audio tracks and add each individually via `pc.addTrack(audioTrack, stream)`.

### Forked flutter_webrtc: rebuild cache invalidation

**Rule:** When iterating on the forked `flutter_webrtc` native C++ code, delete `build/windows/x64/plugins/flutter_webrtc/` before rebuilding. Always build `--release` if testing from the Release folder.

**Why:** CMake's incremental build does not always detect changes in plugin native code. The stale cached `.obj` files cause the old code to be linked. Debug and Release builds use different DLL paths -- running debug DLLs from the Release folder or vice versa causes silent wrong-code execution.

**Where:** Build system: `build/windows/x64/plugins/flutter_webrtc/` cache directory. Build command: `flutter build windows --release`.

---

## File Transfer Gotchas

### Share-backed files (>34 MB) bypass size checks in THREE places

**Rule:** `FileHeader.share_ref` must bypass size validation and `PendingFileStream` registration in exactly three code locations.

**Why:** Files larger than 34 MB use a hidden Share for delivery instead of the normal WSS/WebRTC binary stream. The Share system handles chunking, encryption, and multi-peer distribution independently. If the size check is not bypassed, the sender cannot send the file. If `PendingFileStream` is registered, the system waits forever for binary stream data that will never arrive (Share delivers it through a completely different path).

**Where (all three bypass points):**

| # | File | What is bypassed |
|---|------|-----------------|
| 1 | `rust/hollow_core/src/node/file_handler.rs:handle_send_file()` ~line 83 | Sender-side size limit: `if share_ref.is_none() && file_data.len() > max_size` |
| 2 | `rust/hollow_core/src/node/file_handler.rs:handle_envelope_file_header()` ~line 978 | Receiver-side MLS path: size check + PendingFileStream registration |
| 3 | `swarm.rs` DM FileHeader handler ~line 3451 | Receiver-side Olm/DM path: size check + PendingFileStream registration |

Additionally, `handle_send_file()` skips writing ciphertext to temp file and skips all binary streaming when `share_ref.is_some()`.

**Correct approach:** Guard each of the three locations with `if share_ref.is_none()` before the size check and before registering `PendingFileStream`. When adding new file transfer features, verify they handle `share_ref.is_some()` as a special case (no binary stream, no chunk tracking, Share handles everything).

### Auto-download of share-backed files requires two-step activation

**Rule:** Auto-download of share-backed files follows `ShareOpenLink` -> `ShareManifestReady` -> `ShareStart`. It cannot be a single step.

**Why:** The Share system needs to first join the swarm, discover peers, and download the manifest before it can begin the actual file download. The Dart event handler bridges `ShareProgress`/`ShareCompleted` events to `fileTransferProvider` via the `_shareToFileId` map so that file cards in the chat UI show download progress.

**Where:**
- `lib/src/core/providers/event_provider.dart:_dispatch()` -- `_pendingAutoDownloads` map and `_shareToFileId` map
- `FileHeaderReceived` event handler triggers `ShareOpenLink` for share-backed files
- Share events bridge to file transfer provider

**Correct approach:** On `FileHeaderReceived` with `share_ref`: call `ShareOpenLink` with the root hash and key. When `ShareManifestReady` fires, call `ShareStart`. Bridge progress via `_shareToFileId[rootHash] = fileId`.

### Sender-side FileCompleted emit is required

**Rule:** Any new field added to `FileHeader`/`StoredFile` will be missing from the sender's UI unless the send path also emits `NetworkEvent::FileCompleted`.

**Why:** The sender's UI initially displays an optimistic `FileAttachment` built by Dart's `addFileMessage`. This optimistic attachment may have wrong dimensions, no video thumbnail reference, or missing metadata. The `FileCompleted` event tells Dart to reload the file metadata from the database (where the real values were persisted during the send). Without this event on the sender side, the optimistic data persists in the UI.

**Where:** `rust/hollow_core/src/node/file_handler.rs:handle_send_file()` -- step 9 in the flow. The emit occurs when `store_full_file` is true (DMs, small servers, images).

**Correct approach:** When `store_full_file` is true in `handle_send_file()`, always emit `NetworkEvent::FileCompleted { file_id, file_name, ext, width, height, ... }` after persisting file metadata. The Dart `FileCompleted` handler updates the file attachment in the chat provider.

### Early arrival race condition: WebRTC bytes before FileHeader

**Rule:** WebRTC binary data can arrive before the MLS-encrypted FileHeader. The system must handle this out-of-order arrival.

**Why:** WebRTC data channel transfer starts immediately when the connection is established. MLS decryption is slower than data channel delivery. If the system discards early-arriving bytes, the file transfer fails silently.

**Where:**
- `swarm.rs` -- `early_file_streams: HashMap<String, (PathBuf, u64, String)>` state variable
- `file_handler.rs:handle_completed_stream()` -- stores in `early_file_streams` when no `PendingFileStream` exists
- `file_handler.rs:handle_envelope_file_header()` -- checks for early arrivals after registering `PendingFileStream`
- `swarm.rs` DM FileHeader handler -- same early arrival check

---

## Message Signing Gotchas

### Canonical signing payload must be used at ALL signing sites (v2 since 0.8.3)

**Rule:** All message signing MUST go through `crypto_handler::sign_message_versioned(..., &SignedExtras, text)` and all verification through `verify_message_signature_v2` / `check_backfill_signature` (verify-both: v2 `hollow-msg2:{type}:{context}:{sender}:{ts}:{mid}:{reply_to}:{file_id}:{order_us}:{lp_digest}:{text}` first, legacy v1 `hollow-msg:{type}:{context}:{sender}:{ts}:{text}` fallback). Never sign or verify v1-only.

**Why:** The verification side reconstructs the same payload — including the structured extras, from the same wire/row fields it persists — and checks the signature against it. Any signing site that constructs the payload differently, or any carrier path that LOSES an extras field (order_us defaulted to ts*1000, lp_digest missing from a sync item), makes verification fail: the message shows UNVERIFIED at best, and sync backfill DROPS it as Forged at worst.

**Where:**
- `rust/hollow_core/src/node/message_ops.rs:handle_send_message()` -- DM signing (type="dm", context=peer_id, extras from the wire envelope)
- `rust/hollow_core/src/node/message_ops.rs:handle_send_channel_message()` -- channel signing (type="ch", context="sid:cid")
- `rust/hollow_core/src/node/file_handler.rs:sign_file_message()` -- file message signing (extras: mid + file_id + order_us)
- Edit/delete signing binds the row's FULL extras (`RowExtras::load_*`); deletes use `"dm-delete"` / `"ch-delete"` types to prevent replay
- Reaction signing uses a DIFFERENT format: `"reaction:{mid}:{emoji}:{ts}"` / `"unreaction:{mid}:{emoji}:{ts}"` — live-REQUIRED since 0.8.3 (`reaction_sig_rejected`)
- Message Proof: `verify_message_proof_v2` FFI builds the payload in Rust from the DB row; only `verify_proof_section.dart` (external proof files) mirrors the grammar in Dart

### Dart timestamps must be hydrated from Rust's signed value

**Rule:** Dart timestamps for messages MUST be hydrated from the timestamp in `NetworkEvent::MessageSent` / `ChannelMessageSent`, NOT from `DateTime.now()`.

**Why:** The timestamp is embedded in the signing payload. Rust generates the timestamp (`SystemTime::now()` as millis-since-epoch) and includes it in the signed string. If Dart uses its own `DateTime.now()`, there will be a millisecond-level discrepancy. When the Dart side later tries to verify the signature using its own timestamp, verification fails because the payload string does not match.

**Where:**
- Dart: the event handler for `MessageSent` / `ChannelMessageSent` in `event_provider.dart` must update the optimistic message entry with the `timestamp` from the event
- Rust: `message_ops.rs` emits the Rust-generated timestamp in the event

**Correct approach:** When Dart creates an optimistic message, it may use a placeholder timestamp. Upon receiving `MessageSent` from Rust, Dart MUST replace the placeholder with the Rust-provided timestamp. This timestamp is the one embedded in the signature.

---

## UI Gotchas

### Never use raw OverlayEntry inside SelectionArea

**Rule:** Never use `OverlayEntry` directly when the widget tree contains a `SelectionArea` ancestor. Use `showDialog` with `barrierColor: Colors.transparent` instead.

**Why:** `SelectionArea` intercepts gesture events (tap, long press, drag) for text selection. Raw `OverlayEntry` widgets are part of the overlay stack but still receive gesture events through `SelectionArea`'s hit-testing. This causes taps on overlay content (menus, tooltips, popups) to be intercepted by `SelectionArea`, making them unresponsive or triggering text selection instead.

**Where:** Any overlay-based popup (context menus, dropdowns, pickers) that appears within a `SelectionArea` ancestor. The chat pane has `SelectionArea` at its root for message text selection.

**Correct approach:** Use `showDialog(barrierColor: Colors.transparent, ...)` which creates a new route that sits above `SelectionArea` in the widget tree. The dialog route has its own gesture arena that does not conflict with `SelectionArea`.

### SelectionArea steals TextSpan taps

**Rule:** Use `WidgetSpan` + `GestureDetector` instead of `TextSpan` with `recognizer` inside `SelectionArea`.

**Why:** `SelectionArea` overrides `TextSpan.recognizer` gesture handlers. Tappable text spans (links, mentions, etc.) become non-functional inside `SelectionArea` because the selection gesture always wins.

**Where:** Message bubbles that contain tappable inline elements (URLs, @mentions, custom links) within `SelectionArea`.

**Correct approach:** Wrap tappable content in `WidgetSpan` containing a `GestureDetector`. `WidgetSpan` participates in hit testing independently of `SelectionArea`'s text selection machinery.

### WindowTitleBar must be in MaterialApp.builder, NOT inside HollowShell

**Rule:** `WindowTitleBar` lives in `MaterialApp.builder` (above Navigator), not inside `HollowShell`.

**Why:** If `WindowTitleBar` is inside `HollowShell` (which is inside Navigator), dialogs and overlays (which are rendered above the Navigator in the overlay stack) block the title bar. Users cannot drag, minimize, maximize, or close the window while any dialog is open. This is a showstopper UX bug.

**Where:**
- `lib/src/ui/app.dart` -- `MaterialApp.builder` wraps the navigator child in a `Column` with `WindowTitleBar` at top
- `lib/src/ui/shell/window_title_bar.dart` -- the title bar widget
- The Navigator child is wrapped in `ClipRect` to prevent `BackdropFilter` blur bleed from dialogs into the title bar area

**Correct approach:** Keep `WindowTitleBar` in `MaterialApp.builder`. Wrap the navigator child in `ClipRect`. Never move the title bar into `HollowShell` or any widget below the Navigator.

### showHollowDialog overlays need a Material ancestor

**Rule:** `showHollowDialog` content must have a `Material` ancestor for any `Text` widgets, otherwise they render with yellow debug underlines.

**Why:** Flutter's `Text` widget requires a `DefaultTextStyle` ancestor (provided by `Material` and `Scaffold`). Dialog overlays created with `showGeneralDialog` or `showDialog` may not have a `Material` widget in their subtree if the dialog content is custom. Without it, text renders with yellow double-underline decoration (Flutter debug indicator for missing `DefaultTextStyle`).

**Where:** Any custom dialog content passed to `showHollowDialog()` in `lib/src/ui/components/hollow_dialog.dart`.

**Correct approach:** Wrap dialog content in a `Material(type: MaterialType.transparency, child: ...)` or ensure the dialog builder provides a `Material` ancestor.

### Sentinel pattern in scrollable_positioned_list

**Rule:** The message list uses `scrollable_positioned_list: ^0.3.8` with `itemCount: messages.length + 1`. The `+1` is a sentinel item. Do not remove this package or the sentinel.

**Why:** The sentinel item (an empty `SizedBox` or loading indicator at index 0) serves as the scroll anchor for the "load more" trigger. `ScrollablePositionedList` does not support standard `ScrollController` -- it has its own `ItemPositionsListener`. The sentinel pattern lets the list detect when the user has scrolled to the top (item 0 is visible) and trigger pagination.

**Where:** `lib/src/ui/chat/channel_chat_pane.dart` and `lib/src/ui/chat/chat_pane.dart` -- the message list builders.

### Use AnimatedOpacity, never Opacity widget

**Rule:** Use `AnimatedOpacity` for per-item opacity changes. Never use the raw `Opacity` widget.

**Why:** `Opacity` forces the child subtree into its own compositing layer on every frame, which is expensive. `AnimatedOpacity` is GPU-composited and only creates a layer when the opacity is actually animating or is not 1.0. The performance difference is measurable in lists with many items.

**Where:** All widgets in `lib/src/ui/` that need opacity-based visibility or fade effects.

### HollowTooltip: always use _dismiss() pattern

**Rule:** HollowTooltip must use the `_dismiss()` pattern for closing -- immediate overlay removal with no reverse animation.

**Why:** Reverse animations on tooltips cause visual artifacts when the cursor moves quickly between adjacent tooltip targets. The old tooltip lingers while the new one appears, creating overlapping tooltips. Immediate removal prevents this.

**Where:** `lib/src/ui/components/hollow_tooltip.dart`.

---

## Build and Deploy Gotchas

### flutter_rust_bridge codegen must run from project root

**Rule:** Always run `flutter_rust_bridge_codegen generate` from the HOLLOW project root with explicit args. Never `cd` into `rust/hollow_core/` first.

**Why:** The codegen tool resolves paths relative to the current directory. If run from inside `rust/hollow_core/`, the `--dart-output` path resolves incorrectly, and the tool may fail to find the Dart project structure or generate bindings in the wrong location.

**Where:** Project root `C:\Users\Jabun\Documents\Coding\HOLLOW\`.

**Correct command:**
```bash
flutter_rust_bridge_codegen generate --rust-input "crate::api" --rust-root "rust/hollow_core" --dart-output "lib/src/rust"
```

### Debug vs Release DLL mismatch

**Rule:** Always build with `--release` if testing from the Release folder. The user (Vitalik) runs from the Release folder.

**Why:** Debug and Release builds produce different DLLs in different output directories. If a debug build is done but the app is launched from the Release folder, it loads the stale Release DLL. The stale DLL does not include the latest code changes, causing mysterious bugs where "the fix isn't working" even though the code is correct. This has caused hours of debugging time.

**Where:** Build command: `flutter build windows --release` or `flutter run -d windows --release`. Output directories: `build/windows/x64/runner/Debug/` vs `build/windows/x64/runner/Release/`.

**Correct approach:** Always match the build mode to the test folder. When in doubt, build release. Delete `build/windows/x64/plugins/flutter_webrtc/` when iterating on the forked native plugin.

### SwarmContext struct is intentionally avoided

**Rule:** Do NOT consolidate swarm state variables into a single `SwarmContext` struct. Each handler function takes individual state variables as parameters.

**Why:** Rust's borrow checker prevents mutable borrows of individual fields when they are behind a single `&mut SwarmContext` reference. Crypto helper functions need mutable access to `olm`, `mls`, and `crypto_store` while other code holds references to `server_states`, `ws_room_peers`, etc. With a single struct, the borrow checker would require splitting borrows (which is fragile and verbose) or using interior mutability (which adds runtime overhead and complexity).

**Where:** `rust/hollow_core/src/node/swarm.rs` -- all ~40 state variables are individual `let mut` bindings in `run_event_loop()`. Every handler in `sync_handler.rs`, `message_ops.rs`, `file_handler.rs`, `voice_handler.rs`, `social.rs`, `vault_ops.rs`, and `gossip_relay.rs` takes individual parameters.

### New MessageEnvelope variants go in handle_envelope_* per module

**Rule:** New `MessageEnvelope` variants must be handled in the appropriate module's `handle_envelope_*()` function. `swarm.rs` only delegates to these functions.

**Why:** `swarm.rs` is already ~6,200 lines. Adding more match arms directly in swarm.rs makes it harder to navigate, understand, and maintain. The modular extraction pattern keeps domain logic in focused files while swarm.rs remains a thin dispatcher.

**Where:**
- `sync_handler.rs` -- `handle_envelope_crdt_op()`, `handle_envelope_sync_req()`, `handle_envelope_sync_resp()`, `handle_envelope_channel_sync_req()`, `handle_envelope_channel_sync_batch()`, `handle_envelope_server_delete()`, `handle_envelope_member_kick()`, `handle_envelope_channel_probe()`, `handle_envelope_channel_probe_resp()`
- `file_handler.rs` -- `handle_envelope_file_header()`, `handle_envelope_file_chunk()`, `handle_envelope_broadcast_meta()`
- `message_ops.rs` -- message-related envelope handling
- `swarm.rs` -- the MLS decrypt match block dispatches to these

---

## Privacy Gotchas

### Link previews are sender-side only

**Rule:** Receivers MUST NEVER make HTTP requests to URLs found in messages. Link preview data (title, description, thumbnail) is generated by the sender and embedded in the message.

**Why:** If receivers fetched link previews, every URL sent in a message would trigger HTTP requests from all recipients. This leaks IP addresses to the URL's server, reveals which users are in the chat (via timing correlation), and can be exploited for tracking (unique URLs per message). It also enables denial-of-service by sending URLs that trigger expensive server responses.

**Where:**
- Sender: `rust/hollow_core/src/node/link_preview.rs` -- fetches preview data before sending
- Sender: `message_ops.rs:handle_send_message()` and `handle_send_channel_message()` -- includes `link_preview` in the message envelope
- Receiver: Dart message bubble renders the embedded preview data without fetching anything

**Correct approach:** All link preview HTTP requests happen on the sender's machine before the message is sent. The preview data (title, description, image bytes, URL) is serialized into the message payload. Receivers display the embedded data directly. Never add any HTTP request triggered by receiving a message URL.

---

## Database and Persistence Gotchas

### serde(default) on ALL new persisted fields (repeated for emphasis)

This is the single most dangerous gotcha in the codebase. It has caused data loss in the past (servers vanishing from the UI).

**Rule:** Every new field on a Rust struct that is serialized to SQLCipher MUST have `#[serde(default)]`.

**Why:** SQLCipher stores `ServerState` and other structs as JSON blobs. Existing rows were written without the new field. serde's default behavior is to fail deserialization when a required field is missing. This failure is not caught gracefully -- it causes the entire struct to fail to load, which means the server disappears from the user's view.

**Where:** `rust/hollow_core/src/crdt/server_state.rs` (ServerState), `rust/hollow_core/src/crdt/operations.rs` (CrdtOp, CrdtPayload), and any other struct that goes through `serde_json::to_string()` before being stored in SQLCipher.

**Testing approach:** Before committing a new field:
1. Build the app with the old code, create some test data (join a server, send messages).
2. Apply the new code with the new field.
3. Launch the app and verify all old data loads correctly.
4. If the field lacks `#[serde(default)]`, step 3 will show missing servers.

### HLC is serde(skip) and must be restored after deserialization

**Rule:** `ServerState.hlc` is `#[serde(skip)]`. After loading a `ServerState` from SQLCipher, `state.set_hlc()` must be called before creating any new CRDT operations.

**Why:** The HLC clock must advance monotonically. If it is not restored, the clock starts from zero, and all new operations have timestamps that collide with or are older than existing operations. This breaks CRDT convergence -- new operations may be ignored by peers who already have operations with higher timestamps.

**Where:** `rust/hollow_core/src/crdt/server_state.rs:set_hlc()`. Called after `serde_json::from_str::<ServerState>()` in the initialization path of `swarm.rs`.

---

## Cross-Cutting Couplings

### Channel visibility is cryptographically enforced via per-channel MLS subgroups (Option B, TEXT + VOICE)

**Rule (UPDATED 2026-06-22 — Option B Phase 1 TEXT + Phase 2 VOICE both live):** A RESTRICTED channel (`visibility != Everyone && !is_public`, i.e. `ServerState::channel_uses_subgroup`) is MLS-encrypted under its OWN subgroup keyed `crate::crypto::subgroup_id(server, channel)` = `"{server}#{channel}"`, NOT the server-wide group. Only members whose role satisfies the tier hold the subgroup key, so a non-qualifying member never receives a decryptable copy. `Everyone` channels stay on the server-wide group; public channels stay plaintext.

**VOICE (Phase 2):** a restricted voice channel's SFrame media key is derived from the SUBGROUP `export_secret`, not the server group — a non-qualifying member can't derive it (decodes nothing) AND is rejected from joining outright (`handle_voice_channel_join` `can_see_channel` guard). `NetworkEvent::MlsEpochChanged` carries `channel_id: Option<String>` so Dart routes the key to that voice channel's cryptor; `voiceChannelProvider` caches SFrame keyed `(serverId, channelId)`. Mid-call demotion → subgroup remove-commit → MlsEpochChanged(cid) → forward-secrecy re-key for remaining participants + `auto_leave_invisible_voice_channels` hangs up the demoted member (runs on BOTH the plaintext AND MLS CrdtOp apply paths; Dart `_evictVoiceIfInvisible` is the belt-and-suspenders that calls `leaveChannel()`). VC participants key on the ROUTABLE WS sender, never the MLS leaf credential (multi-device: they differ → phantom participant).

**Subgroup coordinator** prefers the OWNER when online (always `can_see_channel` → one globally-agreed coordinator; avoids split-brain where two qualifying masters fork the group), else lowest qualifying online leaf-holder.

**Posting** is still NOT cryptographically enforced (authorization gate, not a confidentiality boundary).

**Where:** `MlsManager` (opaque-string group keys), `crypto_handler::send_mls_broadcast_topic`/`reconcile_subgroups_for_server`/`elect_subgroup_coordinator`/`request_subgroup_bootstrap`, `voice_handler.rs` (SFrame derivation + guard + auto-leave), `message_ops.rs` send sites, swarm.rs MLS handlers (KeyPackage/Welcome/Commit/decrypt resolve `channel_id`→group_key). Dart `visibleChannelsProvider`/`canPostInChannelProvider` + `voiceChannelProvider._channelUsesSubgroup` are defense-in-depth + UX. See `project_per_channel_mls_subgroups` memory.

### Channel visibility/posting UI reactivity must defeat the CrdtStore write race (desktop + mobile)

**Rule:** A LIVE visibility/posting change propagates correctly via CRDT/MLS, but the UI providers must be refreshed reliably on the receiver. `event_provider.dart:_refreshServerState` reloads `channelListProvider` AND invalidates `serverChannelsProvider(id)` on a retry ramp (0/120/400/1000ms) — `get_server_channels` is a DB read that races the fire-and-forget `CrdtStore` write, so a single fixed delay was unreliable.

**Why:** `visibleChannelsProvider` depends only on `channelListProvider`; `canPostInChannelProvider` on `channelListProvider` + `myRole`/`myPermissions`. `channelListProvider` exists ONLY for the selected server — but mobile's Chats tab has NO selected server, so it can't help there. `serverChannelsProvider` (autoDispose family) is the per-server reactive source for mobile and was previously never invalidated on `ServerUpdated`.

**Eviction:** when the open channel leaves `visibleChannelsProvider`, desktop `hollow_shell` selects the next visible text channel (else clears to home); mobile `mobile_chat_route` pops to the Chats tab. Mobile `MobileChatRoute.initState` must `loadForServer` on open (Chats-tab entry leaves the provider stale), and the Chats-tab `_ChannelList` must role-filter like `visibleChannelsProvider` + react to `serverChannelsProvider`/`myRole`/`myPermissions`. NEVER `ref.invalidate` in `initState` (ProviderScope not wired → throws; defer to a post-frame callback). See `feedback_channel_visibility_posting_ui_reactivity` memory.

### Permission bitmask bit 3 is unused (gap)

**Rule:** Bit 3 (value 8, formerly `MANAGE_INVITES`) is unused and must not be reused without coordinating with existing permission data.

**Why:** `MANAGE_INVITES` was removed, but the bit position was not reclaimed. Existing `role_permissions` values in server states may have bit 3 set or unset depending on when they were created. Reusing bit 3 for a new permission would silently grant or deny that permission based on legacy data.

**Where:** `rust/hollow_core/src/crdt/operations.rs:Permission` -- bit constants. `rust/hollow_core/src/crdt/server_state.rs` -- permission checks.

### Kick/ban broadcast must collect targets BEFORE apply_op

**Rule:** When kicking or banning a member, the list of broadcast targets must be collected from `state.members.keys()` BEFORE calling `state.apply_op(&op)`.

**Why:** `apply_op()` for `MemberRemoved` and `MemberBanned` removes the target peer from the member maps. If targets are collected after `apply_op()`, the kicked/banned peer is no longer in the member list and will not receive the kick notification. Other peers may also be missed if the operation removes additional data.

**Where:**
- `rust/hollow_core/src/node/sync_handler.rs:handle_kick_member()`
- `rust/hollow_core/src/node/sync_handler.rs:handle_ban_member()`
- `rust/hollow_core/src/node/sync_handler.rs:handle_leave_server()`

**Correct approach:**
```rust
let broadcast_targets: Vec<String> = state.members.keys()
    .filter(|m| *m != &local_peer)
    .cloned()
    .collect();
let _ = state.apply_op(&op);
// Now broadcast using broadcast_targets, not state.members
```

### Olm session persistence must happen after EVERY encrypt/decrypt

**Rule:** `persist_crypto_state(olm, crypto_store, peer_id)` must be called after every Olm encrypt or decrypt operation.

**Why:** Olm uses a Double Ratchet algorithm where each message advances the ratchet state. If the state is not persisted and the app crashes, the ratchet is out of sync with the peer's ratchet. The session becomes permanently broken -- messages fail to decrypt until a new session is negotiated.

**Where:** `rust/hollow_core/src/node/crypto_handler.rs:persist_crypto_state()`. Called from `send_encrypted_message()`, and after every `olm.decrypt()` call in `swarm.rs:handle_incoming_request()`.

### Windows Media Foundation has no Opus codec

**Rule:** Opus audio encode/decode on Windows must route through the bundled ffmpeg, not through Windows Media Foundation (MF).

**Why:** Windows MF does not include an Opus codec. Attempting to use MF for Opus results in silent failure (no audio). The bundled ffmpeg at `vendor/ffmpeg/` provides Opus encode/decode support.

**Where:** `vendor/ffmpeg/` -- bundled binaries (gitignored, fetched via `fetch_ffmpeg.ps1`). Any audio processing code that handles Opus-encoded audio.

### Share STUN-only constraint

**Rule:** Share (large file distribution) connections use STUN-only ICE configuration. No TURN relay is used for Share.

**Why:** Share transfers can be very large (hundreds of MB to GB). Routing these through TURN would overwhelm the relay server's bandwidth. STUN-only means peers must have direct P2P connectivity. If STUN fails (both peers behind symmetric NAT), the share transfer falls back to the WSS relay stream path.

**Where:**
- `lib/src/core/services/webrtc_service.dart:connectToPeer()` -- `iceConfigOverride` parameter for STUN-only
- `_stunOnlyPeers` set tracks which peers are STUN-only
- `onShareConnectionFailed` callback fires when STUN-only fails

---

## Linux Desktop Integration

### Window close on Linux must minimize to taskbar, not tray

**Rule:** On Linux, `onWindowClose()` calls `windowManager.minimize()` instead of the tray icon flow. If the window is already minimized when a close event arrives (taskbar right-click → Quit), treat it as a real quit via `_linuxQuit()`.

**Why:** Two things are broken: (1) `tray_manager` uses AppIndicator/DBus which requires a GNOME extension not installed by default on Fedora/Arch/vanilla GNOME — the tray icon appears but is non-interactive. (2) `windowManager.hide()` doesn't reliably hide frameless GTK windows on some Linux WMs. The Linux taskbar already provides click-to-restore and right-click → Quit, making the tray redundant.

**Where:** `lib/main.dart:_HollowWindowListener.onWindowClose()` (Linux branch), `_linuxQuit()` helper.

### Window close on macOS uses the native Dock idiom, not tray (and AppDelegate must not auto-terminate)

**Rule:** On macOS, `onWindowClose()` (minimize-to-tray setting on) just calls `windowManager.hide()` — NO tray icon. The app keeps running in the Dock with the active dot; clicking the Dock icon re-shows the window. This requires `macos/Runner/AppDelegate.swift` to override `applicationShouldTerminateAfterLastWindowClosed` to return **`false`** (the Flutter template default is `true`, which terminates the process on window close and bypasses the Dart handler entirely) plus `applicationShouldHandleReopen` to re-show/focus the window on Dock click. `onWindowFocus()` syncs `windowVisibleProvider = true` on macOS since the native reopen path doesn't go through the tray restore.

**Why:** macOS has no system tray; the native convention is window-less background running. The AppDelegate's `applicationShouldTerminateAfterLastWindowClosed = true` was silently killing the app on X (ignoring the minimize-to-tray setting).

**Where:** `lib/main.dart:_HollowWindowListener.onWindowClose()` (macOS branch) + `onWindowFocus()`; `macos/Runner/AppDelegate.swift` (`applicationShouldTerminateAfterLastWindowClosed` → false, `applicationShouldHandleReopen`).

### record package Linux backend requires parecord

**Rule:** The `record` Dart package (`record_linux` v1.3.0) shells out to `parecord` from `pulseaudio-utils`. This is not installed on PipeWire-only systems (modern Ubuntu 24.04+, Fedora).

**Why:** Mic test in Settings crashes with `ProcessException: No such file or directory`. Voice calls are unaffected — libwebrtc talks to PipeWire directly through its own audio device module.

**Where:** `lib/src/ui/dialogs/user_settings_dialog.dart:_startMicTest()`. Needs a Linux-specific path using WebRTC `getUserMedia` instead of the `record` package.

### Flatpak must use --socket=x11, not fallback-x11

**Rule:** The Flatpak manifest must specify `--socket=x11` to always expose the XWayland socket.

**Why:** `linux/runner/main.cc` forces `GDK_BACKEND=x11` via `setenv()`. With `--socket=fallback-x11`, the X11 socket is only exposed when Wayland is unavailable. On a Wayland session, the Flatpak sandbox has Wayland but no X11 → `cannot open display:` crash.

**Where:** `flatpak/com.anonlisten.Hollow.yml` finish-args, `linux/runner/main.cc` line 6.

## Multi-Device Gotchas (Phase 6)

### peer_is_reachable honors MASTER ids — and reachability gates must never feed raw sends (audit fix 2026-07-02)

**Rule:** `crypto_handler::peer_is_reachable(ws_room_peers, id)` returns true for a bare MASTER id when ANY of its devices is in a room. It must NEVER regain a `resolve(peer) == peer → false` early-return: `resolve(master) == master` ALWAYS (masters are only VALUES in the resolver map), so that early-return made every master "unreachable" — silently disabling owner-preferred coordinator election on non-owner nodes, `server_bootstrap_target` (the 3-failure MLS decrypt recovery found NO target), `request_subgroup_bootstrap`, channel-push offline classification (junk 0x09 for online members), the Twitch owner-verify gate, and vault shard placement. It survived weeks of live testing because only recovery/failure/election paths were broken.

**The paired rule:** any `peer_is_reachable(x) → send_*_to_peer(x)` pair is a silent drop when `x` can be a master (`send_message_to_peer`/`send_encrypted_message` require the EXACT id in a room). Sends must route via `send_raw_to_identity` (fan to all online devices), `preferred_online_device(ws_room_peers, id)` (exact-id-in-room wins, else deterministic lowest online device, else None; reachable ⇒ Some — used by all vault shard sends), or `friend_device_targets` (exact-room-gated; friend request/reject fan through it). The rebalancer's `online_peers` sets include each room device AND its resolved master (placements/members are master-keyed).

**Tests:** `crypto_handler::tests::master_with_online_device_is_reachable`, `preferred_online_device_picks_socket_addressable_id`.

### LEAVE/kick self-eviction converges DURABLY on every device (audit fix 2026-07-02)

**Rule:** when OUR identity stops being a member (own leave fanned from a sibling, plain kick, ban, or an offline-reconciled removal), the node tears down durably — `server_states.remove` + DB `delete_server_state`/`crdt_store.delete_server` + MLS server-group AND subgroup removal + `LeaveRoom` — on ALL THREE apply paths: (1) the plaintext `CrdtOpBroadcast` `MemberRemoved` arm (a `self_evict_teardown` flag set in the arm, executed AFTER the match — the `state` borrow spans the match; running before the subgroup-reconcile also makes it skip the removed server); (2) the MLS `MessageEnvelope::CrdtOp` dispatch CALLER in swarm.rs (capture `was_member_before` before `handle_envelope_crdt_op`, check after — the op travels BOTH MLS and plaintext, op_log-dedup suppresses whichever loses the race, and MLS usually wins); (3) the SyncResponse offline-reconcile branch. All guarded on `!pending_server_joins` so a rejoin replaying the old removal op can't nuke a fresh join.

**Why:** a sibling that only emitted `MemberLeft` kept the shell → it reloaded on restart, re-listed the server, and the sibling re-announce loop re-announced it → the announce handler joins unconditionally → the sibling fast-path re-ADDED the master as a member of a server it LEFT → the `MemberAdded` (authored by a non-member) is rejected by real members → permanent fork. Defense in depth: BOTH re-announce sites (`on_verified_sibling`, `SiblingStateSyncRequest`) and `get_joined_servers` + the harness `servers()` inspector now filter `is_member(local_master)` (non-empty membership only — a mid-bootstrap empty state is exempt), which also heals legacy stranded shells.

**Test:** `test_harness::leave_tears_down_durably_on_sibling_and_owner_prunes_member` (join → sibling onboard → leave → durable teardown both devices → owner prunes member → NO resurrection on sibling reconnect).

### Ingest permission checks are OVERRIDE-AWARE (audit fix 2026-07-02)

**Rule:** every remote-op validation uses `state.get_permissions(&op.author)` (honors CRDT `role_permissions` overrides; Owner ⇒ ALL), never `role.default_permissions()`. Sites: the `allowed` matrices in swarm.rs `CrdtOpBroadcast` + sync_handler `handle_envelope_crdt_op`, and both kick-broadcast checks (`MemberKickBroadcast`, `handle_envelope_member_kick`). Local sends gate on the same `has_permission` — a divergence means an override-GRANTED permission authors ops the whole network rejects (the actor's devices fork; worst case an override-granted `ServerDeleted`), and an override-REVOKED permission still passes ingest (unenforced remotely). `handle_update_server_setting` also has a local Owner/Admin gate (receivers always enforced it; a non-admin FFI call used to diverge its own local state). `MemberAdded`'s allowed-check uses `state.is_member(&op.author)` (resolver-aware), not raw `contains_key`.

### Servers/MLS multi-device (Step 6) — members master-keyed, leaves device-keyed

**Rule:** A server's MLS group holds one leaf PER DEVICE (credential = the bare `device_peer_id`), but `ServerState.members`/`roles`/`banned_members` are keyed by the MASTER identity. THE INVARIANT: `state.members` is master-keyed, `mls.group_members()` returns device ids → every MLS↔CRDT comparison bridges through `resolver::resolve`/`same_identity`. Use `ServerState::is_member(id)` (resolver-aware) instead of `members.contains_key(id)`. A `crdt/mod.rs` resolver-hook (`set_identity_resolver`, installed once at node start) makes the `ServerState` accessors (`get_role`/`has_permission`/`is_banned`/`is_member`) collapse a device id→master internally — one chokepoint covering ~24 lookup sites. Every targeted SEND to a member fans master→online devices via `crypto_handler::send_raw_to_identity` (the bare master is in no room → a direct send is dropped).

**Why:** Getting it wrong silently breaks server delivery. Real bugs found live (2026-06-18): the PeerJoined CRDT-sync + MLS-bootstrap gate keyed `members.contains_key(device)` (false for a master-keyed member → no KeyPackage ever sent → joiner never gets an MLS leaf → all channel messages decrypt-fail "unknown group"); ~34 member-broadcast loops sent to the bare master (dropped). A legacy server's members were split-brain (owner master-keyed, joiners device-keyed) — `ServerState::canonicalize_members(resolve)` folds device-keyed entries→master on load/sync.

**Two more first-join traps:** (1) post-join MLS bootstrap must send the KeyPackage to the SyncResponse responder (`peer_str`) DIRECTLY, not via resolver-based coordinator election — the resolver is cold on a fresh join, so election picks self and sends nothing. (2) A LINKED SIBLING must regenerate its OWN MLS signer/credential — the snapshot import copies the source's `mls_identity` table; reusing it = `DuplicateSignatureKey` on add / `CannotDecryptOwnMessage` on receive. `import_pending_link` clears it; a startup net regenerates iff `cred != device && (cred != master || has_sibling)` (NEVER re-key a sole owner — orphans its servers). See `feedback_mls_sibling_identity_collision`.

**Channel topic subscription:** the relay topic-routes `SendToRoomTopic` (topic = channel_id) — a subscribed socket only receives its topic set; an UNsubscribed socket gets everything (wildcard). So `subscribeChannels` must fire on EVERY channel activation (not only an explicit sidebar click) — `ref.listen(selectedChannelProvider)` in `hollow_shell` + `mobile_shell._openChannel`. Without it, messages only arrive on the next `ChannelSyncRequest` (tab-switch), not live. This is an intentional optimization, not a bug.

**Where:** `rust/hollow_core/src/crdt/mod.rs` (resolver hook), `crdt/server_state.rs` (`is_member`/`canonicalize_members`/resolver-aware accessors), `node/swarm.rs` (PeerJoined gate, post-join bootstrap, MLS identity regen, member-key canonicalization), `node/crypto_handler.rs` (`send_raw_to_identity`, election collapse), `node/sync_handler.rs` + `message_ops.rs` + `vault_ops.rs` + `voice_handler.rs` + `file_handler.rs` (per-device send fan-out), `crypto/mls_manager.rs` (`credential_identity`, `remove_identity_leaves`), `api/storage.rs` (`import_pending_link` MLS clear), `lib/src/ui/shell/{hollow_shell,member_panel,user_bar}.dart`, `lib/src/ui/mobile/{mobile_shell,mobile_member_panel,mobile_members_route}.dart`, `lib/src/ui/chat/channel_chat_pane.dart` (sender-grouping collapse). See memory `project_multidevice_step6_mls_leaves`.

### Server sync hardening (Step 9D) — siblings + offline members + the keystone leaf

**Rule:** Server lifecycle ops must converge BOTH the actor's OWN sibling devices AND offline members. (1) The member broadcast is master-keyed and excludes the actor's identity → plaintext-only handlers (kick/ban/role/leave + pin/unpin/layout/pledge/nickname/twitch) call `fan_to_own_siblings(.., local_device_id, data)` (fans to our online siblings, EXCLUDING the acting device — re-feeding it its own MLS commit self-drops the group). MLS-first ops converge siblings free via `SendToRoom`. (2) Server DELETE is a replicable `CrdtPayload::ServerDeleted` tombstone (NOT a one-shot): apply sets `ServerState.deleted` + keeps the shell/op_log so the owner serves it; offline members reconcile on reconnect via grow-only `SyncResponse`; hidden from `get_joined_servers`. Owner-authorship validated at EVERY ingest (the two `allowed` matches + a pre-merge filter in both `SyncResponse` and `handle_envelope_sync_resp`). (3) Server CREATE auto-onboards online siblings via `HavenMessage::SiblingServerAnnounce` → a SAME-IDENTITY join fast-path (skips ban/Twitch/private/owner-verify gates) → snapshot + MLS leaf. (4) The KEYSTONE device (`device==master`) regenerates a device-credentialed MLS leaf when `has_sibling` (`stale_keystone` in swarm.rs startup; NEVER re-key a sole device — orphans its servers), and re-joins OWNED groups via the **sibling-re-adds-sibling** fast path in the MlsKeyPackage handler (coordinator election excludes our own identity; old+new leaf share credential → remove-then-add).

**Why:** Found by Vitalik's live testing after 9C. Symptoms: a server created/deleted on one device didn't appear/disappear on the sibling; an offline member kept a deleted server forever (one-shot missed, grow-only sync can't carry a removal, the deleting owner dropped its own state so couldn't even answer a sync); the keystone device's channel messages + typing didn't decrypt at a friend on OLD servers (stale master-credentialed leaf). All harness/unit-verified + negative-tested.

**Where:** `node/sync_handler.rs` (`fan_to_own_siblings`, `handle_delete_server`, `handle_create_server`, the 6 plaintext handlers, `handle_envelope_server_delete`, `handle_envelope_sync_resp` filter), `node/swarm.rs` (keystone regen `~439`, MlsKeyPackage sibling-re-add, `ServerDeleted`/`SiblingServerAnnounce` ingest, SyncResponse owner-filter + self-heal, `ServerJoinRequest` sibling fast-path), `crdt/operations.rs` (`ServerDeleted`), `crdt/server_state.rs` (`deleted` + apply arm + `is_deleted`), `crypto/mls_manager.rs` (sibling re-add unit test), `api/crdt.rs` (tombstone hide). See memory `feedback_server_lifecycle_sibling_sync`, `feedback_keystone_mls_leaf_regen`, `project_multidevice_9c_9d_polish`.

### Any per-person UI state must key on the MASTER id, never a raw device id

**Rule:** A friend has several device peer_ids that all resolve to ONE master identity. The relay reports DEVICE ids in rooms / `peersProvider` / `connectionStatusProvider` / typing events. But friend/DM/profile/presence UI keys on the friend's MASTER id (`friend.peerId`). Any code that compares a relay-reported device id against a friend's master id must route through the resolver — Rust `node::resolver::resolve()` / `same_identity()`, or Dart `deviceLinkProvider.identityOf()` / `onlineIdentitiesProvider` / `identityIsOnline()`. A direct `map[friend.peerId]` lookup silently never matches a multi-device friend.

**Why:** Symptoms of getting this wrong: a friend's "typing…" never shows; the Home network panel / DM chat-header shows a multi-device friend stuck "connecting"/"Offline" forever; presence shows offline despite working DMs. The flip side — addressing the bare MASTER where a SEND needs a device — silently drops, because the master authenticates as NO socket (only device peer_ids do). Fixed examples (2026-06-15): `event_provider` `TypingStarted` (resolve before `setTyping`); `home_dashboard._NetworkColumn` + `chat_pane.dart` DM header (scan `links.identityOf(e.key) == f.peerId && e.value.isEncrypted`); Step 2's `friends_bar`/`channel_sidebar` (`identityIsOnline`); **DM typing SEND** (`social::handle_send_typing_indicator` fans out to the recipient's devices — was sent to the bare master → dropped); **sibling-echo DM direction** (`MessageReceived.is_own` → Dart renders outgoing, not incoming). Single-device collapses to identity → perfect no-op.

**Where:** `lib/src/core/providers/device_link_provider.dart`, `event_provider.dart`, `home_dashboard.dart`, `chat_pane.dart`; Rust `node/resolver.rs`, `social.rs` (typing send), `swarm.rs` (MessageReceived.is_own), `api/network.rs` + `types.rs` (the is_own FFI field).

### DM room code is a PURE function of the two ids — never resolve inside it

**Rule:** `node::types::dm_room_code(a, b)` hashes the two ids as-is (no `resolver::resolve`). Pass the MASTER for the local end (the event loop's `local_peer_str` is master) and the friend's identity id for the remote end. A per-device fan-out computes the room from the recipient's MASTER and uses the device id only as `target_peer`.

**Why:** Two friends MUST always derive the SAME DM room. If the room depended on each side's mutable resolver state, a divergence (one side ingested a device list the other hadn't, or a stale/polluted link) makes them compute DIFFERENT rooms → they never meet → key exchange never lands → "keying error" even for plain single-device friends. This regressed plain-friend keying when `dm_room_code` resolved both ends (committed multi-device work); reverted to pure 2026-06-15.

**Where:** `rust/hollow_core/src/node/types.rs` (`dm_room_code`), `message_ops.rs` + `file_handler.rs` (per-device sends pass the master-pair room).

### DM send fan-out: only devices CURRENTLY IN A ROOM (kills ghost-fanout)

**Rule:** `message_ops::collect_target_devices` (and the `file_handler` DM file fan-out) build the target set as `resolver::devices_for(master)` **filtered to ids currently in a room** (`ws_room_for_peer(...).is_some()`), UNIONed with every peer currently in the DM room that resolves to that master. The single-device `fallback_self` (no device links → send to the master id → offline buffer → FCM push) preserves offline push for the common case.

**Why:** The persisted device list accumulates dead ghost ids across re-link cycles (each re-link mints a NEW device peer_id; union-merge never removes them). A ghost keeps a STALE Olm session, so a `has_session` filter is NOT enough — it would still room-send "Sent encrypted DM to offline <ghost>" → relay offline-buffer → a phantom push + a stuck unread pill on the receiver (and the notification shows a raw peer id). Room-presence is the unambiguous liveness test: a ghost is in no room → dropped entirely. A genuinely-offline REAL sibling also isn't in a room now, but its queued copy drains on reconnect (`pending_messages`) + Step 5 backfill, so the message still arrives — just not via the instant offline-buffer path. The live room is authoritative; `ingest_device_list` also registers the SENDER device→master link.

**Companion (Dart):** DM unread counts + notifications MUST resolve `fromPeer`→master (`deviceLinkProvider.identityOf`) before keying — `event_provider` `MessageReceived`. Keying unread on the raw device id made a `dmUnreadCounts[<deviceId>]` entry `markDmSeen(master)` never cleared → a permanently-stuck nav pill that counted a disconnected device.

**Where:** `rust/hollow_core/src/node/message_ops.rs` (`collect_target_devices`, `fan_out_dm_envelope`), `file_handler.rs` (DM branch), `crypto_handler.rs` (`ingest_device_list`), `lib/src/core/providers/event_provider.dart` (`MessageReceived` → resolve to master). See memory `feedback_ghost_device_fanout`.

### Device revocation (Step 7): tombstone the revoked device must REACH it + observers guard against the lingering device

**Rule:** Revocation (`handle_revoke_device` → `revoke_own_device`) tombstones a device in the master-signed list (`revoked` array, version+1) and sends the new list **TO THE REVOKED DEVICE FIRST**, then to everyone else. The revoked device's own ingest fires `NetworkEvent::SelfRevoked` → `event_provider._selfNuke()` wipes the data dir + relaunches to Welcome. Observers (friends/siblings) that ingest the tombstone call `resolver::forget` (drop the device→master link) + `mark_revoked`, and the DM/typing receive paths DROP messages from a `resolver::is_revoked` id.

**Why:** Two traps, both hit live. (1) The revoke handler originally SKIPPED sending the tombstone to the device being revoked ("why message a device we're removing?") — so the revoked device never learned it was revoked, never self-nuked, and kept running/talking as the master. (2) Once a friend `forget`s the link, the still-alive revoked device's id resolves-to-self → its messages spawn a standalone "unknown peer" phantom conversation. The `is_revoked` receive-path guard suppresses that until the device self-nukes/disconnects. (3) The self-nuke itself must `stash_pending_wipe()` FIRST, then show a best-effort `overlayState:` toast — the plain `HollowToast.show(ctx)` form throws from a navigator-key context (`Overlay.of` null check) and aborted the wipe.

**Where:** `rust/hollow_core/src/node/sync_handler.rs` (`handle_revoke_device`), `crypto_handler.rs` (`revoke_own_device`, `ingest_device_list`/`ingest_sibling_device_list` self-nuke + `mark_revoked`), `swarm.rs` (`enforce_device_revocations`, DM/typing `is_revoked` drop), `resolver.rs` (`forget`/`mark_revoked`/`is_revoked`), `lib/src/core/providers/event_provider.dart` (`SelfRevoked` → `_selfNuke`). Manual-only; no relay change. See memory `feedback_ghost_device_fanout`.

### Device linking (Step 4): import the snapshot at NEXT BOOT, never in-place

**Rule:** the multi-device link transfer REUSES the `.hollow` backup pipeline (link CODE as the passphrase) and imports on the NEXT LAUNCH, pre-node-start — the identical path as a manual "Restore from backup". Sender `storage::export_backup_bytes(code,…)` → stream `StreamKind::LinkSnapshot` → receiver `stash_pending_link(blob, code)` (writes `pending_link.hollow`+`.code`) → restart → `_bootstrap` FIRST (before `hasIdentity()`) `has_pending_link()`→`import_pending_link()`→`import_backup_bytes`. NEVER call an in-place importer while the node is running.

**Why:** the first attempt (`import_snapshot_bytes` in-place, while the node ran on the throwaway link identity) corrupted the identity → "Loading… / Offline / peer_id ---" forever. It fought (a) the live SQLCipher connection + its `messages.db-wal`/`-shm` checkpointing back OVER the import, (b) a stale post-import summary handle (read 0 rows), and (c) a leftover throwaway `identity.device` whose at-rest protection mismatched the freshly-imported plaintext master → `load_or_create_device_keypair` throws "Device key is encrypted". `import_backup` sidesteps ALL of this purely by running pre-node-start. General rule: any in-place identity/DB swap while the app/node is live is a trap — stash + restart + reuse the backup pipeline. The empty device uses a THROWAWAY identity just to get a relay socket (the relay needs no new "guest" mode); the snapshot overwrites it.

**Where:** `rust/hollow_core/src/api/storage.rs` (`export_backup_bytes`/`import_backup_bytes`/`stash_pending_link`/`has_pending_link`/`import_pending_link`), `node/link_handler.rs`, `node/file_handler.rs` (completion→stash), `lib/src/ui/shell/hollow_shell.dart` (`_bootstrap` pending-import). See memory `feedback_link_import_identity_device`.

### Device linking: deleting the DB in-process while the node runs leaves messages.db behind (Windows)

**Rule:** backing out of "Link a device" (which created a THROWAWAY identity) must NOT delete the data files in-process. The live node holds open SQLCipher handles (CrdtStore/CryptoStore actor threads + `messages.db-wal`/`-shm`); on Windows `remove_file` on an open `messages.db` fails silently, so it SURVIVES — encrypted with the throwaway passphrase — and the next identity's derived passphrase can't open it → **infinite loading on the next Welcome**. Same family as the in-place-import trap above. Fix = stash-and-reboot: `stash_pending_wipe()` (writes `pending_wipe.marker`) + relaunch (spawn fresh process, NOT bare `exit(0)`); `_bootstrap` runs `perform_pending_wipe()` BEFORE node start (no open handles), removing every data-dir entry except the marker (removed LAST so a mid-wipe crash re-runs) + any `*.lock`.

**Also:** device-link push completion is RECEIVER-ACKED, not queue-drained. The sender stays on its spinner until the receiver sends `HavenMessage::LinkSnapshotAck` (after a successful stash) → `LinkPushComplete`; emitting it when `ws_stream_send_bytes` merely returned flashed "Data sent" while the receiver was still receiving. And `device_link_sync_provider.onDisconnected()` preserves in-flight `waiting/receiving/sending` phases across a transient relay blip (the handshake churns the connection).

**Where:** `rust/hollow_core/src/api/storage.rs` (`stash_pending_wipe`/`has_pending_wipe`/`perform_pending_wipe`), `node/file_handler.rs` (`LinkSnapshotAck` send), `node/swarm.rs` (ack dispatch arm), `node/types.rs` (`HavenMessage::LinkSnapshotAck`), `lib/src/ui/shell/hollow_shell.dart` (`_bootstrap`, go-back relaunch), `lib/src/ui/dialogs/device_link_dialog.dart` (`_failed` Try-again/Back), `lib/src/core/providers/device_link_sync_provider.dart` (`onDisconnected`). See memories `feedback_device_link_push_ack`, `feedback_dm_online_branch_retry_queue`.

### SOLVED: WS/relay presence churn was GHOST-CONNECTION EVICTION (relay-side)

**Symptom (was):** A friend showed offline for stretches even though DMs flowed; the observer saw the peer LEAVE all shared rooms for ~14 min with NO reconnect line in the peer's log. Surfaced — not caused — by multi-device.

**Root cause:** the relay keyed `peer_sockets` + every `ws_rooms[room].peers` slot by `peer_id` with no duplicate-connection handling. A client reconnect (resume/blip/TLS re-handshake) opens a NEW socket while the OLD TCP socket is still half-open; the relay doesn't notice the dead one until its 120s `idleTimeout`. In that window the new socket takes over the rooms; then the OLD socket's delayed close ran `cleanup_peer` → `leave_room` for every stale `peer_rooms` entry, ERASING the live socket's room entries + broadcasting `peer_left`. Nothing rejoined until the 60s `check_peers` heal.

**Fix (deployed 2026-06-15):** (1) `handle_auth` SUPERSEDES a stale duplicate (mark `superseded`, evict its rooms+socket, `end(1000,"superseded")`); (2) `cleanup_peer`/`leave_room` are socket-aware (`expected_ws`) — only tear down a slot that STILL points at the closing socket; (3) buffer a DM for a connected-but-not-yet-in-room target (the WS-auth→room-join race) instead of dropping it. Client `PeerLeft`/`RoomMembers` logic was already correct — it was being fed a lie. **Companion (presence stale on OWN restart):** `ingest_device_list` emits `DeviceListUpdated` even on a redundant re-ingest, so Dart's `deviceLinkProvider` (warmed once at startup, racing the Rust resolver warm) re-pulls the map on every reconnect — removed the need for manual Device List resets.

**Where:** `relay-uws/src/ws_handler.cpp` (`handle_auth`, `cleanup_peer`, `leave_room`, `handle_direct`/`handle_binary_direct_msg`) + `state.h` (`superseded` flag); `rust/hollow_core/src/node/crypto_handler.rs` (`ingest_device_list` nothing_new path), `social.rs` (`send_own_profile_to_peer` de-gate). See memory `feedback_relay_ghost_connection_eviction`, `project_ws_presence_churn`.
