# FFI Network API — Dart-Rust Bridge

Source: `rust/hollow_core/src/api/network.rs` (1902 lines)

This is the primary FFI boundary between Flutter/Dart and the Rust networking node. Every function in this file is annotated with `#[frb]` and scanned by `flutter_rust_bridge` codegen to produce the Dart bindings in `lib/src/rust/api/network.dart`. The file defines FFI-facing data structures (mirroring internal `node::` types), the static singleton pattern for the running node, the event translation layer, and all public functions that Dart calls to control the node.

## Static Singleton Pattern — OnceLock/Mutex Globals

Four `OnceLock<Mutex<...>>` statics manage the node lifetime and shared state:

- `NODE: OnceLock<Mutex<Option<NodeState>>>` — holds the running node's state (peer ID, command sender, task handle, Olm fingerprint). `None` means not running, `Some` means running.
- `TOKIO_RUNTIME: OnceLock<tokio::runtime::Runtime>` — lazily-initialized multi-thread Tokio runtime. Created once on first access via `get_runtime()`. Shared by all FFI functions that need async execution.
- `EVENT_RX: OnceLock<Mutex<Option<mpsc::Receiver<node::NetworkEvent>>>>` — stored separately from `NODE` so `watch_network_events()` can `.take()` ownership of the receiver without holding the node lock. Set during `start_node()`, consumed (taken) by `watch_network_events()`.
- `LICENSE_KEY: OnceLock<Mutex<Option<String>>>` — set from Dart before `start_node()`. Passed to the WS relay client for authentication.

Accessor functions:

- `network.rs:get_node()` — returns `&'static Mutex<Option<NodeState>>`, initializes with `Mutex::new(None)` on first call.
- `network.rs:get_runtime()` — returns `&'static tokio::runtime::Runtime`, builds `Builder::new_multi_thread().enable_all()` on first call.
- `network.rs:get_event_rx()` — returns `&'static Mutex<Option<mpsc::Receiver<...>>>`.
- `network.rs:get_license_key()` — returns `&'static Mutex<Option<String>>`.

The `NodeState` struct holds:
- `local_peer_id: String` — Base58btc-encoded Ed25519 peer ID.
- `cmd_tx: mpsc::Sender<node::NodeCommand>` — command channel sender (capacity 100). All FFI functions use this to dispatch commands to the swarm event loop.
- `handle: tokio::task::JoinHandle<()>` — the spawned event loop task handle. Aborted on `stop_node()`.
- `olm_fingerprint: String` — Curve25519 identity key (base64), extracted before Olm is moved into the swarm.

## NodeState Visibility

`NodeState` and `get_node()` are `pub(crate)`, meaning other files in the `api/` module (like `api/storage.rs`, `api/crdt.rs`, `api/share.rs`) can also access the command sender to dispatch `NodeCommand`s. This is how CRDT operations, vault operations, and share operations route commands through the same channel without duplicating the static pattern.

## start_node() — Node Initialization

`network.rs:start_node()` -> `Result<String, String>`

Dart call: `ffi.startNode()` (async Future<String>). Called from `node_provider.dart:NodeNotifier.start()`.

Sequence:
1. Acquires `NODE` lock, checks not already running (returns error if `Some`).
2. Initializes the debug log file via `crate::log::init()` (writes `hollow_debug.log` next to executable, 10MB rotation).
3. Loads persistent identity via `identity::load_or_create_identity()` — returns `NativeKeypair` (Ed25519 via BIP-39 mnemonic). Creates on first run.
4. Derives DB encryption passphrase: encodes keypair to protobuf, takes first 32 bytes, hex-encodes them. This is the SQLCipher passphrase.
5. Resolves the data directory (`~/.hollow/`) and DB path (`~/.hollow/messages.db`).
6. Loads Olm state from DB (synchronous, on the FFI thread):
   - If existing account found: `OlmManager::from_pickles(account_json, sessions)`.
   - If first run: creates fresh `OlmManager::new()`, persists the account pickle.
7. Extracts `olm_fingerprint` (Curve25519 base64 identity key) before Olm is moved.
8. Loads `invisible_mode` setting from DB so the node starts in the user's persisted status mode (avoids a brief "online" flash on restart).
9. Opens `CryptoStore` persistence actor (runs in its own blocking thread) via `rt.block_on(CryptoStore::open(...))`.
10. Reads the license key from the `LICENSE_KEY` static.
11. Creates two `mpsc` channels (capacity 100 each):
    - `(event_tx, event_rx)` — node events flow from swarm to FFI.
    - `(cmd_tx, cmd_rx)` — commands flow from FFI to swarm.
12. Calls `node::spawn_node(keypair, event_tx, cmd_rx, cmd_tx_clone, olm, crypto_store, license_key, initial_invisible)` which:
    - Spawns the signaling background task (`signaling::spawn_signaling_task`).
    - Spawns the WebSocket relay client (`ws_client::spawn_ws_client` connecting to `wss://relay.anonlisten.com/ws`).
    - Spawns `run_event_loop()` as a tokio task — the main swarm dispatcher in `swarm.rs`.
    - Returns `(peer_id_str, JoinHandle)`.
13. Stores `event_rx` into `EVENT_RX` (separate from `NODE` so `watch_network_events` can take it).
14. Stores `NodeState` into `NODE`.
15. Returns `peer_id_str` to Dart.

## watch_network_events() — StreamSink Event Forwarding

`network.rs:watch_network_events(sink: StreamSink<NetworkEvent>)` -> `Result<(), String>`

Dart call: `ffi.watchNetworkEvents()` returns a `Stream<NetworkEvent>`. Called from `event_provider.dart:EventStreamNotifier.start()` which subscribes with `.listen(_dispatch)`.

Behavior:
1. Takes the `event_rx` from `EVENT_RX` via `.take()` — this means it can only be called once per node lifetime. A second call returns an error.
2. Spawns an async task `event_forwarding_task(rx, sink)` on the shared Tokio runtime.
3. The task loops: `while let Some(event) = rx.recv().await`, converts each `node::NetworkEvent` to the FFI `NetworkEvent` via `to_ffi_event()`, and pushes it into the `StreamSink` via `sink.add(ffi_event)`.
4. If `sink.add()` returns error (Dart side closed the stream), the task logs and breaks.
5. If the channel closes (node stopped), the task logs and exits.

`flutter_rust_bridge` translates the `StreamSink` parameter into a Dart `Stream` automatically. The codegen generates the plumbing so Dart gets a native `Stream<NetworkEvent>` that yields events as they arrive from Rust.

## poll_network_event() — Fallback Polling

`network.rs:poll_network_event()` -> `Option<NetworkEvent>`

Non-blocking `try_recv()` on the event receiver. Returns `None` if no event is available or if the receiver has already been taken by `watch_network_events()`. This is a fallback for platforms where streaming might not work — in practice, the stream-based `watch_network_events()` is always used.

## to_ffi_event() — Event Translation Layer

`network.rs:to_ffi_event(event: node::NetworkEvent)` -> `NetworkEvent`

This function serves two purposes:

1. **Logging:** A large `match &event` block logs every event variant to `hollow_debug.log` via `hollow_log!()`. This provides release-build diagnostics. Not all variants are logged — the catch-all `_ => {}` silently passes less interesting events (vault events, share events, etc. that are logged elsewhere).

2. **Type conversion:** A second `match event` (by value) converts each `node::NetworkEvent` variant into the corresponding FFI `NetworkEvent` variant. Most conversions are 1:1 field copies. Notable transformations:
   - `FileHeaderReceived`: flattens `video_thumb: Option<node::VideoThumbRef>` into `video_thumb: Option<VideoThumbRef>` via `VideoThumbRef::from()`, and splits `share_ref: Option<node::ShareRef>` into two separate fields: `share_root_hash: Option<String>` and `share_key_hex: Option<String>` (because FRB handles flat Option fields better than nested structs in some cases).
   - `ShareList`: maps `Vec<node::ShareEntryRef>` to `Vec<ShareEntry>` field by field.
   - `LinkPreviewRef`: uses `Into::into` trait implementations for bidirectional conversion.

## FFI Data Structures

### NetworkEvent (enum)

The FFI-facing event enum — ~80 variants covering every domain in the app. Organized by phase/feature:

**Core networking:** `PeerDiscovered`, `PeerExpired`, `PeerDisconnected`, `RoomCleared`, `Listening`, `SessionEstablished`, `Error`, `KeyExchangeStarted`, `KeyExchangeProgress`.

**DM messaging:** `MessageReceived` (from_peer, text, timestamp, message_id, reply_to_mid, link_preview, signature, public_key), `MessageSent`, `MessageSendFailed`, `DmMessageEdited`, `DmMessageDeleted`, `DmReactionAdded`, `DmReactionRemoved`, `DmSyncCompleted`.

**Channel messaging:** `ChannelMessageReceived`, `ChannelMessageSent`, `ChannelMessageEdited`, `ChannelMessageDeleted`, `ChannelReactionAdded`, `ChannelReactionRemoved`.

**CRDT/server events (Phase 3):** `ServerCreated`, `ServerUpdated`, `ChannelAdded`, `ChannelRemoved`, `ChannelRenamed`, `ServerDeleted`, `MemberJoined`, `MemberLeft`, `SyncCompleted`, `ServerJoined`, `ServerJoinFailed`, `RoleChanged`.

**Sync events:** `MessageSyncStarted`, `MessageSyncCompleted`, `MessageSyncFailed`, `MessageSyncProgress`.

**Profile events (Phase 3.5):** `ProfileUpdated`.

**Friend events (Phase 3.5):** `FriendRequestReceived`, `FriendRequestAccepted`, `FriendRequestRejected`, `FriendRemoved`.

**Typing/presence:** `TypingStarted`, `PeerStatusChanged`.

**Pinned messages:** `MessagePinned`, `MessageUnpinned`.

**File transfer (Phase 3.5):** `FileHeaderReceived` (includes `video_thumb: Option<VideoThumbRef>`, `share_root_hash`, `share_key_hex`), `FileProgress`, `FileCompleted`, `FileFailed`.

**Vault shards (Phase 4):** `ShardStored`, `ShardStoreAckReceived`, `ShardStoreFailed`, `ShardDeleted`, `ShardReceived`, `ShardRequestFailed`.

**Vault pipeline (Phase 4):** `VaultUploadProgress`, `VaultUploadComplete`, `VaultUploadFailed`, `VaultDownloadProgress`, `VaultDownloadComplete`, `VaultDownloadFailed`, `VaultUploadReplicationFallback`.

**Vault rebalancing:** `RebalanceStarted`, `RebalanceProgress`, `RebalanceCompleted`.

**WebRTC (Phase 5A):** `WebRtcSignal` (peer_id, signal_type, payload, conn_id), `WebRtcSendFile` (peer_id, transfer_id, file_path, total_size, kind, shard_index, chunk_index).

**Voice calls (Phase 5B):** `CallSignal` (peer_id, signal_type, payload).

**Voice channels (Phase 5C):** `VoiceChannelJoined`, `VoiceChannelLeft`, `VoiceChannelSignal`.

**Gossip relay (Phase 5D):** `GossipConnect`, `GossipDisconnect`, `GossipRelayFile`, `VoiceChannelModeChanged`, `MlsEpochChanged`.

**Recovery pool:** `RecoveryPoolCreated`, `RecoveryPoolJoined`, `RecoveryPoolJoinFailed`, `RecoveryPoolMemberJoined`, `RecoveryPoolMemberLeft`, `RecoveryPoolStatus`, `RecoveryPoolShardTransferred`, `RecoveryPoolFileRecovered`, `RecoveryPoolStopped`.

**Hollow Share (Phase 7A):** `ShareManifestReady`, `ShareProgress`, `ShareCompleted`, `ShareFailed`, `ShareSeedingChanged`, `ShareCreated`, `ShareCreatedHidden`, `ShareList`, `ShareNeedWebRtc`.

**License/Twitch/Budget:** `LicenseError`, `TwitchJoinRejected`, `RoomBudgetUpdate`, `RoomCapHit`.

### DiscoveredPeer

FFI struct with `peer_id: String` and `addresses: Vec<String>`. Mirrors the internal peer discovery type.

### VideoThumbRef

FFI struct for video thumbnail back-references (Phase 6.75 video preview). Fields: `cid` (vault content_id of the video), `ext` (file extension), `name` (original filename), `size` (video bytes), `dur_ms` (duration in milliseconds). Has bidirectional `From` impl between `node::VideoThumbRef` and the FFI type.

### LinkPreviewRef

FFI struct for sender-side link previews (Phase 6.75). Fields: `url`, `title`, `description`, `domain`, `site_name`, `thumb_webp_b64: Option<String>` (base64 lossy WebP Q=50, max 400px), `thumb_w`, `thumb_h`. Has bidirectional `From` impl. Privacy invariant: receivers render from embedded data, never fetch the URL.

### ShareEntry

Lightweight FFI mirror of `node::types::ShareEntryRef`. Fields: `root_hash`, `file_name`, `total_size`, `chunks_have`, `chunks_total`, `state` (string), `seeding` (bool), `disk_path`, `bytes_uploaded`, `share_link`, `created_at` (i64 timestamp), `server_id`, `context_type`.

## Command Dispatch Pattern

Nearly all FFI functions that trigger node behavior follow the same pattern:

1. `get_node()` -> lock -> unwrap `NodeState` (error if node not running).
2. `get_runtime()` to get the Tokio runtime.
3. `rt.block_on(state.cmd_tx.send(node::NodeCommand::VariantName { ... }))` — sends a command through the mpsc channel to the swarm event loop.
4. Map send error to `String`.
5. Return `Ok(())`.

This is a synchronous blocking send from the FFI thread into the async event loop. The `block_on` only waits for the send to complete (channel has capacity 100), not for the command to be processed. Processing happens asynchronously in `swarm.rs:run_event_loop()`.

## set_license_key()

`network.rs:set_license_key(key: Option<String>)` -> `Result<(), String>`

Stores a license key into the `LICENSE_KEY` static. Must be called before `start_node()`. The key is passed to the WS relay client during connection for server-side validation.

## get_local_peer_id()

`network.rs:get_local_peer_id()` -> `Option<String>`

Returns the local peer ID (Base58btc) from `NodeState.local_peer_id`, or `None` if node not started. Simple lock + clone.

## get_olm_fingerprint()

`network.rs:get_olm_fingerprint()` -> `Option<String>`

Returns the Curve25519 identity key (base64) from `NodeState.olm_fingerprint`, or `None` if node not started. Used for peer verification UI.

## get_local_public_key()

`network.rs:get_local_public_key()` -> `Result<String, String>`

Loads the identity from disk (or creates it), extracts the Ed25519 public key, encodes it as base64 protobuf. Used by the Verify Peer screen to display "Your Fingerprint". Does NOT require the node to be running (loads identity independently).

## verify_message_proof()

`network.rs:verify_message_proof(sender_peer_id, signature_b64, public_key_b64, canonical_payload)` -> `bool`

Pure crypto function — no node state needed. Delegates to `crate::node::verify_message_signature()`. Used by the Message Proof dialog ("The RAT Files") for real-time VERIFIED/INVALID status display.

## fetch_link_preview()

`network.rs:fetch_link_preview(url: String)` -> `Result<LinkPreviewRef, String>`

Fetches OpenGraph metadata for a URL on the shared Tokio runtime via `rt.block_on(crate::node::link_preview::fetch_link_preview(&url))`. Sender-side only — privacy invariant. Converts internal type to FFI `LinkPreviewRef`. Caller should treat errors as "no preview available."

## Messaging Functions

### send_message()

`network.rs:send_message(peer_id, text, message_id, reply_to_mid, link_preview)` -> `Result<(), String>`

Sends `NodeCommand::SendMessage` for DM messages. The `link_preview` is converted from FFI to internal type via `Into::into`.

### send_channel_message()

`network.rs:send_channel_message(server_id, channel_id, text, message_id, reply_to_mid, link_preview)` -> `Result<(), String>`

Sends `NodeCommand::SendChannelMessage` for server channel messages.

### edit_channel_message()

`network.rs:edit_channel_message(server_id, channel_id, message_id, new_text)` -> `Result<(), String>`

Sends `NodeCommand::EditChannelMessage`. Broadcasts edit to all server members.

### edit_dm_message()

`network.rs:edit_dm_message(peer_id, message_id, new_text)` -> `Result<(), String>`

Sends `NodeCommand::EditDmMessage`.

### delete_channel_message()

`network.rs:delete_channel_message(server_id, channel_id, message_id)` -> `Result<(), String>`

Sends `NodeCommand::DeleteChannelMessage`. Message stays in DB (Rat Files evidence) but is hidden from UI.

### delete_dm_message()

`network.rs:delete_dm_message(peer_id, message_id)` -> `Result<(), String>`

Sends `NodeCommand::DeleteDmMessage`.

## Emoji Reactions

### add_channel_reaction() / remove_channel_reaction()

`network.rs:add_channel_reaction(server_id, channel_id, message_id, emoji)` -> `Result<(), String>`
`network.rs:remove_channel_reaction(server_id, channel_id, message_id, emoji)` -> `Result<(), String>`

Send `NodeCommand::AddChannelReaction` / `NodeCommand::RemoveChannelReaction`.

### add_dm_reaction() / remove_dm_reaction()

`network.rs:add_dm_reaction(peer_id, message_id, emoji)` -> `Result<(), String>`
`network.rs:remove_dm_reaction(peer_id, message_id, emoji)` -> `Result<(), String>`

Send `NodeCommand::AddDmReaction` / `NodeCommand::RemoveDmReaction`.

## Friend System

### send_friend_request()

`network.rs:send_friend_request(peer_id)` -> `Result<(), String>`

Sends `NodeCommand::SendFriendRequest`.

### accept_friend_request()

`network.rs:accept_friend_request(peer_id)` -> `Result<(), String>`

Sends `NodeCommand::AcceptFriendRequest`.

### reject_friend_request()

`network.rs:reject_friend_request(peer_id)` -> `Result<(), String>`

Sends `NodeCommand::RejectFriendRequest`.

### remove_friend()

`network.rs:remove_friend(peer_id)` -> `Result<(), String>`

Sends `NodeCommand::RemoveFriend`.

## Presence & Typing

### send_typing_indicator()

`network.rs:send_typing_indicator(server_id, channel_id)` -> `Result<(), String>`

Sends `NodeCommand::SendTypingIndicator`. For DMs: `server_id = ""`, `channel_id = peer_id`. For channels: both as normal. Ephemeral, not stored.

### set_invisible()

`network.rs:set_invisible(invisible: bool)` -> `Result<(), String>`

Sends `NodeCommand::SetInvisible`. Toggles invisible mode and broadcasts `StatusUpdate` to all connected peers.

## Sync & Room

### request_channel_sync()

`network.rs:request_channel_sync(server_id, channel_id)` -> `Result<(), String>`

Sends `NodeCommand::RequestChannelSync`. Called when user opens a channel to catch up on missed messages from all connected server members.

### join_room()

`network.rs:join_room(room_code: String)` -> `Result<(), String>`

Sends `NodeCommand::JoinRoom`. Registers addresses with the signaling service and bootstraps from other peers in the room. The room code is the server ID or a share hash — used as the WS relay room identifier.

## Profile

### update_profile()

`network.rs:update_profile(display_name, status, about_me, avatar_bytes, banner_bytes)` -> `Result<(), String>`

Sends `NodeCommand::UpdateProfile`. Saves to DB and broadcasts to all connected peers. Avatar and banner are optional raw byte arrays (processed before calling this function).

Note: the function has a duplicate `#[frb]` annotation above its doc comment (harmless, codegen ignores duplicates).

### process_avatar()

`network.rs:process_avatar(raw_bytes: Vec<u8>)` -> `Result<Vec<u8>, String>`

Synchronous image processing — converts raw bytes to 128x128 WebP via `crate::node::image_convert::process_avatar_image()`. No node state needed.

### process_banner()

`network.rs:process_banner(raw_bytes: Vec<u8>)` -> `Result<Vec<u8>, String>`

Synchronous image processing — converts raw bytes to 600x200 WebP via `crate::node::image_convert::process_banner_image()`. No node state needed.

## Shutdown

### notify_shutdown()

`network.rs:notify_shutdown()` -> `Result<(), String>`

Sends `NodeCommand::NotifyShutdown`. Notifies all connected peers of graceful shutdown so they can immediately update peer state (instead of waiting for timeout).

### stop_node()

`network.rs:stop_node()` -> `Result<(), String>`

1. Clears any unconsumed event receiver from `EVENT_RX`.
2. Takes the `NodeState` from `NODE` via `guard.take()`.
3. Calls `state.handle.abort()` to kill the event loop task.
4. Returns `Ok(())`.

Does NOT send a graceful shutdown command — `notify_shutdown()` should be called first. The abort is immediate.

## File Transfer FFI

### send_file()

`network.rs:send_file(peer_id, server_id, channel_id, file_path, message_id, message_text, vthumb, override_width, override_height, share_root_hash, share_key_hex)` -> `Result<(), String>`

Sends `NodeCommand::SendFile`. Handles both DM and channel file sends based on which IDs are provided (empty strings filtered to `None`). The `share_root_hash`/`share_key_hex` pair is reassembled into `Option<node::ShareRef>` for share-backed large files (>34 MB). `vthumb` is converted to internal `node::VideoThumbRef` for video thumbnail back-references. `override_width`/`override_height` are for video files where Dart passes pixel dimensions (Rust extracts these itself for images).

### request_file_from_peer()

`network.rs:request_file_from_peer(file_id, peer_id, chunks: Vec<u32>)` -> `Result<(), String>`

Sends `NodeCommand::RequestFile`. Requests specific file chunks from a peer.

### convert_image_format()

`network.rs:convert_image_format(source_path, target_format)` -> `Result<Vec<u8>, String>`

Synchronous. Reads the source file, converts from WebP to the target format (PNG/JPEG) via `crate::node::image_convert::convert_from_webp()`. Used for "Save As" functionality.

### get_files_dir()

`network.rs:get_files_dir()` -> `String`

Returns `~/.hollow/files/` path as a string. No node state needed.

## Logging

### log_from_dart()

`network.rs:log_from_dart(message: String)`

Writes a message from Dart into `hollow_debug.log` via `hollow_log!()`. Allows Dart-side diagnostics to appear in the same log file as Rust events. Visible in release builds.

## WebRTC FFI (Phase 5A)

All WebRTC signaling is mediated through Rust — Dart's WebRTC implementation calls these functions to coordinate with the swarm event loop.

### webrtc_peer_connected()

`network.rs:webrtc_peer_connected(peer_id)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcPeerConnected`. Notifies Rust that a WebRTC data channel is established with a peer.

### webrtc_peer_disconnected()

`network.rs:webrtc_peer_disconnected(peer_id)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcPeerDisconnected`. Notifies Rust that a WebRTC data channel has been closed.

### webrtc_send_signal()

`network.rs:webrtc_send_signal(peer_id, signal_type, payload, conn_id)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcSendSignal`. Dart calls this to send an SDP offer/answer or ICE candidate. Rust routes it through the WSS relay to the target peer. The `conn_id` disambiguates multiple simultaneous connections.

### webrtc_transfer_complete()

`network.rs:webrtc_transfer_complete(transfer_id, temp_path, sender_peer_id, kind, shard_index)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcTransferComplete` with `chunk_index: 0`. Receiver-side notification that a WebRTC file transfer finished. Rust decrypts and processes the received file.

### webrtc_share_chunk_complete()

`network.rs:webrtc_share_chunk_complete(transfer_id, temp_path, sender_peer_id, chunk_index)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcTransferComplete` with `kind: "share_chunk"` and `shard_index: 0`. Distinct from `webrtc_transfer_complete()` because share chunks need a 32-bit `chunk_index` (up to 4 billion chunks per share). Routes into the share handler verify+decrypt+write path.

### webrtc_send_complete()

`network.rs:webrtc_send_complete(transfer_id)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcSendComplete`. Sender-side notification that a file send finished. Rust cleans up the temp encrypted file.

### webrtc_transfer_failed()

`network.rs:webrtc_transfer_failed(transfer_id, peer_id, error)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcTransferFailed`. Triggers WSS relay fallback for the transfer.

## Voice Call FFI (Phase 5B)

### call_send_signal()

`network.rs:call_send_signal(peer_id, signal_type, payload)` -> `Result<(), String>`

Sends `NodeCommand::CallSendSignal`. Routes voice call signaling (SDP/ICE) through the WS relay for 1:1 calls.

## Voice Channel FFI (Phase 5C)

### voice_channel_join()

`network.rs:voice_channel_join(server_id, channel_id)` -> `Result<(), String>`

Sends `NodeCommand::VoiceChannelJoin`.

### voice_channel_leave()

`network.rs:voice_channel_leave(server_id, channel_id)` -> `Result<(), String>`

Sends `NodeCommand::VoiceChannelLeave`.

### voice_channel_send_signal()

`network.rs:voice_channel_send_signal(server_id, channel_id, peer_id, signal_type, payload)` -> `Result<(), String>`

Sends `NodeCommand::VoiceChannelSendSignal`. Routes SDP/ICE for mesh voice channels.

## Gossip Relay FFI (Phase 5D)

### webrtc_ping_report()

`network.rs:webrtc_ping_report(peer_id, rtt_ms: u32)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcPingReport`. Reports data channel keepalive RTT for gossip peer scoring. The gossip overlay uses RTT to rank peers for neighbor selection.

### webrtc_broadcast_received()

`network.rs:webrtc_broadcast_received(transfer_id, broadcast_id, ttl, origin_peer_id, sender_peer_id, temp_path, total_size, kind, shard_index)` -> `Result<(), String>`

Sends `NodeCommand::WebRtcBroadcastReceived`. Notifies Rust that a broadcast file was received via a gossip data channel. Rust processes the file and may re-broadcast to other gossip neighbors (decrementing TTL).

## Dart-Side Call Flow

The complete call chain from Dart UI to Rust processing:

1. **UI action** (e.g., user presses send button).
2. **Provider/service call** — Dart provider calls a method on `NetworkService` (thin wrapper in `network_service.dart`).
3. **Generated FFI binding** — `NetworkService` delegates to functions in `lib/src/rust/api/network.dart` (generated by `flutter_rust_bridge` codegen from the `#[frb]` annotations).
4. **FRB plumbing** — `lib/src/rust/frb_generated.dart` contains the actual platform channel/FFI calls that cross the Dart-Rust boundary.
5. **Rust FFI function** — The function in `api/network.rs` acquires the node lock, sends a `NodeCommand` variant through the mpsc channel.
6. **Swarm event loop** — `swarm.rs:run_event_loop()` receives the command, matches the variant, delegates to the appropriate handler module (`message_ops.rs`, `sync_handler.rs`, `file_handler.rs`, etc.).
7. **Response event** — The handler emits a `node::NetworkEvent` through `event_tx`.
8. **Event forwarding** — `event_forwarding_task` converts it via `to_ffi_event()` and pushes into the `StreamSink`.
9. **Dart stream** — `EventStreamNotifier._dispatch()` receives the `NetworkEvent`, pattern-matches it, and updates the appropriate Riverpod providers.

## Key Design Decisions

- **Separate EVENT_RX from NODE:** Allows `watch_network_events()` to take exclusive ownership of the receiver (via `.take()`) without keeping the NODE mutex locked during event forwarding.
- **block_on for sends:** FFI functions are synchronous from Dart's perspective (they return a Future that resolves when the Rust function returns). The `block_on` only waits for the mpsc send, not processing — so calls are effectively instant if the channel has capacity.
- **Single event channel:** All events from all subsystems (messaging, CRDT, vault, WebRTC, voice, share) flow through the same single `mpsc::Sender<NetworkEvent>` with capacity 100. This simplifies the FFI surface at the cost of head-of-line blocking if events aren't consumed fast enough.
- **Type duplication:** Every event and struct has two versions — internal (`node::`) and FFI (`api::network`). This is by design: the FFI types are constrained by what `flutter_rust_bridge` can translate, while internal types can use richer Rust features. The `to_ffi_event()` function and `From` impls bridge the gap.
- **OnceLock vs lazy_static:** Uses `std::sync::OnceLock` (stable since Rust 1.70) instead of `lazy_static!` for the global statics. More idiomatic, no external dependency.
