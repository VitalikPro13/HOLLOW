# FFI CRDT and Storage API

Two FFI modules expose Rust CRDT operations and local database access to Dart via flutter_rust_bridge. `api/crdt.rs` handles server/channel/member CRDT mutations and queries. `api/storage.rs` handles message persistence, profiles, settings, file metadata, reactions, unread counts, verified peers, and backup/restore.

## Architecture: Command Dispatch vs Direct DB Read

Every function in these modules follows one of two patterns:

**Command dispatch (mutating operations):** Acquires the global node lock via `get_node()`, sends a `NodeCommand` variant through `state.cmd_tx` (tokio mpsc channel), and returns immediately. The swarm event loop processes the command asynchronously. These functions return `"pending"` or `Ok(())` -- the actual result arrives via `NetworkEvent` stream to Dart.

**Direct DB read (query operations):** Opens `~/.hollow/messages.db` directly using `MessageStore::open()` with the identity-derived passphrase. Deserializes `ServerState` JSON from the `server_states` table. No node lock needed. Every DB-read function in `api/crdt.rs` independently derives the DB passphrase from `identity::load_or_create_identity()` -> protobuf encoding -> first 32 bytes hex-encoded. In `api/storage.rs`, reads go through the global `STORE` singleton instead.

## FFI Struct Definitions (crdt.rs)

### ServerFfi
Fields: `server_id: String`, `name: String`, `member_count: u32`, `channel_count: u32`. Returned by `get_joined_servers()`.

### ChannelFfi
Fields: `channel_id: String`, `name: String`, `category: Option<String>`, `channel_type: String` ("text" or "voice"), `visibility: String` ("everyone"/"moderator"/"admin"), `posting: String` ("everyone"/"moderator"/"admin"). Returned by `get_server_channels()`. Maps from `ChannelType`, `ChannelVisibility`, `ChannelPosting` enums to string representations.

### MemberFfi
Fields: `peer_id: String`, `display_name: String`, `role: String`, `nickname: String`, `twitch_username: String`, `labels: Vec<LabelFfi>`. Returned by `get_server_members()`. Role comes from `state.get_role()`, nickname from `state.get_nickname()`, twitch from `state.get_twitch_username()`, labels from `state.get_member_labels()`.

### LabelFfi
Fields: `label_id: String`, `name: String`, `color: String`. Used in `MemberFfi.labels` and returned by `get_server_labels()`.

### StorageStatsFfi
Fields: `total_pledged_bytes: u64`, `total_used_bytes: u64`, `my_pledge_bytes: u64`, `my_used_bytes: u64`, `member_count: u32`, `min_pledge_mb: u64`. Returned by `get_storage_stats()`.

### VaultFileStatusFfi
Fields: `content_id: String`, `file_name: String`, `original_size: u64`, `k: u16`, `m: u16`, `local_shard_count: u16`, `is_reconstructable: bool`, `channel_id: String`, `created_at: i64`. Returned by `get_vault_file_statuses()`. `is_reconstructable` is true when `local_shard_count >= k`.

## Server CRUD (crdt.rs) -- Command Dispatch

### crdt.rs:create_server()
Signature: `fn create_server(name: String) -> Result<String, String>`. Sends `NodeCommand::CreateServer { name }`. Returns `"pending"` -- the actual server_id arrives via NetworkEvent. The swarm handler generates the server_id, creates the initial ServerState CRDT, joins the WSS relay room, and broadcasts to peers.

### crdt.rs:rename_server()
Signature: `fn rename_server(server_id: String, new_name: String) -> Result<(), String>`. Sends `NodeCommand::RenameServer { server_id, new_name }`. The handler applies a CRDT rename op and broadcasts to peers.

### crdt.rs:delete_server()
Signature: `fn delete_server(server_id: String) -> Result<(), String>`. Sends `NodeCommand::DeleteServer { server_id }`. Removes from local DB and memory. Owner-only operation.

### crdt.rs:join_server()
Signature: `fn join_server(server_id: String, twitch_proof_json: Option<String>) -> Result<(), String>`. Sends `NodeCommand::JoinServer { server_id, twitch_proof_json }`. Connects to the server's signaling room and requests membership from existing members. The optional `twitch_proof_json` carries Twitch OAuth proof for servers requiring Twitch verification.

### crdt.rs:leave_server()
Signature: `fn leave_server(server_id: String) -> Result<(), String>`. Sends `NodeCommand::LeaveServer { server_id }`. The local user is removed from the server. Owner cannot leave -- must delete or transfer ownership first.

## Channel CRUD (crdt.rs)

### crdt.rs:create_channel()
Signature: `fn create_channel(server_id: String, name: String, category: Option<String>, channel_type: String) -> Result<String, String>`. Sends `NodeCommand::CreateChannel { server_id, name, category, channel_type }`. Returns `"pending"`. Actual channel_id comes via event. `channel_type` is "text" or "voice".

### crdt.rs:remove_channel()
Signature: `fn remove_channel(server_id: String, channel_id: String) -> Result<(), String>`. Sends `NodeCommand::RemoveChannel { server_id, channel_id }`.

### crdt.rs:rename_channel()
Signature: `fn rename_channel(server_id: String, channel_id: String, new_name: String) -> Result<(), String>`. Sends `NodeCommand::RenameChannel { server_id, channel_id, new_name }`.

### crdt.rs:set_channel_visibility()
Signature: `fn set_channel_visibility(server_id: String, channel_id: String, visibility: String) -> Result<(), String>`. Sends `NodeCommand::SetChannelVisibility`. Visibility values: "everyone", "moderator", "admin". UI-filtered only -- all members still receive messages via the server-wide MLS group.

### crdt.rs:set_channel_posting()
Signature: `fn set_channel_posting(server_id: String, channel_id: String, posting: String) -> Result<(), String>`. Sends `NodeCommand::SetChannelPosting`. Posting values: "everyone", "moderator", "admin". Same UI-only enforcement caveat as visibility.

### crdt.rs:update_channel_layout()
Signature: `fn update_channel_layout(server_id: String, layout_json: String) -> Result<(), String>`. Sends `NodeCommand::UpdateChannelLayout { server_id, layout_json }`. `layout_json` is a JSON array of `ChannelLayoutItem` objects that defines channel ordering and category grouping.

### crdt.rs:get_channel_layout()
**Direct DB read.** Signature: `fn get_channel_layout(server_id: String) -> Result<String, String>`. Opens DB, loads ServerState, serializes `state.channel_layout` to JSON string. Returns the JSON array of `ChannelLayoutItem`.

### crdt.rs:pin_message()
Signature: `fn pin_message(server_id: String, channel_id: String, message_id: String) -> Result<(), String>`. Sends `NodeCommand::PinMessage`. Requires MANAGE_CHANNELS permission.

### crdt.rs:unpin_message()
Signature: `fn unpin_message(server_id: String, channel_id: String, message_id: String) -> Result<(), String>`. Sends `NodeCommand::UnpinMessage`. Requires MANAGE_CHANNELS permission.

### crdt.rs:get_pinned_messages()
**Direct DB read.** Signature: `fn get_pinned_messages(server_id: String, channel_id: String) -> Result<Vec<String>, String>`. Opens DB, loads ServerState, calls `state.get_pinned_messages(&channel_id)`. Returns list of message IDs.

## Server Queries (crdt.rs) -- Direct DB Read

All query functions follow the same pattern: derive passphrase from identity, open `MessageStore`, load server state JSON, deserialize `ServerState`, extract data.

### crdt.rs:get_joined_servers()
Signature: `fn get_joined_servers() -> Result<Vec<ServerFfi>, String>`. Calls `store.load_all_servers()` which returns `(server_id, state_json)` pairs. Deserializes each into `ServerState`, maps to `ServerFfi` with name, member_count, channel_count. Silently skips servers that fail to deserialize (handles old data gracefully).

### crdt.rs:get_server_channels()
Signature: `fn get_server_channels(server_id: String) -> Result<Vec<ChannelFfi>, String>`. Loads single server state, calls `state.channels_list()`, maps each to `ChannelFfi`. Converts `ChannelType::Voice` to "voice", everything else to "text". Maps `ChannelVisibility` and `ChannelPosting` enums to lowercase strings.

### crdt.rs:get_server_members()
Signature: `fn get_server_members(server_id: String) -> Result<Vec<MemberFfi>, String>`. Calls `state.members_list()`, enriches each member with `state.get_role()`, `state.get_nickname()`, `state.get_twitch_username()`, and `state.get_member_labels()`. Labels are mapped to `LabelFfi` structs.

### crdt.rs:get_server_setting()
Signature: `fn get_server_setting(server_id: String, key: String) -> Result<String, String>`. Reads from `state.settings` HashMap. Each setting is a CRDT register -- calls `.read().clone()` to get the current value. Returns empty string if key not set.

### crdt.rs:get_server_labels()
Signature: `fn get_server_labels(server_id: String) -> Result<Vec<LabelFfi>, String>`. Calls `state.labels_list()`, maps to `LabelFfi` structs.

### crdt.rs:get_banned_members()
Signature: `fn get_banned_members(server_id: String) -> Result<Vec<String>, String>`. Calls `state.banned_list()`. Returns peer_id strings of banned members.

## Roles and Permissions (crdt.rs)

### crdt.rs:get_my_role()
**Direct DB read.** Signature: `fn get_my_role(server_id: String) -> Result<String, String>`. Gets local user's peer_id from identity, calls `state.get_role(&peer_id)`. Returns "owner", "admin", "moderator", or "member".

### crdt.rs:get_my_permissions()
**Direct DB read.** Signature: `fn get_my_permissions(server_id: String) -> Result<u32, String>`. Gets local user's peer_id, calls `state.get_permissions(&peer_id)`. Returns bitmask. The bitmask is defined in `crdt::server_state` (SEND_MESSAGES=1, MANAGE_CHANNELS=2, MANAGE_ROLES=4, KICK_MEMBERS=8, BAN_MEMBERS=16, MANAGE_SERVER=32).

### crdt.rs:change_member_role()
**Command dispatch.** Signature: `fn change_member_role(server_id: String, peer_id: String, new_role: String) -> Result<(), String>`. Sends `NodeCommand::ChangeRole { server_id, peer_id, new_role }`. Requires MANAGE_ROLES permission. Enforced tier-gating: can only change roles below your own rank.

### crdt.rs:change_role_permissions()
**Command dispatch.** Signature: `fn change_role_permissions(server_id: String, role: String, permissions: u32) -> Result<(), String>`. Sends `NodeCommand::ChangeRolePermissions { server_id, role, permissions }`. Owner-only operation.

### crdt.rs:get_role_permissions()
**Direct DB read.** Signature: `fn get_role_permissions(server_id: String, role: String) -> Result<u32, String>`. Calls `state.get_role_permissions(&role)`. Returns custom permissions if set, otherwise default for that role.

## Member Management (crdt.rs) -- Command Dispatch

### crdt.rs:kick_member()
Signature: `fn kick_member(server_id: String, peer_id: String) -> Result<(), String>`. Sends `NodeCommand::KickMember`. Requires KICK_MEMBERS permission and must outrank the target.

### crdt.rs:ban_member()
Signature: `fn ban_member(server_id: String, peer_id: String) -> Result<(), String>`. Sends `NodeCommand::BanMember`. Prevents rejoin. Requires BAN_MEMBERS permission.

### crdt.rs:unban_member()
Signature: `fn unban_member(server_id: String, peer_id: String) -> Result<(), String>`. Sends `NodeCommand::UnbanMember`. Allows the member to rejoin.

### crdt.rs:set_nickname()
Signature: `fn set_nickname(server_id: String, peer_id: String, nickname: String) -> Result<(), String>`. Sends `NodeCommand::SetNickname`. Pass empty string to clear.

### crdt.rs:set_twitch_username()
Signature: `fn set_twitch_username(server_id: String, peer_id: String, twitch_username: String) -> Result<(), String>`. Sends `NodeCommand::SetTwitchUsername`.

## Labels (crdt.rs) -- Command Dispatch

All label mutations send NodeCommands. Labels are cosmetic roles (separate from power roles).

### crdt.rs:create_label()
Signature: `fn create_label(server_id: String, name: String, color: String) -> Result<(), String>`. Sends `NodeCommand::CreateLabel`. The label_id is generated server-side.

### crdt.rs:delete_label()
Signature: `fn delete_label(server_id: String, label_id: String) -> Result<(), String>`. Sends `NodeCommand::DeleteLabel`.

### crdt.rs:update_label()
Signature: `fn update_label(server_id: String, label_id: String, name: String, color: String) -> Result<(), String>`. Sends `NodeCommand::UpdateLabel`.

### crdt.rs:assign_label()
Signature: `fn assign_label(server_id: String, label_id: String, peer_id: String) -> Result<(), String>`. Sends `NodeCommand::AssignLabel`.

### crdt.rs:unassign_label()
Signature: `fn unassign_label(server_id: String, label_id: String, peer_id: String) -> Result<(), String>`. Sends `NodeCommand::UnassignLabel`.

## Server Settings and Avatar (crdt.rs)

### crdt.rs:update_server_setting()
**Command dispatch.** Signature: `fn update_server_setting(server_id: String, key: String, value: String) -> Result<(), String>`. Sends `NodeCommand::UpdateServerSetting { server_id, key, value }`. The key-value pair is stored in `ServerState.settings` as a CRDT register.

### crdt.rs:set_server_avatar()
**Command dispatch (wraps update_server_setting).** Signature: `fn set_server_avatar(server_id: String, raw_bytes: Vec<u8>) -> Result<(), String>`. Processes raw image bytes to 128x128 WebP via `image_convert::process_avatar_image()`, base64-encodes the result, then calls `update_server_setting(server_id, "server_avatar", b64)`. Avatar data is stored directly in the CRDT state as a base64 string.

### crdt.rs:clear_server_avatar()
**Command dispatch (wraps update_server_setting).** Calls `update_server_setting(server_id, "server_avatar", "")`.

### crdt.rs:get_server_avatar()
**Direct DB read (wraps get_server_setting).** Signature: `fn get_server_avatar(server_id: String) -> Result<Option<Vec<u8>>, String>`. Calls `get_server_setting(server_id, "server_avatar")`, base64-decodes if non-empty. Returns `None` if no avatar set, `Some(bytes)` with the 128x128 WebP data otherwise.

## Vault and Storage Stats (crdt.rs)

### crdt.rs:set_storage_pledge()
**Command dispatch.** Signature: `fn set_storage_pledge(server_id: String, pledge_bytes: u64) -> Result<(), String>`. Sends `NodeCommand::SetStoragePledge`. Sets the local user's storage contribution pledge for the server.

### crdt.rs:get_storage_stats()
**Direct DB read + vault read.** Signature: `fn get_storage_stats(server_id: String) -> Result<StorageStatsFfi, String>`. Complex aggregation from multiple sources:
1. CRDT state: `state.total_pledged_bytes()`, `state.get_storage_pledge(&peer_id)`, `state.members.len()`, `state.min_pledge_mb()`
2. Vault ContentStore: `content_store.total_manifest_size(&server_id)` for server total, `content_store.total_storage_used(&server_id)` for local shards
3. MessageStore: `store.total_file_storage_for_server(&server_id)` for P2P file sizes, `store.total_message_storage_for_server(&server_id)` for message text sizes
4. Calculation: `total_used_bytes` = manifest_total + msg_used (if vault has data), else file_used + msg_used. `my_used_bytes` = local_shards + file_used + msg_used. Does not double-count manifests and P2P files.

### crdt.rs:get_vault_file_statuses()
**Direct DB read.** Signature: `fn get_vault_file_statuses(server_id: String) -> Result<Vec<VaultFileStatusFfi>, String>`. Opens ContentStore, lists manifests for the server, filters out full-replication files (k=0, m=0), counts local shards per content_id. Sets `is_reconstructable = local_count >= k`. Used by the Archive tab's shard status indicator.

### crdt.rs:vault_upload_file()
**Command dispatch with preprocessing.** Signature: `fn vault_upload_file(server_id: String, channel_id: String, file_path: String, message_id: String) -> Result<String, String>`. Reads the file from disk, determines MIME type from extension via `vault::pipeline::mime_from_ext()`, encrypts with AES-256-GCM via `vault::pipeline::aes_encrypt()`, computes `content_id` from ciphertext hash via `vault::content_store::content_id()`, then sends `NodeCommand::VaultUploadFile` with all encrypted data. Returns the content_id immediately. The swarm handler performs erasure coding, shard distribution, and manifest broadcast.

### crdt.rs:vault_download_file()
**Hybrid: cache check + command dispatch.** Signature: `fn vault_download_file(server_id: String, content_id: String) -> Result<String, String>`. First checks the local vault cache via `vault::pipeline::check_cache(&content_id, &ext)` -- if cached, returns the disk path immediately. If not cached, sends `NodeCommand::VaultDownloadFile` to the swarm for reconstruction (potentially fetching missing shards from peers). Returns empty string, signaling Dart to watch for a `VaultDownloadComplete` event containing the disk path.

### crdt.rs:delete_vault_content()
**Command dispatch.** Signature: `fn delete_vault_content(server_id: String, content_id: String) -> Result<(), String>`. Sends `NodeCommand::DeleteVaultContent`. Admin-only, requires MANAGE_SERVER permission. Broadcasts `ShardDelete` to all connected members and removes local shards.

## Recovery Pool (crdt.rs) -- Command Dispatch

### crdt.rs:initiate_recovery_pool()
Signature: `fn initiate_recovery_pool(server_id: String) -> Result<String, String>`. Generates a random 16-char hex token (8 random bytes), constructs `hollow://recovery?server={server_id}&token={token}` invite link, sends `NodeCommand::InitiateRecoveryPool { server_id, token }`. Returns the invite link.

### crdt.rs:join_recovery_pool()
Signature: `fn join_recovery_pool(invite_link: String) -> Result<(), String>`. Parses the invite link to extract `server_id` and `token` by splitting on `server=` and `token=` delimiters. Sends `NodeCommand::JoinRecoveryPool { server_id, token }`.

### crdt.rs:stop_recovery_pool()
Signature: `fn stop_recovery_pool(server_id: String) -> Result<(), String>`. Sends `NodeCommand::StopRecoveryPool { server_id }`.

## Storage Module Architecture (storage.rs)

### Global Store Singleton
`static STORE: OnceLock<Mutex<Option<MessageStore>>>` -- initialized once via `open_message_store()`. All subsequent storage FFI functions access the store through `get_store()` which returns a reference to this global. Functions acquire the mutex, unwrap the `Option`, and delegate to `MessageStore` methods. This avoids re-opening the DB on every call (unlike `api/crdt.rs` query functions which open fresh connections each time).

### storage.rs:derive_db_key()
Internal helper. Loads identity, protobuf-encodes the keypair, hex-encodes the first 32 bytes. Same derivation used in `api/crdt.rs` query functions. Deterministic for the same identity.

### storage.rs:open_message_store()
Signature: `fn open_message_store() -> Result<(), String>`. Must be called after identity is loaded, typically once at app start. Creates `~/.hollow/` directory if needed. Opens `~/.hollow/messages.db` with SQLCipher encryption using the identity-derived passphrase. Stores the `MessageStore` in the global `STORE` singleton. No-ops if already open (returns `Ok(())`).

## FFI Struct Definitions (storage.rs)

### StoredMessage
DM message struct. Fields: `id: i64`, `peer_id: String`, `text: String`, `is_mine: bool`, `timestamp: i64`, `signature: Option<String>`, `public_key: Option<String>`, `message_id: Option<String>`, `edited_at: Option<i64>`, `hidden_at: Option<i64>`, `reply_to_mid: Option<String>`, `file_id: Option<String>`, `link_preview: Option<LinkPreviewRef>`. Returned by `load_messages()`, `load_all_dm_messages()`, `search_dm_messages()`.

### StoredChannelMessage
Server channel message struct. Fields: `id: i64`, `server_id: String`, `channel_id: String`, `sender_id: String`, `text: String`, `is_mine: bool`, `timestamp: i64`, `signature: Option<String>`, `public_key: Option<String>`, `message_id: Option<String>`, `edited_at: Option<i64>`, `hidden_at: Option<i64>`, `reply_to_mid: Option<String>`, `file_id: Option<String>`, `link_preview: Option<LinkPreviewRef>`. Returned by `load_channel_messages()`, `load_all_channel_messages()`, `search_channel_messages()`.

### StoredMessageEdit
Edit history entry. Fields: `message_id: String`, `old_text: String`, `new_text: String`, `edited_at: i64`, `signature: Option<String>`, `public_key: Option<String>`, `prev_signature: Option<String>`, `prev_public_key: Option<String>`, `prev_timestamp: Option<i64>`. Returned by `load_message_edits()`.

### UserProfile
Fields: `peer_id: String`, `display_name: String`, `status: String`, `about_me: String`, `updated_at: i64`, `avatar_bytes: Option<Vec<u8>>`, `banner_bytes: Option<Vec<u8>>`. Returned by `get_profile()`, `get_all_profiles()`.

### FriendFfi
Fields: `peer_id: String`, `status: String`, `direction: String`, `requested_at: i64`, `updated_at: i64`. Returned by `load_friends()`.

### StoredReaction
Fields: `message_id: String`, `emoji: String`, `peer_id: String`, `added_at: i64`. Returned by `load_reactions()`.

### StoredFileInfo
File metadata struct. Fields: `file_id: String`, `file_name: String`, `file_ext: String`, `mime_type: String`, `size_bytes: u64`, `chunk_count: u32`, `chunks_received: u32`, `is_image: bool`, `width: Option<u32>`, `height: Option<u32>`, `message_id: Option<String>`, `context_type: String`, `context_id: String`, `sender_id: String`, `is_mine: bool`, `created_at: i64`, `completed_at: Option<i64>`, `disk_path: Option<String>`, `expired_at: Option<i64>`, `video_thumb: Option<VideoThumbRef>`. The `video_thumb` field indicates this file is a thumbnail for a vault-stored video -- Dart renders a play button overlay. Conversion from internal `StoredFile` to FFI struct handled by `stored_file_to_ffi()` helper.

## DM Message Operations (storage.rs)

### storage.rs:save_message()
Signature: `fn save_message(peer_id, text, is_mine, timestamp, signature, public_key) -> Result<i64, String>`. Inserts a DM message. Delegates to `ms.insert()` with `None` for message_id, reply_to_mid, and file_id (those are set elsewhere). Returns the SQLite row id.

### storage.rs:load_messages()
Signature: `fn load_messages(peer_id: String, limit: i32) -> Result<Vec<StoredMessage>, String>`. Loads recent DM messages for a peer, ordered oldest-first, up to `limit`. Delegates to `ms.load_for_peer()`. Excludes soft-deleted messages (hidden_at set).

### storage.rs:load_all_dm_messages()
Signature: `fn load_all_dm_messages(peer_id: String) -> Result<Vec<StoredMessage>, String>`. Loads ALL DM messages including soft-deleted (hidden_at set). No limit. Ordered oldest-first. Used by the Archive "My Data" viewer for full data export.

### storage.rs:count_dm_messages()
Signature: `fn count_dm_messages(peer_id: String) -> Result<u32, String>`. Counts all DM messages for a peer including hidden/deleted. Delegates to `ms.count_dm_messages()`.

### storage.rs:search_dm_messages()
Signature: `fn search_dm_messages(peer_id: String, query: String, limit: i32) -> Result<Vec<StoredMessage>, String>`. Full-text search within DM messages for a specific peer. Delegates to `ms.search_dm_messages()`.

### storage.rs:get_dm_peer_ids()
Signature: `fn get_dm_peer_ids() -> Result<Vec<String>, String>`. Returns all distinct peer IDs that have DM messages in the local database. Used to populate the DM conversation list.

## Channel Message Operations (storage.rs)

### storage.rs:save_channel_message()
Signature: `fn save_channel_message(server_id, channel_id, sender_id, text, is_mine, timestamp, signature, public_key) -> Result<i64, String>`. Inserts a channel message. Delegates to `ms.insert_channel_message()` with `None` for message_id, reply_to_mid, and file_id. Returns row id cast to i64.

### storage.rs:load_channel_messages()
Signature: `fn load_channel_messages(server_id: String, channel_id: String, limit: i32) -> Result<Vec<StoredChannelMessage>, String>`. Loads recent channel messages, ordered oldest-first, up to `limit`. Delegates to `ms.load_channel_messages()`.

### storage.rs:load_all_channel_messages()
Signature: `fn load_all_channel_messages(server_id: String, channel_id: String) -> Result<Vec<StoredChannelMessage>, String>`. Loads ALL channel messages including soft-deleted. No limit. Ordered oldest-first. Used by the Archive "My Data" viewer.

### storage.rs:count_channel_messages_ffi()
Signature: `fn count_channel_messages_ffi(server_id: String, channel_id: String) -> Result<u32, String>`. Counts all channel messages including hidden/deleted. Note the `_ffi` suffix to avoid name collision with internal methods.

### storage.rs:search_channel_messages()
Signature: `fn search_channel_messages(server_id: String, channel_id: String, query: String, limit: i32) -> Result<Vec<StoredChannelMessage>, String>`. Full-text search within a specific channel. Delegates to `ms.search_channel_messages()`.

## Edit History (storage.rs)

### storage.rs:load_message_edits()
Signature: `fn load_message_edits(message_ids: Vec<String>) -> Result<Vec<StoredMessageEdit>, String>`. Batch loads edit history for multiple message IDs. Delegates to `ms.load_edits_for_messages()` which returns `HashMap<String, Vec<(old_text, new_text, edited_at, signature, public_key, prev_signature, prev_public_key, prev_timestamp)>>`. Flattens into a single `Vec<StoredMessageEdit>` sorted by `edited_at` ascending. Each edit preserves the cryptographic chain: `prev_signature` and `prev_public_key` link back to the message or prior edit being replaced.

## Reactions (storage.rs)

### storage.rs:load_reactions()
Signature: `fn load_reactions(message_ids: Vec<String>) -> Result<Vec<StoredReaction>, String>`. Batch loads reactions for multiple message IDs. Delegates to `ms.load_reactions_for_messages()` which returns `HashMap<String, Vec<(emoji, peer_id, added_at)>>`. Flattens into a single `Vec<StoredReaction>`. Efficient bulk loading for displaying reactions on a page of messages.

## Unread Counts (storage.rs)

### storage.rs:count_unread_dm()
Signature: `fn count_unread_dm(peer_id: String, last_seen_message_id: String) -> Result<u32, String>`. Counts DM messages newer than the given last-seen message ID. Only counts non-hidden messages from the other peer (`is_mine = 0`). Used when the user has previously opened the DM and has a last-seen marker.

### storage.rs:count_unread_channel()
Signature: `fn count_unread_channel(server_id: String, channel_id: String, last_seen_message_id: String) -> Result<u32, String>`. Counts channel messages newer than the given last-seen message ID. Only counts non-hidden messages from other members (`is_mine = 0`).

### storage.rs:count_all_unread_dm()
Signature: `fn count_all_unread_dm(peer_id: String) -> Result<u32, String>`. Counts ALL non-hidden messages from others in a DM. Used for never-opened DMs where there is no last-seen marker.

### storage.rs:count_all_unread_channel()
Signature: `fn count_all_unread_channel(server_id: String, channel_id: String) -> Result<u32, String>`. Counts ALL non-hidden messages from others in a channel. Used for never-opened channels.

## Profiles (storage.rs)

### storage.rs:get_profile()
Signature: `fn get_profile(peer_id: String) -> Result<Option<UserProfile>, String>`. Returns the stored profile for a specific peer. Returns `None` if no profile stored. Delegates to `ms.load_profile()`. Profile includes avatar_bytes and banner_bytes as raw binary data.

### storage.rs:get_all_profiles()
Signature: `fn get_all_profiles() -> Result<Vec<UserProfile>, String>`. Returns all stored profiles. Used to populate the profile cache on app startup. Delegates to `ms.load_all_profiles()`.

## App Settings KV Store (storage.rs)

### storage.rs:save_setting()
Signature: `fn save_setting(key: String, value: String) -> Result<(), String>`. Saves a key-value setting to the local database. Delegates to `ms.save_setting()`. Used for app preferences, UI state, license key, etc.

### storage.rs:load_setting()
Signature: `fn load_setting(key: String) -> Result<Option<String>, String>`. Loads a setting by key. Returns `None` if not set. Delegates to `ms.load_setting()`.

### storage.rs:save_mnemonic()
Convenience wrapper. Calls `ms.save_setting("recovery_mnemonic", &mnemonic)`. Called once on first identity generation.

### storage.rs:get_mnemonic()
Convenience wrapper. Calls `ms.load_setting("recovery_mnemonic")`. Returns the stored BIP-39 recovery mnemonic.

## Verified Peers / RAT Files (storage.rs)

### storage.rs:set_peer_verified()
Signature: `fn set_peer_verified(peer_id: String) -> Result<(), String>`. Marks a peer as identity-verified (fingerprint confirmed in person). Delegates to `ms.set_peer_verified()`.

### storage.rs:remove_peer_verified()
Signature: `fn remove_peer_verified(peer_id: String) -> Result<(), String>`. Removes verified status. Delegates to `ms.remove_peer_verified()`.

### storage.rs:is_peer_verified()
Signature: `fn is_peer_verified(peer_id: String) -> Result<bool, String>`. Checks verification status. Delegates to `ms.is_peer_verified()`.

### storage.rs:get_verified_peers()
Signature: `fn get_verified_peers() -> Result<Vec<(String, i64)>, String>`. Returns all verified peers as `(peer_id, verified_at_ms)` pairs. Delegates to `ms.get_verified_peers()`.

## Friends (storage.rs)

### storage.rs:load_friends()
Signature: `fn load_friends(status: Option<String>) -> Result<Vec<FriendFfi>, String>`. Loads all friends, optionally filtered by status (e.g., "accepted", "pending"). Delegates to `ms.load_friends()` which returns tuples of `(peer_id, status, direction, requested_at, updated_at)`. Maps to `FriendFfi` structs.

## File Metadata Operations (storage.rs)

### storage.rs:get_file_metadata()
Signature: `fn get_file_metadata(file_id: String) -> Result<Option<StoredFileInfo>, String>`. Gets file metadata by ID. Delegates to `ms.get_file_metadata()`, maps through `stored_file_to_ffi()`.

### storage.rs:get_content_id_for_file()
Signature: `fn get_content_id_for_file(file_id: String) -> Result<Option<String>, String>`. Gets the vault `content_id` linked to a file. Returns `None` for DM files or files in servers with <6 members (those use P2P replication, not vault erasure coding).

### storage.rs:get_files_for_message()
Signature: `fn get_files_for_message(message_id: String) -> Result<Vec<StoredFileInfo>, String>`. Gets all files attached to a specific message. Used to render file attachments in the chat UI.

### storage.rs:get_incomplete_files()
Signature: `fn get_incomplete_files() -> Result<Vec<StoredFileInfo>, String>`. Returns files where transfer is not yet complete (`completed_at` is NULL or `chunks_received < chunk_count`). Used for sync resume after reconnection.

### storage.rs:mark_file_complete()
Signature: `fn mark_file_complete(file_id: String, disk_path: String) -> Result<(), String>`. Marks a file as complete with its disk path. Used for share-backed files where the download completes through the Share system rather than the normal chunk transfer.

### storage.rs:get_missing_file_ids()
Signature: `fn get_missing_file_ids() -> Result<Vec<String>, String>`. Finds file_ids from messages that have no completed file on disk. Used to discover files that need downloading after message sync (late joiner scenario).

### storage.rs:reset_stale_files()
Signature: `fn reset_stale_files() -> Result<u32, String>`. Checks all completed files and resets those whose `disk_path` no longer exists on disk. Returns the count of reset entries. The reset files will be re-requested from peers on next sync.

### storage.rs:get_missing_image_file_ids_for_server()
Signature: `fn get_missing_image_file_ids_for_server(server_id: String) -> Result<Vec<String>, String>`. Gets file IDs for missing images in a specific server. Used for late-joiner image sync in 6+ member servers where images are fully replicated but the late joiner doesn't have them yet.

## Identity (storage.rs)

### storage.rs:has_identity()
Signature: `fn has_identity() -> Result<bool, String>`. Checks if `~/.hollow/identity.key` exists on disk. Used at app startup to determine whether to show the onboarding flow or go straight to login.

## Backup and Restore (storage.rs)

### storage.rs:export_backup()
Signature: `fn export_backup(output_path: String, include_vault: bool, include_files: bool, passphrase: String) -> Result<u64, String>`. Creates an encrypted `.hollow` backup file. Process:
1. Builds a ZIP archive in memory containing `identity.key` and `messages.db` (always included), plus optionally `vault/*` shard files and `files/*` downloaded files
2. Derives a 256-bit encryption key from the user passphrase via Argon2id (memory=64MB, iterations=3, parallelism=1, 16-byte random salt)
3. Encrypts the ZIP with AES-256-GCM (12-byte random nonce)
4. Writes output format: `[6-byte "HOLLOW" magic][16-byte salt][12-byte nonce][ciphertext...]`
5. Returns the total file size in bytes

### storage.rs:import_backup()
Signature: `fn import_backup(backup_path: String, passphrase: String) -> Result<(), String>`. Restores from a `.hollow` backup file. Must be called BEFORE `start_node()` since it overwrites the data directory. Process:
1. Validates the 6-byte "HOLLOW" magic header
2. Minimum size check: 6 + 16 + 12 + 16 bytes (magic + salt + nonce + minimum ciphertext with GCM tag)
3. Extracts salt and nonce, derives key via same Argon2id parameters
4. Decrypts ciphertext with AES-256-GCM. Wrong passphrase returns `"Wrong passphrase or corrupted backup"`
5. Validates the ZIP contains `identity.key` (required)
6. Extracts all files to `~/.hollow/`, creating subdirectories as needed (vault/, files/)

## Complete Function Classification

### Command dispatch functions (send NodeCommand, return immediately):
`crdt.rs`: `create_server`, `create_channel`, `remove_channel`, `rename_server`, `rename_channel`, `update_server_setting`, `set_server_avatar` (wraps update_server_setting), `clear_server_avatar` (wraps update_server_setting), `join_server`, `leave_server`, `delete_server`, `change_member_role`, `kick_member`, `ban_member`, `unban_member`, `set_nickname`, `set_twitch_username`, `update_channel_layout`, `pin_message`, `unpin_message`, `change_role_permissions`, `set_storage_pledge`, `vault_upload_file`, `delete_vault_content`, `initiate_recovery_pool`, `join_recovery_pool`, `stop_recovery_pool`, `create_label`, `delete_label`, `update_label`, `assign_label`, `unassign_label`

### Hybrid functions (cache check then optional command dispatch):
`crdt.rs`: `vault_download_file`

### Direct DB read functions (open DB, query, return):
`crdt.rs`: `get_joined_servers`, `get_server_channels`, `get_server_members`, `get_server_setting`, `get_server_avatar` (wraps get_server_setting), `get_my_role`, `get_my_permissions`, `get_role_permissions`, `get_channel_layout`, `get_pinned_messages`, `get_banned_members`, `get_server_labels`, `get_storage_stats`, `get_vault_file_statuses`

### Global store singleton functions (use STORE static):
`storage.rs`: All functions -- `open_message_store`, `save_message`, `load_messages`, `load_all_dm_messages`, `load_message_edits`, `count_dm_messages`, `count_channel_messages_ffi`, `save_channel_message`, `load_channel_messages`, `load_all_channel_messages`, `search_channel_messages`, `search_dm_messages`, `load_reactions`, `get_profile`, `get_all_profiles`, `save_setting`, `load_setting`, `set_peer_verified`, `remove_peer_verified`, `is_peer_verified`, `get_verified_peers`, `count_unread_dm`, `count_unread_channel`, `count_all_unread_dm`, `count_all_unread_channel`, `get_dm_peer_ids`, `load_friends`, `get_file_metadata`, `get_content_id_for_file`, `get_files_for_message`, `get_incomplete_files`, `mark_file_complete`, `get_missing_file_ids`, `reset_stale_files`, `get_missing_image_file_ids_for_server`, `save_mnemonic`, `get_mnemonic`, `has_identity`, `export_backup`, `import_backup`

## DB Access Pattern Difference

`api/crdt.rs` query functions open a fresh `MessageStore` connection on every call, independently deriving the passphrase from identity each time. This is because CRDT queries need to deserialize `ServerState` from the `server_states` table, and the crdt module was designed to be callable even if the global store hasn't been initialized.

`api/storage.rs` uses the global `STORE` singleton (initialized by `open_message_store()`). Every function acquires the mutex and unwraps the Option. If the store hasn't been opened, all functions return `"Message store is not open"`. The singleton pattern avoids repeated DB open overhead for the high-frequency message operations.

Both use the same DB file (`~/.hollow/messages.db`) and the same identity-derived passphrase, so they operate on the same SQLCipher database.
