# Swarm Event Loop — Central Dispatcher

The event loop in `swarm.rs` (~6,200 lines) is the heart of the Rust backend. It owns all networking state, dispatches every inbound and outbound message, manages encryption sessions, coordinates timers, and bridges the Rust layer to the Dart UI via `StreamSink<NetworkEvent>`. Every other `node/` module is a stateless handler that borrows from the loop's state.

Source: `rust/hollow_core/src/node/swarm.rs`

## Entry Point: spawn_node()

`swarm.rs:spawn_node(native_keypair, device_keypair, …)` is the only public function (re-exported via `mod.rs`). It receives the MASTER + DEVICE identities, crypto managers, and channel endpoints from the FFI layer, spawns background tasks, and returns the MASTER peer ID + a `JoinHandle`.

**Multi-device key routing (Phase 6, locked):** the **device** keypair drives the WS relay auth + the signaling register ONLY (distinct relay socket per physical device); the **master** keypair (`native_keypair`) drives everything else — the event loop's `local_peer_str`, MLS/server membership, message-content signing, and the DB passphrase. Rooms are master-derived (`inbox:{master}`, `dm_room_code`→master, `server_id`), so a device authenticates as itself yet sits in its identity's rooms. On a pre-multi-device install device==master (migration keystone) so it's behavior-neutral. See `rust_storage_db.md` "Multi-Device Foundation" + `node/resolver.rs` header.

**Initialization sequence:**
1. Clone the MASTER keypair for the event loop; derive `master_peer_id` + `device_peer_id`.
2. Spawn the signaling background task via `signaling::spawn_signaling_task(device_keypair, device_peer_id, …)` (DEVICE-keyed register).
3. Create the WS relay client via `ws_client::spawn_ws_client(…, device_peer_id, device_proto, …)` — DEVICE-keyed auth; connects to `wss://relay.anonlisten.com/ws`.
4. Derive `db_path` (from the global `data_dir()`) + `db_passphrase` (hex of the master keypair's first 32 protobuf bytes) and spawn the main event loop via `tokio::spawn(run_event_loop(…, master_peer_id, device_peer_id, initial_invisible, db_path, db_passphrase))`. **`run_event_loop` takes `db_path`/`db_passphrase` as PARAMETERS** (it no longer derives them from the global `data_dir()` internally) — so the headless multi-node test harness can inject per-node temp DBs and run several nodes in one process without colliding on the one process-global default DB. Production passes the same derived values → behavior-neutral.
5. Return `(master_peer_id, handle)` — the app's "my peer id" is the master.

**Test seam (`#[cfg(test)] spawn_node_mock`):** a cfg(test) twin of `spawn_node` that SKIPS the real `spawn_ws_client` + `spawn_signaling_task` and instead returns the injected WS channel ends `(master_peer_id, JoinHandle, ws_cmd_rx, ws_event_tx)`, so the in-process `MockRelay` (`node/test_harness.rs`) can route between several nodes with no network/TLS/auth. Used by the multi-node integration harness (Step 9B-i). Production `spawn_node` is untouched. See `reports/MULTINODE_TEST_HARNESS_HANDOFF.md`.

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
- `guest_rooms: HashSet<String>` — WS rooms joined as a non-member for browsing public channels (guest sync).

### Encryption State
- `olm: OlmManager` — mutable Olm encryption manager for DM sessions.
- `mls: Option<MlsManager>` — MLS group encryption for servers. Created or restored from DB during init.
- `decrypt_fail_cooldown: HashMap<String, Instant>` — last session-kill time per peer. 5-second cooldown prevents rapid session thrashing when many in-flight chunks fail decrypt.
- `key_request_in_flight: HashMap<String, Instant>` — peers with an in-flight KeyRequest, timestamped. A bare `HashSet` (no timeout) previously stranded the flag forever when a handshake frame dropped (the relay never ACKs), so a session could never re-key without both peers restarting. Now mirrors `mls_bootstrap_requested`'s timestamped-retry idiom: guard with `key_request_is_fresh()` (`OLM_KEY_REQUEST_TIMEOUT` = 10s), not `.contains()`. A stale/absent entry allows a resend.
- `pending_messages: HashMap<String, Vec<String>>` — messages buffered while key exchange is in progress.
- `pending_mls_key_packages: HashMap<String, Vec<(String, Vec<u8>)>>` — KeyPackages queued for batch MLS addition.
- `mls_bootstrap_requested: HashSet<String>` — server_ids for which we already sent a KeyPackage to the owner.
- `mls_decrypt_failures: HashMap<String, u32>` — consecutive MLS decrypt failure counter per server. Triggers recovery after 3.
- `subscribed_channels: HashMap<String, Vec<String>>` — channels the Dart UI is subscribed to per server. Updated from `SubscribeChannels` command. Used to scope sync-on-decrypt-failure to only active channels.

### CRDT / Server State
- `server_states: HashMap<String, ServerState>` — all server CRDT states, keyed by server_id. Loaded from SQLCipher on init, each auto-joins its WS relay room.
- `pending_server_joins: HashMap<String, PendingJoin>`: joins in flight or parked, keyed by server_id. `PendingJoin` carries the Twitch proof, NSFW consent, the request nonce (`requested_at`), a `parked` flag, `last_deposited_at`, and our own signed `device_list` (see `rust_types.md` § PendingJoin). **Boot restore (pending joins rung 1):** at startup, every persisted row in state `"pending"` is loaded via `store.load_pending_joins()`, rebuilt with a freshly-built `device_list`, and inserted here with `parked: true` and NO 15s timer (a parked entry has already parked, so it waits indefinitely). Rows in state `"rejected"` deliberately get no RAM entry: they are a tile, not a join in flight. The room join itself happens later, in the `WsEvent::Connected` handler, same as every other room.
- `join_resolutions: HashMap<String, i64>` (pending joins rung 1): `"{server_id}|{master}"` maps to the newest `requested_at` this node has resolved or seen resolved. Written by the `ServerJoinRequest` arm on every verdict and by the `ServerJoinResolved` arm (max-wins), so a stale copy replayed out of the `~join` ring can never re-serve or undo a newer answer.
- `join_request_seen: HashMap<String, Instant>` (pending joins rung 1): `"{server_id}|{peer_str}"` maps to the last time we served a LIVE (non-parked) request from that device, gating the coordinator election to one responder unless the joiner's 4s retry fires (`JOIN_SERVE_RETRY_WINDOW` = 12s). A parked copy never touches this map.
- `awaiting_mls_after_parked_join: HashSet<String>` (pending joins rung 1): server_ids where the CRDT admission landed (a parked join completed) but the MLS leaf has not formed yet. Drives the "waiting for a member to finish setup" badge: inserted at CRDT completion (`PendingJoinUpdated{admitted}`), removed and `PendingJoinUpdated{ready}` emitted when `MlsWelcome` lands for that server. RAM only, so a restart between admitted and ready just drops the badge.
- `relay_catchup_done: HashSet<(String, String)>`: `(room, channel_or_topic)` pairs this CONNECTION has already requested `TopicCatchup` for; cleared on `WsEvent::Disconnected`. The join ring (`JOIN_TOPIC`) rides the same set, keyed `(server_id, "~join")`.
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
        _ = rebootstrap_timer.tick()       => { /* WS DiscoverPeers for all rooms + Olm sweep (30s) */ }
        _ = sync_dispatch_timer.tick()     => { /* Fan-out sync coordinator (100ms) */ }
        _ = stream_progress_timer.tick()   => { /* File transfer progress poll (500ms) */ }
        _ = rebalance_timer.tick()         => { /* Vault rebalance + retention (30 min) */ }
        _ = rebalance_debounce.tick()      => { /* Event-driven vault rebalance (10s) */ }
        _ = gossip_rotation_timer.tick()   => { /* Gossip neighbor rotation (5 min) */ }
        _ = gossip_eviction_timer.tick()   => { /* Gossip dedup eviction (60s) */ }
        _ = gossip_exchange_timer.tick()   => { /* Gossip peer exchange (2 min) */ }
        _ = share_tick_timer.tick()        => { /* Share scheduler (50ms) */ }
        _ = grant_sweep_timer.tick()       => { /* Temp channel-grant expiry sweep (30s prod, 2s cfg(test)) */ }
    }
}
```

All timers consume their immediate first tick during initialization so they do not fire at time=0.

**`grant_sweep_timer` (issue #32):** the grant predicate is LAZY (an expired grant already reads as denied); the sweep enacts consequences. A watermark (`grant_sweep_last_ms`, starts 0 so offline-expired grants reconcile once on the first tick) selects only (server, channel)s with a grant expiring inside `(last, now]`; each fires one `reconcile_subgroups_for_server(Some(cid))` (MLS leaf eviction), `auto_leave_invisible_voice_channels`, and a `ServerUpdated` so the expired member's own UI re-evaluates `me_can_see`.

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
- `SetChannelVisibility` / `SetChannelPosting` / `SetChannelPublic` -> `sync_handler::handle_set_channel_*()`
- `SetNickname` / `SetTwitchUsername` -> `sync_handler::handle_set_*()`
- `RequestPublicChannels` -> inline: if member, emit from local state; else join WS room as guest + broadcast `PublicChannelListRequest`.
- `RequestPublicChannelSync` -> inline: if member, serve from local DB; else broadcast `PublicChannelSyncRequest` to room.
- `LeaveGuestRoom` -> inline: remove from `guest_rooms`, send `WsCommand::LeaveRoom`.
- `RequestChannelSync` -> `sync_handler::handle_request_channel_sync()`
- `UpdateChannelLayout` -> `sync_handler::handle_update_channel_layout()`
- `PinMessage` / `UnpinMessage` -> `sync_handler::handle_*_message()`
- `SetStoragePledge` -> `sync_handler::handle_set_storage_pledge()`
- `RetryPendingJoin` -> `sync_handler::handle_retry_pending_join()` (4s; re-asks every room peer, which bypasses their coordinator gate)
- `CheckPendingJoinTimeout` -> `sync_handler::handle_check_pending_join_timeout()`: the live window elapsed (`only_if_empty` = the 3 s window, parks only if the room holds no other device; else 15 s); PARKS the join (deposits into the `~join` ring, emits `ServerJoinParked`), never fails it. `ServerJoinFailed` has no emitter anywhere any more.
- `DiscardPendingJoin { server_id }` -> `sync_handler::handle_discard_pending_join()` (pending joins rung 1): user gave up on a pending/rejected tile, drops the row, leaves the room, emits `PendingJoinUpdated{discarded}`.
- `RequestPendingJoinAgain { server_id }` (pending joins rung 1), inline in `swarm.rs`: loads the row via `crdt_store.load_pending_join()`, then re-runs `sync_handler::handle_join_server()` with the row's stored NSFW consent / Twitch proof and a FRESH nonce ("Request again" on a rejected tile).

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
   - Requests proxy profiles: for offline server members without cached profiles, sends `ProfileRequestFor` to this peer (max 10 per PeerJoined). Relayed profile includes avatar but no banner.
   - **Sibling server re-announce (2026-06-19):** if the joining peer is in our OWN inbox (`inbox:{master}` — only our own devices ever join it), RE-ANNOUNCE every non-deleted `server_states` entry to it via `SiblingServerAnnounce`/`SendDirect`. Closes the offline-reconnect gap (`SiblingServerAnnounce` is a one-shot live msg; a sibling offline at create/join never learned the server). Receiver is idempotent.
7. **OUTSIDE the `is_new` guard (runs every PeerJoined):** server-join request if `pending_server_joins.contains(room)`; the friend request/removal/accept drains (one-shot `.remove()`); and the **DM-room co-presence Olm re-key (2026-06-23):** if `!olm.has_session(peer_id) && room == dm_room_code(local_master, resolve(peer_id))`, send a fresh `KeyRequest` (bypassing the freshness gate) + set `key_request_in_flight`. THIS is the prompt heal for the friend-handshake Olm wedge — the friend-request inbox-leave can drop the accepter's KeyBundle (requester in no shared room yet) → one side never builds a session, the other defers forever (was only healed by the 30s sweep). Gated on `!has_session` (not `!has_confirmed_session`) so only the wedged/deferred side kicks. Siblings never join `dm_room_code(M,M)` → no sibling regression.

### WsEvent::PeerLeft { room, peer_id }
1. Removes peer from `ws_room_peers[room]`.
2. Share: drops peer from peer_have + frees in-flight chunks.
3. Recovery pool: tracks member departure.
4. Triggers event-driven vault rebalance.
5. Updates gossip overlay (removes peer, picks replacement neighbor).
6. If peer no longer reachable via ANY room: removes from `synced_peers`, emits PeerDisconnected.
7. **If the peer IS still listed in other rooms: re-joins those rooms** (`WsCommand::JoinRoom`) to refresh their membership snapshots — those entries may be STALE leftovers from the peer's earlier connection (the relay only sends PeerLeft for rooms a connection is currently in), and stale entries used to pin a quit peer "online" forever.

### WsEvent::RoomMembers { room, peers }
Fires when we join a room — provides the full member list. This is the relay's AUTHORITATIVE snapshot for the room. Similar to PeerJoined but for all members at once:
1. **Diffs the old room set against the new one** — peers that vanished are stale entries from a previous connection of theirs; for each, re-runs the global reachability check and emits `PeerDisconnected` (+ `synced_peers.remove`) if they're gone from every room. (Self-healing presence — generalizes what mobile resume rejoin did accidentally.)
2. Replaces `ws_room_peers[room]` with the new set.
3. Initializes/updates gossip overlay if server has 6+ members.
4. On first RoomMembers event: broadcasts profile to all peers.
5. For each peer: same sync logic as PeerJoined (CRDT sync, channel sync registration, Olm session establishment, DM sync).
6. **Sibling server re-announce (reconnecting side):** mirror of the PeerJoined re-announce. RoomMembers fires on the device that JUST reconnected and lists peers already present, so PeerJoined never fires for them here — without this branch, servers created/joined while WE were offline would never sync back. If a listed peer is in our `inbox:{master}`, re-announce every non-deleted server to it via `SiblingServerAnnounce`.
6b. **The `~join` ring (pending joins rung 1).** Read once per connection, by BOTH roles that need it: a MEMBER collects parked requests + other members' resolutions it missed, and a JOINER (not in `server_states` at all, so it cannot ride the per-server block above) collects the resolution addressed to it. Gated on `relay_catchup_secs() > 0 || pending_server_joins.contains_key(room)` and deduped through `relay_catchup_done.insert((room, JOIN_TOPIC))`; requests `WsCommand::TopicCatchup { max_age_secs: 0 }` (no watermark; unlike channel frames, an OLD join request is exactly the one to want). Members never SUBSCRIBE to `~join`: live joins stay unicast, the ring is read-by-catch-up only. Immediately after, a STILL-PARKED join of our own re-deposits its copy (`sync_handler::deposit_parked_join` + `upsert_pending_join`) but only once `now - last_deposited_at >= REDEPOSIT_INTERVAL_MS` (12h): the ring is 200 frames shared by every joiner of that server, so a joiner that flaps every minute would own the whole thing.
7. **OUTSIDE the `is_new` guard (2026-06-23) — REQUIRED twin of the PeerJoined out-of-guard block:** the friend request/removal/accept drains AND the DM-room co-presence Olm re-key (see PeerJoined #7). Both MUST be out of `is_new` because RoomMembers fires for a peer ALREADY present when WE join/reconnect → `is_new=false` for an already-synced peer. Two bugs this fixed: (a) a **re-add while online** never delivered (the queued FriendRequest drain was inside `is_new`, peer already in `synced_peers`); (b) the friend-handshake Olm wedge where the wedged side learns of the peer's DM-room entry via RoomMembers, not PeerJoined.

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
- `KeyRequest` — **authenticates the frame first** (`verify_key_exchange` + device-list check; unsigned is REFUSED, `REQUIRE_SIGNED_KEY_EXCHANGE` = true), then generates a one-time key and responds with a DEVICE-SIGNED `KeyBundle`. Authentication matters here specifically because this handler TEARS DOWN a working session — unsigned, it was a remote session-reset primitive against any peer. See `rust_crypto.md` → "Authenticated key exchange".
- `KeyBundle` — **verifies the DEVICE signature, recipient binding, freshness, and device-list membership before touching the ratchet** (this is the fix for the reported relay MITM — unauthenticated, the relay could substitute its own Curve25519 keys). Then creates the outbound Olm session and drains pending_messages. **Glare tiebreaker compares DEVICE ids:** when both peers sent each other a KeyBundle (each responding to the other's KeyRequest), only the lower-id peer creates the outbound session; the higher defers to the other's PreKey. The comparison is `device_peer_id > peer_str` (our DEVICE id vs the sender's DEVICE id — the relay reports device ids and Olm sessions live on sockets). It must NOT use the local MASTER (`local_peer_str`): master-vs-device is two unrelated strings, so under near-simultaneous delivery BOTH peers could satisfy `local > peer` and both defer → permanent deadlock until the 30s sweep. All `key_bundle_sent_to`/`key_request_in_flight`/KeyRequest targets are already device-keyed. (Fixed 2026-06-19; surfaced by the multi-node harness, also a latent multi-device production bug.)
- `Encrypted` — decrypts via Olm (PreKey or Normal message type), then falls through to Layer 2. **Every inbound death site on this path is sender-tagged logged (2026-08-08 — the fwd-signal blackhole was only diagnosable from log ABSENCE):** WS entry frames failing UTF-8/HavenMessage parse (these payloads are always HavenMessage JSON; binary chunks ride 0x02/BinaryDirect), base64-decode failures, PreKey-missing-identity-key, the prekey-with-existing fallthrough, the both-paths-failed PreKey drop (log UNGATED; only the re-key keeps the 5 s cooldown — a burst used to go completely dark), and a decrypted payload failing MessageEnvelope parse (which is silently MISROUTED into the legacy raw-text-DM fallback — version skew's signature; logged when the payload looks like JSON). Same treatment on both fetch.rs lanes; the MLS parse-fail log carries group + sender leaf. The VPS forwarder's logs stay identity-free BY DESIGN (zero-metadata doctrine).

**CRDT sync (plaintext):**
- `SyncRequest` — computes delta from op_log, responds with `SyncResponse`.
- `SyncResponse` — persists ALL incoming ops via `insert_crdt_op` (op_log is skip_serializing, so without this sync-merged history is RAM-only and lost on restart), merges via `merge_ops(&incoming_ops)`, handles pending server joins. Join completion also runs when `applied == 0` if a join is pending (a `ServerStateSnapshot` may already carry everything). The pending-join skeleton does NOT seed the responder as Owner (name reg zeroed, member/role seeds stripped; real name/owner come from `ServerCreated` in the op log). On completion: `crdt_store.delete_pending_join(server_id)`; **if the completed join was `parked`** (pending joins rung 1), emits `NetworkEvent::PendingJoinUpdated { server_id, state: "admitted", reason: "" }` BEFORE `ServerJoined` (so the pending tile turns INTO a server rather than blinking out) and inserts into `awaiting_mls_after_parked_join`: the join is real and browsable but the traffic is unreadable until the MLS leaf forms on next co-presence (`MlsWelcome`, above, fires the matching `"ready"`). After join completes: post-join proxy-profile backfill (`ProfileRequestFor` to the responder for offline members without cached profiles, cap 10).
- `ServerStateSnapshot` — full authoritative server state sent by the join responder BEFORE the op log (op logs compact at 1000 ops / can have pre-persistence history loss, so op replay alone can't reconstruct a server). SECURITY: only honored while `pending_server_joins` contains the server — an established member never lets a peer overwrite its state. Verifies `state.server_id` matches, re-keys the HLC, persists, inserts into `server_states`.
- `CrdtOpBroadcast`: validates permissions per-payload type AGAINST `op.author` (never the transport sender, since ops can be relayed); self-leave `MemberRemoved { peer_id == op.author }` always allowed; applies op, forwards to other members, emits specific NetworkEvent per payload. **The ingest body was extracted VERBATIM (2026-08-29) into `async fn apply_remote_crdt_op(..)`** so a `ServerJoinResolved` ring frame's carried `MemberAdded` op can never become a SECOND, weaker ingest path: it calls the same function this arm calls, gates included (`op_allowed` on the op's author, `insert_crdt_op`, the payload's own event, one re-flood).

**Server join flow (attribution + parked rules rewritten 2026-08-29 for pending joins rung 1):**

**2026-09-05 additions.** (1) The parked branch, after every gate and the `MemberJoined` emit, decodes the carried `key_package`, requires `MlsManager::key_package_identity(kp) == peer_str` (else a `[HOLLOW-SECURITY]` drop) and queues `(peer_str, kp)` into `pending_mls_key_packages[server_id]` when we hold the group or are the owner (lazy `create_group`); no group and not owner = the leaf waits for co-presence (logged). (2) Batch tick: phase 0 sweeps `mls_welcome_grace` (armed on `CommitApplyOutcome::Evicted`, cleared by a Welcome and on `Disconnected`; after `MLS_WELCOME_GRACE` 6 s with no group it requests one bootstrap and stamps the throttle); phase 2 addresses the Welcome for an UNREACHABLE device into the server room by name (`send_message_to_peer_in_room`) so the relay buffers it FIFO behind the snapshot and SyncResponse. (3) SyncResponse arm, join completion: a parked row that carried a package sends nothing and arms throttle + grace; otherwise the bootstrap KeyPackage (minted once) goes to `server_bootstrap_target` via `send_raw_to_identity` and stamps the throttle only when it reached a device, else raw to the responder unstamped. After a server-group Welcome that clears `awaiting_mls_after_parked_join`, `request_channel_catchups` is re-issued. (4) `ChannelSyncRequest`, `ChannelSyncProbe` and the `FileRequest` channel arm gate on `crypto_handler::channel_readable_by` (membership-or-public AND `can_see_channel`), a refusal returns; wiki `security_write_gates` section 7. (5) The `MemberAdded` and auto-pledge `CrdtOpBroadcast` twins are sent UNCONDITIONALLY alongside the MLS copy (the old `else` never reached a leaf-less member); content and ephemeral signals elsewhere use `crypto_handler::leafless_member_devices`.
- `ServerJoinRequest`: **ATTRIBUTION FIRST, before anything reads the joiner's identity.** A PARKED request is read out of a TTL ring by a member that has never been online with the joiner, so `resolver::resolve(sender_device)` hands the device straight back: every gate downstream (ban, private, cap, the `MemberAdded` key) would then be computed against a device id, not the joiner's master. So the request now CARRIES the joiner's own `device_list: Option<SignedDeviceList>`. When present: it must pass `verify_device_list` (sig + pubkey/master_peer_id binding) AND the relay-authenticated sender device must be listed in `devices` and NOT in `revoked`; a PRESENT-but-BAD list is a DROP with no fallback to the resolver (`if list.is_some()` must never be the bypass, mirrors the `FriendReject` carried-list rule). A valid list is ingested through `ingest_device_list()` (the same path every other carried list uses) and `member_master = list.master_peer_id`. An absent list (a pre-parked-joins client) falls back to `resolver::resolve(&peer_str)`, byte-for-byte the old behaviour, which only ever worked once the two had actually met.
  - `is_sibling` (a same-identity requester, exempt from the strangers-only gates below) is checked first.
  - **`parked` copies are held to stricter rules than a live one** (it was written into a shared ring, possibly days ago, read by whoever happens to come back): already-a-member gets a no-op (either already resolved, or the joiner's own live re-request on co-presence is the right rebuild path); `join_resolutions[{sid}|{master}] >= requested_at` skips it (somebody already answered this exact ask or a newer one, and the answer rides the SAME ring so every catch-up sees it before the request); on a Twitch-gated server it returns SILENTLY (the parked copy carries no proof by design, so it is not actionable: no reject, no ring write, the joiner's live re-request on co-presence carries the proof and runs today's gate unchanged).
  - **`!parked` (live) copies** run the **COORDINATOR GATE**: gated on `crypto_handler::elect_server_coordinator` over the CRDT members minus the joiner, UNLESS this is a REPEAT ask inside `JOIN_SERVE_RETRY_WINDOW` (12s, tracked in `join_request_seen`, keyed by device; parked copies never touch this map), in which case every member serves (that is the joiner's 4s `RetryPendingJoin` escalating, and it rescues a join whose elected coordinator's socket died). Siblings are never gated.
  - **Ban / Twitch / owner-verify gates now key on `member_master`, not the raw sender string.** The old device-keyed ban check would have let a never-met banned stranger straight through on the parked path. Each early-`return`s via `sync_handler::send_join_rejection` with a prefixed reason.
  - INSIDE `if !already_member`: **private gate** (`state.is_private()` -> `server_private:{name}`) then **NSFW consent gate** (`state.is_nsfw() && !nsfw_confirmed` -> `nsfw_confirm:{name}`, a QUESTION not a rejection, see `is_interactive_reason`) then **member-cap gate** (`server_full:{name}:{max}`). On success: `MemberAdded` op authored and applied (display name from the master id), persisted, broadcast MLS-first with the plaintext `CrdtOpBroadcast` fallback (this site is one of the eight `feedback_mls_first_fallback_dead_targets` sweep candidates still using the `if !mls_sent` shape; covered here because the ring resolution's `op_json` is the actual convergence path for an absent joiner).
  - Snapshot, `SyncResponse` and every reject now go via `send_message_to_peer_in_room(server_id, joiner_device)`, the DETERMINISTIC server room, never a presence lookup, so the relay buffers them for an absent (parked) joiner and replays on their next join of that room. That buffered pair is how a parked join completes with nobody online.
  - Every final verdict (reject or admit) publishes `ServerJoinResolved` into the ring via `sync_handler::publish_join_resolution` when `requested_at != 0 && catchup_secs > 0` (admissions carry the `MemberAdded` op JSON so a member that was offline for the whole exchange still converges), EXCEPT interactive reasons (`nsfw_confirm:`/`twitch_required:`), which are questions and are never written into the ring.
- `ServerJoinResolved` (`join_resolved`, pending joins rung 1): a member's answer to a join, read out of the `~join` ring. **Joiner half runs FIRST:** if `pending_server_joins` holds this `server_id` and `joiner_master == local_peer_str && requested_at == pending.requested_at` (exact-nonce match, so a copy replayed out of a three-day ring can never resolve a request made afterwards): `admitted` is a no-op (the buffered snapshot/SyncResponse is what completes us; if the relay dropped them, the next live co-presence rejoin does); `!admitted` routes through `sync_handler::handle_join_refused` (the SAME landing pad as a targeted `ServerJoinRejected`, so the two legs of one answer can never diverge: an interactive reason should be unreachable here by construction, but routing through the shared handler means a hostile member forging one only costs a dismissible dialog, not a poisoned tile). **Member half:** requires we hold `server_states[server_id]` AND `resolver::resolve(sender)` is a CURRENT CRDT member (anyone in the room can publish on the topic; only a member can resolve anything). Records max-wins into `join_resolutions`, then ingests the carried `op_json` through `apply_remote_crdt_op` (see below), never a second, weaker apply.
- `ServerJoinRejected`: dedups the rejection popup: a join request reaches EVERY online member, so each may send its own refusal, and only the FIRST for an in-flight join is acted on. **NONCE GUARD (2026-08-29):** this frame now rides the deterministic server room (buffered and replayed on the joiner's next room join, normally the user asking AGAIN), so `requested_at != 0 && requested_at != pending.requested_at` is ignored outright (a copy naming an older ask must not touch a newer one); `0` means a pre-parked-joins peer, "refuse whatever is pending". Routes through the same `sync_handler::handle_join_refused` as the ring path.
- `ServerDeleteBroadcast` — verifies sender is Owner, removes server state.
- `MemberKickBroadcast` — verifies sender has KICK_MEMBERS and outranks us, removes server state.
- `SiblingServerAnnounce { server_id }` — (multi-device) one of OUR OWN devices is telling us to onboard a server. `same_identity` only. Returns early if already-`pending_server_joins` or tombstoned. **Otherwise ALWAYS runs the inline join flow — even if we ALREADY hold the server** (deliberate, 2026-06-19; the previous `contains_key`→`ServerUpdated` nudge was unreliable at refreshing the UI list). The join completes with 0 new ops when pending (`applied > 0 || pending_server_joins.contains_key`) and fires `NetworkEvent::ServerJoined` → Dart `onServerCreated` (UNCONDITIONAL list insert). The responder's same-identity `ServerJoinRequest` fast-path re-serves the snapshot idempotently; MLS is not re-keyed. Logs `running join flow (have_it=…)`.
- `SiblingStateSyncRequest` — (multi-device MANUAL sync, Security→Your Devices "Sync from this device") `same_identity` only. The SOURCE responds by announcing every non-deleted server via `SiblingServerAnnounce` (drives the requester's join flow above) + re-sharing its friend list via `FriendListSync`. Servers + friends only. Triggered by the requester's `NodeCommand::RequestStateSync { source_device_id }` (FFI `request_state_sync`), which targets the source via `inbox:{master}` (fallback: any room listing it). Logs `Manual state-sync from …: announced N server(s) + M friend(s)`.

**Channel sync (plaintext):**
- `ChannelSyncRequest` — queries DB for messages since timestamp (per-sender or legacy), responds with `ChannelSyncBatch` via MLS or Olm.
- `ChannelSyncProbe` / `ChannelSyncProbeResponse` — lightweight probe/response for checking if sync is needed.
- `DmSyncRequest { since_timestamp, both_directions }` — (friend↔friend) responds with `DmSyncBatch` via Olm. Item packing factored into `build_dm_sync_items()` (reactions + file-meta batch joins), shared with the sibling responder below. **Multi-device PEER-FALLBACK (Step 5 second half, 2026-06-18):** `both_directions` (`#[serde(default)]`) is set by a MULTI-DEVICE requester (`!resolver::devices_for(local_master).is_empty()`); when set, the responder serves `get_dm_messages_for_sibling(convo, since, 200)` (BOTH directions) instead of `get_dm_messages_since` (`is_mine=1`-only). This lets a friend re-serve the requester's OWN messages that were sent from another (now-offline) device — otherwise stranded (the sibling backfill below needs the sibling ONLINE). Decision lives on the REQUESTER (always knows it's multi-device; the responder may not have ingested the requester's device list — cold-start race). Set at all THREE DM-sync triggers (PeerJoined, RoomMembers, `DmSyncBatch` pagination follow-up) with the high-water from `get_latest_dm_timestamp_any()` (both directions) instead of `get_latest_dm_timestamp()` (`is_mine=0`-only). **`DmSyncBatch` receiver — `mine` is RESPONDER-RELATIVE:** `DmSyncItem.mine` is `is_mine` in the SENDER's DB. From a FRIEND it's the OPPOSITE of ours (their sent = our received), so the receiver computes `is_mine = if same_identity(sender) { msg.mine } else { !msg.mine }` and uses it for BOTH the insert AND the per-direction sig-verify context. (The pre-both-directions path hardcoded the insert to `false` and only ever got the friend's own sends → implicitly `!mine` for that single case; this generalizes it.) Single-device + normal single-device friends never set the flag → byte-for-byte unchanged. NO FFI/codegen.
- `DmSiblingSyncRequest` — (multi-device Step 5, sibling DM offline-gap backfill) honored ONLY from a `same_identity` sender (a FRIEND must never pull our whole DB). Carries `per_convo_since: Vec<(friend_master, latest_ts)>`. Enumerates `get_dm_peer_ids()` and serves one `DmSiblingSyncBatch` per conversation via `get_dm_messages_for_sibling(convo, since, 200)` — **BOTH directions** (a sibling needs the friend's half too; `get_dm_messages_since` is `is_mine=1`-only). `DmSiblingSyncBatch` receiver files under `convo` (the FRIEND master, NOT `resolve(sender)`=our own master since the sender is our sibling), preserves `is_mine` direction, verifies the ORIGINAL sig context per direction (sigs never involve device ids → validate intact), emits `MessageReceived { is_own: msg.mine }`. Triggered from BOTH sibling-detection paths (swarm.rs inbox-proof AND `crypto_handler::ingest_sibling_device_list`) with our per-convo high-water from `get_latest_dm_timestamp_any()` (MAX ts, no is_mine filter); idempotent (message_id dedup), so the redundant double-fire is harmless. NO FFI/codegen.

**MLS management:**
- `MlsChannelMessage` — base64-decodes, MLS-decrypts, then dispatches the inner `MessageEnvelope` (see Layer 2). If group unknown, sends KeyPackage to coordinator (lowest online peer) for bootstrap. After 3 consecutive decrypt failures, drops group and requests re-bootstrap — but **only if those failures are SUSTAINED and no epoch probe is outstanding** (2026-08-27). `mls_decrypt_failures` carries `(count, first_failure_at)`: the drop also needs `MLS_DECRYPT_FAIL_WINDOW` (3s) elapsed, plus no `{group}|probe` cooldown entry younger than `EPOCH_PROBE_GRACE` (5s). Without those a rejoining member nuked its own group before it could be healed cheaply: the relay's availability cache replays every buffered channel frame AT ONCE, so three undecryptable frames land in the same millisecond, before the first `SyncRequest` carrying an epoch hint has even arrived. The log signature was `Sent epoch probe` → 3× `Decrypt failed` → `initiating MLS recovery` → `Ignoring MlsCommitCatchup for group we don't hold`. A burst is ONE event, not three.
- `MlsKeyPackage` — coordinator check (lowest online MLS member, **excluding the sender** — they don't have the group), cleans stale members, removes if already present (recovery re-add), queues for batch processing.
- `MlsWelcome` — joins MLS group from Welcome, then sends ChannelSyncRequest for channels with no messages. **Pending joins rung 1:** if `awaiting_mls_after_parked_join.remove(&server_id)` succeeds (a parked join had already completed its CRDT half here and was only waiting for the leaf), emits `NetworkEvent::PendingJoinUpdated { server_id, state: "ready", reason: "" }`, the badge-clearing counterpart of the `"admitted"` event fired earlier when the CRDT admission landed.
- `MlsCommit` — processes commit to advance MLS epoch, emits MlsEpochChanged for SFrame rotation. On failure, drops group and requests re-bootstrap.
- `MlsKeyPackageRequest` — responds with own KeyPackage if not already in the group.

**Social:**
- `FriendRequest` / `FriendAccept` / `FriendReject` / `FriendRemove` — persists to DB, registers DM room with signaling, emits events.
- `TypingIndicator` — emits TypingStarted.
- `StatusUpdate` — emits PeerStatusChanged.
- `ProfileUpdate` — validates sizes, decodes avatar/banner base64, saves to DB, updates server member display names, emits ProfileUpdated.
- `ProfileRequest` — sends own profile via `social::send_own_profile_to_peer()`.
- `ProfileRequestFor { target_peer_id }` — delegates to `social::handle_profile_request_for()` (looks up target's cached profile, sends back as ProfileRelay).
- `ProfileRelay` — delegates to `social::handle_profile_relay()` (saves profile + avatar with timestamp check, emits ProfileUpdated).
- `PeerDisconnecting` — emits PeerDisconnected.

**Public channel messages (plaintext, no MLS):**
- `PublicChannelMessage` / `PublicChannelEdit` / `PublicChannelDelete` / `PublicChannelAddReaction` / `PublicChannelRemoveReaction` — skip-if-self, delegate to existing `message_ops::handle_envelope_*()` functions. Broadcast via SendToRoom (received by members AND guests).

**Guest sync (public channels):**
- `PublicChannelListRequest` — member responds with `PublicChannelListResponse` listing public text channels. Uses `send_message_to_peer()` for targeted response.
- `PublicChannelListResponse` — guest-side: guards with `guest_rooms.contains()`, emits `PublicChannelListReceived`.
- `PublicChannelSyncRequest` — member verifies `is_channel_public()`, rate-limits via `channel_sync_sent`, serves 50-msg paginated history with reactions + file metadata. Targeted response.
- `PublicChannelSyncResponse` — guest-side: converts `SyncMessageItem` to `GuestSyncMessageFfi`, emits `PublicChannelSyncReceived`.

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
1. **Batch removals** — drains `pending_mls_removals` queue (stale members + recovery re-adds), calls `remove_members_batch()` for a single commit.
2. **Batch additions** — drains `pending_mls_key_packages` queue, deduplicates by peer_id, calls `add_members_batch()` for a single commit, sends Welcome to new members (targeted `SendDirect` per joiner — each Welcome carries the ratchet tree).
Result: N recovering peers = 2 total epoch advances instead of 2N.

**Commit fan-out (Tier 1 large-server scaling, 2026-07-06):** both phases broadcast the commit as ONE `SendToRoom` frame via `crypto_handler::broadcast_mls_commit()` — never a per-device `SendDirect` loop (commit bytes are identical for every recipient; the relay fans out). The wire `MlsCommit` carries a `#[serde(default)] epoch` (POST-merge): receivers at/past that epoch SKIP processing instead of erroring into the drop-group + re-bootstrap path (a room broadcast also lands on fresh Welcome joiners and duplicates). Kick/leave/ban and `remove_identity_from_subgroups` use the same helper; commit-path `fan_to_own_siblings` was removed (siblings are in the room). See `reports/LARGE_SERVER_SCALING_2026.md` §7.

### rebootstrap_timer (30 seconds)
Sends `WsCommand::DiscoverPeers` for the active DM room + all server rooms — WS-native peer discovery over the live socket (the HTTP signaling task this used to re-register with was RETIRED 2026-07; the relay answers `discovered_peers` from its live room map). Also hosts the Olm session reconciliation sweep.

### turn_refresh_timer (50 minutes)
Sends `WsCommand::GetTurnCredentials` so long-lived sessions refresh TURN credentials (1h TTL) before expiry. A fresh set is also requested on every `WsEvent::Connected`; the resulting `WsEvent::TurnCredentials` is forwarded to Dart as `NetworkEvent::TurnCredentials` → `iceConfigProvider`.

### mls_persist_timer (2 seconds)
Flushes `mls_dirty` (RECEIVE-path MLS ratchet changes) via `persist_mls_state`. Receive-only by design: a regressed receive ratchet can ratchet forward after a crash, but SEND-path encrypts persist immediately inside `send_mls_broadcast*` (persist-on-encrypt rule — a send-side debounce was tried 2026-07 and wedged live messages with `TooDistantInThePast`; do not retry).

### sync_dispatch_timer (100ms)
Checks `SyncCoordinator` for servers that have passed the 500ms collection window. Dispatches channel sync probes across peers (fan-out pattern). Uses plaintext `ChannelSyncRequest` instead of MLS `ChannelProbe` for reliability after reconnection.

### stream_progress_timer (500ms)
Polls `ws_stream_transfer::stream_progress()` atomic counters and emits `FileProgress` events to Dart.

### rebalance_timer (30 minutes)
Full vault maintenance:
1. Updates last_seen for all connected server members.
2. File retention enforcement: deletes expired vault manifests and channel files per `retention_files` setting.
3. Message retention enforcement: prunes channel messages per `retention_messages` setting (absent = permanent since 2026-09-05; files stay 365d). Forward-only — only deletes messages sent after the policy was set (`retention_messages_since` timestamp). Uses `prune_channel_messages_in_range()`.
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

## Signaling Events — REMOVED (2026-07)

The `sig_event_rx` select arm and the whole HTTP signaling task are gone (see `rust_networking.md` → "HTTP Signaling — RETIRED"). `PeerDiscovered` now comes from the WS `DiscoveredPeers` handler.

## Off-Loop CPU Re-entry Commands (internal, never from FFI)

Two CPU-heavy send paths hop off the event loop via `spawn_blocking` and RE-ENTER through `cmd_tx` so the dispatcher keeps processing messages/CRDT/call signaling meanwhile:

- `NodeCommand::SendFileConverted(Box<SendFileConvertedPayload>)` — image WebP/GIF conversion result; `handle_send_file` offloads convertible images, `finish_send_file` resumes at the store/fan-out steps (non-image files go straight through inline).
- `NodeCommand::VaultUploadPrepared(Box<VaultUploadPreparedPayload>)` — Reed-Solomon encode + local shard writes done on the blocking pool; `handle_vault_upload_prepared` resumes distribution/manifest broadcast. Failures emit `FileFailed`/`VaultUploadFailed` from the spawned task directly.

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

### Olm session establishment self-heal
The relay never ACKs a direct message, so a dropped KeyRequest/KeyBundle/SessionAck/PreKey would strand the handshake (recoverable only by both peers restarting). Hardening:
- **Confirmed vs unconfirmed sessions** — `OlmManager` exposes `has_confirmed_session()` (inbound-derived, or outbound that the peer acknowledged via SessionAck / a decrypted reply that cleared `outbound_only`) and `has_unconfirmed_session()`. `SessionEstablished` is emitted ONLY on real confirmation (SessionAck received at the `MessageEnvelope::SessionAck` arm, or a successful normal-decrypt that flips an unconfirmed session) — never optimistically on outbound-session creation. Optimistic emit was the "A sends, B never sees it" bug.
- **Reconciliation sweep** — in the 30s `rebootstrap_timer`, for every online peer (in `ws_room_peers`, gated to shared-server members / **accepted friends (2026-06-23)** / peers with queued DMs / half-built sessions) lacking a confirmed session whose `key_request_in_flight` entry is stale, resend `KeyRequest`. The `is_friend` term (built once per sweep from `load_friends(Some("accepted"))`, matched via `resolve(peer)`) is the BACKSTOP for the friend-handshake Olm wedge — the deferred side holds NO session (absent, not unconfirmed → `half_session` false), so without `is_friend` a wedged friend with no queued DM was never swept. The prompt heal is the DM-room co-presence re-key (PeerJoined/RoomMembers); this guarantees EVENTUAL convergence. Converts "wedged until restart" into "self-heals within ~30s" (and now within seconds via the co-presence re-key).
- **KeyRequest against an existing session** — no longer silently ignored: if the session is unconfirmed or the peer re-requests, tear down + re-bundle (gated by the 5s `decrypt_fail_cooldown`).
- **Glare defer** (higher peer) REFRESHES its in-flight timestamp instead of clearing it, so a dropped low-peer PreKey self-heals via the sweep.
- **Prune** (`prune_stale_sessions`) returns pruned peer IDs; the caller clears their `key_request_in_flight` + `decrypt_fail_cooldown`.

### MLS decrypt failure
1. **Immediate sync from sender** — request `ChannelSyncRequest` for all subscribed channels from the peer who sent the undecryptable message (5s dedup). Recovers the dropped message before the sender's next successful message advances per-sender timestamps past the gap.
2. Increment per-server failure counter.
3. After 3 consecutive failures: drop the broken MLS group, send recovery KeyPackage to the coordinator (lowest online peer).
4. Reset counter on any successful decrypt.

### MLS recovery after Welcome
After joining from Welcome, sync ALL channels from the coordinator (not just empty ones). Messages dropped during the stale epoch left gaps even in channels with existing history. The coordinator also requests sync FROM each recovered peer after batch-add, so both sides recover.

### MLS group loss (auto-recovery)
Three paths detect and recover from a missing MLS group:
1. **MlsChannelMessage unknown group** — sends KeyPackage to coordinator (not owner).
2. **PeerJoined** — if we're missing a group for a shared server, sends KeyPackage to the joining peer.
3. **RoomMembers (startup)** — checks all shared servers, sends KeyPackage for any missing groups.

The KeyPackage handler excludes the sender from coordinator election (they sent it because they lost their group). Without this exclusion, the lowest-peer-ID member losing their group creates a deadlock.

### MLS commit failure
Drop stale local group, send KeyPackage to coordinator for re-bootstrap.

### WebRTC transfer failure
`file_handler::handle_webrtc_transfer_failed()` removes peer from `webrtc_peers`, falls back to WS stream for the pending send. Also serves as the receiver-side re-request path: the Dart flush-verify (short on-disk file after `sink.close()`) and the Rust decrypt-failure auto-retry both route here / through `FileRequest`. See `rust_file_handler.md` → Decrypt-failure auto-retry.

### Peer discovery (WS-based, replaces HTTP /bootstrap)
Primary peer discovery rides the LIVE WS connection, not the HTTP `/bootstrap` poll (which paid a fresh TLS handshake per request and could stall under a WS frame burst on the relay's single event loop). The `rebootstrap_timer` sends `WsCommand::DiscoverPeers { room }` for the active room + each server; the relay responds with `discovered_peers` (the room's `ws_rooms` peer set). `WsEvent::DiscoveredPeers` populates `ws_room_peers` and key-exchanges with any peer lacking a confirmed session (reusing the sweep's freshness guard). HTTP bootstrap is kept as a non-fatal fallback — its failures are logged quietly, never surfaced as `NetworkEvent::Error`. The relay's `members`-on-join response already covers most discovery, so this is belt-and-suspenders.

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

- `dm_room_code(a, b)` — deterministic DM room code from two peer IDs (lexicographic ordering). **PURE function of the two ids — NO resolver lookup** (changed 2026-06-15). Resolving inside it broke the invariant that two friends always derive the SAME room: if one side's resolver diverged (stale/polluted link, or one side ingested a device list the other hadn't) they computed different rooms and never met → keying errors. Callers pass the MASTER for the local end (the event loop's `local_peer_str` is master) and the friend's identity id for the remote end, so all of a master's devices land in the same room. A per-device fan-out send computes the room from the recipient's MASTER (`resolver::resolve` at the call site) and uses the device id only as the direct `target_peer` — it must NOT pass a device id here.
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
