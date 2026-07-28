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
- Unread tracking: Checks `windowVisibleProvider`, `selectedServerProvider`, `selectedChannelProvider`, and `chatAtBottomProvider`. Gets effective channel notification level. If level is `mentions`, checks if message actually mentions local user via `@everyone`, `@displayName`, `@nickname`, or is a reply. If not muted and not mention-filtered, calls `unreadProvider.notifier.onChannelMessage(serverId, channelId, messageId, isViewingChannel, isMention: isMentioned)`. Always adds channel to `_recentLiveChannels` dedup set (even if mention-filtered) so notification hints are properly deduped.
- System notification: If not viewing and not filtered, calls `_notifyChannelWithName(serverId, channelId, fromPeer, text, replyToMid)`.

**`NetworkEvent_ChannelNotificationHint`** (serverId, channelId, fromPeer, hasEveryone, mentionedNames, isReply)
- Lightweight hint broadcast via SendToRoom (0x03) by the message sender. Allows unsubscribed channels (topic routing) to track unread/mentions without receiving the full message.
- Skips if: own hint, viewing channel, channel is subscribed (in `_recentLiveChannels` or has existing unread in same server), or muted.
- For "mentions" mode: checks `hasEveryone`, `mentionedNames.contains(localName/localNick)`, `isReply`. Skips non-mentions.
- Increments unread via `onChannelMessage()` with synthetic message ID (`hint-{timestamp}`).

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
- If `newMessageCount > 0`: clears channel chat cache for the server (unconditional), merges from DB if currently viewing. (Channel file bytes arrive via the viewport sweep `requestVisibleFiles`; the old dead `_requestMissingFiles` helper was DELETED 2026-07-16.)
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

**`NetworkEvent_TwitchJoinRejected`** (serverId, reason) — the generic join-rejection channel (name is historical; carries all rejection reasons, not just Twitch).
- Parses the reason string to determine sub-type:
  - `'twitch_required:{channel_id}:{channel_name}:{server_name}:{min_follow_days}:{require_sub}'` -- Opens `showTwitchJoinDialog()` with parsed parameters. If dialog is already open (retry failed), routes via `handleTwitchJoinResult()`.
  - `'twitch_failed:{channel_name}:{server_name}:{human_reason}'` -- Opens dialog with failure reason or toast.
  - `'twitch_owner_offline:{server_name}'` -- Shows toast about owner being offline for verification.
  - `'server_private:{server_name}'` -- Opens `showJoinRejectedDialog()` (in `twitch_join_dialog.dart`): title "Server is private", message "{name} is private and doesn't accept new members." (No "invite-only"/"ask an admin to add you" — there's no add-peer feature.)
  - `'server_full:{server_name}:{max}'` -- `showJoinRejectedDialog()`: title "Server is full", message "{name} has reached its member limit (N members)."
  - Default: shows generic toast or routes to existing dialog.
- The Rust dispatch only emits this event for the FIRST rejection of an in-flight join (gated on `pending_server_joins.remove().is_some()`), so the joiner sees one popup even though every online member sends its own rejection. See `rust_swarm_event_loop.md`.

### Helper Methods

**`_requestMissingFiles`** -- DELETED 2026-07-16 (was dead code with no call sites). Channel files are fetched on demand by `channel_chat_provider.requestVisibleFiles` (viewport sweep), whose candidates are now THIS server's online members — sender's master first (collapsed via `identityOf`), then other online members sorted — ONE request only (Rust `handle_request_file` reroutes an offline target to another member); zero online members = skip WITHOUT throttling so a later pass retries.

**`_requestMissingFilesForDm(String peerId)`** -- The live missing-file sweep: fires on DM chat open (`requestMissingDmFilesOnOpen` from ChatPane / MobileChatRoute) and on message-bearing `DmSyncCompleted`. Since 2026-07-06 (bandwidth leak fix, see memory `feedback_profile_light_announce_bandwidth_leak`): queries `getMissingFileIdsForDm(peerId)` — THIS conversation only, never account-global (which also leaked unrelated file ids to the friend); requests each id from exactly ONE source (the friend if any of their devices is online, else the first online sibling — parallel sources trigger the AES-key-mismatch decrypt loop documented in `handle_request_file`); and applies `_throttleFileRequest` — per-file 10-min cooldown + 3 attempts per app run (both cleared on `FileCompleted`), so ids nobody holds stop re-firing on every open.

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

**The exception, and when you must take it:** a setting read by the FIRST frame cannot use this pattern. Rust `load_setting` returns `Err("Message store is not open")` until the SQLCipher store opens, so an eager `build()` read parks the provider in `AsyncError` and the saved value is silently lost on every launch (feedback_load_persisted_setting_from_bootstrap_not_build). Those settings are synchronous `Notifier`s with an explicit `load()` called from `HollowShell._bootstrap` — `themeModeProvider`, `accentHueProvider`, `backgroundProvider`, `invisibleModeProvider`, and the display-scale pair below.

### Minimize to Tray
Provider: `minimizeToTrayProvider` -- `AsyncNotifierProvider<MinimizeToTrayNotifier, bool>`
- Key: `'minimize_to_tray'`
- Default: `true` (minimize to tray on close).
- `setEnabled(bool value)` -- Persists and updates state.

### Display Scale — interface zoom + chat text size (issue #20, 2026-07-26)
File: `lib/src/core/providers/display_scale_provider.dart`. Both are synchronous `NotifierProvider<_, double>` loaded from `_bootstrap` (see the exception above), not `AsyncNotifier`s.

- `uiScaleProvider` — key `'ui_scale'`, default 1.0. Range is form-factor dependent: `uiScaleMin`/`uiScaleMax` = 0.75–2.0 desktop, 0.9–1.5 mobile (a 360dp phone at 2.0x would lay out at 180dp — narrower than the Settings list needed to undo it). `setScale` moves state FIRST then persists (so Ctrl +/- lands next frame) and swallows write failures with a log; `nudge(steps)` walks the 5% grid; `reset()` returns to 100%. Consumed by `UiScale` in `app.dart`'s builder, the title-bar `ZoomIndicator`, and `_handleGlobalKey`.
- `chatTextScaleProvider` — key `'chat_text_scale'`, default 1.0, range 0.8–2.0. Consumed by `ChatTextScale` (message lists, both composers, archive viewer, guest viewer).

Helpers exported alongside: `snapScale`, `scaleDivisions`, `scalePercentLabel`. The APPLIED interface scale is not necessarily the stored one — `effectiveUiScale()` (`ui_scale.dart`) reduces it when the window is too small to show the app at it.

### Reduce Motion (replaced Disable Animations, 2026-06-24)
Provider: `reduceMotionProvider` -- `AsyncNotifierProvider<ReduceMotionNotifier, ReduceMotionMode>`
- Key: `'reduce_motion_mode'` (values `auto`/`on`/`off`). Migrates the legacy `'disable_animations'` bool on first read (true→`on`, else→`auto`).
- Default: `ReduceMotionMode.auto` (follow OS Reduce-Motion flag).
- `setMode(ReduceMotionMode)` -- Persists, then calls `ReduceMotionController.instance.setMode()` which recomputes effective reduce-motion and writes both motion statics + pauses/resumes the ticker. See `lib/src/core/reduce_motion.dart`.

### Reduce Transparency
Provider: `reduceTransparencyProvider` -- `AsyncNotifierProvider<ReduceTransparencyNotifier, bool>`
- Key: `'reduce_transparency'`. Default `false`. Also mirrors into a process-wide `reduceTransparencyFlag` ValueNotifier so the ref-less `showHollowDialog` can drop glass blur to 0.

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
- Key: `'mic_gain_v2'` (fresh key 2026-07-02 — the old `'mic_gain'` predates the trim-semantics rescale and pinned users at its old floor)
- Default: `1.0` = displays "50%". Range 0.68–4.0 (`kMicGainMin`/`kMicGainMax`), display % = `gain / kMicGainDisplayUnit(2.0) * 100` → 34%–200%.
- Semantics: with Voice Enhancement ON this is the chain's input TRIM (2.0 = unity); with it OFF, the legacy flat makeup gain. IGNORED (slider shows "Auto") while Dynamic mode is on.
- `setGain(double gain)` -- Persists with 2 decimal places. Applied natively via `Helper.setCaptureGain` (post-APM capture processor), live mid-call.

### Voice Enhancement (3 providers, 2026-07-02)
**voiceEnhanceProvider** -- `AsyncNotifierProvider<VoiceEnhanceNotifier, bool>`
- Key: `'voice_enhance'`, default `true`. The native EQ+compressor+limiter capture chain (Audition curve: HP 100 Hz 24 dB/oct, shelf 110/+6, peaks 291/−3, 3k/+2, 7k/+3.5, 12k/+1.5 → comp −18 dBFS 3:1 10/100 ms → −1 dBFS limiter). OFF = legacy flat gain + −3 dBFS limiter. Live mid-call A/B.

**voiceEnhanceStrengthProvider** -- `AsyncNotifierProvider<VoiceEnhanceStrengthNotifier, double>`
- Key: `'voice_enhance_strength'`, percent 0–150, default `30`. Maps to the chain's compressor makeup gain via `enhanceStrengthToMakeupDb` (100% = +12 dB, 30% = +3.6 dB). Locked ("Auto") while Dynamic mode is on.

**voiceEnhanceDynamicProvider** -- `AsyncNotifierProvider<VoiceEnhanceDynamicNotifier, bool>`
- Key: `'voice_enhance_dynamic'`, default `true`. The auto-level servo: a slow speech-gated RMS meter in the native processor servos the input trim so ANY mic converges to the calibrated golden level (speech ≈ −28 dBFS RMS at the compressor input, makeup fixed at +3.6 dB). Locks the gain + strength sliders while active.

All three are seeded into `VoiceService`/`VoiceChannelService` at service creation and `ref.listen`ed for live mid-call updates (`updateVoiceEnhance` / `updateVoiceEnhanceStrength` / `updateVoiceEnhanceDynamic` → one method channel `setVoiceEnhance{enabled, makeupDb, dynamic}`; the Dart param is `dynamicMode` because `dynamic` shadows the built-in type).

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

### Anti-Censorship Proxy (REALITY tunnel)
Provider: `proxyConfigProvider` -- `AsyncNotifierProvider<ProxyConfigNotifier, ProxyConfig>` (replaced the old dead `proxyEnabledProvider`).
- `ProxyConfig`: `enabled` + `server`/`uuid`/`publicKey`/`shortId`/`sni` (the VLESS+REALITY params). Persisted as 6 `proxy_*` `app_settings` keys.
- Fields default to compiled-in `kDefaultProxy*` consts (the official Hollow Xray on the VPS) — like `kDefaultRelayDomain`. `build()` uses `?? kDefault…` so a fresh install is PRE-FILLED and the user just flips one toggle; an explicit stored value (self-hoster) is respected.
- `build()` and `save()` push to Rust via `network_api.setProxyConfig(...)` — seeds a global read by `start_node`, which launches the bundled `shoes` REALITY client as a local SOCKS5 subprocess (`node/proxy_tunnel.rs`) and routes the relay WSS through it. Toggling requires a node RESTART (WS URL captured at spawn). Desktop-only in v1 (mobile toggle is disabled). See `project_anti_censorship_transport`.

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

**Instance convenience methods** (for use with `ref.watch(notificationSettingsProvider.select(...))`):
- `isDmEnabled(peerId)` -- Returns `dmEnabled[peerId] ?? true`.
- `isServerMuted(serverId)` -- Returns `true` if server level is `nothing`.
- `isChannelMuted(serverId, channelId)` -- Checks channel override first, falls back to server mute.

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

**`init()`** -- Initializes `DesktopNotificationService` (native OS toasts). Called once at startup. Only runs on Windows/Linux/macOS. Sets `_nativeInitialized` flag.

**`notifyDm(fromPeerId, text, replyToMid, messageId?)`**
- Checks DM notification setting; resolves sender name from `profileProvider`.
- **Mobile (Android/iOS):** routes by `appLifecycleProvider`. Backgrounded -> real OS notification via `push.showLocalDmNotification` (reuses the FCM push UI). Foreground -> in-app overlay card.
- **Desktop:** native OS toast fires when the window is **hidden (tray) OR unfocused** (`DesktopNotificationService.showDm`). The in-app overlay card fires whenever the window is **VISIBLE** (focused-on-another-chat OR unfocused). When focused-on-this-exact-chat, `event_provider` never calls this (gated by `isViewingDm`).
- Avatar bytes fetched + cached via `getPushProfile` (`_avatarFor`).

**`notifyChannel(serverId, channelId, fromPeerId, text, replyToMid, channelName?, messageId?)`**
- Checks notification level. If `nothing`: return. If `mentions`: checks for @mentions/@everyone/reply.
- Same mobile-lifecycle / desktop-window-state routing as DM. Channel toast uses the **sender's** avatar (a real peer id).

**`dismissCard(sourceKey)`** / **`dismissAll()`** -- Removes a card / clears all.

### DesktopNotificationService (`lib/src/core/services/desktop_notification_service.dart`)
- **Windows = RICH toast** via `flutter_local_notifications_windows` (the FFI plugin, called DIRECTLY -- the unified `flutter_local_notifications` facade does NOT route Windows). Avatar app-logo-override (circle), sender name, ONE message line, inline **Reply** action (DMs only). Each message gets a FRESH toast id (`_toastCounter`) so a new message STACKS rather than replacing -- replacing would wipe a mid-typed reply. Brand icon next to "Hollow" = `WindowsInitializationSettings.iconPath` (bundled `hollow_logo_rounded.png` written to temp). Reply args encode the peer (`reply:<peerId>`); typed text in `response.data['replyText']`. Tap/Reply handlers registered in `hollow_shell._registerDesktopNotificationHandlers` (Reply -> `chatProvider.sendMessage`).
- **macOS/Linux = plain** `local_notifier` (title + body + click).

### In-App Overlay (desktop = `NotificationOverlay`, mobile = `MobileInChatBanner`)
- Provider state: up to 3 cards; new cards dropped at the limit; grouped by sourceKey; `withMessage` keeps the last 5 messages per card.
- Desktop `NotificationOverlay`: bottom-right card stack.
- **Mobile: the ONLY in-app banner is `MobileInChatBanner`** (shown WHILE inside a chat, for other conversations; top, below header, last 3 messages, 5s countdown ring, swipe/tap dismiss). The old top-tabs `MobileNotificationBanner` was REMOVED -- outside a chat, mobile relies on OS notifications.

---

## Archive Providers

File: `lib/src/core/providers/archive_provider.dart`

A collection of providers managing the Archive tab UI, which gives users access to their complete message history (My Data) and imported `.hollow-archive` files.

### Tab and Selection State Providers

**`archiveTabOpenProvider`** -- `StateProvider<bool>`, default `false`. Controls whether the Archive tab replaces the main content area. One of the four mutually exclusive centre tabs — write it only via `setShellTab()` (`shell_tab.dart`); see `ui_shell_layout.md` → Chat Area Content Resolution.

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
5. Calls `storage_api.resetStaleFiles()` — since 2026-07-06 this first tries to HEAL a stale absolute `disk_path` by checking the current `data_dir/files/{file_id}.{ext}` (data-dir moves must not manufacture "missing" files); only files truly absent from disk get `completed_at` nulled, to be re-requested by the DM chat-open sweep.
6. Calls `eventStreamProvider.notifier.start()` to begin event polling.

**`stop()`**
1. Calls `eventStreamProvider.notifier.stop()`.
2. Calls `networkService.stopNode()`.
3. Sets status to `loading`.

**`clearError()`** -- Sets error to null.

The node provider is the orchestrator of the Rust node lifecycle. The event stream only runs while the node is active.

---

## Relay Domain Provider

File: `lib/src/core/providers/relay_domain_provider.dart`

### relayDomainProvider -- `NotifierProvider<RelayDomainNotifier, String>`
- Active relay domain. Default: `relay.anonlisten.com` (`kDefaultRelayDomain` constant).
- Persisted in SQLCipher as `relay_domain` setting.
- `loadCached()` — reads from DB. Called in `_bootstrap()` after identity load.
- `setDomain(String)` — writes to DB + updates state.
- Read by all providers that build relay URLs (ICE config, relay status, relay stats).
- Passed to Rust via `network_api.setRelayUrl(domain:)` before `start_node()`.

### savedRelayListProvider -- `NotifierProvider<SavedRelayListNotifier, List<String>>`
- List of saved relay domains for the Settings UI selector.
- Persisted in SQLCipher as `relay_domain_list` (comma-separated).
- Always includes `kDefaultRelayDomain` as first entry.
- `loadCached()`, `addRelay(String)`, `removeRelay(String)` — all persist to DB.

## Relay Bandwidth Provider (daily byte budget)

File: `lib/src/core/providers/relay_bandwidth_provider.dart`
Provider: `relayBandwidthProvider` -- `NotifierProvider.autoDispose<RelayBandwidthNotifier, RelayBandwidth>`

This connection's daily relay byte budget (10 GB/day per IP, relay-RAM counter, binary frames both directions, UTC-day window).

### RelayBandwidth Model
- `usedBytes`, `budgetBytes` -- from the relay's `bandwidth_status` reply.
- `resetAt` -- `DateTime?` local UTC deadline of the day rollover, computed at receipt from the relay's `reset_in_secs` (clock-skew immune; `StatusCountdown` ticks against it).
- `limited` -- true after a `1008 "bandwidth_limit"` close; cleared by the first reply showing headroom.
- `hasData` (`budgetBytes > 0`), `usagePercent`, `usageLabel` (`"X of Y"` via `formatBytes`).

### RelayBandwidthNotifier
- Demand-driven autoDispose: 30s `Timer.periodic` fire-and-forgets `request_relay_bandwidth()` FFI (`.catchError((_) {})` — node may not be running) ONLY while a relay card watches. Lifecycle-gated like relayStatsProvider.
- ALSO re-requests on `overallConnectionProvider` offline→online — at app launch the card mounts before the relay WS is up, so without this the meter only appeared at the first 30s tick.
- Data arrives via the event stream: event_provider dispatches `NetworkEvent_BandwidthStatus` → `onStatus(...)`; `NetworkEvent_BandwidthLimited` → `onLimited()` + error toast (overlayState pattern).
- Consumers: desktop `_RelayStatsCard` (Home) + mobile `_MobileRelayCard` (Settings, gated on tab 3) — both render `DailyUsageMeter` "Daily Relay Data" (renamed 2026-07-06; desktop adds a tooltip: per-IP, shared across the network, both directions, P2P excluded) only when `usedBytes > 0`.

## Blocked Users Provider (2026-07-07)

File: `lib/src/core/providers/blocked_users_provider.dart`
Provider: `blockedUsersProvider` -- `NotifierProvider<BlockedUsersNotifier, Set<String>>`

Set of blocked MASTER peer_ids mirroring the Rust block list (SQLCipher `blocked_peers` + `node/blocklist.rs`). Rust drops the DM surfaces at ingest; this mirror drives the UI: Block/Unblock button state (profile card/popup/mobile sheet), hiding blocked senders' channel messages (`channel_chat_pane._displayMessages`), suppressing their channel unread/notifications (event_provider), and the Settings > Security "Blocked users" management list (+ mobile settings page).
- `load()` -- from `loadBlockedPeers()` FFI, called in hollow_shell `_bootstrap` (beside hiddenArchiveDms load), never in build().
- `block()`/`unblock()` -- optimistic set update + `blockPeer`/`unblockPeer` FFI, revert + rethrow on error (callers toast).
- ALWAYS compare `deviceLinkProvider.identityOf(peerId)` against the set, never a raw device id.
- Report flow (relay-side counts, not part of this provider): `report_user` FFI from `report_user_dialog.dart` (4 categories: spam/harassment/illegal_content/impersonation).

## Saved Messages Provider (2026-07-07)

File: `lib/src/core/providers/saved_messages_provider.dart`
Provider: `savedMessagesPeerIdProvider` -- `Provider<String?>`

The peer id of the "Saved messages" conversation = your OWN master id (`identityOf(identityProvider.peerId)`); null until identity loads. Saved messages is a self-DM riding the whole normal DM pipeline (Rust skips the recipient fan-out branch and fans only to siblings). UI surfaces keying on it: FriendsBar bookmark button (left of Help center), ChatPane/MobileChatRoute self-mode headers (bookmark avatar via `components/saved_messages_avatar.dart`, no presence/call buttons), pinned rows in the Classic sidebar DM section, mobile Chats tab, and both archive lists.

## Relay Stats Provider

File: `lib/src/core/providers/relay_stats_provider.dart`
Provider: `relayStatsProvider` -- `NotifierProvider<RelayStatsNotifier, RelayStats>`

### RelayStats Model
- `memTotalKb`, `memUsedKb` -- VPS memory.
- `rxMbps`, `txMbps` -- Network bandwidth.
- `bandwidthCapMbps` -- Default 400 Mbps.
- `onlineUsers` -- Currently connected users.
- `fetchCount` -- Increments per successful fetch (used only for the pulse-animation refresh, NOT for the status dot).
- `lastSuccessAt` -- `DateTime?` of the last successful fetch.
- `isFresh` -- Computed: a fetch succeeded in the last ~20s (3 missed 7s polls). Status dots use THIS, not `fetchCount > 0` (which stayed green forever after the first ever fetch even when the relay later went unreachable).
- `memUsagePercent` -- Computed: `memUsedKb / memTotalKb`.
- `bandwidthUsagePercent` -- Computed: `(rxMbps + txMbps) / bandwidthCapMbps`.
- `memLabel` -- Formatted string: `"X / Y MB"`.
- `bandwidthLabel` -- Formatted string: `"X / Y Mbps"`.

### RelayStatsNotifier
- Polls `https://{relayDomain}/server-stats` every 7 seconds via `Timer.periodic`. Domain read from `relayDomainProvider`.
- Uses raw `HttpClient` (not http package) with 10-second timeout.
- Initial fetch fires immediately via `Future.microtask`.
- On error: keeps last known stats but RE-EMITS state each interval (so `isFresh` recomputes and time-based status dots flip grey when polls stop — a failing poll otherwise produced no new state and the dot never updated).
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

## Guest / Public Channel Browser Providers

File: `lib/src/core/providers/guest_provider.dart`

Providers managing the Public Channel Browser panel — a first-class shell panel (like Share/Archive) for browsing public channels on servers you're not a member of.

### Panel & Selection State

**`guestTabOpenProvider`** -- `StateProvider<bool>`, default `false`. Controls panel visibility. One of the four mutually exclusive centre tabs: written ONLY via `setShellTab()` in `lib/src/core/providers/shell_tab.dart` (guarded by `test/shell_tab_test.dart`), never directly. See `ui_shell_layout.md` → Chat Area Content Resolution.

**`guestExpandedServerProvider`** -- `StateProvider<String?>`. Which server is expanded in the accordion sidebar.

**`guestSelectedServerProvider`** -- `StateProvider<String?>`. Which server's channel is currently viewed.

**`guestSelectedChannelProvider`** -- `StateProvider<String?>`. Which channel is displayed in the chat pane.

### Per-Server/Channel State

**`guestChannelMapProvider`** -- `StateNotifierProvider<GuestChannelMapNotifier, Map<String, List<GuestChannelEntry>>>`. Per-server channel lists (key: serverId). Updated by `PublicChannelListReceived` event.

**`guestHasMoreProvider`** -- `StateProvider<Map<String, bool>>`. Per-channel pagination flag (key: `serverId:channelId`). Updated by `PublicChannelSyncReceived` event.

**`guestLoadingProvider`** -- `StateProvider<Set<String>>`. Server IDs currently loading channel lists.

**`guestServerAvatarProvider`** -- `StateProvider<Map<String, List<int>>>`. Server avatar bytes received from `PublicChannelListResponse`.

**`guestSenderProfilesProvider`** -- `StateProvider<Map<String, GuestSenderProfile>>`. Guest sender profiles keyed by peer ID. Populated from `sender_profiles` map in `PublicChannelSyncResponse`. Model: `GuestSenderProfile { name, avatar }`. On receipt, profiles are also injected into `profileProvider` (as synthetic `UserProfile` entries) and `avatarProvider` so `ChannelMessageBubble` and `HollowAvatar` work without guest-specific code.

### GuestChannelMapNotifier methods

`setChannels(serverId, channels)`, `addChannel(serverId, channel)`, `removeChannel(serverId, channelId)`, `removeServer(serverId)`, `clear()`.

### Persistence

**`savedGuestServersProvider`** -- `AsyncNotifierProvider<SavedGuestServersNotifier, List<SavedGuestServer>>`. DB-backed via `app_settings` JSON key `guest_saved_servers`. Model: `SavedGuestServer { serverId, serverName, fetchMode, savedAt }`. Fetch modes: `GuestFetchMode.realtime` (max 7), `onLaunch`, `manual`, `periodic5m/15m/30m/1h`. Methods: `addServer`, `removeServer`, `updateFetchMode`, `updateServerName`.

### Startup

`autoJoinGuestRooms(ref)` -- called from `node_provider.dart` after `eventStreamProvider.start()`. Joins WS rooms for all saved servers with `realtime` or `onLaunch` fetch mode.

## Duplicate-aware receive events + gated unread recompute (2026-07-03)

`MessageReceived`/`ChannelMessageReceived` ALWAYS emit from Rust, carrying `duplicate: bool` (true = the row already existed — a sync batch/pending-drain/fetch insert beat the live delivery). event_provider appends to the chat provider unconditionally (in-memory mid dedup = idempotent) then `if (duplicate) break;` BEFORE unread increments + notifications — replays must not double-count or re-toast. Never gate the emission itself on is_new (that left open panes stale while typing kept animating).

`MessageSyncCompleted` → `recomputeServerUnread` only when `newMessageCount > 0`: every channel-open fires a sync, and unconditional server-wide recounts on no-op completions re-materialized stale sibling-channel badges.
