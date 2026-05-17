# Swarm Event Loop — Central Dispatcher

The event loop in `swarm.rs` (~6,200 lines) is the heart of the Rust backend. It owns all networking state, dispatches every inbound and outbound message, manages encryption sessions, coordinates timers, and bridges the Rust layer to the Dart UI via `StreamSink<NetworkEvent>`. Every other `node/` module is a stateless handler that borrows from the loop's state.

Source: `rust/hollow_core/src/node/swarm.rs`

## Entry Point: spawn_node()

`swarm.rs:spawn_node()` is the only public function (re-exported via `mod.rs`). It receives identity, crypto managers, and channel endpoints from the FFI layer, spawns background tasks, and returns the local peer ID + a `JoinHandle`.

**Initialization sequence:**
1. Clone `NativeKeypair` for signaling and event loop use.
2. Extract `peer_id_str` from the keypair (Ed25519 public key).
3. Spawn the signaling background task via `signaling::spawn_signaling_task()` — returns `(sig_cmd_tx, sig_event_rx)`.
4. Create the WS relay client via `ws_client::spawn_ws_client()` — connects to `wss://relay.anonlisten.com/ws`, returns `(ws_cmd_tx, ws_event_rx)`.
5. Spawn the main event loop as a Tokio task via `tokio::spawn(run_event_loop(...))`.
6. Return `(peer_id_str, handle)`.

Parameters received:
- `NativeKeypair` — Ed25519 identity for signing.
- `event_tx: mpsc::Sender<NetworkEvent>` — outbound to Dart via StreamSink.
- `cmd_rx / cmd_tx: mpsc::Receiver/Sender<NodeCommand>` — inbound from Dart FFI.
- `OlmManager` — vodozemac Olm encryption for DMs.
- `CryptoStore` — Olm session persistence.
- `license_key: Option<String>` — relay auth key.
- `initial_invisible: bool` — start in invisible mode.

## State Variables

The loop owns ~40 mutable state variables. They are NOT consolidated into a struct (deferred due to borrow checker constraints with crypto helpers that need field-level borrows). Each is passed individually to handler functions.

### Peer Tracking
- `ws_room_peers: HashMap<String, HashSet<String>>` — which peers are in which WS rooms. Key=room_code, Value=set of peer_id strings. Updated on PeerJoined/PeerLeft/RoomMembers/Disconnected.
- `synced_peers: HashSet<String>` — peers we have already triggered sync for this session. Prevents duplicate sync when both WS and signaling fire.
- `webrtc_peers: HashSet<String>` — peers with active WebRTC data channels. Updated via `NodeCommand::WebRtcPeerConnected/Disconnected`.
- `active_room: Option<String>` — the current DM room code.

### Encryption State
- `olm: OlmManager` — mutable Olm encryption manager for DM sessions.
- `mls: Option<MlsManager>` — MLS group encryption for servers. Created or restored from DB during init.
- `decrypt_fail_cooldown: HashMap<String, Instant>` — last session-kill time per peer. 5-second cooldown prevents rapid session thrashing when many in-flight chunks fail decrypt.
- `key_request_in_flight: HashSet<String>` — peers with active KeyRequest to avoid duplicates.
- `pending_messages: HashMap<String, Vec<String>>` — messages buffered while key exchange is in progress.
- `pending_mls_key_packages: HashMap<String, Vec<(String, Vec<u8>)>>` — KeyPackages queued for batch MLS addition.
- `mls_bootstrap_requested: HashSet<String>` — server_ids for which we already sent a KeyPackage to the owner.
- `mls_decrypt_failures: HashMap<String, u32>` — consecutive MLS decrypt failure counter per server. Triggers recovery after 3.

### CRDT / Server State
- `server_states: HashMap<String, ServerState>` — all server CRDT states, keyed by server_id. Loaded from SQLCipher on init, each auto-joins its WS relay room.
- `pending_server_joins: HashMap<String, Option<String>>` — server_ids we are trying to join. Value is optional Twitch proof JSON.
- `pending_sync_requests: HashMap<String, Vec<(String, String, i64)>>` — failed sync requests per peer, retried after session re-establishment.

### Sync Coordination
- `sync_coordinator: SyncCoordinator` — multi-peer fan-out sync. Collects connected peers for 500ms, then assigns channels evenly across them.
- `channel_sync_sent: HashMap<String, Instant>` — dedup for channel sync requests, prevents the same channel from being sync-requested multiple times within 5 seconds.

### File Transfer State
- `pending_file_streams: HashMap<String, PendingFileStream>` — files awaiting binary stream data. Key=file_id.
- `early_file_streams: HashMap<String, (PathBuf, u64, String)>` — WebRTC bytes that arrived before the FileHeader.
- `pending_shard_assembly: HashMap<String, PendingShardAssembly>` — chunked vault shard reassembly. Key="content_id:shard_index:sender_peer".
- `pending_shard_streams: HashMap<String, PendingShardStream>` — vault shards awaiting stream data.
- `pending_vault_downloads: HashMap<String, (String, usize, usize)>` ��� vault downloads waiting for remote shards.
- `pending_webrtc_sends: HashMap<String, (...)>` — pending WebRTC sends for retry on failure.
- `pending_ws_transfers: HashMap<String, WsTransferState>` — WS stream transfer reassembly state.

### Voice / Gossip State
- `voice_channel_participants: HashMap<String, HashSet<String>>` — key="server_id:channel_id", value=set of peer_ids in the voice channel.
- `voice_channel_gossip_mode: HashMap<String, bool>` — true=gossip, false=mesh per voice channel.
- `gossip_overlays: HashMap<String, GossipOverlay>` — gossip relay tree state per server room.

### Hollow Share State
- `share_registry: ShareRegistry` — registry of active share swarms.
- `seed_budget: SeedBudget` — process-wide outbound seed bandwidth bucket.
- `last_message_traffic: Instant` — coexistence: messaging/voice sends bump this; share scheduler pauses while recent.

### Other
- `recovery_pool_state: Option<RecoveryPoolState>` — evidence recovery pool state.
- `is_invisible: bool` — invisible mode flag.
- `profile_broadcast_done: bool` — whether first profile broadcast has been sent.
- `pending_friend_requests: HashMap<String, i64>` — queued friend requests for offline peers.

### Rate Limiting
- `peer_rate_tokens: HashMap<String, (u32, Instant)>` — per-peer token bucket (100 burst, 20/sec refill).
- `vc_signal_rate_tokens: HashMap<String, (u32, Instant)>` — tighter sub-limiter for VC signaling (30 burst, 10/sec).

## Main Loop Structure

`swarm.rs:run_event_loop()` runs a `loop { tokio::select! { ... } }` that multiplexes over these channels and timers:

```
loop {
    tokio::select! {
        Some(cmd) = cmd_rx.recv()          => { /* NodeCommand from Dart FFI */ }
        Some(sig) = sig_event_rx.recv()    => { /* SignalingEvent (bootstrap peers) */ }
        Some(ws)  = ws_event_rx.recv()     => { /* WsEvent from relay client */ }
        _ = mls_batch_timer.tick()         => { /* MLS batch KeyPackage processing */ }
        _ = rebootstrap_timer.tick()       => { /* Re-register with signaling (30s) */ }
        _ = sync_dispatch_timer.tick()     => { /* Fan-out sync coordinator (100ms) */ }
        _ = stream_progress_timer.tick()   => { /* File transfer progress poll (500ms) */ }
        _ = rebalance_timer.tick()         => { /* Vault rebalance + retention (30 min) */ }
        _ = rebalance_debounce.tick()      => { /* Event-driven vault rebalance (10s) */ }
        _ = gossip_rotation_timer.tick()   => { /* Gossip neighbor rotation (5 min) */ }
        _ = gossip_eviction_timer.tick()   => { /* Gossip dedup eviction (60s) */ }
        _ = gossip_exchange_timer.tick()   => { /* Gossip peer exchange (2 min) */ }
        _ = share_tick_timer.tick()        => { /* Share scheduler (50ms) */ }
    }
}
```

All timers consume their immediate first tick during initialization so they do not fire at time=0.

## NodeCommand Dispatch (Dart FFI to Rust)

`cmd_rx.recv()` receives `NodeCommand` variants from Dart. The loop matches each variant and delegates to the appropriate handler module. Pattern: `module::handle_*()`.

### Message Operations (message_ops)
- `SendMessage` -> `message_ops::handle_send_message()` — Olm-encrypted DM.
- `SendChannelMessage` -> `message_ops::handle_send_channel_message()` — MLS-encrypted channel message.
- `EditChannelMessage` -> `message_ops::handle_edit_channel_message()`
- `EditDmMessage` -> `message_ops::handle_edit_dm_message()`
- `DeleteChannelMessage` -> `message_ops::handle_delete_channel_message()`
- `DeleteDmMessage` -> `message_ops::handle_delete_dm_message()`
- `AddChannelReaction` / `AddDmReaction` -> `message_ops::handle_add_*_reaction()`
- `RemoveChannelReaction` / `RemoveDmReaction` -> `message_ops::handle_remove_*_reaction()`

### CRDT / Server Commands (sync_handler)
- `CreateServer` -> `sync_handler::handle_create_server()`
- `CreateChannel` / `RemoveChannel` / `RenameChannel` -> `sync_handler::handle_*_channel()`
- `RenameServer` / `DeleteServer` -> `sync_handler::handle_*_server()`
- `UpdateServerSetting` -> `sync_handler::handle_update_server_setting()`
- `JoinServer` -> `sync_handler::handle_join_server()`
- `ChangeRole` / `ChangeRolePermissions` -> `sync_handler::handle_change_role*()`
- `KickMember` / `BanMember` / `UnbanMember` -> `sync_handler::handle_*_member()`
- `LeaveServer` -> `sync_handler::handle_leave_server()`
- `CreateLabel` / `DeleteLabel` / `UpdateLabel` / `AssignLabel` / `UnassignLabel` -> `sync_handler::handle_label_op()` with appropriate `CrdtPayload` variant.
- `SetChannelVisibility` / `SetChannelPosting` -> `sync_handler::handle_set_channel_*()`
- `SetNickname` / `SetTwitchUsername` -> `sync_handler::handle_set_*()`
- `RequestChannelSync` -> `sync_handler::handle_request_channel_sync()`
- `UpdateChannelLayout` -> `sync_handler::handle_update_channel_layout()`
- `PinMessage` / `UnpinMessage` -> `sync_handler::handle_*_message()`
- `SetStoragePledge` -> `sync_handler::handle_set_storage_pledge()`
- `CheckPendingJoinTimeout` -> `sync_handler::handle_check_pending_join_timeout()`

### Social (social)
- `UpdateProfile` -> `social::handle_update_profile()`
- `SendFriendRequest` -> `social::handle_send_friend_request()`
- `AcceptFriendRequest` / `RejectFriendRequest` / `RemoveFriend` -> `social::handle_*_friend_request()`
- `SendTypingIndicator` -> `social::handle_send_typing_indicator()` (skipped if invisible)
- `SetInvisible` -> `social::handle_set_invisible()`

### Vault (vault_ops)
- `VaultUploadFile` / `VaultDownloadFile` / `DeleteVaultContent` -> `vault_ops::handle_vault_*()`
- `RequestShardFromPeer` / `StoreShardOnPeer` -> `vault_ops::handle_*_shard_*()`

### File Transfer (file_handler)
- `SendFile` -> `file_handler::handle_send_file()`
- `RequestFile` -> `file_handler::handle_request_file()`

### WebRTC (voice_handler / file_handler)
- `WebRtcPeerConnected` / `WebRtcPeerDisconnected` -> `voice_handler::handle_webrtc_peer_*()`
- `WebRtcSendSignal` -> `voice_handler::handle_webrtc_send_signal()`
- `WebRtcTransferComplete` -> `file_handler::handle_webrtc_transfer_complete()` or `share_handler::handle_webrtc_share_chunk_complete()` (if kind=="share_chunk")
- `WebRtcSendComplete` -> `file_handler::handle_webrtc_send_complete()`
- `WebRtcTransferFailed` -> `file_handler::handle_webrtc_transfer_failed()`
- `WebRtcPingReport` -> `voice_handler::handle_webrtc_ping_report()`
- `WebRtcBroadcastReceived` -> `gossip_relay::handle_webrtc_broadcast_received()`

### Voice Channels (voice_handler)
- `CallSendSignal` -> `voice_handler::handle_call_send_signal()`
- `VoiceChannelJoin` / `VoiceChannelLeave` -> `voice_handler::handle_voice_channel_*()`
- `VoiceChannelSendSignal` -> `voice_handler::handle_voice_channel_send_signal()`

### Hollow Share (share_handler)
- `ShareCreate` / `ShareCreateHidden` -> `share_handler::handle_command_share_create()`
- `ShareOpenLink` -> `share_handler::handle_command_share_open_link()`
- `ShareStart` / `ShareCancel` / `ShareSetSeeding` / `ShareRemove` / `ShareList` -> `share_handler::handle_command_share_*()`

### Other
- `JoinRoom` — sets active_room, joins WS relay room, registers with signaling.
- `NotifyShutdown` — unregisters from signaling for all rooms.

## WS Event Dispatch

`ws_event_rx.recv()` receives events from the WS relay client. The match arms:

### WsEvent::Connected
- Joins personal inbox room (`inbox:{peer_id}`).
- Auto-joins rooms for all known servers from `server_states`.
- Auto-joins DM rooms for all accepted friends from DB.
- Runs shard integrity verification (removes DB records for corrupt/missing shards).

### WsEvent::Disconnected
- Clears `ws_room_peers` entirely.
- Clears `synced_peers` — ensures full re-sync on reconnect (without this, peers skip sync because they're already in the set).
- Clears `key_request_in_flight` — allows fresh key exchange after reconnect.
- Clears `mls_bootstrap_requested` — allows MLS bootstrap retry.
- Drains `pending_messages` — stale queued messages from pre-disconnect.
- Cleans up in-progress WS stream transfers.

### WsEvent::PeerJoined { room, peer_id }
Critical path — triggers most of the sync machinery:
1. Adds peer to `ws_room_peers[room]`.
2. Recovery pool: sends inventory to peer if recovery room.
3. Share: broadcasts Have bitmap to peer if share room.
4. Triggers event-driven vault rebalance for server rooms.
5. Updates gossip overlay (adds known peer, maybe connects as neighbor).
6. If `synced_peers.insert(peer_id)` returns true (first time this session):
   - Sends own profile (with invisible flag).
   - Initiates Olm key exchange if no session exists.
   - If Olm session exists: emits SessionEstablished, drains pending_messages, flushes pending_sync_requests.
   - For each shared server: sends CRDT SyncReq (always plaintext — MLS epoch may be stale after reconnect), registers for channel sync via coordinator, requests MLS KeyPackage if coordinator.
   - Re-broadcasts voice channel joins to reconnecting peer.
   - Sends DmSyncRequest for DM history.
7. If room matches a pending server join: sends ServerJoinRequest.

### WsEvent::PeerLeft { room, peer_id }
1. Removes peer from `ws_room_peers[room]`.
2. Share: drops peer from peer_have + frees in-flight chunks.
3. Recovery pool: tracks member departure.
4. Triggers event-driven vault rebalance.
5. Updates gossip overlay (removes peer, picks replacement neighbor).
6. If peer no longer reachable via ANY room: removes from `synced_peers`, emits PeerDisconnected.

### WsEvent::RoomMembers { room, peers }
Fires when we join a room — provides the full member list. Similar to PeerJoined but for all members at once:
1. Replaces `ws_room_peers[room]` with the new set.
2. Initializes/updates gossip overlay if server has 6+ members.
3. On first RoomMembers event: broadcasts profile to all peers.
4. For each peer: same sync logic as PeerJoined (CRDT sync, channel sync registration, Olm session establishment, DM sync).

### WsEvent::Message / DirectMessage { room, from, data }
The main incoming message path:
1. Parses JSON as `HavenMessage`.
2. Rate limiting: token bucket check (100 burst, 20/sec per peer). Drop if rate-limited.
3. **Recovery interception:** if message is a Recovery* variant, handle inline and `continue`.
4. **Share interception:** if message is a Share* variant, dispatch to `share_handler::handle_envelope_share_*()` and `continue`.
5. Otherwise: passes to `handle_incoming_request()`.

### WsEvent::BinaryDirect { room, from, data }
Binary stream data. Passed to `ws_stream_transfer::ws_stream_receive()`. If complete, dispatches to `file_handler::handle_completed_stream()`.

### WsEvent::LicenseError / RoomBudgetUpdate / RoomCapHit
Forwarded directly to Dart as NetworkEvent variants.

## Incoming Message Dispatch: handle_incoming_request()

This ~3,600-line function handles all `HavenMessage` variants after WS delivery. It performs two layers of dispatch:

### Layer 1: Plaintext HavenMessage variants
These are handled directly in `handle_incoming_request()`:

**Crypto handshake:**
- `KeyRequest` — generates one-time key, responds with `KeyBundle`.
- `KeyBundle` — creates outbound Olm session, drains pending_messages.
- `Encrypted` — decrypts via Olm (PreKey or Normal message type), then falls through to Layer 2.

**CRDT sync (plaintext):**
- `SyncRequest` — computes delta from op_log, responds with `SyncResponse`.
- `SyncResponse` — merges incoming ops into server_state, handles pending server joins.
- `CrdtOpBroadcast` — validates permissions per-payload type, applies op, forwards to other members, emits specific NetworkEvent per payload.

**Server join flow:**
- `ServerJoinRequest` — ban check, Twitch verification, owner-online check, adds member via CRDT op, sends full state to joiner.
- `ServerJoinRejected` — removes from pending_server_joins, emits TwitchJoinRejected.
- `ServerDeleteBroadcast` — verifies sender is Owner, removes server state.
- `MemberKickBroadcast` — verifies sender has KICK_MEMBERS and outranks us, removes server state.

**Channel sync (plaintext):**
- `ChannelSyncRequest` — queries DB for messages since timestamp (per-sender or legacy), responds with `ChannelSyncBatch` via MLS or Olm.
- `ChannelSyncProbe` / `ChannelSyncProbeResponse` — lightweight probe/response for checking if sync is needed.
- `DmSyncRequest` — queries DB for DM messages since timestamp, responds with `DmSyncBatch` via Olm.

**MLS management:**
- `MlsChannelMessage` — base64-decodes, MLS-decrypts, then dispatches the inner `MessageEnvelope` (see Layer 2). If group unknown, sends KeyPackage to coordinator (lowest online peer) for bootstrap. After 3 consecutive decrypt failures, drops group and requests re-bootstrap.
- `MlsKeyPackage` — coordinator check (lowest online MLS member, **excluding the sender** — they don't have the group), cleans stale members, removes if already present (recovery re-add), queues for batch processing.
- `MlsWelcome` — joins MLS group from Welcome, then sends ChannelSyncRequest for channels with no messages.
- `MlsCommit` — processes commit to advance MLS epoch, emits MlsEpochChanged for SFrame rotation. On failure, drops group and requests re-bootstrap.
- `MlsKeyPackageRequest` — responds with own KeyPackage if not already in the group.

**Social:**
- `FriendRequest` / `FriendAccept` / `FriendReject` / `FriendRemove` — persists to DB, registers DM room with signaling, emits events.
- `TypingIndicator` — emits TypingStarted.
- `StatusUpdate` — emits PeerStatusChanged.
- `ProfileUpdate` — validates sizes, decodes avatar/banner base64, saves to DB, updates server member display names, emits ProfileUpdated.
- `PeerDisconnecting` ��� emits PeerDisconnected.

**File transfer:**
- `FileRequest` — reads file from disk, AES-encrypts, sends FileHeader + streams data.

### Layer 2: MessageEnvelope after decryption

After Olm decryption of `HavenMessage::Encrypted`, the plaintext is parsed as `MessageEnvelope`. This is also the inner dispatch for MLS-decrypted messages from `MlsChannelMessage`.

**Olm path (DMs + fallback):**
The Olm decryption result is matched against MessageEnvelope variants inline in `handle_incoming_request()`. Key variants:

- `ChannelMessage` — verifies server membership + signature, persists to DB (INSERT OR IGNORE dedup), emits ChannelMessageReceived.
- `DirectMessage` — verifies signature, persists to DB, emits MessageReceived.
- `ChannelSyncBatch` — persists messages with dedup, inserts file metadata, syncs reactions, handles pagination (has_more), emits MessageSyncProgress/Completed.
- `DmSyncBatch` — same pattern for DM sync batches.
- `EditMessage` / `DeleteMessage` — verifies sender owns the message, persists edit/hide, emits events.
- `AddReaction` / `RemoveReaction` — persists to DB, emits events.
- `FileHeader` — validates file size, saves metadata, registers pending stream if AES key present, handles early-arrival race.
- `FileChunk` — writes chunk to disk, updates DB, checks completion, assembles file.
- `ShardStore` / `ShardChunk` / `ShardStoreAck` — vault shard storage with chunked reassembly.
- `ShardRequest` / `ShardResponse` / `ShardResponseChunk` — vault shard retrieval.
- `ShardDelete` / `ShardProbe` / `ShardProbeResponse` — vault shard management.
- `VaultManifestBroadcast` — saves manifest to ContentStore.
- `ShardMigrate` — stores migrated shard.
- `SessionAck` — marks Olm session as bidirectional (ratchet upgraded).
- `CrdtOp` / `SyncReq` / `SyncResp` — Olm fallback for CRDT sync when MLS is unavailable.
- Voice channel SDP/ICE variants (Olm fallback) — forwarded to Dart as VoiceChannelSignal events.

**MLS path (server channels):**
After MLS decryption in the `MlsChannelMessage` handler, the inner envelope is matched and dispatched to extracted handler functions:

- `ChannelMessage` -> `message_ops::handle_envelope_channel_message()`
- `EditMessage` -> `message_ops::handle_envelope_edit_message()`
- `DeleteMessage` -> `message_ops::handle_envelope_delete_message()`
- `AddReaction` / `RemoveReaction` -> `message_ops::handle_envelope_*_reaction()`
- `FileHeader` -> `file_handler::handle_envelope_file_header()`
- `FileChunk` -> `file_handler::handle_envelope_file_chunk()`
- `CrdtOp` -> `sync_handler::handle_envelope_crdt_op()`
- `ServerDelete` -> `sync_handler::handle_envelope_server_delete()`
- `MemberKick` -> `sync_handler::handle_envelope_member_kick()`
- `Typing` -> `social::handle_envelope_typing()`
- `ProfileUpdate` -> `social::handle_envelope_profile_update()`
- `SyncReq` / `SyncResp` -> `sync_handler::handle_envelope_sync_*()`
- `ChannelSyncReq` -> `sync_handler::handle_envelope_channel_sync_req()`
- `ChannelProbe` / `ChannelProbeResp` -> `sync_handler::handle_envelope_channel_probe*()`
- `ChannelSyncBatch` -> `sync_handler::handle_envelope_channel_sync_batch()`
- `ShardStore` / `ShardChunk` / `ShardStoreAck` / `ShardDelete` / `ShardRequest` / `ShardResponse` / `ShardProbe` / `ShardProbeResponse` / `VaultManifestBroadcast` / `ShardMigrate` -> `vault_ops::handle_envelope_*()`
- Voice channel join/leave/SDP/ICE/audio/screen/camera state -> `voice_handler::handle_envelope_voice_channel_*()`
- `BroadcastMeta` -> `file_handler::handle_envelope_broadcast_meta()`

**MLS target filtering:** Before dispatching, the MLS path checks `envelope.target()`. If the envelope has a target peer and it is not us, it is silently discarded (the ratchet already advanced by decrypting).

**VC signal rate limiting:** Voice channel signal envelopes have a dedicated sub-rate-limiter check via `voice_handler::vc_rate_check()` before dispatch.

## Timer-Based Operations

### mls_batch_timer (2 seconds)
Two-phase processing per server:
1. **Batch removals** — drains `pending_mls_removals` queue (stale members + recovery re-adds), calls `remove_members_batch()` for a single commit, broadcasts commit to remaining members.
2. **Batch additions** — drains `pending_mls_key_packages` queue, deduplicates by peer_id, calls `add_members_batch()` for a single commit, sends Welcome to new members, broadcasts commit to existing members.
Result: N recovering peers = 2 total epoch advances instead of 2N.

### rebootstrap_timer (30 seconds)
Re-registers with the signaling server for all rooms (active_room + all server_ids) to discover new peers.

### sync_dispatch_timer (100ms)
Checks `SyncCoordinator` for servers that have passed the 500ms collection window. Dispatches channel sync probes across peers (fan-out pattern). Uses plaintext `ChannelSyncRequest` instead of MLS `ChannelProbe` for reliability after reconnection.

### stream_progress_timer (500ms)
Polls `ws_stream_transfer::stream_progress()` atomic counters and emits `FileProgress` events to Dart.

### rebalance_timer (30 minutes)
Full vault maintenance:
1. Updates last_seen for all connected server members.
2. File retention enforcement: deletes expired vault manifests and channel files per `retention_files` setting.
3. Message retention enforcement: prunes channel messages per `retention_messages` setting (default 365d). Forward-only — only deletes messages sent after the policy was set (`retention_messages_since` timestamp). Uses `prune_channel_messages_in_range()`.
4. Shard health: detects under-replicated content, computes repair plans, requests shards from online holders (coordinator-only).
5. Cache eviction: LRU eviction of vault cache (configurable cap, default 1 GB).

### rebalance_debounce (10 seconds)
Event-driven vault rebalance triggered by peer join/leave. Processes `rebalance_pending` set. Runs repair (under-replicated content) and migration (shift shards to new members) with coordinator gating.

### gossip_rotation_timer (5 minutes)
`gossip_relay::handle_gossip_rotation()` — rotates gossip overlay neighbors based on peer scores.

### gossip_eviction_timer (60 seconds)
`gossip_relay::handle_gossip_eviction()` — removes stale broadcast IDs from dedup sets.

### gossip_exchange_timer (2 minutes)
`gossip_relay::handle_gossip_exchange()` — shares neighbor lists with peers.

### share_tick_timer (50ms)
Drives Hollow Share scheduler. Chunk requests, Have rebroadcast every 10s, in-flight timeout/retry. Pauses chunk requests when `last_message_traffic` is recent (coexistence with messaging/voice).

## Signaling Events

`sig_event_rx.recv()` receives `SignalingEvent::BootstrapPeers` or `SignalingEvent::Error`. Bootstrap peers that are not already visible via WS relay trigger `PeerDiscovered` events.

## Coordination Between WS, WebRTC, and Gossip

The event loop coordinates all three transport layers:

**WS relay** is the primary transport. All messages flow through `ws_cmd_tx` (UnboundedSender to the WS client). Helper functions `send_message_to_peer()` and `send_mls_broadcast()` route messages via WS.

**WebRTC** is used for binary file/shard transfers and voice signaling. The loop tracks peers with active data channels in `webrtc_peers`. File/shard sends prefer WebRTC when available (`file_handler::stream_to_peer()` checks `webrtc_peers` first). WebRTC transfer lifecycle is managed through NodeCommand variants: `WebRtcTransferComplete`, `WebRtcSendComplete`, `WebRtcTransferFailed`.

**Gossip overlay** activates for servers with 6+ members. The loop maintains per-server `GossipOverlay` instances in `gossip_overlays`. Peer join/leave updates the overlay. File broadcasts use gossip for large server fan-out (`file_handler::broadcast_to_gossip_neighbors()`). Three timers maintain gossip health.

**Transport selection for sends:**
1. `send_message_to_peer()` finds the WS room containing the target peer and sends plaintext via WS `SendDirect`.
2. `send_encrypted_message()` Olm-encrypts and sends via WS `SendDirect` to a specific peer. Used for all targeted sends (shard requests, sync batches, file headers, voice signaling).
3. `send_mls_broadcast()` MLS-encrypts and sends via WS `SendToRoom` (all members receive). Used for group messages (channel messages, CRDT ops, profile updates).
4. `file_handler::stream_to_peer()` checks `webrtc_peers` first (sends via `NodeCommand` to Dart which drives WebRTC), falls back to WS stream transfer.

## Error Handling and Recovery

### Olm decrypt failure
1. Check cooldown (5s per peer) to prevent rapid session thrashing.
2. Remove stale session, persist state.
3. Emit `MessageSyncFailed` for all servers where the peer is a member (prevents UI stuck on "Syncing...").
4. Send `KeyRequest` to re-establish session.
5. Within cooldown window: silently drop the stale message.

### MLS decrypt failure
1. Increment per-server failure counter.
2. After 3 consecutive failures: drop the broken MLS group, send recovery KeyPackage to the coordinator (lowest online peer).
3. Reset counter on any successful decrypt.

### MLS group loss (auto-recovery)
Three paths detect and recover from a missing MLS group:
1. **MlsChannelMessage unknown group** — sends KeyPackage to coordinator (not owner).
2. **PeerJoined** — if we're missing a group for a shared server, sends KeyPackage to the joining peer.
3. **RoomMembers (startup)** — checks all shared servers, sends KeyPackage for any missing groups.

The KeyPackage handler excludes the sender from coordinator election (they sent it because they lost their group). Without this exclusion, the lowest-peer-ID member losing their group creates a deadlock.

### MLS commit failure
Drop stale local group, send KeyPackage to coordinator for re-bootstrap.

### WebRTC transfer failure
`file_handler::handle_webrtc_transfer_failed()` removes peer from `webrtc_peers`, falls back to WS stream for the pending send.

### WS disconnect
Clears `ws_room_peers`, `synced_peers`, `key_request_in_flight`, `mls_bootstrap_requested`, drains `pending_messages`, and cleans up in-progress WS transfers. The WS client auto-reconnects; on reconnect (`WsEvent::Connected`), rooms are re-joined and full sync is retriggered for all peers.

### MLS Welcome after join
After joining from Welcome, sends plaintext `ChannelSyncRequest` for channels with no messages (MLS epoch may be stale on responder, so MLS sync would silently fail).

## Dispatch Pattern Summary

The architecture follows a strict delegation pattern:
- `swarm.rs` owns all mutable state and the `select!` loop.
- `swarm.rs:handle_incoming_request()` handles plaintext HavenMessage dispatch and Olm decryption, with inline handling for crypto handshake and some message types.
- Domain-specific modules (`message_ops`, `sync_handler`, `file_handler`, `vault_ops`, `voice_handler`, `social`, `share_handler`, `gossip_relay`) export `pub(crate) async fn handle_*()` functions.
- Handler functions receive individual state variables as parameters (not a context struct).
- Both Olm and MLS paths converge on the same handler functions (e.g., `message_ops::handle_envelope_channel_message()` is called from both the Olm inline match and the MLS dispatch).
- Recovery/Share messages are intercepted before `handle_incoming_request()` in the WS event match and handled with `continue` to skip the general dispatcher.

## Helper Functions (in swarm.rs)

- `dm_room_code(a, b)` — deterministic DM room code from two peer IDs (lexicographic ordering).
- `SyncCoordinator` — struct for multi-peer fan-out sync coordination with 500ms collection window.

All other helper functions have been extracted to their respective modules (see comments at line ~2563):
- `send_message_to_peer` -> `crypto_handler`
- `send_own_profile_to_peer` -> `social`
- `handle_completed_stream`, `stream_to_peer`, `broadcast_to_gossip_neighbors` -> `file_handler`

## Security Enforcement in the Loop

The event loop enforces security at multiple levels:
- **Per-peer rate limiting** on all incoming WS messages (token bucket).
- **VC signal sub-rate-limiter** (tighter limits for voice signaling).
- **Server membership verification** before accepting channel messages, shard operations, CRDT ops.
- **Permission checks** on CrdtOpBroadcast — validates the AUTHOR's role per payload type.
- **Signature verification** on messages using `message_signing_payload()` + `verify_message_signature()`.
- **Message text truncation** to 4,000 characters.
- **Profile field truncation** (display_name 64, status 96, about_me 256 chars).
- **File size validation** against server limit (default 34 MB), skipped for share-backed files.
- **Emoji length limit** on reactions (10 characters).
- **Ban check** on ServerJoinRequest before any other verification.
- **Twitch proof validation** on server join with enriched rejection reasons.
- **Owner-only gating** for server deletion and Twitch owner-verify joins.
- **Outranking check** for kick/ban operations.
- **SDP size limit** (64 KB) on voice channel offers/answers.
