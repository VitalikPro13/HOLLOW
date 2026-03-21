import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/sync_progress_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/core/providers/pinned_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/vault_status_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Listens to the Rust event stream and dispatches events
/// to the appropriate providers.
class EventStreamNotifier extends Notifier<bool> {
  StreamSubscription<NetworkEvent>? _subscription;
  final Map<String, Timer> _syncTimeouts = {};

  @override
  bool build() => false; // streaming?

  void start() {
    if (_subscription != null) return;
    final networkService = ref.read(networkServiceProvider);
    _subscription = networkService.watchNetworkEvents().listen(
      _dispatch,
      onError: (error) {
        debugPrint('[HOLLOW] Event stream error: $error');
      },
      onDone: () {
        debugPrint('[HOLLOW] Event stream closed');
        _subscription = null;
        state = false;
      },
    );
    state = true;
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    state = false;
  }

  void _dispatch(NetworkEvent event) {
    // SECURITY: Wrap dispatch in try-catch to prevent unhandled exceptions
    // from killing the event loop.
    try {
    switch (event) {
      case NetworkEvent_PeerDiscovered(:final peer):
        debugPrint(
            '[HOLLOW] Peer discovered: ${peer.peerId} at ${peer.addresses}');
        ref.read(peersProvider.notifier).addPeer(peer.peerId, peer.addresses);
        ref.read(connectionStatusProvider.notifier).onPeerConnected(peer.peerId);

      case NetworkEvent_PeerExpired(:final peerId):
        ref.read(peersProvider.notifier).removePeer(peerId);
        // Don't deselect — friends stay visible when offline.

      case NetworkEvent_PeerDisconnected(:final peerId):
        debugPrint('[HOLLOW] Peer disconnected: $peerId');
        ref.read(peersProvider.notifier).removePeer(peerId);
        ref.read(connectionStatusProvider.notifier).onPeerDisconnected(peerId);
        // Don't deselect — friends stay visible when offline.

      case NetworkEvent_RoomCleared():
        debugPrint('[HOLLOW] Room cleared');
        ref.read(peersProvider.notifier).clearAll();
        ref.read(selectedPeerProvider.notifier).state = null;

      case NetworkEvent_Listening(:final address):
        debugPrint('[HOLLOW] Listening: $address');

      case NetworkEvent_MessageReceived(:final fromPeer, :final text, :final timestamp, :final messageId, :final replyToMid):
        ref.read(chatProvider.notifier).receiveMessage(fromPeer, text, timestamp, messageId, replyToMid);
        ref.read(typingProvider.notifier).clearTyping(fromPeer, fromPeer);
        // Track unread DM — only if not muted.
        // Window must be visible AND viewing this DM to count as "viewing".
        final windowVisible = ref.read(windowVisibleProvider);
        final isViewingDm = windowVisible &&
            ref.read(selectedPeerProvider) == fromPeer &&
            ref.read(selectedServerProvider) == null;
        final isDmMuted = !ref
            .read(notificationSettingsProvider.notifier)
            .isDmEnabled(fromPeer);
        if (!isDmMuted) {
          ref.read(unreadProvider.notifier).onDmMessage(
              fromPeer, messageId, isViewingDm);
        }
        // System notification for DM.
        if (!isViewingDm && !isDmMuted) {
          ref.read(systemNotificationProvider.notifier).notifyDm(
                fromPeerId: fromPeer,
                text: text,
                replyToMid: replyToMid,
              );
        }

      case NetworkEvent_ChannelMessageReceived(
            :final serverId, :final channelId, :final fromPeer, :final text, :final timestamp, :final messageId, :final replyToMid):
        ref
            .read(channelChatProvider.notifier)
            .receiveMessage(serverId, channelId, fromPeer, text, timestamp, messageId, replyToMid);
        ref.read(typingProvider.notifier).clearTyping('$serverId:$channelId', fromPeer);
        // Track unread channel message — only if not muted.
        // Window must be visible AND viewing this channel to count as "viewing".
        final isViewingChannel = ref.read(windowVisibleProvider) &&
            ref.read(selectedServerProvider) == serverId &&
            ref.read(selectedChannelProvider) == channelId;
        final channelNotifLevel = ref
            .read(notificationSettingsProvider.notifier)
            .effectiveChannelLevel(serverId, channelId);
        final isChannelMuted =
            channelNotifLevel == NotificationLevel.nothing;
        if (!isChannelMuted) {
          ref.read(unreadProvider.notifier).onChannelMessage(
              serverId, channelId, messageId, isViewingChannel);
        }
        // System notification for channel message.
        if (!isViewingChannel && !isChannelMuted) {
          // Resolve channel name and notify (async, fire-and-forget).
          _notifyChannelWithName(
              serverId, channelId, fromPeer, text, replyToMid);
        }

      case NetworkEvent_SessionEstablished(:final peerId):
        ref.read(peersProvider.notifier).markEncrypted(peerId);
        ref.read(connectionStatusProvider.notifier).onSessionEstablished(peerId);
        // After re-key, clear any "Sync failed" status for servers where this
        // peer is a member, so the UI recovers automatically.
        _clearFailedSyncForPeer(peerId);

      case NetworkEvent_MessageSent():
        break;

      case NetworkEvent_MessageSendFailed(:final toPeer, :final error):
        ref.read(chatProvider.notifier).addSendFailure(toPeer, error);

      case NetworkEvent_Error(:final message):
        debugPrint('[HOLLOW] $message');
        ref.read(nodeProvider.notifier).state =
            ref.read(nodeProvider).copyWith(error: message);

      // -- CRDT events (Phase 3) --
      case NetworkEvent_ServerCreated(:final serverId, :final name):
        debugPrint('[HOLLOW] Server created: $name ($serverId)');
        ref.read(serverListProvider.notifier).onServerCreated(serverId, name);

      case NetworkEvent_ServerUpdated(:final serverId):
        debugPrint('[HOLLOW] Server updated: $serverId');
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);
        // Reload channels and layout in case they changed.
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(channelListProvider.notifier).loadForServer(serverId);
          ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
        }

      case NetworkEvent_ChannelAdded(
            :final serverId, :final channelId, :final name):
        debugPrint('[HOLLOW] Channel added: $name ($channelId) in $serverId');
        ref
            .read(channelListProvider.notifier)
            .onChannelAdded(serverId, channelId, name);

      case NetworkEvent_ChannelRemoved(:final serverId, :final channelId):
        debugPrint('[HOLLOW] Channel removed: $channelId in $serverId');
        ref
            .read(channelListProvider.notifier)
            .onChannelRemoved(serverId, channelId);

      case NetworkEvent_ChannelRenamed(
            :final serverId, :final channelId, :final newName):
        debugPrint(
            '[HOLLOW] Channel renamed: $channelId to $newName in $serverId');
        ref
            .read(channelListProvider.notifier)
            .onChannelRenamed(serverId, channelId, newName);

      case NetworkEvent_ServerDeleted(:final serverId):
        debugPrint('[HOLLOW] Server deleted: $serverId');
        ref.read(serverListProvider.notifier).onServerDeleted(serverId);
        // Deselect if this was the active server.
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(selectedServerProvider.notifier).state = null;
          ref.read(selectedChannelProvider.notifier).state = null;
          ref.read(serverSettingsOpenProvider.notifier).state = false;
        }

      case NetworkEvent_MemberJoined(:final serverId, :final peerId):
        debugPrint('[HOLLOW] Member joined: $peerId in $serverId');
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);
        ref.invalidate(serverMembersProvider(serverId));

      case NetworkEvent_MemberLeft(:final serverId, :final peerId):
        debugPrint('[HOLLOW] Member left: $peerId in $serverId');
        final localId = ref.read(identityProvider).peerId;
        if (peerId == localId) {
          // Local user was kicked — remove server from UI.
          ref.read(serverListProvider.notifier).onServerDeleted(serverId);
          if (ref.read(selectedServerProvider) == serverId) {
            ref.read(selectedServerProvider.notifier).state = null;
            ref.read(selectedChannelProvider.notifier).state = null;
            ref.read(serverSettingsOpenProvider.notifier).state = false;
          }
        } else {
          ref.read(serverListProvider.notifier).onServerUpdated(serverId);
          ref.invalidate(serverMembersProvider(serverId));
        }

      case NetworkEvent_SyncCompleted(:final serverId, :final opsApplied):
        debugPrint('[HOLLOW] Sync completed: $serverId ($opsApplied ops)');
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);
        ref.invalidate(serverMembersProvider(serverId));
        // Reload channels in case they changed while offline.
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(channelListProvider.notifier).loadForServer(serverId);
          ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
        }

      case NetworkEvent_ServerJoined(:final serverId, :final name):
        debugPrint('[HOLLOW] Server joined: $name ($serverId)');
        ref.read(serverListProvider.notifier).onServerCreated(serverId, name);
        // Auto-select the newly joined server and load its channels
        ref.read(selectedServerProvider.notifier).state = serverId;
        ref
            .read(channelListProvider.notifier)
            .loadForServer(serverId);
        ref.read(selectedChannelProvider.notifier).state = null;
        ref.read(serverSettingsOpenProvider.notifier).state = false;

      case NetworkEvent_MessageSyncStarted(:final serverId, :final peerId):
        debugPrint('[HOLLOW] Message sync started for $serverId with $peerId');
        ref.read(syncingPeersProvider.notifier).addPeer(serverId, peerId);
        final current = ref.read(serverSyncStatusProvider(serverId));
        ref.read(syncStatusProvider.notifier).setStatus(
          serverId,
          current == ServerSyncStatus.failed
              ? ServerSyncStatus.retrying
              : ServerSyncStatus.syncing,
        );
        // Timeout: if no progress/completion within 10s, clear syncing status.
        _syncTimeouts[serverId]?.cancel();
        _syncTimeouts[serverId] = Timer(const Duration(seconds: 10), () {
          final status = ref.read(serverSyncStatusProvider(serverId));
          if (status == ServerSyncStatus.syncing ||
              status == ServerSyncStatus.retrying) {
            ref.read(syncStatusProvider.notifier).setStatus(
                  serverId, ServerSyncStatus.idle);
            ref.read(syncingPeersProvider.notifier).clearServer(serverId);
          }
          _syncTimeouts.remove(serverId);
        });

      case NetworkEvent_MessageSyncCompleted(
            :final serverId, :final newMessageCount):
        debugPrint(
            '[HOLLOW] Message sync: $newMessageCount new messages for $serverId');
        _syncTimeouts[serverId]?.cancel();
        _syncTimeouts.remove(serverId);
        ref.read(syncingPeersProvider.notifier).clearServer(serverId);
        ref.read(syncProgressProvider.notifier).clearServer(serverId);
        ref.read(syncStatusProvider.notifier).setStatus(
            serverId, ServerSyncStatus.synced);
        final selectedServer = ref.read(selectedServerProvider);
        final selectedChannel = ref.read(selectedChannelProvider);
        if (newMessageCount > 0) {
          // New messages arrived — clear cache and reload (includes reactions).
          ref
              .read(channelChatProvider.notifier)
              .clearServerCache(serverId);
          if (selectedServer == serverId && selectedChannel != null) {
            ref
                .read(channelChatProvider.notifier)
                .loadHistory(serverId, selectedChannel);
          }
        } else if (selectedServer == serverId && selectedChannel != null) {
          // No new messages but reactions may have synced — just refresh
          // reactions on existing in-memory messages (no sync trigger).
          ref
              .read(channelChatProvider.notifier)
              .reloadReactions(serverId, selectedChannel);
        }
        // Always refresh pins (lightweight, no sync loop risk).
        if (selectedServer == serverId && selectedChannel != null) {
          ref
              .read(pinnedProvider.notifier)
              .loadPins(serverId, selectedChannel);
        }

        // After message sync, request any missing files (delayed to avoid
        // interfering with the sync pipeline).
        if (newMessageCount > 0) {
          _requestMissingFiles(serverId);
        }

      case NetworkEvent_MessageSyncFailed(:final serverId, :final error):
        debugPrint('[HOLLOW] Message sync failed for $serverId: $error');
        _syncTimeouts[serverId]?.cancel();
        _syncTimeouts.remove(serverId);
        ref.read(syncingPeersProvider.notifier).clearServer(serverId);
        ref.read(syncProgressProvider.notifier).clearServer(serverId);
        // Transient decrypt failures during re-key → show "Retrying"
        // instead of stuck "Failed" state.
        final isReKeying = error.contains('re-keying') ||
            error.contains('re-key');
        ref.read(syncStatusProvider.notifier).setStatus(
            serverId,
            isReKeying
                ? ServerSyncStatus.retrying
                : ServerSyncStatus.failed);

      case NetworkEvent_MessageSyncProgress(
            :final serverId, :final channelId, :final receivedCount, :final totalCount):
        debugPrint(
            '[HOLLOW] Sync progress: $receivedCount/$totalCount for $channelId in $serverId');
        // Reset sync timeout — progress is happening.
        _syncTimeouts[serverId]?.cancel();
        _syncTimeouts[serverId] = Timer(const Duration(seconds: 10), () {
          final status = ref.read(serverSyncStatusProvider(serverId));
          if (status == ServerSyncStatus.syncing ||
              status == ServerSyncStatus.retrying) {
            ref.read(syncStatusProvider.notifier).setStatus(
                  serverId, ServerSyncStatus.idle);
            ref.read(syncingPeersProvider.notifier).clearServer(serverId);
          }
          _syncTimeouts.remove(serverId);
        });
        ref.read(syncProgressProvider.notifier).updateProgress(
            serverId, receivedCount, totalCount);

      case NetworkEvent_RoleChanged(:final serverId, :final peerId, :final newRole):
        debugPrint('[HOLLOW] Role changed: $peerId is now $newRole in $serverId');
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);
        ref.invalidate(serverMembersProvider(serverId));
        ref.invalidate(myRoleProvider(serverId));
        ref.invalidate(myPermissionsProvider(serverId));

      case NetworkEvent_DmSyncCompleted(:final peerId, :final newMessageCount):
        debugPrint('[HOLLOW] DM sync: $newMessageCount new messages from $peerId');
        // Always reload DM history from DB after sync completes — even if
        // newMessageCount == 0. Dart may have cleared its in-memory cache on
        // disconnect, and the messages are all in DB already (duplicates).
        final chatNotifier = ref.read(chatProvider.notifier);
        chatNotifier.clearPeerCache(peerId);
        final selectedPeer = ref.read(selectedPeerProvider);
        if (selectedPeer == peerId) {
          chatNotifier.loadHistory(peerId);
        }

        // Request missing DM files after sync.
        if (newMessageCount > 0) {
          _requestMissingFilesForDm(peerId);
        }

      case NetworkEvent_ProfileUpdated(:final peerId):
        debugPrint('[HOLLOW] Profile updated: $peerId');
        ref.read(profileProvider.notifier).reloadProfile(peerId);

      case NetworkEvent_ChannelMessageEdited(
            :final serverId, :final channelId, :final messageId, :final newText, :final editedAt):
        debugPrint('[HOLLOW] Channel message edited: $messageId in $serverId/$channelId');
        ref.read(channelChatProvider.notifier).applyEdit(
            serverId, channelId, messageId, newText, editedAt);

      case NetworkEvent_DmMessageEdited(
            :final peerId, :final messageId, :final newText, :final editedAt):
        debugPrint('[HOLLOW] DM message edited: $messageId from $peerId');
        ref.read(chatProvider.notifier).applyEdit(
            peerId, messageId, newText, editedAt);

      case NetworkEvent_ChannelMessageDeleted(
            :final serverId, :final channelId, :final messageId, :final deletedAt):
        debugPrint('[HOLLOW] Channel message deleted: $messageId in $serverId/$channelId');
        ref.read(channelChatProvider.notifier).applyDelete(
            serverId, channelId, messageId, deletedAt);

      case NetworkEvent_DmMessageDeleted(
            :final peerId, :final messageId, :final deletedAt):
        debugPrint('[HOLLOW] DM message deleted: $messageId from $peerId');
        ref.read(chatProvider.notifier).applyDelete(
            peerId, messageId, deletedAt);

      // -- Emoji reaction events (Phase 3.5) --
      case NetworkEvent_ChannelReactionAdded(
            :final serverId, :final channelId, :final messageId, :final emoji, :final reactor):
        debugPrint('[HOLLOW] Reaction $emoji on $messageId by $reactor in $serverId/$channelId');
        ref.read(channelChatProvider.notifier).applyAddReaction(
            serverId, channelId, messageId, emoji, reactor);

      case NetworkEvent_DmReactionAdded(
            :final peerId, :final messageId, :final emoji, :final reactor):
        debugPrint('[HOLLOW] DM reaction $emoji on $messageId by $reactor for $peerId');
        ref.read(chatProvider.notifier).applyAddReaction(
            peerId, messageId, emoji, reactor);

      case NetworkEvent_ChannelReactionRemoved(
            :final serverId, :final channelId, :final messageId, :final emoji, :final reactor):
        debugPrint('[HOLLOW] Reaction $emoji removed on $messageId by $reactor in $serverId/$channelId');
        ref.read(channelChatProvider.notifier).applyRemoveReaction(
            serverId, channelId, messageId, emoji, reactor);

      case NetworkEvent_DmReactionRemoved(
            :final peerId, :final messageId, :final emoji, :final reactor):
        debugPrint('[HOLLOW] DM reaction $emoji removed on $messageId by $reactor for $peerId');
        ref.read(chatProvider.notifier).applyRemoveReaction(
            peerId, messageId, emoji, reactor);

      // -- Friend events (Phase 3.5) --
      case NetworkEvent_FriendRequestReceived(:final peerId):
        debugPrint('[HOLLOW] Friend request received from $peerId');
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_FriendRequestAccepted(:final peerId):
        debugPrint('[HOLLOW] Friend accepted by $peerId');
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_FriendRequestRejected(:final peerId):
        debugPrint('[HOLLOW] Friend rejected by $peerId');
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_FriendRemoved(:final peerId):
        debugPrint('[HOLLOW] Friend removed: $peerId');
        ref.read(friendsProvider.notifier).loadAll();
        // Close chat if viewing the removed friend.
        if (ref.read(selectedPeerProvider) == peerId) {
          ref.read(selectedPeerProvider.notifier).state = null;
        }
        // Close split pane if showing the removed friend.
        final splitState = ref.read(splitViewProvider);
        if (splitState.isSplit && splitState.rightPane?.peerId == peerId) {
          ref.read(splitViewProvider.notifier).closeSplit();
        }

      // -- Typing indicator events (Phase 3.5) --
      case NetworkEvent_TypingStarted(
            :final peerId, :final serverId, :final channelId):
        final key = serverId.isEmpty ? peerId : '$serverId:$channelId';
        ref.read(typingProvider.notifier).setTyping(key, peerId);

      // -- Pinned message events (Phase 3.5) --
      case NetworkEvent_MessagePinned(
            :final serverId, :final channelId, :final messageId):
        debugPrint('[HOLLOW] Message pinned: $messageId in $serverId/$channelId');
        ref.read(pinnedProvider.notifier).applyPin(serverId, channelId, messageId);

      case NetworkEvent_MessageUnpinned(
            :final serverId, :final channelId, :final messageId):
        debugPrint('[HOLLOW] Message unpinned: $messageId in $serverId/$channelId');
        ref.read(pinnedProvider.notifier).applyUnpin(serverId, channelId, messageId);

      // -- File transfer events (Phase 3.5) --
      case NetworkEvent_FileHeaderReceived(
            :final fileId, :final fileName, :final sizeBytes,
            :final isImage, :final width, :final height,
            messageId: _, senderId: _,
            serverId: _, channelId: _):
        debugPrint('[HOLLOW] File header: $fileId ($fileName, $sizeBytes bytes)');
        ref.read(fileTransferProvider.notifier).onFileHeaderReceived(
              fileId: fileId,
              fileName: fileName,
              sizeBytes: sizeBytes.toInt(),
              isImage: isImage,
              width: width?.toInt(),
              height: height?.toInt(),
            );
        // Reload chat so the message gets its fileAttachment from DB
        // (replacing the raw [file:xxx] text with the file card).
        _reloadChatForFile(fileId);

      case NetworkEvent_FileProgress(
            :final fileId, :final chunksReceived, :final totalChunks):
        ref.read(fileTransferProvider.notifier).onFileProgress(
              fileId, chunksReceived, totalChunks);

      case NetworkEvent_FileCompleted(:final fileId, :final diskPath):
        debugPrint('[HOLLOW] File completed: $fileId at $diskPath');
        ref.read(fileTransferProvider.notifier).onFileCompleted(
              fileId, diskPath);
        // Reload the chat that contains this file to show the image.
        _reloadChatForFile(fileId);

      case NetworkEvent_FileFailed(:final fileId, :final error):
        debugPrint('[HOLLOW] File failed: $fileId — $error');
        ref.read(fileTransferProvider.notifier).onFileFailed(
              fileId, error);

      // -- Vault shard events (Phase 4) --
      case NetworkEvent_ShardStored(:final serverId, :final contentId,
            fromPeer: _):
        ref.read(vaultStatusProvider.notifier).onShardStored(
              serverId, contentId);
      case NetworkEvent_ShardStoreAckReceived(:final serverId,
            :final contentId, shardIndex: _, :final success, error: _):
        ref.read(vaultStatusProvider.notifier).onShardAckReceived(
              serverId, contentId, success);
      case NetworkEvent_ShardStoreFailed():
        break;
      case NetworkEvent_ShardDeleted():
        break;
      case NetworkEvent_ShardReceived():
        break;
      case NetworkEvent_ShardRequestFailed():
        break;

      // -- Vault upload/download pipeline events (Phase 4) --
      case NetworkEvent_VaultUploadProgress(:final serverId,
            :final contentId, :final phase, :final progress):
        ref.read(vaultStatusProvider.notifier).onUploadProgress(
              serverId, contentId, phase, progress);
      case NetworkEvent_VaultUploadComplete(:final serverId,
            :final contentId, channelId: _):
        ref.read(vaultStatusProvider.notifier).onUploadComplete(
              serverId, contentId);
      case NetworkEvent_VaultUploadFailed(:final serverId,
            :final contentId, :final error):
        ref.read(vaultStatusProvider.notifier).onUploadFailed(
              serverId, contentId, error);
      case NetworkEvent_VaultDownloadProgress(:final serverId,
            :final contentId, :final phase, :final progress):
        ref.read(vaultStatusProvider.notifier).onDownloadProgress(
              serverId, contentId, phase, progress);
        // Also update file transfer provider so the file card shows vault phase.
        ref.read(fileTransferProvider.notifier).onVaultDownloadProgress(
              contentId, phase, progress);
      case NetworkEvent_VaultDownloadComplete(:final serverId,
            :final contentId, :final diskPath):
        ref.read(vaultStatusProvider.notifier).onDownloadComplete(
              serverId, contentId);
        ref.read(fileTransferProvider.notifier).onVaultDownloadComplete(
              contentId, diskPath);
      case NetworkEvent_VaultDownloadFailed(:final serverId,
            :final contentId, :final error):
        ref.read(vaultStatusProvider.notifier).onDownloadFailed(
              serverId, contentId, error);

      // -- Vault rebalancing events (Phase 4) --
      case NetworkEvent_RebalanceStarted():
        break; // Logged in Rust, UI tracks via vault status provider
      case NetworkEvent_RebalanceProgress():
        break;
      case NetworkEvent_RebalanceCompleted():
        break;

      // -- Connection status events (granular UI) --
      case NetworkEvent_ConnectionAttemptStarted(
            :final peerId, :final method):
        ref
            .read(connectionStatusProvider.notifier)
            .onConnectionAttemptStarted(peerId, method);

      case NetworkEvent_ConnectionAttemptFailed(
            :final peerId, :final method, :final reason):
        ref
            .read(connectionStatusProvider.notifier)
            .onConnectionAttemptFailed(peerId, method, reason);

      case NetworkEvent_KeyExchangeStarted(:final peerId):
        ref
            .read(connectionStatusProvider.notifier)
            .onKeyExchangeStarted(peerId);

      case NetworkEvent_KeyExchangeProgress(
            :final peerId, :final stage):
        ref
            .read(connectionStatusProvider.notifier)
            .onKeyExchangeProgress(peerId, stage);

      case NetworkEvent_RelayStatusChanged(:final status):
        ref
            .read(connectionStatusProvider.notifier)
            .onRelayStatusChanged(status);
    }
    } catch (e, st) {
      debugPrint('[HOLLOW] Unhandled dispatch error: $e\n$st');
    }
  }

  /// Request missing files after message sync completes.
  /// Queries messages with file_id that have no completed file on disk.
  /// Delayed by 2 seconds to let sync pipeline settle.
  Future<void> _requestMissingFiles(String serverId) async {
    await Future.delayed(const Duration(seconds: 2));
    try {
      final missingIds = await storage_api.getMissingFileIds();
      if (missingIds.isEmpty) return;
      // Skip files that already have an active stream transfer in flight.
      final activeTransfers = ref.read(fileTransferProvider);
      final toRequest = missingIds.where((id) {
        final t = activeTransfers[id];
        return t == null || (!t.isDownloading && !t.isComplete);
      }).toList();
      if (toRequest.isEmpty) return;
      debugPrint('[HOLLOW] ${toRequest.length} missing files found, requesting...');
      final peers = ref.read(peersProvider);
      if (peers.isEmpty) return;
      for (final fileId in toRequest) {
        for (final peerId in peers.keys) {
          try {
            await requestFileFromPeer(
              fileId: fileId,
              peerId: peerId,
              chunks: [],
            );
            break;
          } catch (_) {}
        }
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to request missing files: $e');
    }
  }

  /// Request missing files after DM sync completes.
  Future<void> _requestMissingFilesForDm(String peerId) async {
    await Future.delayed(const Duration(seconds: 2));
    try {
      final missingIds = await storage_api.getMissingFileIds();
      if (missingIds.isEmpty) return;
      final activeTransfers = ref.read(fileTransferProvider);
      final toRequest = missingIds.where((id) {
        final t = activeTransfers[id];
        return t == null || (!t.isDownloading && !t.isComplete);
      }).toList();
      if (toRequest.isEmpty) return;
      debugPrint('[HOLLOW] ${toRequest.length} missing DM files, requesting from $peerId');
      for (final fileId in toRequest) {
        try {
          await requestFileFromPeer(
            fileId: fileId,
            peerId: peerId,
            chunks: [],
          );
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 500));
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to request missing DM files: $e');
    }
  }

  /// When a file transfer completes, reload the chat that contains
  /// the file message so the image preview renders.
  Future<void> _reloadChatForFile(String fileId) async {
    try {
      final fileInfo = await storage_api.getFileMetadata(fileId: fileId);
      if (fileInfo == null) return;
      if (fileInfo.contextType == 'dm') {
        // Reload the DM chat.
        await ref.read(chatProvider.notifier).loadHistory(fileInfo.contextId);
      } else if (fileInfo.contextType == 'channel') {
        // contextId is "serverId:channelId"
        final parts = fileInfo.contextId.split(':');
        if (parts.length == 2) {
          await ref.read(channelChatProvider.notifier)
              .loadHistory(parts[0], parts[1]);
        }
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to reload chat for file $fileId: $e');
    }
  }

  /// When a session is (re-)established with a peer, clear any "Sync failed"
  /// Resolve channel name and show notification (async helper).
  Future<void> _notifyChannelWithName(String serverId, String channelId,
      String fromPeer, String text, String? replyToMid) async {
    String? chName = ref.read(channelListProvider)[channelId]?.name;
    if (chName == null) {
      try {
        final channels =
            await crdt_api.getServerChannels(serverId: serverId);
        chName = channels
            .where((c) => c.channelId == channelId)
            .firstOrNull
            ?.name;
      } catch (_) {}
    }
    ref.read(systemNotificationProvider.notifier).notifyChannel(
          serverId: serverId,
          channelId: channelId,
          fromPeerId: fromPeer,
          text: text,
          replyToMid: replyToMid,
          channelName: chName,
        );
  }

  /// status for servers where that peer is a member, and re-trigger sync for
  /// the active channel so the UI recovers automatically after re-key.
  void _clearFailedSyncForPeer(String peerId) {
    final syncStatuses = ref.read(syncStatusProvider);
    final servers = ref.read(serverListProvider);

    for (final serverId in servers.keys) {
      final status = syncStatuses[serverId];
      if (status != ServerSyncStatus.failed) continue;

      // Check if this peer is a member of this server.
      final membersAsync = ref.read(serverMembersProvider(serverId));
      final isMember = membersAsync.whenOrNull(
        data: (members) => members.any((m) => m.peerId == peerId),
      ) ?? false;

      if (isMember) {
        // Clear the failed status — effective status will derive from peer count.
        ref.read(syncStatusProvider.notifier).setStatus(
            serverId, ServerSyncStatus.idle);

        // Re-trigger sync for the currently viewed channel.
        final selectedServer = ref.read(selectedServerProvider);
        final selectedChannel = ref.read(selectedChannelProvider);
        if (selectedServer == serverId && selectedChannel != null) {
          try {
            requestChannelSync(
              serverId: serverId,
              channelId: selectedChannel,
            );
          } catch (_) {}
        }
      }
    }
  }
}

final eventStreamProvider =
    NotifierProvider<EventStreamNotifier, bool>(EventStreamNotifier.new);
