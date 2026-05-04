# Event System, Settings, and Miscellaneous Providers

This document covers the central event routing system (EventStreamNotifier), all settings/preference providers, notification providers, and every miscellaneous provider (archive, updater, news, room budget, license key, vault status, node lifecycle, relay stats, recovery pool).

Source: `lib/src/core/providers/event_provider.dart`, `settings_provider.dart`, `theme_provider.dart`, `layout_provider.dart`, `notification_provider.dart`, `system_notification_provider.dart`, `archive_provider.dart`, `updater_provider.dart`, `news_provider.dart`, `room_budget_provider.dart`, `license_key_provider.dart`, `vault_status_provider.dart`, `node_provider.dart`, `relay_stats_provider.dart`, `recovery_pool_provider.dart`, `background_provider.dart`.

---

## EventStreamNotifier -- The Central Event Router

File: `lib/src/core/providers/event_provider.dart` (~1242 lines)
Provider: `eventStreamProvider` -- `NotifierProvider<EventStreamNotifier, bool>` (state = whether streaming is active)

### Architecture

EventStreamNotifier is the SINGLE funnel through which ALL Rust-to-Dart events flow. Rust emits `NetworkEvent` variants through a `StreamSink` bridge (flutter_rust_bridge). The notifier subscribes to this stream via `networkService.watchNetworkEvents()` and routes each event to the appropriate Dart provider method.

### Lifecycle

- `start()` -- Subscribes to the Rust event stream. Guards against double-subscription (`if (_subscription != null) return`). Sets state to `true`. Error handler prints to debug console. On stream close, sets `_subscription = null` and `state = false`.
- `stop()` -- Cancels subscription, nullifies it, sets state to `false`.
- `build()` -- Returns `false` (not streaming initially). The node provider calls `start()` after the Rust node boots.

### Internal State Maps

- `_syncTimeouts: Map<String, Timer>` -- Per-server 10-second timers that clear stale sync status if no progress/completion arrives.
- `_pendingAutoDownloads: Map<String, ({bool sequential, String link, String fileId})>` -- Keyed by share rootHash. Tracks share-backed files awaiting manifest before auto-download can begin.
- `_shareToFileId: Map<String, String>` -- Maps share rootHash to file ID. Bridges Share progress/completion events to the file transfer provider so file cards show download state.
- `_serverSyncDone: Set<String>` -- Servers that have completed initial message sync. Share-backed file auto-downloads are suppressed during sync burst to prevent cache thrash on reconnection.

### The _dispatch() Method -- Complete Event Routing

The entire body is wrapped in `try-catch` to prevent unhandled exceptions from killing the event loop. Events are matched via Dart 3 pattern matching (`switch (event) { case NetworkEvent_Foo(...): ... }`).

#### Peer Discovery and Connection Events

**`NetworkEvent_PeerDiscovered`** (peerId, addresses)
- `peersProvider.notifier.addPeer(peerId, addresses)`
- `connectionStatusProvider.notifier.onPeerConnected(peerId)`

**`NetworkEvent_PeerExpired`** (peerId)
- `peersProvider.notifier.removePeer(peerId)`
- `invisiblePeersProvider.notifier.removePeer(peerId)`
- `webRtcProvider.notifier.disconnectPeer(peerId)`
- Does NOT deselect -- friends remain visible when offline.

**`NetworkEvent_PeerDisconnected`** (peerId)
- `peersProvider.notifier.removePeer(peerId)`
- `invisiblePeersProvider.notifier.removePeer(peerId)`
- `connectionStatusProvider.notifier.onPeerDisconnected(peerId)`
- `webRtcProvider.notifier.disconnectPeer(peerId)`
- `callProvider.notifier.handlePeerDisconnected(peerId)`
- `voiceChannelProvider.notifier.onPeerDisconnected(peerId)`
- Does NOT deselect -- friends remain visible when offline.

**`NetworkEvent_RoomCleared`**
- `peersProvider.notifier.clearAll()`
- Sets `selectedPeerProvider` to null.

**`NetworkEvent_Listening`** (address)
- Debug print only.

**`NetworkEvent_SessionEstablished`** (peerId)
- `peersProvider.notifier.markEncrypted(peerId)`
- `connectionStatusProvider.notifier.onSessionEstablished(peerId)`
- Calls `_clearFailedSyncForPeer(peerId)` -- clears "Sync failed" status for servers where this peer is a member and re-triggers sync for the currently viewed channel.
- `webRtcProvider.notifier.ensureConnection(peerId)` -- proactively establishes WebRTC data channel for P2P file transfers.

**`NetworkEvent_KeyExchangeStarted`** (peerId)
- `connectionStatusProvider.notifier.onKeyExchangeStarted(peerId)`

**`NetworkEvent_KeyExchangeProgress`** (peerId, stage)
- `connectionStatusProvider.notifier.onKeyExchangeProgress(peerId, stage)`

**`NetworkEvent_PeerStatusChanged`** (peerId, status) -- Phase 6.75 presence
- If status is `'invisible'`: `invisiblePeersProvider.notifier.setInvisible(peerId)`
- Otherwise: `invisiblePeersProvider.notifier.setOnline(peerId)`

#### DM Message Events

**`NetworkEvent_MessageReceived`** (fromPeer, text, timestamp, messageId, replyToMid, linkPreview, signature, publicKey)
- `chatProvider.notifier.receiveMessage(...)` with all fields including linkPreview, signature, publicKey.
- `typingProvider.notifier.clearTyping(fromPeer, fromPeer)`
- Unread tracking: Reads `windowVisibleProvider`, `selectedPeerProvider`, `selectedServerProvider`, and `chatAtBottomProvider` to determine if user is currently viewing this DM. Checks `notificationSettingsProvider.notifier.isDmEnabled(fromPeer)`. If not muted, calls `unreadProvider.notifier.onDmMessage(fromPeer, messageId, isViewingDm)`.
- System notification: If not viewing and not muted, calls `systemNotificationProvider.notifier.notifyDm(fromPeerId, text, replyToMid)`.

**`NetworkEvent_MessageSent`** (toPeer, messageId, timestamp, signature, publicKey)
- `chatProvider.notifier.hydrateSignature(toPeer, messageId, timestamp.toInt(), signature, publicKey)` -- Hydrates the optimistic in-memory entry with Rust's signed timestamp and signature/publicKey so Message Proof shows VERIFIED on fresh sends. Critical because Dart's `DateTime.now()` can differ from Rust's `SystemTime::now()` by a few ms.

**`NetworkEvent_MessageSendFailed`** (toPeer, error)
- `chatProvider.notifier.addSendFailure(toPeer, error)`

**`NetworkEvent_DmMessageEdited`** (peerId, messageId, newText, editedAt, signature, publicKey)
- `chatProvider.notifier.applyEdit(peerId, messageId, newText, editedAt, signature: signature, publicKey: publicKey)`

**`NetworkEvent_DmMessageDeleted`** (peerId, messageId, deletedAt)
- `chatProvider.notifier.applyDelete(peerId, messageId, deletedAt)`

**`NetworkEvent_DmReactionAdded`** (peerId, messageId, emoji, reactor)
- `chatProvider.notifier.applyAddReaction(peerId, messageId, emoji, reactor)`

**`NetworkEvent_DmReactionRemoved`** (peerId, messageId, emoji, reactor)
- `chatProvider.notifier.applyRemoveReaction(peerId, messageId, emoji, reactor)`

**`NetworkEvent_DmSyncCompleted`** (peerId, newMessageCount)
- If `newMessageCount > 0`: calls `chatProvider.notifier.loadHistory(peerId)` (atomic state replace, no separate clear step), `unreadProvider.notifier.recomputeDmUnread(peerId)`, and `_requestMissingFilesForDm(peerId)`.
- If `newMessageCount == 0`: does nothing. Live-delivered messages are already in memory via MessageReceived events.

#### Channel Message Events

**`NetworkEvent_ChannelMessageReceived`** (serverId, channelId, fromPeer, text, timestamp, messageId, replyToMid, linkPreview, signature, publicKey)
- `channelChatProvider.notifier.receiveMessage(...)` with all fields.
- `typingProvider.notifier.clearTyping('$serverId:$channelId', fromPeer)`
- Unread tracking: Checks `windowVisibleProvider`, `selectedServerProvider`, `selectedChannelProvider`, and `chatAtBottomProvider`. Gets effective channel notification level. If level is `mentions`, checks if message actually mentions local user via `@everyone`, `@displayName`, `@nickname`, or is a reply. If not muted and not mention-filtered, calls `unreadProvider.notifier.onChannelMessage(serverId, channelId, messageId, isViewingChannel)`.
- System notification: If not viewing and not filtered, calls `_notifyChannelWithName(serverId, channelId, fromPeer, text, replyToMid)`.

**`NetworkEvent_ChannelMessageSent`** (serverId, channelId, messageId, timestamp, signature, publicKey)
- `channelChatProvider.notifier.hydrateSignature(serverId, channelId, messageId, timestamp.toInt(), signature, publicKey)`

**`NetworkEvent_ChannelMessageEdited`** (serverId, channelId, messageId, newText, editedAt, signature, publicKey)
- `channelChatProvider.notifier.applyEdit(serverId, channelId, messageId, newText, editedAt, signature: signature, publicKey: publicKey)`

**`NetworkEvent_ChannelMessageDeleted`** (serverId, channelId, messageId, deletedAt)
- `channelChatProvider.notifier.applyDelete(serverId, channelId, messageId, deletedAt)`

**`NetworkEvent_ChannelReactionAdded`** (serverId, channelId, messageId, emoji, reactor)
- `channelChatProvider.notifier.applyAddReaction(serverId, channelId, messageId, emoji, reactor)`

**`NetworkEvent_ChannelReactionRemoved`** (serverId, channelId, messageId, emoji, reactor)
- `channelChatProvider.notifier.applyRemoveReaction(serverId, channelId, messageId, emoji, reactor)`

#### CRDT / Server Events

**`NetworkEvent_ServerCreated`** (serverId, name)
- `serverListProvider.notifier.onServerCreated(serverId, name)`
- `serverStripLayoutProvider.notifier.onServerCreated(serverId)`

**`NetworkEvent_ServerUpdated`** (serverId)
- `serverListProvider.notifier.onServerUpdated(serverId)`
- `serverAvatarProvider.notifier.loadAvatar(serverId)`
- `ref.invalidate(serverMembersProvider(serverId))`
- `ref.invalidate(myPermissionsProvider(serverId))`
- `ref.invalidate(myRoleProvider(serverId))`
- If this is the selected server: reloads `channelListProvider` and `channelLayoutProvider` for the server.

**`NetworkEvent_ServerDeleted`** (serverId)
- `serverListProvider.notifier.onServerDeleted(serverId)`
- `serverStripLayoutProvider.notifier.onServerDeleted(serverId)`
- If this was the active server: nullifies `selectedServerProvider`, `selectedChannelProvider`, and sets `serverSettingsOpenProvider` to false.

**`NetworkEvent_ServerJoined`** (serverId, name)
- Calls `handleTwitchJoinResult(success: true)` (routes to Twitch dialog if open).
- `serverListProvider.notifier.onServerCreated(serverId, name)`
- `serverStripLayoutProvider.notifier.onServerCreated(serverId)`
- Auto-selects the server: sets `selectedServerProvider`, nullifies `selectedPeerProvider`, clears `serverSettingsOpenProvider`.
- Loads channels and layout, then auto-selects the first text channel in layout order.
- Shows a HollowToast success notification.

**`NetworkEvent_ServerJoinFailed`** (serverId, reason)
- Shows HollowToast error with the failure reason.

**`NetworkEvent_ChannelAdded`** (serverId, channelId, name, channelType)
- `channelListProvider.notifier.onChannelAdded(serverId, channelId, name, channelType: channelType)`

**`NetworkEvent_ChannelRemoved`** (serverId, channelId)
- `channelListProvider.notifier.onChannelRemoved(serverId, channelId)`

**`NetworkEvent_ChannelRenamed`** (serverId, channelId, newName)
- `channelListProvider.notifier.onChannelRenamed(serverId, channelId, newName)`

**`NetworkEvent_MemberJoined`** (serverId, peerId)
- `serverListProvider.notifier.onServerUpdated(serverId)`
- `ref.invalidate(serverMembersProvider(serverId))`

**`NetworkEvent_MemberLeft`** (serverId, peerId)
- If peerId equals local user: treats as kick. Removes server from UI via `onServerDeleted`, removes from strip layout, deselects if active.
- If remote peer: `onServerUpdated` and invalidates `serverMembersProvider`.

**`NetworkEvent_RoleChanged`** (serverId, peerId, newRole)
- `serverListProvider.notifier.onServerUpdated(serverId)`
- `ref.invalidate(serverMembersProvider(serverId))`
- `ref.invalidate(myRoleProvider(serverId))`
- `ref.invalidate(myPermissionsProvider(serverId))`

**`NetworkEvent_SyncCompleted`** (serverId, opsApplied)
- `serverListProvider.notifier.onServerUpdated(serverId)`
- `serverAvatarProvider.notifier.loadAvatar(serverId)`
- `ref.invalidate(serverMembersProvider(serverId))`
- If selected server: reloads channels and layout.
- If NOT selected server: recomputes unread counts from DB via `crdt_api.getServerChannels()` then `unreadProvider.notifier.recomputeServerUnread()`.

#### Message Sync Events

**`NetworkEvent_MessageSyncStarted`** (serverId, peerId)
- `syncingPeersProvider.notifier.addPeer(serverId, peerId)`
- Sets sync status to `retrying` if currently failed, otherwise `syncing`.
- Starts a 10-second timeout timer. On expiration, clears status to `idle` and clears syncing peers.

**`NetworkEvent_MessageSyncCompleted`** (serverId, newMessageCount)
- Adds serverId to `_serverSyncDone` set (enables share auto-download for future messages).
- Cancels sync timeout timer.
- Clears syncing peers and sync progress for the server.
- Sets sync status to `synced`.
- If `newMessageCount > 0`: clears channel chat cache for the server (unconditional), merges from DB if currently viewing, calls `_requestMissingFiles(serverId)`.
- If `newMessageCount == 0` but viewing: reloads reactions only.
- Always refreshes pins for the viewed channel.
- Always recomputes unread counts from DB for non-viewed servers.

**`NetworkEvent_MessageSyncFailed`** (serverId, error)
- Cancels sync timeout and clears syncing peers/progress.
- If error contains `'re-keying'` or `'re-key'`: sets status to `retrying` (transient decrypt failure).
- Otherwise: sets status to `failed`.

**`NetworkEvent_MessageSyncProgress`** (serverId, channelId, receivedCount, totalCount)
- Resets the 10-second sync timeout (progress is happening).
- `syncProgressProvider.notifier.updateProgress(serverId, receivedCount, totalCount)`

#### Friend Events

**`NetworkEvent_FriendRequestReceived`**, **`NetworkEvent_FriendRequestAccepted`**, **`NetworkEvent_FriendRequestRejected`**, **`NetworkEvent_FriendRemoved`** (peerId)
- All call `friendsProvider.notifier.loadAll()` to refresh the full friend list.
- `FriendRemoved` additionally: deselects peer if viewing, closes split pane if showing the removed friend.

#### Typing Events

**`NetworkEvent_TypingStarted`** (peerId, serverId, channelId)
- Key is `peerId` for DMs (when serverId is empty), or `'$serverId:$channelId'` for channels.
- `typingProvider.notifier.setTyping(key, peerId)`

#### Pinned Message Events

**`NetworkEvent_MessagePinned`** (serverId, channelId, messageId)
- `pinnedProvider.notifier.applyPin(serverId, channelId, messageId)`

**`NetworkEvent_MessageUnpinned`** (serverId, channelId, messageId)
- `pinnedProvider.notifier.applyUnpin(serverId, channelId, messageId)`

#### Profile Events

**`NetworkEvent_ProfileUpdated`** (peerId)
- `profileProvider.notifier.reloadProfile(peerId)`

#### Error Events

**`NetworkEvent_Error`** (message)
- Debug prints the error.
- Copies message into `nodeProvider` state's error field.

#### File Transfer Events

**`NetworkEvent_FileHeaderReceived`** (fileId, fileName, sizeBytes, isImage, width, height, messageId, senderId, serverId, channelId, videoThumb, shareRootHash, shareKeyHex)
- Determines vault mode: `serverId != null && members >= 6`.
- `fileTransferProvider.notifier.onFileHeaderReceived(...)` with isVaultMode flag.
- Calls `_reloadChatForFile(fileId)` to update message UI.
- If share-backed (shareRootHash + shareKeyHex present) AND server sync is done: checks `autoDownloadThresholdProvider` (default 169 MB). If file size is within threshold, initiates auto-download via `share_api.shareStartFromRef()`. Maps rootHash to fileId in `_shareToFileId` and stores pending download info in `_pendingAutoDownloads`. If sync not yet done, skips auto-download to prevent cache thrash.

**`NetworkEvent_FileProgress`** (fileId, chunksReceived, totalChunks)
- `fileTransferProvider.notifier.onFileProgress(fileId, chunksReceived, totalChunks)`

**`NetworkEvent_FileCompleted`** (fileId, diskPath)
- `fileTransferProvider.notifier.onFileCompleted(fileId, diskPath)`
- Calls `_reloadChatForFile(fileId)` to render the image/file preview.

**`NetworkEvent_FileFailed`** (fileId, error)
- `fileTransferProvider.notifier.onFileFailed(fileId, error)`

#### Vault Shard Events (Phase 4)

**`NetworkEvent_ShardStored`** (serverId, contentId, fromPeer)
- `vaultStatusProvider.notifier.onShardStored(serverId, contentId)`

**`NetworkEvent_ShardStoreAckReceived`** (serverId, contentId, shardIndex, success, error)
- `vaultStatusProvider.notifier.onShardAckReceived(serverId, contentId, success)`

**`NetworkEvent_ShardStoreFailed`**, **`NetworkEvent_ShardDeleted`**, **`NetworkEvent_ShardReceived`**, **`NetworkEvent_ShardRequestFailed`**
- All are `break` (no-ops at Dart level).

#### Vault Upload/Download Pipeline Events (Phase 4)

**`NetworkEvent_VaultUploadProgress`** (serverId, contentId, phase, progress)
- `vaultStatusProvider.notifier.onUploadProgress(serverId, contentId, phase, progress)`

**`NetworkEvent_VaultUploadComplete`** (serverId, contentId, channelId)
- `vaultStatusProvider.notifier.onUploadComplete(serverId, contentId)`

**`NetworkEvent_VaultUploadFailed`** (serverId, contentId, error)
- `vaultStatusProvider.notifier.onUploadFailed(serverId, contentId, error)`

**`NetworkEvent_VaultDownloadProgress`** (serverId, contentId, phase, progress)
- `vaultStatusProvider.notifier.onDownloadProgress(serverId, contentId, phase, progress)`
- Also updates file transfer provider: `fileTransferProvider.notifier.onVaultDownloadProgress(contentId, phase, progress)` so file cards show vault phase.

**`NetworkEvent_VaultDownloadComplete`** (serverId, contentId, diskPath)
- `vaultStatusProvider.notifier.onDownloadComplete(serverId, contentId)`
- `fileTransferProvider.notifier.onVaultDownloadComplete(contentId, diskPath)`
- If recovery pool is active for this server: bridges to `recoveryPoolProvider.notifier.onFileRecovered(serverId, contentId, diskPath)`.

**`NetworkEvent_VaultDownloadFailed`** (serverId, contentId, error)
- `vaultStatusProvider.notifier.onDownloadFailed(serverId, contentId, error)`

**`NetworkEvent_VaultUploadReplicationFallback`** (serverId, contentId, online, needed)
- Debug print only (informational: not enough peers for erasure coding, using replication fallback).

#### Vault Rebalancing Events

**`NetworkEvent_RebalanceStarted`** (serverId, shardsToMove)
- `downloadManagerStateProvider.notifier.onRebalanceStarted(serverId, shardsToMove)`

**`NetworkEvent_RebalanceProgress`** (serverId, moved, total)
- `downloadManagerStateProvider.notifier.onRebalanceProgress(serverId, moved, total)`

**`NetworkEvent_RebalanceCompleted`** (serverId)
- `downloadManagerStateProvider.notifier.onRebalanceCompleted(serverId)`

#### WebRTC Events (Phase 5A)

**`NetworkEvent_WebRtcSignal`** (peerId, signalType, payload, connId)
- `webRtcProvider.notifier.handleSignal(peerId, signalType, payload, connId)`

**`NetworkEvent_WebRtcSendFile`** (peerId, transferId, filePath, totalSize, kind, shardIndex, chunkIndex)
- `webRtcProvider.notifier.handleSendFile(peerId, transferId, filePath, totalSize.toInt(), kind, shardIndex, chunkIndex: chunkIndex)`

#### Voice Call Events (Phase 5B)

**`NetworkEvent_CallSignal`** (peerId, signalType, payload)
- `callProvider.notifier.handleCallSignal(peerId, signalType, payload)`

#### Voice Channel Events (Phase 5C)

**`NetworkEvent_VoiceChannelJoined`** (serverId, channelId, peerId)
- `voiceChannelProvider.notifier.onPeerJoined(serverId, channelId, peerId)`
- If local peer: caches current selected channel as `preVcChannelId`, calls `onLocalJoined()`, auto-selects the voice channel.
- If remote peer and local user is in the same channel: calls `onRemotePeerJoined(peerId)` to initiate WebRTC.

**`NetworkEvent_VoiceChannelLeft`** (serverId, channelId, peerId)
- `voiceChannelProvider.notifier.onPeerLeft(serverId, channelId, peerId)`
- If local peer: restores the previously cached channel (or falls back to first text channel), clears `preVcChannelId`, calls `onLocalLeft()`.
- If remote peer: calls `onRemotePeerLeft(peerId)`.

**`NetworkEvent_VoiceChannelSignal`** (serverId, channelId, peerId, signalType, payload)
- `voiceChannelProvider.notifier.handleSignal(peerId, signalType, payload, serverId, channelId)`

**`NetworkEvent_VoiceChannelModeChanged`** (serverId, channelId, mode, gossipNeighbors)
- `voiceChannelProvider.notifier.onModeChanged(serverId, channelId, mode, gossipNeighbors)`

**`NetworkEvent_MlsEpochChanged`** (serverId, epoch, sframeKey)
- `voiceChannelProvider.notifier.onEpochChanged(serverId, epoch.toInt(), Uint8List.fromList(sframeKey))`

#### Gossip Relay Events (Phase 5D)

**`NetworkEvent_GossipConnect`** (peerId)
- `webRtcProvider.notifier.ensureConnection(peerId)`

**`NetworkEvent_GossipDisconnect`** (peerId)
- `webRtcProvider.notifier.disconnectPeer(peerId)`

**`NetworkEvent_GossipRelayFile`** (broadcastId, ttl, originPeerId, filePath, totalSize, kind, shardIndex, excludePeerId, serverId, channelId)
- `webRtcProvider.notifier.relayBroadcast(...)` with all gossip relay parameters.

#### Recovery Pool Events

**`NetworkEvent_RecoveryPoolCreated`** (serverId, inviteLink)
- `recoveryPoolProvider.notifier.onPoolCreated(serverId, inviteLink)`

**`NetworkEvent_RecoveryPoolJoined`** (serverId)
- `recoveryPoolProvider.notifier.onPoolJoinedPending(serverId)` -- pending mode until welcome confirmation.

**`NetworkEvent_RecoveryPoolJoinFailed`** (serverId, reason)
- Debug print only.

**`NetworkEvent_RecoveryPoolMemberJoined`** (serverId, peerId)
- `recoveryPoolProvider.notifier.onMemberJoined(serverId, peerId)`

**`NetworkEvent_RecoveryPoolMemberLeft`** (serverId, peerId)
- `recoveryPoolProvider.notifier.onMemberLeft(serverId, peerId)`

**`NetworkEvent_RecoveryPoolStatus`** (serverId, totalFiles, reconstructable, partial, noShards, progressPct)
- `recoveryPoolProvider.notifier.onStatus(serverId, ...)` with all status fields.

**`NetworkEvent_RecoveryPoolShardTransferred`**
- `break` -- dashboard updates via status events.

**`NetworkEvent_RecoveryPoolFileRecovered`** (serverId, contentId, diskPath)
- `recoveryPoolProvider.notifier.onFileRecovered(serverId, contentId, diskPath)`

**`NetworkEvent_RecoveryPoolStopped`** (serverId)
- `recoveryPoolProvider.notifier.onPoolStopped(serverId)`

#### Hollow Share Events

**`NetworkEvent_ShareManifestReady`** (rootHash, fileName, totalSize, chunkCount)
- `shareTabProvider.notifier.handleShareManifestReady(rootHash, fileName, totalSize.toInt(), chunkCount)`
- Checks `_pendingAutoDownloads` for this rootHash. If found, auto-starts download via `share_api.shareStartDownload()`.

**`NetworkEvent_ShareProgress`** (rootHash, chunksHave, chunksTotal, seeders, leechers, bytesPerSec)
- `shareTabProvider.notifier.handleShareProgress(...)`
- If rootHash is mapped in `_shareToFileId`: bridges to `fileTransferProvider.notifier.onFileProgress()` and `onSeedersUpdate()`.

**`NetworkEvent_ShareCompleted`** (rootHash, diskPath)
- `shareTabProvider.notifier.handleShareCompleted(rootHash, diskPath)`
- If rootHash is mapped in `_shareToFileId`: calls `storage_api.markFileComplete(fileId, diskPath)`, then `fileTransferProvider.notifier.onFileCompleted()`, then `_reloadChatForFile()`.

**`NetworkEvent_ShareFailed`** (rootHash, error)
- `shareTabProvider.notifier.handleShareFailed(rootHash, error)`

**`NetworkEvent_ShareSeedingChanged`** (rootHash, seeding, seeders, leechers, bytesUploaded)
- `shareTabProvider.notifier.handleShareSeedingChanged(...)`

**`NetworkEvent_ShareCreated`** (rootHash, link, fileName, totalSize)
- `shareTabProvider.notifier.handleShareCreated(rootHash, link, fileName, totalSize.toInt())`
- `fileTransferProvider.notifier.onShareCreatedForFile(link, fileName, rootHash)`

**`NetworkEvent_ShareCreatedHidden`** (rootHash, keyHex, fileName, totalSize)
- Debug print only (hidden shares are internal, no UI tab entry needed).

**`NetworkEvent_ShareList`** (entries)
- `shareTabProvider.notifier.handleShareList(entries)`

**`NetworkEvent_ShareNeedWebRtc`** (peerId, hidden)
- `webRtcProvider.notifier.ensureConnection(peerId, iceConfigOverride: ...)` -- Uses `streamIceConfigProvider` for hidden shares, `shareIceConfigProvider` for public shares.

#### License and Budget Events

**`NetworkEvent_LicenseError`** (reason)
- Sets `licenseErrorProvider` state to the error reason.

**`NetworkEvent_RoomBudgetUpdate`** (joined, limit)
- Sets `roomBudgetProvider` state to `RoomBudget(joined: joined, limit: limit)`.

**`NetworkEvent_RoomCapHit`** (room)
- Shows a HollowToast error. Determines kind from room prefix: `'share:'` -> Share, `'inbox:'` -> Inbox, otherwise Connection.

#### Twitch Events

**`NetworkEvent_TwitchJoinRejected`** (serverId, reason)
- Parses the reason string to determine sub-type:
  - `'twitch_required:{channel_id}:{channel_name}:{server_name}:{min_follow_days}:{require_sub}'` -- Opens `showTwitchJoinDialog()` with parsed parameters. If dialog is already open (retry failed), routes via `handleTwitchJoinResult()`.
  - `'twitch_failed:{channel_name}:{server_name}:{human_reason}'` -- Opens dialog with failure reason or toast.
  - `'twitch_owner_offline:{server_name}'` -- Shows toast about owner being offline for verification.
  - Default: shows generic toast or routes to existing dialog.

### Helper Methods

**`_requestMissingFiles(String serverId)`** -- Called after message sync completes with new messages. Queries DB for file IDs with no completed file on disk. For 6+ member servers, only auto-requests images (non-images use vault erasure shards). Delays 1-1.5s to let sync settle. Skips files already in active transfer. Iterates through peers to find one that can serve each file.

**`_requestMissingFilesForDm(String peerId)`** -- Same pattern as above but for DM messages. Delays 1s, queries all missing file IDs, requests from the specific DM peer.

**`_reloadChatForFile(String fileId)`** -- Looks up file metadata to determine context (DM or channel), then reloads the appropriate chat history so image previews render.

**`_notifyChannelWithName(serverId, channelId, fromPeer, text, replyToMid)`** -- Async helper that resolves channel name (from loaded channels or CRDT API fallback), then calls `systemNotificationProvider.notifier.notifyChannel()`.

**`_clearFailedSyncForPeer(String peerId)`** -- On session re-establishment, iterates all servers. For any server with `failed` sync status where this peer is a member, clears the status to `idle` and re-triggers sync for the currently viewed channel.

### Provider Invalidation Chains

The event provider triggers cascading invalidations for several key providers:
- `serverMembersProvider(serverId)` -- Invalidated on: ServerUpdated, MemberJoined, MemberLeft, SyncCompleted, RoleChanged.
- `myPermissionsProvider(serverId)` -- Invalidated on: ServerUpdated, RoleChanged.
- `myRoleProvider(serverId)` -- Invalidated on: ServerUpdated, RoleChanged.
- `channelListProvider` / `channelLayoutProvider` -- Reloaded on: ServerUpdated (if selected), SyncCompleted (if selected), ServerJoined (auto-load).
- `unreadProvider` -- Updated on: MessageReceived, ChannelMessageReceived, MessageSyncCompleted, DmSyncCompleted, SyncCompleted.

---

## Theme Provider

File: `lib/src/core/providers/theme_provider.dart`
Provider: `themeModeProvider` -- `StateProvider<ThemeMode>`, default `ThemeMode.dark`

Simple state provider. Controls whether the app uses dark or light mode. No persistence yet (TODO comment: persist in Phase 3 via SQLCipher). The actual theme data comes from `HollowTheme.dark()` / `HollowTheme.light()` plus hue variants.

---

## Background Provider

File: `lib/src/core/providers/background_provider.dart`
Provider: `backgroundProvider` -- `NotifierProvider<BackgroundNotifier, BackgroundState>`

### BackgroundState
- `imageBytes: Uint8List?` -- Raw bytes of the custom background image.
- `panelOpacity: double` -- 0.0 (fully transparent panels) to 1.0 (solid, default). Controls overlay panel opacity when a background image is set.
- `hasBackground` -- Convenience getter, true when `imageBytes` is non-null and non-empty.

### BackgroundNotifier Methods
- `load()` -- Reads panel opacity from `storage_api.loadSetting(key: 'bg_panel_opacity')` and image bytes from `~/.hollow/custom_background.img` (or `HOLLOW_DATA_DIR` override). Called during bootstrap.
- `setImage(Uint8List bytes)` -- Writes bytes to `custom_background.img` in the hollow data directory.
- `clearImage()` -- Deletes the background image file, sets state with `clearImage: true`.
- `setOpacity(double opacity)` -- Clamps to [0.0, 1.0], persists to `'bg_panel_opacity'` setting.

---

## Layout Mode Provider

File: `lib/src/core/providers/layout_provider.dart`
Provider: `layoutModeProvider` -- `AsyncNotifierProvider<LayoutModeNotifier, LayoutMode>`

### LayoutMode Enum
- `classic` -- Discord-like 4-panel: ServerStrip (72px) | ChannelSidebar (240px) | ChatPane | MemberPanel (240px).
- `dock` -- Default. FriendsBar (top) | ChannelSidebar + ChatPane + MemberPanel | BottomBar (bottom).

### LayoutModeNotifier Methods
- `build()` -- Loads from `storage_api.loadSetting(key: 'layout_mode')`. Returns `dock` unless stored value is `'classic'`.
- `setMode(LayoutMode mode)` -- Persists as `'classic'` or `'dock'` string to settings, updates state.

---

## Settings Provider

File: `lib/src/core/providers/settings_provider.dart`

All settings providers follow the same pattern: `AsyncNotifierProvider` that loads from `storage_api.loadSetting(key: ...)` in `build()` and persists via `storage_api.saveSetting(key: ..., value: ...)` on change. All use the `app_settings` table in SQLCipher.

### Minimize to Tray
Provider: `minimizeToTrayProvider` -- `AsyncNotifierProvider<MinimizeToTrayNotifier, bool>`
- Key: `'minimize_to_tray'`
- Default: `true` (minimize to tray on close).
- `setEnabled(bool value)` -- Persists and updates state.

### Disable Animations
Provider: `disableAnimationsProvider` -- `AsyncNotifierProvider<DisableAnimationsNotifier, bool>`
- Key: `'disable_animations'`
- Default: `false` (animations enabled).
- `setEnabled(bool value)` -- Persists and updates state. When true, all UI transitions become instant.

### Audio Input Device
Provider: `audioInputDeviceProvider` -- `AsyncNotifierProvider<AudioInputDeviceNotifier, String?>`
- Key: `'audio_input_device'`
- Default: `null` (system default).
- `setDevice(String? deviceId)` -- Persists empty string for null. CRITICAL: uses `sourceId` constraint pattern per project conventions.

### Audio Output Device
Provider: `audioOutputDeviceProvider` -- `AsyncNotifierProvider<AudioOutputDeviceNotifier, String?>`
- Key: `'audio_output_device'`
- Default: `null` (system default).
- `setDevice(String? deviceId)` -- Persists empty string for null. Uses `win32audio` for output device selection per project conventions.

### Camera Device
Provider: `cameraDeviceProvider` -- `AsyncNotifierProvider<CameraDeviceNotifier, String?>`
- Key: `'camera_device'`
- Default: `null` (system default).
- `setDevice(String? deviceId)` -- Persists empty string for null. Uses `sourceId` constraint.

### Image Quality
Provider: `imageQualityProvider` -- `AsyncNotifierProvider<ImageQualityNotifier, ImageQuality>`
- Key: `'image_quality'`
- Default: `ImageQuality.balanced`

**ImageQuality enum:**
- `lossless` -- "Lossless (100%)" -- Pixel-perfect for art, diagrams, screenshots.
- `balanced` -- "Balanced (50%)" -- Indistinguishable, ~95% smaller. Default.
- `small` -- "Small (30%)" -- Aggressive compression for slow connections.

Controls the Rust-side WebP encoder in `image_convert::convert_to_webp_with_quality`.

### Audio Quality
Provider: `audioQualityProvider` -- `AsyncNotifierProvider<AudioQualityNotifier, AudioQualityPreset>`
- Key: `'audio_quality'`
- Default: `AudioQualityPreset.voice`

**AudioQualityPreset enum:**
- `voice` -- 32 kbps mono, speech-optimized.
- `music` -- 128 kbps stereo, CD-like quality.
- `hifi` -- 256 kbps stereo, perceptually lossless.

Controls Opus bitrate and stereo settings via SDP munging in voice calls.

### Microphone Gain
Provider: `micGainProvider` -- `AsyncNotifierProvider<MicGainNotifier, double>`
- Key: `'mic_gain'`
- Default: `1.0` (no boost). Range: 0.0 to 2.0.
- Values >1.0 boost, <1.0 reduce. Applied to the local audio track.
- `setGain(double gain)` -- Persists with 2 decimal places.

### Ringtone Settings (5 providers)

**ringtonePathProvider** -- `AsyncNotifierProvider<RingtonePathNotifier, String?>`
- Key: `'ringtone_path'`
- Default: `null` (system default sound).

**ringtoneDurationProvider** -- `AsyncNotifierProvider<RingtoneDurationNotifier, double>`
- Key: `'ringtone_duration'`
- Default: `0`. Cached duration in seconds. Updated when a new file is selected, avoids re-probing.

**ringtoneVolumeProvider** -- `AsyncNotifierProvider<RingtoneVolumeNotifier, double>`
- Key: `'ringtone_volume'`
- Default: `0.5`. Range: 0.0 to 1.0.

**ringtoneStartProvider** -- `AsyncNotifierProvider<RingtoneStartNotifier, double>`
- Key: `'ringtone_start'`
- Default: `0.0`. Clip start offset in seconds.

**ringtoneEndProvider** -- `AsyncNotifierProvider<RingtoneEndNotifier, double>`
- Key: `'ringtone_end'`
- Default: `30.0`. Clip end offset in seconds (or song duration if shorter).

### Auto-Download Threshold
Provider: `autoDownloadThresholdProvider` -- `AsyncNotifierProvider<AutoDownloadThresholdNotifier, int>`
- Key: `'auto_download_threshold_mb'`
- Default: `169` MB. Minimum: `34` MB (the share-backed file threshold). Maximum: `2048` MB.
- Files up to this size auto-download when received as share-backed attachments. Larger ones require manual action.
- `setThreshold(int mb)` -- Clamps to [34, 2048] before persisting.

### Vault Cache Capacity
Provider: `vaultCacheCapProvider` -- `AsyncNotifierProvider<VaultCacheCapNotifier, int>`
- Key: `'vault_cache_cap_mb'`
- Default: `1024` MB (1 GB). Minimum: `256` MB. Maximum: `10240` MB (10 GB).
- Controls LRU eviction limit for `~/.hollow/vault_cache/`. Eviction runs every 30 minutes.
- `setCap(int mb)` -- Clamps to [256, 10240] before persisting.

### Proxy Enabled
Provider: `proxyEnabledProvider` -- `AsyncNotifierProvider<ProxyEnabledNotifier, bool>`
- Key: `'proxy_enabled'`
- Default: `false`. For censored networks. Note: Shadowsocks tunnel was implemented then fully removed from Rust; this setting is vestigial (dead Dart code remains).

### Invisible Mode
Provider: `invisibleModeProvider` -- `NotifierProvider<InvisibleModeNotifier, bool>` (synchronous, NOT async)
- Key: `'invisible_mode'`
- Default: `false`.
- `load()` -- Called during bootstrap (fire-and-forget). Reads from DB and sets synchronous state.
- `setInvisible(bool value)` -- Updates synchronous state immediately, persists to DB, then calls `network_api.setInvisible(invisible: value)` to notify the Rust node. The Rust node broadcasts status changes to peers.

---

## Notification Settings Provider

File: `lib/src/core/providers/notification_provider.dart`
Provider: `notificationSettingsProvider` -- `NotifierProvider<NotificationSettingsNotifier, NotificationSettingsState>`

### NotificationLevel Enum
- `all` -- Notify on all messages.
- `mentions` -- Only notify on replies/mentions.
- `nothing` -- Muted.

### ChannelNotificationLevel Enum
- `inherit` -- Use server-level setting (default).
- `all`, `mentions`, `nothing` -- Override server setting.

### NotificationSettingsState
Immutable state holding three maps:
- `serverLevels: Map<String, NotificationLevel>` -- Per-server notification level.
- `channelOverrides: Map<String, ChannelNotificationLevel>` -- Per-channel overrides, keyed as `'serverId:channelId'`.
- `dmEnabled: Map<String, bool>` -- Per-DM-peer toggle.

### Storage Keys
- `notif:{serverId}` -- `"all"` / `"mentions"` / `"nothing"`
- `notif:{serverId}:{channelId}` -- `"inherit"` / `"all"` / `"mentions"` / `"nothing"`
- `notif:dm:{peerId}` -- `"true"` / `"false"`

### NotificationSettingsNotifier Methods
- `loadAll(serverIds, channelIds, dmPeerIds)` -- Bulk loads all notification settings from DB. Called during bootstrap.
- `serverLevel(serverId)` -- Returns the server-level notification setting, defaults to `all`.
- `effectiveChannelLevel(serverId, channelId)` -- Returns the effective level for a channel. Falls back to server level if channel is set to `inherit`.
- `channelOverride(serverId, channelId)` -- Returns the raw channel override (may be `inherit`).
- `setServerLevel(serverId, level)` -- Persists and updates map.
- `setChannelOverride(serverId, channelId, level)` -- Persists. Removes key from map when set to `inherit`.
- `isDmEnabled(peerId)` -- Returns whether DM notifications are enabled, defaults to `true`.
- `setDmEnabled(peerId, enabled)` -- Persists and updates map.
- `isChannelMuted(serverId, channelId)` -- Convenience: effective level == nothing.
- `isServerMuted(serverId)` -- Convenience: server level == nothing.

### Cross-References from EventStreamNotifier
- `isDmEnabled()` is checked in `NetworkEvent_MessageReceived` to gate DM unread tracking and notifications.
- `effectiveChannelLevel()` is checked in `NetworkEvent_ChannelMessageReceived` to gate channel unread tracking and notifications, with special `mentions` logic that checks for `@everyone`, `@displayName`, `@nickname`, and reply-to.

---

## System Notification Provider

File: `lib/src/core/providers/system_notification_provider.dart`
Provider: `systemNotificationProvider` -- `NotifierProvider<SystemNotificationNotifier, List<NotificationCard>>`

State is a list of up to 3 `NotificationCard` objects (in-app overlay cards).

### NotificationCard Model
- `sourceKey` -- Unique identifier. For DMs: peerId. For channels: `'serverId:channelId'`.
- `title` -- Display title. DMs: sender name. Channels: `'ServerName > #channelName'`.
- `avatarId` -- ID used for avatar lookup.
- `isDm`, `serverId`, `channelId`, `peerId` -- Routing metadata for click handlers.
- `messages: List<NotificationMessage>` -- Last 5 messages grouped under this card.
- `createdAt` -- When the card was first created.
- `withMessage(msg)` -- Returns new card with message appended. Keeps last 5 messages max.

### NotificationMessage Model
- `senderPeerId`, `senderName`, `text`, `timestamp`

### SystemNotificationNotifier Methods

**`init()`** -- Initializes `local_notifier` for native OS notifications. Called once at startup. Only runs on Windows/Linux/macOS. Sets `_nativeInitialized` flag.

**`notifyDm(fromPeerId, text, replyToMid)`**
- Checks DM notification setting.
- Resolves sender name from `profileProvider`.
- If window is hidden (tray mode): uses native OS notification via `local_notifier`.
- If window is visible but unfocused: adds in-app overlay card.
- If window is visible and focused: does nothing (user is already looking at the app).

**`notifyChannel(serverId, channelId, fromPeerId, text, replyToMid, channelName?)`**
- Checks notification level. If `nothing`: return. If `mentions`: checks for @mentions and replies.
- Same window state logic as DM: hidden -> native, unfocused -> overlay, focused -> nothing.

**`dismissCard(sourceKey)`** -- Removes specific card from state.

**`dismissAll()`** -- Clears all cards.

### Native OS Notifications
- Uses `local_notifier` package.
- `_showNativeNotification(title, body)` -- Closes any existing active notification, creates new `LocalNotification`, sets `onClick` to bring window to front via `windowManager.show()` + `windowManager.focus()`.

### In-App Overlay
- Maximum 3 cards visible at once. New cards are dropped if limit reached.
- Cards are grouped by sourceKey. New messages from the same source append to existing card.

---

## Archive Providers

File: `lib/src/core/providers/archive_provider.dart`

A collection of providers managing the Archive tab UI, which gives users access to their complete message history (My Data) and imported `.hollow-archive` files.

### Tab and Selection State Providers

**`archiveTabOpenProvider`** -- `StateProvider<bool>`, default `false`. Controls whether the Archive tab replaces the main content area.

**`archiveSubTabProvider`** -- `StateProvider<ArchiveSubTab>`, default `myData`. Enum: `myData`, `importedArchives`.

**`myDataInnerTabProvider`** -- `StateProvider<MyDataInnerTab>`, default `dms`. Enum: `dms`, `channels`, `vaultFiles`.

**`archiveSelectedDmProvider`** -- `StateProvider<String?>`. Currently selected DM peer ID.

**`archiveSelectedChannelProvider`** -- `StateProvider<String?>`. Composite key `"serverId:channelId"`.

**`archiveSearchProvider`** -- `StateProvider<String>`. Filters the conversation list.

**`archiveFilterSenderProvider`** -- `StateProvider<String?>`. Filters channel messages by sender ID (null = show all).

**`archiveMessageSearchOpenProvider`** -- `StateProvider<bool>`. In-message search bar toggle.

**`archiveMessageSearchQueryProvider`** -- `StateProvider<String>`. Search query text.

**`archiveSearchMatchIndexProvider`** -- `StateProvider<int>`. Current match index (0-based) for navigating search results.

**`archiveJumpToDateProvider`** -- `StateProvider<DateTime?>`. Target date for jump-to-date functionality.

**`importedArchiveSelectedChannelProvider`** -- `StateProvider<String?>`. Selected channel within an imported server archive.

### Edit History Providers

**`archiveDmEditsProvider`** -- `FutureProvider.autoDispose.family<Map<String, List<ArchiveEditEntry>>, String>` (keyed by peerId)
- Loads all DM messages, finds those with `editedAt` set, bulk-loads edit records from `storage_api.loadMessageEdits()`.
- Returns map of messageId -> list of `ArchiveEditEntry` objects.

**`archiveChannelEditsProvider`** -- `FutureProvider.autoDispose.family<Map<String, List<ArchiveEditEntry>>, String>` (keyed by `"serverId:channelId"`)
- Same pattern as DM edits but for channel messages.

**ArchiveEditEntry** model: `messageId`, `oldText`, `newText`, `editedAt`, `signature`, `publicKey`, `prevSignature`, `prevPublicKey`, `prevTimestampMs`.

### Conversation List Providers

**`archiveDmListProvider`** -- `FutureProvider<List<ArchiveDmEntry>>`
- Queries all DM peer IDs from storage, counts messages per peer, returns sorted by message count descending.
- `ArchiveDmEntry`: `peerId`, `messageCount`.

**`archiveChannelListProvider`** -- `FutureProvider<List<ArchiveChannelGroup>>`
- Queries joined servers via CRDT API. For each server, gets channels, filters by user's role priority (respects visibility: moderator/admin-only channels hidden from lower roles), counts messages, groups into `ArchiveChannelGroup` objects.
- Skips voice channels.
- `ArchiveChannelGroup`: `serverId`, `serverName`, `channels: List<ArchiveChannelEntry>`.
- `ArchiveChannelEntry`: `serverId`, `serverName`, `channelId`, `channelName`, `messageCount`.

### Message Loading Providers

**`archiveDmMessagesProvider`** -- `FutureProvider.autoDispose.family<List<ChatMessage>, String>` (keyed by peerId)
- Loads ALL DM messages (including deleted/hidden). Bulk-loads reactions and file attachments. Constructs full `ChatMessage` objects with all fields including `hiddenAt`, `editedAt`, reactions, file attachments, link previews.

**`archiveChannelMessagesProvider`** -- `FutureProvider.autoDispose.family<List<ChannelChatMessage>, String>` (keyed by `"serverId:channelId"`)
- Same pattern for channel messages. Returns `ChannelChatMessage` objects with `senderId`.

### Imported Archives Providers

**`selectedImportedArchiveProvider`** -- `StateProvider<String?>`. Selected archive file path.

**`importedArchivePathsProvider`** -- `AsyncNotifierProvider<ImportedArchivePathsNotifier, List<String>>`
- Settings key: `'imported_archive_paths'` -- JSON array of file paths.
- `build()` loads paths, validates they still exist on disk, prunes missing.
- `addPath(path)` -- Appends if not already present.
- `removePath(path)` -- Removes and clears selection if it was selected.

**`importedArchiveVerifyProvider`** -- `FutureProvider.family<ArchiveVerifyResult, String>` (keyed by path)
- Quick-verify: manifest + signatures only via `archive_api.verifyArchive()`.

**`importedArchiveDataProvider`** -- `FutureProvider.autoDispose.family<ArchiveData, String>` (keyed by path)
- Full load via `archive_api.loadArchive()`. Auto-disposes when user navigates away.

### Archive Message Conversion Functions

**`convertArchiveDmMessages(data, localPeerId)`** -- Converts `ArchiveData` messages to `List<ChatMessage>`. Maps file attachments from archive's embedded files.

**`convertArchiveChannelMessages(data, localPeerId)`** -- Same for `List<ChannelChatMessage>`.

---

## Updater Provider

File: `lib/src/core/providers/updater_provider.dart`
Provider: `updaterProvider` -- `NotifierProvider<UpdateNotifier, UpdateState>`
Derived: `hasUpdateProvider` -- `Provider<bool>` (watches `updaterProvider`, returns true if `manifest.latest != currentVersion`)

### Constants
- `kManifestUrl = 'https://anonlisten.com/hollow/releases/manifest.json'`

### VersionManifest / VersionInfo
- `VersionManifest`: `latest` (string), `versions` (list).
- `VersionInfo`: `version`, `date`, `url`, `notes`.

### UpdateStatus Enum
`idle`, `checking`, `downloading`, `extracting`, `readyToInstall`, `error`

### UpdateState
Fields: `status`, `manifest`, `selectedVersion`, `downloadProgress` (0.0-1.0), `bytesDownloaded`, `totalBytes`, `downloadedZipPath`, `batPath`, `error`, `currentVersion`.

### UpdateNotifier Methods

**`build()`** -- Returns idle state with `currentVersion` from `updater_api.getCurrentVersion()`.

**`checkForUpdates()`** -- Guards against re-checking during active operations. Fetches manifest JSON with cache-bust query param. Parses into `VersionManifest`.

**`downloadVersion(VersionInfo version)`** -- Downloads zip to `~/.hollow/updates/{version}.zip` (or `HOLLOW_DATA_DIR`). Streams progress via `updater_api.downloadUpdate()`. After download, transitions to `extracting` and calls `updater_api.applyUpdate(zipPath, appDir, version)` which returns a `.bat` path for the swap script.

**`installAndRestart()`** -- Launches the bat script via `Process.start('cmd', ['/c', 'start', '', batPath])` in detached mode, then calls `exit(0)`.

**`cancelDownload()`** -- Resets state to idle.

---

## News Provider

File: `lib/src/core/providers/news_provider.dart`
Provider: `newsProvider` -- `NotifierProvider<NewsNotifier, NewsState>`

### Constants
- `kNewsUrl = 'https://anonlisten.com/hollow/releases/news.json'`

### NewsPost Model
- `id`, `date`, `title`, `body` (detailed markdown content).

### NewsState
- `posts: List<NewsPost>`, `hasFetched: bool`.

### NewsNotifier Methods
- `build()` -- Triggers `_fetch()` and `updaterProvider.notifier.checkForUpdates()` on first build via `Future.microtask()`.
- `_fetch()` -- Fetches news.json with cache-bust. Parses JSON array into `NewsPost` list. Sets `hasFetched = true` on completion (even on error).
- `refresh()` -- Public method to force re-fetch.

---

## Room Budget Provider

File: `lib/src/core/providers/room_budget_provider.dart`
Provider: `roomBudgetProvider` -- `StateProvider<RoomBudget>`

### RoomBudget Model
- `joined: int` (default 0) -- Number of WS rooms currently joined.
- `limit: int` (default 2000) -- Maximum allowed rooms.
- `usage` -- Returns `joined / limit` ratio.
- `remaining` -- Returns `limit - joined`, clamped to [0, limit].
- `isNearLimit` -- `usage >= 0.9`.
- `isAtLimit` -- `joined >= limit`.

Updated by `NetworkEvent_RoomBudgetUpdate` from the event provider. The relay enforces a 2000 room cap per connection. Rooms include server rooms, inbox rooms, share rooms, and voice rooms.

---

## License Key Provider

File: `lib/src/core/providers/license_key_provider.dart`
Provider: `licenseKeyProvider` -- `NotifierProvider<LicenseKeyNotifier, String?>`
Provider: `licenseErrorProvider` -- `StateProvider<String?>`, default null.

### LicenseKeyNotifier Methods
- `build()` -- Returns null initially.
- `loadCached()` -- Loads from `storage_api.loadSetting(key: 'license_key')`. Sets state if non-empty.
- `setKey(String key)` -- Updates state and persists.
- `clearKey()` -- Sets state to null and persists empty string.

The `licenseErrorProvider` is set by `NetworkEvent_LicenseError` from the event provider. The app checks `/relay-status` on startup; if license keys are required, it shows a dialog. The key is cached in SQLCipher.

---

## Vault Status Provider

File: `lib/src/core/providers/vault_status_provider.dart`
Provider: `vaultStatusProvider` -- `NotifierProvider<VaultStatusNotifier, Map<String, VaultServerStatus>>`

State is a map of serverId to `VaultServerStatus`.

### VaultHealth Enum
- `healthy` -- All files distributed.
- `degraded` -- Some files still distributing.
- `critical` -- Distribution failed.

### VaultFileStatus Model
- `contentId`, `phase` (encrypting/encoding/distributing/complete/failed), `progress` (0.0-1.0), `shardsConfirmed`, `shardsTotal`, `error`.

### VaultServerStatus Model
- `activeUploads: Map<String, VaultFileStatus>` -- Keyed by contentId.
- `activeDownloads: Map<String, VaultFileStatus>` -- Keyed by contentId.
- `shardsStoredLocally: int` -- Count of locally stored shards.
- `computeHealth()` -- Returns `critical` if any upload failed, `degraded` if any non-complete, otherwise `healthy`.
- `healthMessage` -- Human-readable health string.

### VaultStatusNotifier Methods

**Upload events:**
- `onUploadProgress(serverId, contentId, phase, progress)` -- Creates or updates file status in `activeUploads`.
- `onUploadComplete(serverId, contentId)` -- Sets phase to `'complete'`, progress to 1.0.
- `onUploadFailed(serverId, contentId, error)` -- Sets phase to `'failed'` with error.

**Download events:**
- `onDownloadProgress(serverId, contentId, phase, progress)` -- Creates or updates in `activeDownloads`.
- `onDownloadComplete(serverId, contentId)` -- REMOVES from `activeDownloads` (not marked complete, just cleaned up).
- `onDownloadFailed(serverId, contentId, error)` -- Sets phase to `'failed'` with error.

**Shard events:**
- `onShardStored(serverId, contentId)` -- Increments `shardsStoredLocally` counter.
- `onShardAckReceived(serverId, contentId, success)` -- If success, increments `shardsConfirmed` on the matching upload entry.

---

## Node Provider

File: `lib/src/core/providers/node_provider.dart`
Provider: `nodeProvider` -- `NotifierProvider<NodeNotifier, NodeState>`

### NodeStatus Enum (from `lib/src/core/models/node_status.dart`)
- `loading`, `starting`, `connected`, `error`

### NodeState Model
- `status: NodeStatus` (default `loading`), `error: String?`.

### NodeNotifier Methods

**`build()`** -- Returns `const NodeState()` (loading, no error).

**`start()`**
1. Sets status to `starting`.
2. Calls `networkService.startNode()` which returns the local peerId.
3. Updates `identityProvider` with the peerId.
4. Sets status to `connected`.
5. Calls `storage_api.resetStaleFiles()` to clear files marked complete but missing on disk. These will be picked up by `_requestMissingFiles()` when sync events fire.
6. Calls `eventStreamProvider.notifier.start()` to begin event polling.

**`stop()`**
1. Calls `eventStreamProvider.notifier.stop()`.
2. Calls `networkService.stopNode()`.
3. Sets status to `loading`.

**`clearError()`** -- Sets error to null.

The node provider is the orchestrator of the Rust node lifecycle. The event stream only runs while the node is active.

---

## Relay Stats Provider

File: `lib/src/core/providers/relay_stats_provider.dart`
Provider: `relayStatsProvider` -- `NotifierProvider<RelayStatsNotifier, RelayStats>`

### RelayStats Model
- `memTotalKb`, `memUsedKb` -- VPS memory.
- `rxMbps`, `txMbps` -- Network bandwidth.
- `bandwidthCapMbps` -- Default 400 Mbps.
- `onlineUsers` -- Currently connected users.
- `fetchCount` -- Increments per successful fetch (used for UI refresh detection).
- `memUsagePercent` -- Computed: `memUsedKb / memTotalKb`.
- `bandwidthUsagePercent` -- Computed: `(rxMbps + txMbps) / bandwidthCapMbps`.
- `memLabel` -- Formatted string: `"X / Y MB"`.
- `bandwidthLabel` -- Formatted string: `"X / Y Mbps"`.

### RelayStatsNotifier
- Polls `https://relay.anonlisten.com/server-stats` every 7 seconds via `Timer.periodic`.
- Uses raw `HttpClient` (not http package) with 10-second timeout.
- Initial fetch fires immediately via `Future.microtask`.
- On error: silently keeps last known state.
- Disposes timer and client on provider disposal.
- Parses JSON response fields: `mem_total_kb`, `mem_used_kb`, `rx_mbps`, `tx_mbps`, `bandwidth_cap_mbps`, `online_users`.

---

## Recovery Pool Provider

File: `lib/src/core/providers/recovery_pool_provider.dart`
Provider: `recoveryPoolProvider` -- `NotifierProvider<RecoveryPoolNotifier, RecoveryPoolState?>`

State is null when no recovery pool is active.

### RecoveryPoolState Model
- `serverId` -- Which server this pool is for.
- `inviteLink` -- Share link for others to join.
- `memberPeerIds: List<String>` -- Current pool members.
- `totalFiles`, `reconstructable`, `partial`, `noShards` -- File health breakdown.
- `overallProgress: double` -- 0.0 to 1.0.
- `isInitiator: bool` -- Whether local user created the pool.
- `isActive: bool` -- Whether pool is currently running.
- `isPending: bool` -- True while waiting for welcome confirmation (join dialog still polling). Dashboard hides while pending.
- `recoveredFiles: List<RecoveredFile>` -- Files successfully reconstructed.

### RecoveredFile Model
- `contentId`, `diskPath`.

### RecoveryPoolNotifier Methods

**`onPoolCreated(serverId, inviteLink)`** -- Creates state with `isInitiator: true`, `isActive: true`.

**`onPoolJoinedPending(serverId)`** -- Creates state with `isPending: true`, `isInitiator: false`, `isActive: true`. Member events can accumulate but dashboard won't show.

**`confirmJoin()`** -- Clears `isPending` flag. Called by the join dialog after welcome confirmation.

**`onPoolJoined(serverId)`** -- Creates state directly active (no pending phase).

**`onMemberJoined(serverId, peerId)`** -- Appends peerId to `memberPeerIds`.

**`onMemberLeft(serverId, peerId)`** -- Removes peerId from `memberPeerIds`.

**`onStatus(serverId, totalFiles, reconstructable, partial, noShards, progressPct)`** -- Updates all status fields.

**`onFileRecovered(serverId, contentId, diskPath)`** -- Appends to `recoveredFiles` list.

**`onPoolStopped(serverId)`** -- For non-initiators: clears state to null (auto-clear). For initiators: sets `isActive: false` (they stopped it, dashboard shows final state).

**`clear()`** -- Sets state to null.

The recovery pool is also fed by `NetworkEvent_VaultDownloadComplete` in the event provider, which bridges vault reconstruction to the pool when it is active for the same server.
