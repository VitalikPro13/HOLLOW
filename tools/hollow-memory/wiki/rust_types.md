# Rust Types — NetworkEvent, NodeCommand, HavenMessage, MessageEnvelope

Source: `rust/hollow_core/src/node/types.rs` (~2002 lines)

This file defines every enum and struct that crosses the Rust event loop boundary (Rust-to-Dart, Dart-to-Rust, and wire protocol). All four primary enums live here: `NetworkEvent`, `NodeCommand`, `HavenMessage`, `MessageEnvelope`, plus all helper types referenced by their fields.

---

## Security Constants

- `MAX_SDP_SIZE` = 64 KB — upper bound for SDP payloads; realistic SDP is 2-10 KB
- `MAX_PEER_EXCHANGE_SIZE` = 50 — max peers in a single PeerExchange gossip message
- `MAX_BROADCAST_TTL` = 8 — max allowed TTL on incoming BroadcastMeta gossip messages
- `default_broadcast_ttl()` — returns `gossip::DEFAULT_BROADCAST_TTL` for serde backward compat with old peers
- `VC_SIGNAL_RATE_BURST` = 30 — voice channel signaling rate limiter burst capacity per peer
- `VC_SIGNAL_RATE_REFILL` = 10 — tokens per second per peer

## Utility Functions

### `types.rs:dm_room_code(peer_a, peer_b) -> String`
Computes a deterministic DM room code. Sorts both peer IDs, hashes `"dm-{sorted[0]}-{sorted[1]}"` with SHA-256, truncates to 32 hex chars (128-bit). Both peers compute the same code so signaling matches them to the same WS relay room.

---

## NetworkEvent (Rust -> Dart)

Emitted via `StreamSink` from the Rust event loop to Dart. Consumed by `EventStreamNotifier` in `event_provider.dart`. Each variant maps to a specific handler branch in the Dart event stream listener.

### Core Connectivity

- **`PeerDiscovered { peer: DiscoveredPeer }`** — a new peer was discovered on the local network or via signaling. Contains peer_id and addresses.
- **`PeerExpired { peer_id }`** — a previously discovered peer timed out (no keepalive response).
- **`PeerDisconnected { peer_id }`** — a peer left the WS room or its connection dropped.
- **`RoomCleared`** — the local node left all WS rooms (cleanup event).
- **`Listening { address }`** — the node started listening on the given address.
- **`Error { message }`** — generic error event for non-fatal issues.

### Key Exchange & Sessions

- **`KeyExchangeStarted { peer_id }`** — Olm key exchange initiated with a peer.
- **`KeyExchangeProgress { peer_id, stage }`** — progress update during key exchange (e.g., "sending_key_bundle", "creating_session").
- **`SessionEstablished { peer_id }`** — Olm session fully established; encrypted messaging ready.

### Direct Messages

- **`MessageReceived { from_peer, text, timestamp, message_id, reply_to_mid, link_preview, signature, public_key }`** — an incoming DM was decrypted and delivered. `link_preview` is `Option<LinkPreviewRef>` for sender-generated URL previews. `signature`/`public_key` are Ed25519 verification data.
- **`MessageSent { to_peer, message_id, timestamp, signature, public_key }`** — confirms a DM was successfully encrypted and dispatched. Timestamp is hydrated from Rust's signed value (not Dart `DateTime.now()`).
- **`MessageSendFailed { to_peer, error }`** — DM send failed (no session, peer offline, etc.).
- **`DmMessageEdited { peer_id, message_id, new_text, edited_at, signature, public_key }`** — a DM was edited by the sender.
- **`DmMessageDeleted { peer_id, message_id, deleted_at }`** — a DM was soft-deleted (hidden).
- **`DmSyncCompleted { peer_id, new_message_count }`** — DM sync batch from a peer finished processing.

### Channel Messages

- **`ChannelMessageReceived { server_id, channel_id, from_peer, text, timestamp, message_id, reply_to_mid, link_preview, signature, public_key }`** — a channel message received (decrypted from MLS or Olm). Same signature/preview fields as DM.
- **`ChannelMessageSent { server_id, channel_id, message_id, timestamp, signature, public_key }`** — confirms channel message sent.
- **`ChannelMessageEdited { server_id, channel_id, message_id, new_text, edited_at, signature, public_key }`** — channel message edited.
- **`ChannelMessageDeleted { server_id, channel_id, message_id, deleted_at }`** — channel message soft-deleted.

### Emoji Reactions

- **`ChannelReactionAdded { server_id, channel_id, message_id, emoji, reactor, added_at }`** — reaction added to a channel message.
- **`DmReactionAdded { peer_id, message_id, emoji, reactor, added_at }`** — reaction added to a DM.
- **`ChannelReactionRemoved { server_id, channel_id, message_id, emoji, reactor, removed_at }`** — reaction removed from channel message.
- **`DmReactionRemoved { peer_id, message_id, emoji, reactor, removed_at }`** — reaction removed from DM.

### CRDT / Server Events

- **`ServerCreated { server_id, name }`** — local user created a new server.
- **`ServerUpdated { server_id }`** — server state changed (CRDT op applied affecting permissions, channels, labels, etc.). Dart handler invalidates `myPermissionsProvider`, `myRoleProvider`, `serverMembersProvider`. CRITICAL: new CrdtPayload variants must explicitly emit this, not fall into the `_ =>` wildcard.
- **`ChannelAdded { server_id, channel_id, name, channel_type }`** — a channel was added to a server.
- **`ChannelRemoved { server_id, channel_id }`** — a channel was removed.
- **`ChannelRenamed { server_id, channel_id, new_name }`** — a channel was renamed.
- **`ServerDeleted { server_id }`** — server was deleted by owner.
- **`MemberJoined { server_id, peer_id }`** — a new member joined the server.
- **`MemberLeft { server_id, peer_id }`** — a member left the server.
- **`SyncCompleted { server_id, ops_applied }`** — CRDT sync finished with N ops applied. Emitted from the `_ =>` wildcard in MLS path (does NOT trigger provider invalidation for permissions/roles).
- **`ServerJoined { server_id, name }`** — local user successfully joined a server (invite accepted, MLS welcome received).
- **`ServerJoinFailed { server_id, reason }`** — server join failed (bad invite, Twitch gate rejected, etc.).
- **`RoleChanged { server_id, peer_id, new_role }`** — a member's power role changed.

### Message Sync

- **`MessageSyncStarted { server_id, peer_id }`** — channel message sync started with a peer.
- **`MessageSyncCompleted { server_id, new_message_count }`** — channel message sync finished.
- **`MessageSyncFailed { server_id, error }`** — sync failed.
- **`MessageSyncProgress { server_id, channel_id, received_count, total_count }`** — per-channel sync progress update.

### Profile

- **`ProfileUpdated { peer_id }`** — a peer's profile was updated (display name, status, avatar, banner, about_me). Dart re-reads from local cache.

### Friends

- **`FriendRequestReceived { peer_id }`** — incoming friend request.
- **`FriendRequestAccepted { peer_id }`** — friend request was accepted by the remote peer.
- **`FriendRequestRejected { peer_id }`** — friend request was rejected.
- **`FriendRemoved { peer_id }`** — friend was removed.

### Typing & Presence

- **`TypingStarted { peer_id, server_id, channel_id }`** — a peer started typing. `server_id`/`channel_id` empty for DMs.
- **`PeerStatusChanged { peer_id, status }`** — peer's online/invisible status changed. Phase 6.75.

### Pinned Messages

- **`MessagePinned { server_id, channel_id, message_id }`** — message was pinned.
- **`MessageUnpinned { server_id, channel_id, message_id }`** — message was unpinned.

### File Transfer

- **`FileHeaderReceived { file_id, file_name, size_bytes, is_image, width, height, message_id, sender_id, server_id, channel_id, video_thumb, share_ref }`** — file metadata header received. `server_id` empty for DMs, `channel_id` is peer_id for DMs. `video_thumb: Option<VideoThumbRef>` present when the file is a thumbnail for a vault video. `share_ref: Option<ShareRef>` present when file bytes come via Share P2P instead of direct stream.
- **`FileProgress { file_id, chunks_received, total_chunks }`** — file download progress.
- **`FileCompleted { file_id, disk_path }`** — file download finished, written to disk. CRITICAL: sender side must also emit this for new FileHeader fields to appear in sender's UI.
- **`FileFailed { file_id, error }`** — file transfer failed.

### Vault Shard Events

- **`ShardStored { server_id, content_id, shard_index, from_peer }`** — a shard was stored locally.
- **`ShardStoreAckReceived { server_id, content_id, shard_index, success, error }`** — acknowledgment that a remote peer stored our shard.
- **`ShardStoreFailed { server_id, content_id, shard_index, target_peer, error }`** — shard storage failed on a target peer.
- **`ShardDeleted { server_id, content_id }`** — all shards for a content item were deleted locally.
- **`ShardReceived { server_id, content_id, shard_index, from_peer }`** — a requested shard was received.
- **`ShardRequestFailed { server_id, content_id, shard_index, error }`** — shard retrieval failed.

### Vault Upload/Download Pipeline

- **`VaultUploadProgress { server_id, content_id, phase, progress }`** — upload pipeline progress. `phase` is e.g. "encrypting", "erasure_coding", "distributing". `progress` is 0.0-1.0.
- **`VaultUploadComplete { server_id, content_id, channel_id }`** — vault upload finished.
- **`VaultUploadFailed { server_id, content_id, error }`** — vault upload failed.
- **`VaultDownloadProgress { server_id, content_id, phase, progress }`** — download pipeline progress.
- **`VaultDownloadComplete { server_id, content_id, disk_path }`** — vault download finished, file written.
- **`VaultDownloadFailed { server_id, content_id, error }`** — vault download failed.

### Vault Rebalancing

- **`RebalanceStarted { server_id, shards_to_move }`** — shard rebalancing started (member join/leave triggered redistribution).
- **`RebalanceProgress { server_id, moved, total }`** — rebalancing progress.
- **`RebalanceCompleted { server_id }`** — rebalancing finished.
- **`VaultUploadReplicationFallback { server_id, content_id, online, needed }`** — vault guard detected insufficient peers for erasure coding; fell back to full replication.

### WebRTC Events

- **`WebRtcSignal { peer_id, signal_type, payload, conn_id }`** — forward incoming WebRTC signaling to Dart (SDP offer/answer, ICE candidate). `conn_id` identifies the specific connection.
- **`WebRtcSendFile { peer_id, transfer_id, file_path, total_size, kind, shard_index, chunk_index }`** — tells Dart to send a file over WebRTC data channel. `kind` is "file", "shard", or "share_chunk". `chunk_index` only meaningful for "share_chunk".

### Voice Call Events

- **`CallSignal { peer_id, signal_type, payload }`** — forward incoming 1:1 voice call signaling to Dart.

### Voice Channel Events

- **`VoiceChannelJoined { server_id, channel_id, peer_id }`** — a peer joined a voice channel.
- **`VoiceChannelLeft { server_id, channel_id, peer_id }`** — a peer left a voice channel.
- **`VoiceChannelSignal { server_id, channel_id, peer_id, signal_type, payload }`** — voice channel WebRTC signaling forwarded to Dart.
- **`VoiceChannelModeChanged { server_id, channel_id, mode, gossip_neighbors }`** — voice channel topology changed between "mesh" and "gossip". `gossip_neighbors` lists peers for gossip relay tree.
- **`MlsEpochChanged { server_id, epoch, sframe_key }`** — MLS epoch rotated; Dart must update SFrame encryption key for voice/video.

### Gossip Relay Tree

- **`GossipConnect { peer_id }`** — Dart should establish a WebRTC data channel to this peer (gossip neighbor).
- **`GossipDisconnect { peer_id }`** — Dart should close the WebRTC data channel to this peer.
- **`GossipRelayFile { broadcast_id, ttl, origin_peer_id, file_path, total_size, kind, shard_index, exclude_peer_id, server_id, channel_id }`** — tells Dart to relay a file broadcast to gossip neighbors, excluding the sender. `ttl` is decremented each hop.

### Recovery Pool Events

- **`RecoveryPoolCreated { server_id, invite_link }`** — recovery pool was created, invite link ready.
- **`RecoveryPoolJoined { server_id }`** — successfully joined a recovery pool.
- **`RecoveryPoolJoinFailed { server_id, reason }`** — failed to join recovery pool.
- **`RecoveryPoolMemberJoined { server_id, peer_id }`** — a peer joined the recovery pool.
- **`RecoveryPoolMemberLeft { server_id, peer_id }`** — a peer left the recovery pool.
- **`RecoveryPoolStatus { server_id, total_files, reconstructable, partial, no_shards, progress_pct }`** — pool-wide status dashboard update.
- **`RecoveryPoolShardTransferred { server_id, content_id, shard_index }`** — a shard was transferred within the recovery pool.
- **`RecoveryPoolFileRecovered { server_id, content_id, disk_path }`** — a file was fully recovered from pool shards.
- **`RecoveryPoolStopped { server_id }`** — recovery pool stopped.

### Hollow Share Events (Phase 7A)

- **`ShareManifestReady { root_hash, file_name, total_size, chunk_count }`** — manifest fetched and verified; download can be started.
- **`ShareProgress { root_hash, chunks_have, chunks_total, seeders, leechers, bytes_per_sec }`** — periodic progress for active share download or seed.
- **`ShareCompleted { root_hash, disk_path }`** — download finished, file written.
- **`ShareFailed { root_hash, error }`** — fatal error, swarm state dropped.
- **`ShareSeedingChanged { root_hash, seeding, seeders, leechers, bytes_uploaded }`** — seeding flag toggled (manual or auto-seed on completion).
- **`ShareCreated { root_hash, link, file_name, total_size }`** — `share_create_from_file` finished; share link ready.
- **`ShareCreatedHidden { root_hash, key_hex, file_name, total_size }`** — hidden share created for large file / video streaming. Contains root_hash + key_hex needed to build a `ShareRef` for the FileHeader.
- **`ShareList { entries: Vec<ShareEntryRef> }`** — result of `ShareList` command, streamed back via event.
- **`ShareNeedWebRtc { peer_id, hidden }`** — a share peer needs a WebRTC connection. Dart should call `ensureConnection`. `hidden` = true means use TURN-enabled ICE config.

### License & Misc

- **`LicenseError { reason }`** — license key validation failed.
- **`TwitchJoinRejected { server_id, reason }`** — Twitch-gated server join was rejected (no follow/sub).
- **`RoomBudgetUpdate { joined, limit }`** — current WS room count vs budget (2000 cap).
- **`RoomCapHit { room }`** — attempted to join a room but budget was exhausted.

---

## NodeCommand (Dart -> Rust)

Commands sent from the Flutter FFI layer into the Rust swarm event loop via `mpsc::UnboundedSender<NodeCommand>`. Processed in `swarm.rs:run_event_loop()` match arms, delegated to handler modules.

### Direct Messages

- **`SendMessage { peer_id, text, message_id, reply_to_mid, link_preview }`** — send a DM. Handler: `message_ops.rs:handle_send_dm()`. `link_preview: Option<LinkPreviewRef>` for sender-side URL preview. `reply_to_mid: Option<String>` for reply threading.
- **`EditDmMessage { peer_id, message_id, new_text }`** — edit a DM. Handler: `message_ops.rs:handle_edit_dm()`.
- **`DeleteDmMessage { peer_id, message_id }`** — soft-delete a DM. Handler: `message_ops.rs:handle_delete_dm()`.

### Channel Messages

- **`SendChannelMessage { server_id, channel_id, text, message_id, reply_to_mid, link_preview }`** — send a channel message. Handler: `message_ops.rs:handle_send_channel_message()`.
- **`EditChannelMessage { server_id, channel_id, message_id, new_text }`** — edit a channel message. Handler: `message_ops.rs:handle_edit_channel_message()`.
- **`DeleteChannelMessage { server_id, channel_id, message_id }`** — soft-delete a channel message. Handler: `message_ops.rs:handle_delete_channel_message()`.

### Emoji Reactions

- **`AddChannelReaction { server_id, channel_id, message_id, emoji }`** — add reaction to channel message. Handler: `message_ops.rs:handle_add_channel_reaction()`.
- **`AddDmReaction { peer_id, message_id, emoji }`** — add reaction to DM. Handler: `message_ops.rs:handle_add_dm_reaction()`.
- **`RemoveChannelReaction { server_id, channel_id, message_id, emoji }`** — remove channel reaction. Handler: `message_ops.rs:handle_remove_channel_reaction()`.
- **`RemoveDmReaction { peer_id, message_id, emoji }`** — remove DM reaction. Handler: `message_ops.rs:handle_remove_dm_reaction()`.

### Room Management

- **`JoinRoom { room_code }`** — join a WS relay room. Processed directly in swarm.rs event loop (sends JoinRoom to WS client).

### CRDT / Server Commands

- **`CreateServer { name }`** — create a new server. Handler: `sync_handler.rs:handle_create_server()`.
- **`CreateChannel { server_id, name, category, channel_type }`** — add a channel. `channel_type` is "text" or "voice". `category: Option<String>` for channel grouping. Handler: `sync_handler.rs:handle_create_channel()`.
- **`RemoveChannel { server_id, channel_id }`** — remove a channel. Handler: `sync_handler.rs:handle_remove_channel()`.
- **`RenameServer { server_id, new_name }`** — rename a server. Handler: `sync_handler.rs`.
- **`RenameChannel { server_id, channel_id, new_name }`** — rename a channel. Handler: `sync_handler.rs`.
- **`UpdateServerSetting { server_id, key, value }`** — update a server setting (icon, description, twitch gate, etc.). Handler: `sync_handler.rs`.
- **`DeleteServer { server_id }`** — delete server (owner only). Handler: `sync_handler.rs:handle_delete_server()`.
- **`JoinServer { server_id, twitch_proof_json }`** — request to join a server. `twitch_proof_json: Option<String>` for Twitch-gated servers. Handler: `sync_handler.rs:handle_join_server()`.
- **`RequestChannelSync { server_id, channel_id }`** — manually request channel message sync. Handler: `sync_handler.rs`.
- **`LeaveServer { server_id }`** — leave a server voluntarily. Handler: `sync_handler.rs:handle_leave_server()`.

### Roles & Permissions

- **`ChangeRole { server_id, peer_id, new_role }`** — change a member's power role (Owner/Admin/Moderator/Member). Handler: `sync_handler.rs`.
- **`KickMember { server_id, peer_id }`** — kick a member. Handler: `sync_handler.rs`.
- **`BanMember { server_id, peer_id }`** — ban a member. Handler: `sync_handler.rs`.
- **`UnbanMember { server_id, peer_id }`** — unban a member. Handler: `sync_handler.rs`.
- **`ChangeRolePermissions { server_id, role, permissions }`** — update permission bitmask for a power role. Tier-gated (can only edit roles below your own rank). Handler: `sync_handler.rs`.

### Labels

- **`CreateLabel { server_id, name, color }`** — create a cosmetic label. Handler: `sync_handler.rs`.
- **`DeleteLabel { server_id, label_id }`** — delete a label. Handler: `sync_handler.rs`.
- **`UpdateLabel { server_id, label_id, name, color }`** — update label name/color. Handler: `sync_handler.rs`.
- **`AssignLabel { server_id, label_id, peer_id }`** — assign a label to a member. Handler: `sync_handler.rs`.
- **`UnassignLabel { server_id, label_id, peer_id }`** — remove a label from a member. Handler: `sync_handler.rs`.

### Channel Modes

- **`SetChannelVisibility { server_id, channel_id, visibility }`** — set who can see a channel ("all", or specific role names). Handler: `sync_handler.rs`.
- **`SetChannelPosting { server_id, channel_id, posting }`** — set who can post in a channel ("all", "moderator+", "admin+"). Handler: `sync_handler.rs`.

### Member Metadata

- **`SetNickname { server_id, peer_id, nickname }`** — set a member's server-specific nickname. Handler: `sync_handler.rs`.
- **`SetTwitchUsername { server_id, peer_id, twitch_username }`** — set a member's Twitch username. Handler: `sync_handler.rs`.
- **`NotifyShutdown`** — app is shutting down; broadcast `PeerDisconnecting` to all connected peers. Handler: swarm.rs directly.

### Profile

- **`UpdateProfile { display_name, status, about_me, avatar_bytes, banner_bytes }`** — update local user's profile. `avatar_bytes`/`banner_bytes` are `Option<Vec<u8>>` raw image data. Handler: `social.rs:handle_update_profile()`.

### Friends

- **`SendFriendRequest { peer_id }`** — send a friend request. Handler: `social.rs:handle_send_friend_request()`.
- **`AcceptFriendRequest { peer_id }`** — accept a friend request. Handler: `social.rs:handle_accept_friend_request()`.
- **`RejectFriendRequest { peer_id }`** — reject a friend request. Handler: `social.rs:handle_reject_friend_request()`.
- **`RemoveFriend { peer_id }`** — remove a friend. Handler: `social.rs:handle_remove_friend()`.

### Typing & Presence

- **`SendTypingIndicator { server_id, channel_id }`** — send typing indicator. Handler: `social.rs:handle_send_typing()`.
- **`SetInvisible { invisible }`** — toggle invisible mode. Sends `StatusUpdate` to all connected peers. Handler: `social.rs`.

### Channel Layout & Pinning

- **`UpdateChannelLayout { server_id, layout_json }`** — persist channel layout (ordering, categories). Handler: `sync_handler.rs`.
- **`PinMessage { server_id, channel_id, message_id }`** — pin a message. Handler: `sync_handler.rs`.
- **`UnpinMessage { server_id, channel_id, message_id }`** — unpin a message. Handler: `sync_handler.rs`.

### File Sharing

- **`SendFile { peer_id, server_id, channel_id, file_path, message_id, message_text, vthumb, override_width, override_height, share_ref }`** — send a file. `peer_id` set for DMs, `server_id`+`channel_id` set for channels. `vthumb: Option<VideoThumbRef>` for video thumbnail pipeline. `override_width`/`override_height` used by video preview for aspect ratio. `share_ref: Option<ShareRef>` for >34 MB files delivered via Share infrastructure. Handler: `file_handler.rs:handle_send_file()`.
- **`RequestFile { file_id, peer_id, chunks }`** — request file chunks from a peer. `chunks` empty = all. Handler: `file_handler.rs:handle_request_file()`.

### Storage Pledge

- **`SetStoragePledge { server_id, pledge_bytes }`** — set how much disk space user pledges for vault shards. Handler: `vault_ops.rs`.

### Vault Operations

- **`VaultUploadFile { server_id, channel_id, file_name, mime_type, message_id, ciphertext, aes_key, aes_nonce, original_size, content_id }`** — upload a file to the vault (erasure-coded shard distribution). Handler: `vault_ops.rs:handle_vault_upload()`.
- **`VaultDownloadFile { server_id, content_id }`** — download a file from the vault (collect shards, reconstruct). Handler: `vault_ops.rs:handle_vault_download()`.
- **`DeleteVaultContent { server_id, content_id }`** — delete vault content (admin-only). Handler: `vault_ops.rs`.
- **`RequestShardFromPeer { server_id, content_id, shard_index, shard_key, target_peer }`** — request a specific shard from a specific peer. Handler: `vault_ops.rs`.
- **`StoreShardOnPeer { server_id, content_id, shard_index, shard_key, k, m, total_data_size, storage_tier, data, target_peer }`** — send a shard to a specific peer for storage. `k`/`m` are Reed-Solomon parameters. `storage_tier` is "standard", "low", or "permanent". Handler: `vault_ops.rs`.

### WebRTC Commands

- **`WebRtcPeerConnected { peer_id }`** — Dart notifies Rust that a WebRTC data channel is established. Handler: swarm.rs.
- **`WebRtcPeerDisconnected { peer_id }`** — Dart notifies Rust that a WebRTC data channel closed. Handler: swarm.rs.
- **`WebRtcSendSignal { peer_id, signal_type, payload, conn_id }`** — Dart sends a WebRTC signal (SDP/ICE) to relay to a peer. Handler: swarm.rs.
- **`WebRtcTransferComplete { transfer_id, temp_path, sender_peer_id, kind, shard_index, chunk_index }`** — Dart reports a completed WebRTC file receive. `kind` is "file", "shard", or "share_chunk". Handler: `file_handler.rs` / `vault_ops.rs` depending on kind.
- **`WebRtcSendComplete { transfer_id }`** — Dart reports a completed WebRTC file send. Handler: swarm.rs.
- **`WebRtcTransferFailed { transfer_id, peer_id, error }`** — WebRTC transfer failed. Handler: swarm.rs.
- **`WebRtcBroadcastReceived { transfer_id, broadcast_id, ttl, origin_peer_id, sender_peer_id, temp_path, total_size, kind, shard_index }`** — Dart reports a completed broadcast file transfer for gossip relay decision. Handler: `gossip_relay.rs`.
- **`WebRtcPingReport { peer_id, rtt_ms }`** — Dart reports data channel keepalive RTT for peer scoring in gossip overlay. Handler: `gossip.rs`.

### Voice Call Commands

- **`CallSendSignal { peer_id, signal_type, payload }`** — send 1:1 voice call signaling (SDP/ICE/invite/accept/etc.). Handler: `voice_handler.rs`.

### Voice Channel Commands

- **`VoiceChannelJoin { server_id, channel_id }`** — join a voice channel. Handler: `voice_handler.rs:handle_vc_join()`.
- **`VoiceChannelLeave { server_id, channel_id }`** — leave a voice channel. Handler: `voice_handler.rs:handle_vc_leave()`.
- **`VoiceChannelSendSignal { server_id, channel_id, peer_id, signal_type, payload }`** — send voice channel signaling to a specific peer. Handler: `voice_handler.rs`.

### Gossip Relay Tree

- **`CheckPendingJoinTimeout { server_id }`** — internal: check if a pending server join timed out (timer-driven). Handler: swarm.rs.

### Recovery Pool Commands

- **`InitiateRecoveryPool { server_id, token }`** — create a recovery pool for a dead server. Handler: `recovery_pool.rs`.
- **`JoinRecoveryPool { server_id, token }`** — join an existing recovery pool. Handler: `recovery_pool.rs`.
- **`StopRecoveryPool { server_id }`** — stop a recovery pool. Handler: `recovery_pool.rs`.

### Hollow Share Commands (Phase 7A)

- **`ShareCreate { source_path }`** — build ShareManifest from a local file, persist, generate link, start auto-seeding. Emits `ShareCreated`. Handler: `swarm.rs` (share module).
- **`ShareCreateHidden { source_path }`** — create a hidden share (not shown in Share tab) for large file / video streaming. Emits `ShareCreatedHidden`. Handler: `swarm.rs` (share module).
- **`ShareOpenLink { link, server_id, context_type }`** — decode a `hollow://share/` link, join swarm room, fetch manifest. `server_id`/`context_type` are optional metadata. Emits `ShareManifestReady` or `ShareFailed`. Handler: `swarm.rs`.
- **`ShareStart { root_hash, save_dir, link, sequential }`** — begin downloading chunks. `sequential: true` for video streaming (in-order fetch). Handler: `swarm.rs`.
- **`ShareCancel { root_hash }`** — stop an in-flight download (keeps partial + bitmap for resume). Handler: `swarm.rs`.
- **`ShareSetSeeding { root_hash, seeding }`** — toggle seeding for a completed share (joins/leaves swarm room). Handler: `swarm.rs`.
- **`ShareRemove { root_hash, delete_file }`** — drop a share entry. `delete_file: true` also unlinks file/partial. Handler: `swarm.rs`.
- **`ShareList`** — enumerate persisted shares; result returned via `NetworkEvent::ShareList`. Handler: `swarm.rs`.

---

## HavenMessage (Wire Protocol)

The plaintext wire protocol enum. Serialized as JSON with `#[serde(tag = "type")]`. Used for WS relay messages and as the plaintext content inside Olm `Encrypted` envelopes. All variants use `#[serde(rename = "...")]` for compact wire names.

### Key Exchange

- **`KeyRequest`** — `"key_request"` — initiator requests Olm key bundle from peer.
- **`KeyBundle { identity_key, one_time_key }`** — `"key_bundle"` — responder sends Olm key material (identity key + one-time prekey).
- **`Encrypted { message_type, body, identity_key }`** — `"encrypted"` — Olm-encrypted payload. `message_type` is 0 (PreKey) or 1 (Normal). `body` is base64 ciphertext. `identity_key` present for PreKey messages.
- **`Ack`** — `"ack"` — acknowledgment (generic).

### CRDT Sync (Plaintext Path)

These are the plaintext variants used before MLS is established or as fallback. MLS path uses `MessageEnvelope` equivalents.

- **`SyncRequest { server_id, state_vector_json }`** — `"sync_request"` — request CRDT ops the peer has that we don't. `state_vector_json` is our CRDT state vector.
- **`SyncResponse { server_id, ops_json }`** — `"sync_response"` — response with missing CRDT ops.
- **`CrdtOpBroadcast { server_id, op_json }`** — `"crdt_op"` — broadcast a single CRDT operation to all server members.
- **`ServerJoinRequest { server_id, twitch_proof_json }`** — `"join_request"` — request to join a server. `twitch_proof_json` optional for Twitch-gated servers.
- **`ServerJoinRejected { server_id, reason }`** — `"join_rejected"` — join request rejected.
- **`ServerDeleteBroadcast { server_id }`** — `"server_delete"` — owner broadcast: server deleted.
- **`MemberKickBroadcast { server_id }`** — `"member_kick"` — sent to kicked member so they remove themselves.

### Channel Sync

- **`ChannelSyncRequest { server_id, channel_id, since_timestamp, sender_timestamps }`** — `"ch_sync_req"` — request channel messages since timestamp. `sender_timestamps: HashMap<String, i64>` for per-sender gap-free sync (empty = legacy fallback).
- **`ChannelSyncProbe { server_id, channel_id, our_latest, msg_count }`** — `"ch_sync_probe"` — lightweight probe asking "what's your latest timestamp for this channel?" Used to skip channels with no new messages before full sync.
- **`ChannelSyncProbeResponse { server_id, channel_id, their_latest, msg_count }`** — `"ch_sync_probe_resp"` — response to a sync probe with the peer's latest timestamp and count.
- **`DmSyncRequest { since_timestamp }`** — `"dm_sync_req"` — request missed DMs from a peer since timestamp.

### Lifecycle

- **`PeerDisconnecting`** — `"disconnecting"` — broadcast when the app is shutting down. Lets peers immediately mark the user as offline instead of waiting for keepalive timeout.

### MLS Group Messages

- **`MlsChannelMessage { server_id, body }`** — `"mls_msg"` — MLS-encrypted channel message. `body` is base64 MLS ciphertext. Replaces Olm fan-out for server channels.
- **`MlsKeyPackage { server_id, key_package }`** — `"mls_kp"` — peer sends their KeyPackage to be added to the MLS group. `key_package` is base64 serialized.
- **`MlsWelcome { server_id, welcome }`** — `"mls_welcome"` — Welcome message sent to a joiner after `add_members()`. `welcome` is base64 serialized.
- **`MlsCommit { server_id, commit }`** — `"mls_commit"` — Commit message (membership change) from the MLS coordinator. `commit` is base64 serialized.
- **`MlsKeyPackageRequest { server_id }`** — `"mls_kp_req"` — request all peers to send their KeyPackages for MLS group bootstrap.

### Profile

- **`ProfileUpdate { display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible }`** — `"profile_update"` — broadcast profile update (plaintext, not sensitive). `avatar_b64`/`banner_b64` are base64-encoded images. `is_invisible` for invisible mode (Phase 6.75).
- **`ProfileRequest`** — `"profile_request"` — request a peer's profile (they respond with `ProfileUpdate`).

### Friends

- **`FriendRequest { requested_at }`** — `"friend_request"` — send a friend request with timestamp.
- **`FriendAccept`** — `"friend_accept"` — accept a friend request.
- **`FriendReject`** — `"friend_reject"` — reject a friend request.
- **`FriendRemove`** — `"friend_remove"` — remove a friend.

### Typing & Status

- **`TypingIndicator { server_id, channel_id }`** — `"typing"` — ephemeral typing indicator. Not stored, not signed. Empty strings for DMs.
- **`StatusUpdate { status }`** — `"status_update"` — ephemeral status update ("online" or "invisible"). Fire-and-forget. Phase 6.75.

### File Sharing

- **`FileRequest { file_id, chunks }`** — `"file_req"` — request file chunks from a peer. `chunks` empty = all.
- **`FileProbe { file_id }`** — `"file_probe"` — ask "do you have this file?"
- **`FileProbeResponse { file_id, has_file, available_chunks }`** — `"file_probe_resp"` — response: has file and which chunks.

### WebRTC Signaling

- **`RtcOffer { sdp, conn_id }`** — `"rtc_offer"` — SDP offer for WebRTC data channel connection.
- **`RtcAnswer { sdp, conn_id }`** — `"rtc_answer"` — SDP answer for WebRTC data channel connection.
- **`RtcIceCandidate { candidate, sdp_mid, sdp_mline_index, conn_id }`** — `"rtc_ice"` — ICE candidate for WebRTC connection establishment.

### Voice Call Signaling (1:1 Calls)

- **`CallInvite { call_id, video, sframe_key }`** — `"call_invite"` — invite peer to a voice/video call. `video: bool` indicates video call. `sframe_key` is the SFrame encryption key (AES-128-GCM).
- **`CallAccept { call_id, sframe_key }`** — `"call_accept"` — accept a call invitation.
- **`CallReject { call_id }`** — `"call_reject"` — reject a call.
- **`CallEnd { call_id }`** — `"call_end"` — end an active call.
- **`CallBusy { call_id }`** — `"call_busy"` — signal that we're already in another call.
- **`CallSdpOffer { call_id, sdp }`** — `"call_sdp_offer"` — SDP offer for voice call WebRTC connection.
- **`CallSdpAnswer { call_id, sdp }`** — `"call_sdp_answer"` — SDP answer for voice call.
- **`CallIceCandidate { call_id, candidate, sdp_mid, sdp_mline_index }`** — `"call_ice"` — ICE candidate for voice call.
- **`CallVideoState { call_id, enabled }`** — `"call_video_state"` — camera on/off during a call.
- **`CallScreenState { call_id, enabled, quality }`** — `"call_screen_state"` — screen share on/off during a call. `quality: Option<String>`.
- **`CallScreenOffer { call_id, sdp }`** — `"call_screen_offer"` — SDP offer for screen share (separate PeerConnection).
- **`CallScreenAnswer { call_id, sdp }`** — `"call_screen_answer"` — SDP answer for screen share.
- **`CallScreenIce { call_id, candidate, sdp_mid, sdp_mline_index, role }`** — `"call_screen_ice"` — ICE candidate for screen share. `role` identifies direction.

### Voice Channel State (Plaintext for MLS Epoch Resilience)

These use plaintext HavenMessage instead of MLS MessageEnvelope so they survive epoch staleness after reconnection. Only state broadcasts are plaintext; SDP/ICE (which contain IPs) stay MLS-encrypted with Olm fallback.

- **`VoiceChannelJoin { server_id, channel_id }`** — `"vc_join"` — broadcast: user joined a voice channel.
- **`VoiceChannelLeave { server_id, channel_id }`** — `"vc_leave"` — broadcast: user left a voice channel.
- **`VoiceChannelAudioState { server_id, channel_id, muted, deafened }`** — `"vc_audio_state"` — broadcast: audio mute/deafen state.
- **`VoiceChannelScreenState { server_id, channel_id, enabled, quality }`** — `"vc_screen_state"` — broadcast: screen share on/off.
- **`VoiceChannelCameraState { server_id, channel_id, enabled }`** — `"vc_camera_state"` — broadcast: camera on/off.

### Gossip Relay Tree

- **`PeerExchange { server_id, peers }`** — `"peer_exchange"` — share neighbor list for topology discovery. Capped at `MAX_PEER_EXCHANGE_SIZE` (50).

### Recovery Pool (Plaintext — No MLS Group Exists for Dead Server)

- **`RecoveryHello { server_id, manifest_ids, shard_inventory_json }`** — `"recovery_hello"` — sent when joining a recovery pool room. Lists locally available vault manifests and shard inventory.
- **`RecoveryWelcome { manifest_ids, shard_inventory_json }`** — `"recovery_welcome"` — reply from existing pool members to a new joiner.
- **`RecoveryManifestSync { manifests_json }`** — `"recovery_manifest_sync"` — coordinator broadcasts the merged manifest set.
- **`RecoveryTransferPlan { plan_json }`** — `"recovery_transfer_plan"` — coordinator assigns shard transfers (who sends which shard to whom).
- **`RecoveryShardReceived { content_id, shard_index }`** — `"recovery_shard_received"` — broadcast when a shard arrives in the pool.
- **`RecoveryStatus { status_json }`** — `"recovery_status"` — coordinator broadcasts pool-wide status for the dashboard.
- **`RecoveryStop`** — `"recovery_stop"` — initiator stops the pool.

### Hollow Share (Phase 7A)

Share control lives in HavenMessage (not MessageEnvelope) because share swarms have no stable MLS group — anyone with the link joins/leaves freely.

- **`ShareManifestRequest { root_hash }`** — `"share_manifest_req"` — peer just joined a share swarm and needs the manifest. Any seeder responds.
- **`ShareManifestResponse { root_hash, manifest_b64 }`** — `"share_manifest_resp"` — manifest payload (base64 JSON of ShareManifest). Receiver verifies SHA-256(manifest_bytes) == root_hash.
- **`ShareHave { root_hash, bitmap_b64, chunk_count }`** — `"share_have"` — periodic broadcast of which chunks sender holds. `bitmap_b64` is base64(little-endian-packed bits, MSB-first within each byte).
- **`ShareChunkRequest { root_hash, indices }`** — `"share_chunk_req"` — request a batch of chunks from a specific peer.
- **`ShareChunkResponse { root_hash, index, data_b64 }`** — `"share_chunk_resp"` — inline chunk delivery for very small chunks. Bulk path uses ws_stream binary frames + WebRtcSendFile pipeline with kind = "share_chunk". Receiver verifies SHA-256(data) == manifest.chunk_hashes[index] then AES-GCM decrypts.

---

## MessageEnvelope (Encrypted Message Formats)

The typed envelope for plaintext body inside Olm `Encrypted` messages and MLS `MlsChannelMessage` payloads. Serialized as JSON with `#[serde(tag = "t")]`. Legacy DMs are raw text (no JSON); new messages use this envelope.

Many variants include a `target: Option<String>` field — when present, only the targeted peer processes the message (others decrypt but discard). The `types.rs:MessageEnvelope::target()` method extracts this field for all applicable variants.

### Chat Messages

- **`DirectMessage` (`"dm"`)** — DM content.
  - `text` — message text
  - `ts` — sender-generated timestamp (millis since epoch)
  - `sig: Option<String>` — Ed25519 signature (base64) over canonical payload
  - `pk: Option<String>` — sender's Ed25519 public key (base64 protobuf)
  - `mid: Option<String>` — unique message ID (UUID, sender-generated)
  - `reply_to: Option<String>` — message ID this is replying to
  - `file_id: Option<String>` — file attachment ID
  - `link_preview: Option<LinkPreviewRef>` — sender-generated URL preview (Phase 6.75)

- **`ChannelMessage` (`"ch"`)** — server channel message.
  - `sid` — server ID
  - `cid` — channel ID
  - `text` — message text
  - `ts` — timestamp (millis since epoch)
  - `sig, pk, mid, reply_to, file_id, link_preview` — same as DirectMessage

### Sync Batches

- **`ChannelSyncBatch` (`"ch_sync"`)** — batch of synced channel messages.
  - `sid` — server ID
  - `cid` — channel ID
  - `messages: Vec<SyncMessageItem>` — the synced messages
  - `total` — total messages available since requested timestamp (for progress indication)
  - `has_more: Option<bool>` — if true, more messages available; receiver should send follow-up request
  - `target: Option<String>` — only the targeted peer processes this batch

- **`DmSyncBatch` (`"dm_sync"`)** — batch of synced DMs.
  - `messages: Vec<DmSyncItem>` — the synced DMs
  - `has_more: Option<bool>` — if true, more DMs available

### Edit & Delete

- **`EditMessage` (`"edit"`)** — edit an existing message (channel or DM).
  - `mid` — original message ID
  - `text` — new text content
  - `ts` — edit timestamp
  - `sig, pk` — Ed25519 signature over edit payload
  - `sid, cid` — present for channel edits, absent for DM edits

- **`DeleteMessage` (`"delete"`)** — soft-delete (hide) a message.
  - `mid` — message ID to delete
  - `ts` — deletion timestamp
  - `sig, pk` — Ed25519 signature over deletion payload
  - `sid, cid` — present for channel deletions, absent for DM

### Emoji Reactions

- **`AddReaction` (`"reaction"`)** — add an emoji reaction.
  - `mid` — message ID being reacted to
  - `emoji` — Unicode emoji string
  - `ts` — timestamp
  - `sig, pk` — Ed25519 signature
  - `sid, cid` — present for channel reactions, absent for DM

- **`RemoveReaction` (`"unreaction"`)** — remove an emoji reaction.
  - `mid, emoji, ts, sig, pk, sid, cid` — same fields as AddReaction

### File Transfer

- **`FileHeader` (`"file_hdr"`)** — file metadata header sent before file chunks.
  - `fid` — unique file ID (32-char hex)
  - `name` — original file name
  - `ext` — file extension
  - `mime` — MIME type
  - `size` — total size in bytes
  - `chunks` — number of chunks (0 for streamed transfers)
  - `img` — is this an image
  - `w, h` — image dimensions (if image)
  - `mid` — message ID this file is attached to
  - `sid, cid` — server/channel ID (for channel files)
  - `ts` — timestamp
  - `sig, pk` — Ed25519 signature
  - `aes_key` — AES-256-GCM key (hex); present means file bytes arrive via stream
  - `aes_nonce` — AES-256-GCM nonce (hex); present with aes_key
  - `target` — only targeted peer processes
  - `vthumb: Option<VideoThumbRef>` — video thumbnail back-reference (Phase 6.75); present when this file is a thumbnail for a vault video
  - `share_ref: Option<ShareRef>` — hidden share back-reference; when present, file bytes delivered via Share P2P instead of direct stream

- **`FileChunk` (`"file_chunk"`)** — a single file chunk.
  - `fid` — file ID
  - `idx` — 0-based chunk index
  - `data` — base64-encoded chunk data (up to 256KB decoded)

### Vault Shard Operations

- **`ShardStore` (`"shard_store"`)** — vault shard store request (header + optional inline data).
  - `sid` — server ID
  - `cid` — content ID
  - `si` — shard index (u16)
  - `sk` — shard key
  - `k, m` — Reed-Solomon parameters (u16)
  - `total_size` — total data size
  - `tier` — storage tier ("standard", "low", "permanent")
  - `data` — base64 shard data
  - `chunks` — number of chunks (if shard is chunked)
  - `target` — targeted peer

- **`ShardChunk` (`"shard_chunk"`)** — vault shard chunk (for shards > 256KB).
  - `sid, cid, si` — server/content/shard identity
  - `ci` — chunk index (u32)
  - `data` — base64 chunk data

- **`ShardStoreAck` (`"shard_ack"`)** — shard storage acknowledgment.
  - `sid, cid, si` — server/content/shard identity
  - `ok` — success boolean
  - `err: Option<String>` — error message if failed
  - `target` — targeted peer

- **`ShardDelete` (`"shard_delete"`)** — vault shard deletion request (admin-only, MANAGE_SERVER permission).
  - `sid, cid` — server/content identity

- **`ShardRequest` (`"shard_req"`)** — request a specific shard from a peer.
  - `sid, cid, si, sk` — server/content/shard/key identity
  - `target` — targeted peer

- **`ShardResponse` (`"shard_resp"`)** — response with shard data.
  - `sid, cid, si` — identity
  - `data` — base64 shard data
  - `chunks` — chunk count
  - `found` — whether shard was found
  - `target` — targeted peer

- **`ShardResponseChunk` (`"shard_resp_chunk"`)** — chunked shard response (for shards > 256KB).
  - `sid, cid, si` — identity
  - `ci` — chunk index
  - `data` — base64 chunk data
  - `target` — targeted peer

- **`ShardProbe` (`"shard_probe"`)** — ask peer which shards they have for a content item.
  - `sid, cid` — server/content identity
  - `target` — targeted peer

- **`ShardProbeResponse` (`"shard_probe_resp"`)** — list of locally available shard indices.
  - `sid, cid` — identity
  - `shards: Vec<u16>` — available shard indices
  - `target` — targeted peer

- **`VaultManifestBroadcast` (`"vault_manifest"`)** — carries file manifest (contains AES key) to all server members.
  - `sid` — server ID
  - `cid` — content ID
  - `chid` — channel ID
  - `manifest` — manifest JSON

- **`ShardMigrate` (`"shard_migrate"`)** — proactive shard move during rebalancing.
  - `sid, cid, si, sk` — identity
  - `data` — base64 shard data
  - `target` — targeted peer

### MLS-Path Server Messages (Phase 6)

These replace plaintext HavenMessage variants when MLS is active. They travel inside `MlsChannelMessage` envelopes.

- **`CrdtOp` (`"crdt_op"`)** — CRDT operation broadcast via MLS.
  - `sid` — server ID
  - `op_json` — CRDT operation JSON

- **`ServerDelete` (`"srv_delete"`)** — server deletion via MLS.
  - `sid` — server ID

- **`MemberKick` (`"member_kick"`)** — member kick notification via MLS.
  - `sid` — server ID

- **`Typing` (`"srv_typing"`)** — typing indicator via MLS.
  - `sid` — server ID
  - `cid` — channel ID

- **`ProfileUpdate` (`"srv_profile"`)** — profile update broadcast via MLS.
  - `display_name, status, about_me, updated_at, avatar_b64, banner_b64, is_invisible` — same fields as HavenMessage::ProfileUpdate

- **`SyncReq` (`"sync_req"`)** — CRDT sync request via MLS.
  - `sid` — server ID
  - `state_vector_json` — CRDT state vector
  - `target` — targeted peer

- **`SyncResp` (`"sync_resp"`)** — CRDT sync response via MLS.
  - `sid` — server ID
  - `ops_json` — CRDT operations
  - `target` — targeted peer

- **`ChannelSyncReq` (`"ch_sync_req"`)** — channel message sync request via MLS.
  - `sid, cid` — server/channel identity
  - `since_timestamp` — request messages since this timestamp
  - `sender_timestamps: HashMap<String, i64>` — per-sender latest timestamps for gap-free sync
  - `target` — targeted peer

- **`ChannelProbe` (`"ch_probe"`)** — channel sync probe via MLS.
  - `sid, cid` — server/channel identity
  - `our_latest` — our latest timestamp
  - `msg_count` — our total message count
  - `target` — targeted peer

- **`ChannelProbeResp` (`"ch_probe_resp"`)** — channel sync probe response via MLS.
  - `sid, cid` — server/channel identity
  - `their_latest` — peer's latest timestamp
  - `msg_count` — peer's message count
  - `target` — targeted peer

- **`SessionAck` (`"session_ack"`)** — lightweight encrypted ping sent after creating an inbound Olm session. Causes the remote peer's outbound session to ratchet (upgrade from PreKey type 0 to Normal type 1).

### Voice Channel Signaling (MLS Path)

These are the MLS-encrypted equivalents of the plaintext voice channel HavenMessage variants. SDP/ICE (which contain IPs) use these for privacy; only state broadcasts use plaintext.

- **`VoiceChannelJoin` (`"vc_join"`)** — `sid, cid`
- **`VoiceChannelLeave` (`"vc_leave"`)** — `sid, cid`
- **`VoiceChannelSdpOffer` (`"vc_sdp_offer"`)** — `sid, cid, sdp, target`
- **`VoiceChannelSdpAnswer` (`"vc_sdp_answer"`)** — `sid, cid, sdp, target`
- **`VoiceChannelIce` (`"vc_ice"`)** — `sid, cid, candidate, sdp_mid, sdp_mline_index, target`
- **`VoiceChannelAudioState` (`"vc_audio_state"`)** — `sid, cid, muted, deafened, target`
- **`VoiceChannelScreenOffer` (`"vc_screen_offer"`)** — `sid, cid, sdp, target`
- **`VoiceChannelScreenAnswer` (`"vc_screen_answer"`)** — `sid, cid, sdp, target`
- **`VoiceChannelScreenIce` (`"vc_screen_ice"`)** — `sid, cid, candidate, sdp_mid, sdp_mline_index, role, target`
- **`VoiceChannelScreenState` (`"vc_screen_state"`)** — `sid, cid, enabled, target, quality`
- **`VoiceChannelRenegOffer` (`"vc_reneg_offer"`)** — `sid, cid, sdp, target` — renegotiation SDP offer (adding/removing video track)
- **`VoiceChannelRenegAnswer` (`"vc_reneg_answer"`)** — `sid, cid, sdp, target` — renegotiation SDP answer
- **`VoiceChannelCameraState` (`"vc_camera_state"`)** — `sid, cid, enabled, target`

### Gossip Relay Tree

- **`BroadcastMeta` (`"broadcast_meta"`)** — broadcast metadata notifying server members that a gossip file broadcast is in flight.
  - `broadcast_id` — unique broadcast ID
  - `origin` — originating peer ID
  - `sid` — server ID
  - `cid` — channel ID (context)
  - `file_id` — file being broadcast
  - `ttl` — time-to-live, decremented each hop. Default from `default_broadcast_ttl()`. Capped at `MAX_BROADCAST_TTL` (8).

### `MessageEnvelope::target()` Method

Returns `Option<&str>` with the target peer ID if the variant has a `target` field. Used in swarm.rs dispatch to skip processing messages not meant for the local peer. Covers: `ChannelSyncBatch`, `FileHeader`, all `Shard*` variants, `SyncReq`, `SyncResp`, `ChannelSyncReq`, `ChannelProbe`, `ChannelProbeResp`, all `VoiceChannel*` signaling variants.

---

## Helper Types

### `DiscoveredPeer`
```
pub(crate) struct DiscoveredPeer {
    pub peer_id: String,
    pub addresses: Vec<String>,
}
```
A discovered peer on the local network. Used in `NetworkEvent::PeerDiscovered`.

### `ShareEntryRef`
Lightweight share entry for streaming lists to Dart. The persisted row is wider (manifest_json, encryption_key blob, etc.); Dart only needs what it renders.
- `root_hash: String` — share identifier
- `file_name: String` — original file name
- `total_size: u64` — file size in bytes
- `chunks_have: u32` — chunks downloaded so far
- `chunks_total: u32` — total chunk count
- `state: String` — "downloading" | "completed" | "paused" | "failed"
- `seeding: bool` — whether actively seeding
- `disk_path: Option<String>` — path to completed file
- `bytes_uploaded: u64` — total bytes uploaded while seeding
- `share_link: String` — the `hollow://share/` link
- `created_at: i64` — Unix timestamp at creation
- `server_id: Option<String>` — server context (for hidden shares backing channel files)
- `context_type: Option<String>` — context metadata

### `ShareManifest`
Describes a shared file. Transmitted in the clear over the swarm room (the manifest's SHA-256 IS the root_hash from the share link, so encrypting it would prevent discovery). The decryption key is in the link only, never in the manifest.
- `version: u16` — format version (bump if chunk hash domain or nonce derivation changes)
- `file_name: String` — original file name
- `mime: String` — MIME type
- `total_size: u64` — total file size
- `chunk_size: u32` — 262144 (256 KiB) for v1
- `chunk_count: u32` — number of chunks
- `chunk_hashes: Vec<[u8; 32]>` — SHA-256 of each encrypted chunk (ciphertext || GCM tag), in order
- `created_at: u64` — Unix seconds at creation
- `note: Option<String>` — optional creator-supplied note

### `VideoThumbRef`
Back-reference from a thumbnail image (sent via P2P image path) to the underlying video bytes (stored in vault). Carried in `MessageEnvelope::FileHeader` and persisted alongside file metadata. Phase 6.75 video preview.
- `cid: String` — vault content_id (SHA-256 of ciphertext) of the underlying video
- `ext: String` — original video file extension (mp4, webm, mkv, ...)
- `name: String` — original video file name (for Save As dialog)
- `size: u64` — video size in bytes
- `dur_ms: u32` — video duration in milliseconds

### `ShareRef`
Back-reference to a hidden Share for large files (>34 MB) or progressive video streaming. Embedded in `MessageEnvelope::FileHeader` so receiver can join the share swarm.
- `root_hash: String` — root hash of the share manifest (hex, 64 chars)
- `key: String` — AES-256-GCM encryption key for share chunks (hex, 64 chars)

### `LinkPreviewRef`
Sender-generated URL preview embedded in outgoing DMs/channel messages. Receivers render the card from these fields and NEVER make HTTP requests to the previewed URL (privacy requirement).
- `url: String` — the previewed URL
- `title: String` — og:title or <title> fallback (truncated to 200 chars)
- `description: String` — og:description or meta description (truncated to 400 chars)
- `domain: String` — display domain parsed from URL (e.g. "github.com")
- `site_name: String` — og:site_name if present (e.g. "GitHub"); empty = fall back to domain
- `thumb_webp_b64: Option<String>` — base64-encoded lossy WebP thumbnail (Q=50, max dim 400px). None = no og:image found
- `thumb_w: Option<u32>` — thumbnail width after resize
- `thumb_h: Option<u32>` — thumbnail height after resize

### `PendingShardAssembly`
State for reassembling a chunked vault shard from multiple `ShardChunk` messages.
- `server_id, content_id, shard_index, shard_key` — shard identity
- `k, m` — Reed-Solomon parameters
- `total_size` — total data size
- `tier` — storage tier
- `expected_chunks: u32` — how many chunks to expect
- `received: HashSet<u32>` — which chunk indices have arrived
- `chunk_data: Vec<(u32, Vec<u8>)>` — collected chunk data
- `sender_peer: String` — who is sending
- `received_at: Instant` — when assembly started (for timeout)

### `PendingFileStream`
Pending streamed file transfer state. AES key stored here until stream bytes arrive.
- `aes_key, aes_nonce` — AES-256-GCM encryption material
- `file_name, ext` — file identity
- `sender` — sender peer ID
- `server_id, channel_id` — context (empty for DMs)
- `message_id` — associated message
- `is_image` — whether file is an image
- `width, height` — image dimensions (if applicable)

### `PendingShardStream`
Pending streamed shard transfer metadata. Stored until stream bytes arrive.
- `server_id, content_id, shard_index, shard_key` — shard identity
- `k, m` — Reed-Solomon parameters
- `total_size` — total data size
- `tier` — storage tier

### `SyncMessageItem`
A single message in a channel sync batch (`ChannelSyncBatch.messages`).
- `s` — sender peer ID
- `t` — message text
- `ts` — timestamp (millis since epoch)
- `sig, pk` — Ed25519 signature and public key
- `mid` — unique message ID
- `edited_at: Option<i64>` — edit timestamp (if edited)
- `reply_to: Option<String>` — reply threading
- `file_id: Option<String>` — file attachment
- `file_meta: Option<SyncFileMetaItem>` — file metadata for late joiners (so they can create file cards)
- `hidden_at: Option<i64>` — deletion timestamp (if soft-deleted)
- `reactions: Vec<SyncReactionItem>` — reactions on this message

### `SyncReactionItem`
A single reaction in a sync batch.
- `e` — emoji string
- `p` — reactor peer ID
- `ts` — added_at timestamp
- `sig, pk` — Ed25519 verification data

### `SyncFileMetaItem`
File metadata bundled with sync messages so late joiners can create file cards without having the actual file.
- `fid` — file ID
- `name` — file name
- `ext` — extension
- `mime` — MIME type
- `size` — file size
- `img` — is image
- `w, h` — dimensions (if image)
- `mid` — message ID
- `ts` — timestamp
- `sender` — sender peer ID
- `vthumb: Option<VideoThumbRef>` — video thumbnail back-reference (Phase 6.75)

### `DmSyncItem`
A single DM in a DM sync batch (`DmSyncBatch.messages`).
- `t` — message text
- `ts` — timestamp (millis since epoch)
- `mine: bool` — true if the sync-batch sender originally sent this message
- `sig, pk` — Ed25519 verification data
- `mid` — unique message ID
- `edited_at: Option<i64>` — edit timestamp
- `reply_to: Option<String>` — reply threading
- `file_id: Option<String>` — file attachment
- `file_meta: Option<SyncFileMetaItem>` — file metadata for late joiners
- `hidden_at: Option<i64>` — deletion timestamp
- `reactions: Vec<SyncReactionItem>` — reactions

---

## SyncCoordinator (Multi-Peer Fan-Out Sync)

Coordinates multi-peer fan-out sync across servers and channels. Instead of syncing every channel from one peer, the coordinator spreads channel sync across ALL available peers evenly.

### Flow
1. `SessionEstablished` -> register peer with coordinator via `types.rs:SyncCoordinator::register_peer()`
2. After 500ms collection window -> assign channels to peers round-robin
3. Send lightweight `ChannelSyncProbe` to each assigned peer
4. Probe response: if timestamps differ -> fire full `ChannelSyncRequest`. If timestamps match -> skip
5. Result: parallel sync, spread evenly, zero wasted bandwidth

### `PendingServerSync`
Tracks a server that needs sync after reconnection.
- `available_peers: Vec<String>` — peer IDs available for sync (connected server members)
- `channels: Vec<(String, i64)>` — channels needing sync: (channel_id, our_latest_timestamp)
- `started_at: Instant` — when first peer registered
- `dispatched: bool` — whether probes have been sent

### `SyncCoordinator`
- `pending: HashMap<String, PendingServerSync>` — servers waiting for sync
- `collection_window: Duration` — 500ms default; waits for more peers to connect before dispatching

### Methods
- `types.rs:SyncCoordinator::new()` — creates coordinator with 500ms collection window
- `types.rs:SyncCoordinator::register_peer(server_id, peer_str, channels_with_timestamps)` — register a newly connected peer for a server's sync. Called from PeerJoined. Updates channel list if the new registration provides more channels.
- `types.rs:SyncCoordinator::collect_ready()` — returns servers ready for dispatch (collection window elapsed). Assigns channels to peers via round-robin with optional backup peer (if >= 3 peers available, backup offset = peer_count/2 + 1 for maximum spread). Returns `Vec<(server_id, Vec<(peer_str, Vec<(channel_id, our_latest)>)>)>`.
- `types.rs:SyncCoordinator::remove_server(server_id)` — remove completed server from pending map.
- `types.rs:SyncCoordinator::has_pending()` — check if any servers still need dispatch.
- `types.rs:SyncCoordinator::cleanup_stale()` — clean up dispatched entries older than 30 seconds.
