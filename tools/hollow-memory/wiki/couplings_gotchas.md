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

Current variants that correctly emit `ServerUpdated`: `ServerSettingChanged`, `ServerRenamed`, `RolePermissionsChanged`, `MemberBanned`, `MemberUnbanned`, `ChannelVisibilityChanged`, `ChannelPostingChanged`, all Label variants (`LabelCreated`, `LabelDeleted`, `LabelUpdated`, `LabelAssigned`, `LabelUnassigned`).

### serde(default) is mandatory on all new persisted fields

**Rule:** ALWAYS add `#[serde(default)]` to ANY new field added to `ServerState` or any struct stored as JSON in SQLCipher.

**Why:** Existing data in the database was serialized without the new field. Without `#[serde(default)]`, deserialization fails with a missing-field error. The failure is silent from the user's perspective -- servers simply vanish from the UI because the entire `ServerState` fails to load.

**Where:** `rust/hollow_core/src/crdt/server_state.rs:ServerState` and any nested struct that gets serialized to the `server_states` or `app_settings` SQLCipher tables.

**Correct approach:** Every new field on a persisted struct gets `#[serde(default)]`. Use appropriate default values (empty HashMap, empty Vec, false, 0, None). Test by verifying that a DB created before the change still loads correctly after the change.

Fields that already have `#[serde(default)]` in ServerState: `nicknames`, `twitch_usernames`, `pinned_messages`, `channel_layout`, `storage_pledges`, `settings` (actually required), `role_permissions`, `banned_members`, `labels`, `label_assignments`.

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

### Canonical signing payload must be used at ALL signing sites

**Rule:** All message signing MUST use `crypto_handler::message_signing_payload(msg_type, context, sender, ts, text)` to construct the payload string. The format is `hollow-msg:{type}:{context}:{sender}:{ts}:{text}`.

**Why:** The verification side reconstructs the same payload and checks the signature against it. If any signing site constructs the payload differently (different field order, missing fields, different separator), verification fails. Failed verification means the message shows as UNVERIFIED in the UI's Message Proof dialog.

**Where:**
- `rust/hollow_core/src/node/message_ops.rs:handle_send_message()` -- DM signing (type="dm", context=peer_id)
- `rust/hollow_core/src/node/message_ops.rs:handle_send_channel_message()` -- channel signing (type="ch", context="sid:cid")
- `rust/hollow_core/src/node/file_handler.rs:handle_send_file()` -- file message signing
- Delete message signing uses `"dm-delete"` and `"ch-delete"` types to prevent replay
- Reaction signing uses a DIFFERENT format: `"reaction:{mid}:{emoji}:{ts}"` / `"unreaction:{mid}:{emoji}:{ts}"`

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

### Channel visibility is UI-only, not cryptographically enforced

**Rule:** Channel `visibility` and `posting` modes are UI-filtered only. ALL members still receive ALL messages via the server-wide MLS group.

**Why:** The current implementation uses a single MLS group per server. Every message encrypted for that group is decryptable by every member, regardless of channel visibility settings. Per-channel MLS subgroups (Option B in the design document) are needed for true cryptographic enforcement but are not yet implemented.

**Implication:** Do not rely on channel visibility for security-sensitive features. A malicious client can ignore UI filtering and read all channel messages. This is a known limitation documented for pre-v1.0.

**Where:** `lib/src/core/providers/channel_provider.dart:visibleChannelsProvider` -- UI filtering. `lib/src/core/providers/channel_provider.dart:canPostInChannelProvider` -- UI posting guard. The Rust side does NOT enforce channel-level access on message delivery.

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
