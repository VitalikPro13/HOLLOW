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
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
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
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/recovery_pool_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';
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
        ref.read(webRtcProvider.notifier).disconnectPeer(peerId);
        // Don't deselect — friends stay visible when offline.

      case NetworkEvent_PeerDisconnected(:final peerId):
        debugPrint('[HOLLOW] Peer disconnected: $peerId');
        ref.read(peersProvider.notifier).removePeer(peerId);
        ref.read(connectionStatusProvider.notifier).onPeerDisconnected(peerId);
        ref.read(webRtcProvider.notifier).disconnectPeer(peerId);
        ref.read(callProvider.notifier).handlePeerDisconnected(peerId);
        ref.read(voiceChannelProvider.notifier).onPeerDisconnected(peerId);
        // Don't deselect — friends stay visible when offline.

      case NetworkEvent_RoomCleared():
        debugPrint('[HOLLOW] Room cleared');
        ref.read(peersProvider.notifier).clearAll();
        ref.read(selectedPeerProvider.notifier).state = null;

      case NetworkEvent_Listening(:final address):
        debugPrint('[HOLLOW] Listening: $address');

      case NetworkEvent_MessageReceived(:final fromPeer, :final text, :final timestamp, :final messageId, :final replyToMid, :final linkPreview, :final signature, :final publicKey):
        ref.read(chatProvider.notifier).receiveMessage(
              fromPeer, text, timestamp, messageId, replyToMid,
              linkPreview: linkPreview,
              signature: signature,
              publicKey: publicKey,
            );
        ref.read(typingProvider.notifier).clearTyping(fromPeer, fromPeer);
        // Track unread DM — only if not muted.
        // Window must be visible AND viewing this DM to count as "viewing".
        final windowVisible = ref.read(windowVisibleProvider);
        final isViewingDm = windowVisible &&
            ref.read(selectedPeerProvider) == fromPeer &&
            ref.read(selectedServerProvider) == null &&
            ref.read(chatAtBottomProvider);
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
            :final serverId, :final channelId, :final fromPeer, :final text, :final timestamp, :final messageId, :final replyToMid, :final linkPreview, :final signature, :final publicKey):
        ref.read(channelChatProvider.notifier).receiveMessage(
              serverId, channelId, fromPeer, text, timestamp, messageId, replyToMid,
              linkPreview: linkPreview,
              signature: signature,
              publicKey: publicKey,
            );
        ref.read(typingProvider.notifier).clearTyping('$serverId:$channelId', fromPeer);
        // Track unread channel message — only if not muted.
        // Must be visible, viewing this channel, AND scrolled to bottom.
        final isViewingChannel = ref.read(windowVisibleProvider) &&
            ref.read(selectedServerProvider) == serverId &&
            ref.read(selectedChannelProvider) == channelId &&
            ref.read(chatAtBottomProvider);
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
        // Proactively establish WebRTC data channel for P2P file transfers.
        ref.read(webRtcProvider.notifier).ensureConnection(peerId);

      case NetworkEvent_MessageSent(
            :final toPeer, :final messageId, :final timestamp, :final signature, :final publicKey):
        // Hydrate the optimistic in-memory entry with Rust's signed timestamp
        // + sig/pk so the Message Proof dialog shows VERIFIED on fresh sends.
        // The Dart-side DateTime.now() used at optimistic-add time can differ
        // from Rust's SystemTime::now() by a few ms on machines with coarse
        // OS timer resolution (e.g. VMs), breaking canonical payload parity.
        ref.read(chatProvider.notifier).hydrateSignature(
              toPeer, messageId, timestamp.toInt(), signature, publicKey,
            );

      case NetworkEvent_ChannelMessageSent(
            :final serverId, :final channelId, :final messageId, :final timestamp, :final signature, :final publicKey):
        ref.read(channelChatProvider.notifier).hydrateSignature(
              serverId, channelId, messageId, timestamp.toInt(), signature, publicKey,
            );

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
        ref.read(serverStripLayoutProvider.notifier).onServerCreated(serverId);

      case NetworkEvent_ServerUpdated(:final serverId):
        debugPrint('[HOLLOW] Server updated: $serverId');
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);
        ref.read(serverAvatarProvider.notifier).loadAvatar(serverId);
        // Reload channels and layout in case they changed.
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(channelListProvider.notifier).loadForServer(serverId);
          ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
        }

      case NetworkEvent_ChannelAdded(
            :final serverId, :final channelId, :final name, :final channelType):
        debugPrint('[HOLLOW] Channel added: $name ($channelId) type=$channelType in $serverId');
        ref
            .read(channelListProvider.notifier)
            .onChannelAdded(serverId, channelId, name, channelType: channelType);

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
        ref.read(serverStripLayoutProvider.notifier).onServerDeleted(serverId);
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
          ref.read(serverStripLayoutProvider.notifier).onServerDeleted(serverId);
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
        ref.read(serverAvatarProvider.notifier).loadAvatar(serverId);
        ref.invalidate(serverMembersProvider(serverId));
        // Reload channels in case they changed while offline.
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(channelListProvider.notifier).loadForServer(serverId);
          ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
        }
        // Recompute server unread counts after CRDT sync. This ensures
        // badges show on startup even if channel message sync hasn't
        // completed yet (loadAll ran before the node connected).
        if (ref.read(selectedServerProvider) != serverId) {
          crdt_api.getServerChannels(serverId: serverId).then((channels) {
            final channelIds = channels.map((c) => c.channelId).toList();
            ref.read(unreadProvider.notifier).recomputeServerUnread(
                serverId, channelIds);
          }).catchError((_) {});
        }

      case NetworkEvent_ServerJoined(:final serverId, :final name):
        debugPrint('[HOLLOW] Server joined: $name ($serverId)');
        ref.read(serverListProvider.notifier).onServerCreated(serverId, name);
        ref.read(serverStripLayoutProvider.notifier).onServerCreated(serverId);
        // Auto-select the newly joined server and load its channels
        ref.read(selectedServerProvider.notifier).state = serverId;
        ref.read(selectedPeerProvider.notifier).state = null;
        ref.read(serverSettingsOpenProvider.notifier).state = false;
        ref.read(channelListProvider.notifier).loadForServer(serverId).then((_) async {
          await ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
          // Auto-select first text channel in layout order after load completes.
          final joinedChannels = ref.read(channelListProvider);
          if (joinedChannels.isNotEmpty) {
            final layout = ref.read(channelLayoutProvider);
            ref.read(selectedChannelProvider.notifier).state =
                firstTextChannelInLayout(joinedChannels, layout)
                    ?? joinedChannels.keys.first;
          }
        });
        // Toast feedback
        final joinCtx = hollowNavigatorKey.currentContext;
        if (joinCtx != null) {
          HollowToast.show(joinCtx, 'Joined $name',
              type: HollowToastType.success);
        }

      case NetworkEvent_ServerJoinFailed(:final serverId, :final reason):
        debugPrint('[HOLLOW] Server join failed: $serverId — $reason');
        final failCtx = hollowNavigatorKey.currentContext;
        if (failCtx != null) {
          HollowToast.show(failCtx, 'Failed to join server: $reason',
              type: HollowToastType.error);
        }

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
          // New messages arrived — clear cache so next channel view loads fresh from DB.
          // Like DM sync: unconditional, no viewing-state dependency.
          ref
              .read(channelChatProvider.notifier)
              .clearServerCache(serverId);
          // If currently viewing this server, merge immediately for the selected channel.
          if (selectedServer == serverId && selectedChannel != null) {
            ref
                .read(channelChatProvider.notifier)
                .mergeFromDb(serverId, selectedChannel);
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

        // After message sync, request any missing files.
        if (newMessageCount > 0) {
          _requestMissingFiles(serverId);
        }

        // Always recompute unread counts from DB after sync completes for
        // non-viewed servers. loadAll() runs before the node starts, so its
        // snapshot is stale once sync finishes. Even with newMessageCount == 0,
        // live events during sync may have added messages to DB.
        if (selectedServer != serverId) {
          crdt_api.getServerChannels(serverId: serverId).then((channels) {
            final channelIds = channels.map((c) => c.channelId).toList();
            ref.read(unreadProvider.notifier).recomputeServerUnread(
                serverId, channelIds);
          }).catchError((_) {});
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
        debugPrint('[HOLLOW] DM sync completed for $peerId: $newMessageCount new messages');
        final chatNotifier = ref.read(chatProvider.notifier);
        if (newMessageCount > 0) {
          // New messages arrived via sync — reload from DB to pick them up.
          // loadHistory does an atomic state replace (no separate clear step),
          // so live-delivered messages are never briefly wiped.
          chatNotifier.loadHistory(peerId).catchError((e) {
            debugPrint('[HOLLOW] Failed to load DM history after sync for $peerId: $e');
          });
          ref.read(unreadProvider.notifier).recomputeDmUnread(peerId);
          _requestMissingFilesForDm(peerId);
        }
        // When newMessageCount == 0: do nothing. Live-delivered messages
        // (from pending_messages queue) are already in memory via
        // MessageReceived events. Clearing the cache would destroy them.

      case NetworkEvent_ProfileUpdated(:final peerId):
        debugPrint('[HOLLOW] Profile updated: $peerId');
        ref.read(profileProvider.notifier).reloadProfile(peerId);

      case NetworkEvent_ChannelMessageEdited(
            :final serverId, :final channelId, :final messageId, :final newText, :final editedAt, :final signature, :final publicKey):
        debugPrint('[HOLLOW] Channel message edited: $messageId in $serverId/$channelId');
        ref.read(channelChatProvider.notifier).applyEdit(
              serverId, channelId, messageId, newText, editedAt,
              signature: signature,
              publicKey: publicKey,
            );

      case NetworkEvent_DmMessageEdited(
            :final peerId, :final messageId, :final newText, :final editedAt, :final signature, :final publicKey):
        debugPrint('[HOLLOW] DM message edited: $messageId from $peerId');
        ref.read(chatProvider.notifier).applyEdit(
              peerId, messageId, newText, editedAt,
              signature: signature,
              publicKey: publicKey,
            );

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
            :final serverId, channelId: _,
            :final videoThumb):
        debugPrint('[HOLLOW] File header: $fileId ($fileName, $sizeBytes bytes)');
        // In erasure coding mode (6+ members), file data comes via vault shards,
        // not P2P streaming — so don't mark as "downloading".
        final isVaultMode = serverId != null &&
            (ref.read(serverMembersProvider(serverId)).valueOrNull?.length ?? 0) >= 6;
        ref.read(fileTransferProvider.notifier).onFileHeaderReceived(
              fileId: fileId,
              fileName: fileName,
              sizeBytes: sizeBytes.toInt(),
              isImage: isImage,
              width: width?.toInt(),
              height: height?.toInt(),
              isVaultMode: isVaultMode,
              videoThumb: videoThumb,
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
        // Bridge to recovery pool: if pool is active for this server,
        // this reconstruction was triggered by recovery shard transfer.
        final activePool = ref.read(recoveryPoolProvider);
        if (activePool != null && activePool.isActive && activePool.serverId == serverId) {
          ref.read(recoveryPoolProvider.notifier).onFileRecovered(
                serverId, contentId, diskPath);
        }
      case NetworkEvent_VaultDownloadFailed(:final serverId,
            :final contentId, :final error):
        ref.read(vaultStatusProvider.notifier).onDownloadFailed(
              serverId, contentId, error);

      // -- Vault rebalancing events (Phase 4) --
      case NetworkEvent_RebalanceStarted(:final serverId, :final shardsToMove):
        ref.read(downloadManagerStateProvider.notifier)
            .onRebalanceStarted(serverId, shardsToMove);
      case NetworkEvent_RebalanceProgress(:final serverId, :final moved, :final total):
        ref.read(downloadManagerStateProvider.notifier)
            .onRebalanceProgress(serverId, moved, total);
      case NetworkEvent_RebalanceCompleted(:final serverId):
        ref.read(downloadManagerStateProvider.notifier)
            .onRebalanceCompleted(serverId);

      // -- Connection status events --
      case NetworkEvent_KeyExchangeStarted(:final peerId):
        ref
            .read(connectionStatusProvider.notifier)
            .onKeyExchangeStarted(peerId);

      case NetworkEvent_KeyExchangeProgress(
            :final peerId, :final stage):
        ref
            .read(connectionStatusProvider.notifier)
            .onKeyExchangeProgress(peerId, stage);

      // -- Vault guard events --
      case NetworkEvent_VaultUploadReplicationFallback(
            :final serverId, :final contentId, :final online, :final needed):
        debugPrint('[HOLLOW] Vault upload fallback: $online online < $needed needed for $contentId in $serverId — using replication');

      // -- WebRTC events (Phase 5A) --
      case NetworkEvent_WebRtcSignal(
            :final peerId, :final signalType, :final payload, :final connId):
        ref.read(webRtcProvider.notifier).handleSignal(
              peerId, signalType, payload, connId);

      case NetworkEvent_WebRtcSendFile(
            :final peerId, :final transferId, :final filePath,
            :final totalSize, :final kind, :final shardIndex, :final chunkIndex):
        ref.read(webRtcProvider.notifier).handleSendFile(
              peerId, transferId, filePath, totalSize.toInt(), kind, shardIndex,
              chunkIndex: chunkIndex);

      // -- Voice call events (Phase 5B) --
      case NetworkEvent_CallSignal(
            :final peerId, :final signalType, :final payload):
        ref.read(callProvider.notifier).handleCallSignal(
              peerId, signalType, payload);

      // -- Voice channel events (Phase 5C) --
      case NetworkEvent_VoiceChannelJoined(
            :final serverId, :final channelId, :final peerId):
        final vcNotifier = ref.read(voiceChannelProvider.notifier);
        vcNotifier.onPeerJoined(serverId, channelId, peerId);
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        if (peerId == localPeerId) {
          // Cache the currently selected channel so we can restore it on leave.
          vcNotifier.preVcChannelId = ref.read(selectedChannelProvider);
          vcNotifier.onLocalJoined(serverId, channelId);
          // Auto-select the voice channel for the main pane.
          ref.read(selectedChannelProvider.notifier).state = channelId;
        } else {
          // Remote peer joined — initiate WebRTC if we're in the same channel.
          final vcState = ref.read(voiceChannelProvider);
          if (vcState.currentServerId == serverId &&
              vcState.currentChannelId == channelId) {
            vcNotifier.onRemotePeerJoined(peerId);
          }
        }

      case NetworkEvent_VoiceChannelLeft(
            :final serverId, :final channelId, :final peerId):
        final vcNotifier = ref.read(voiceChannelProvider.notifier);
        vcNotifier.onPeerLeft(serverId, channelId, peerId);
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        if (peerId == localPeerId) {
          // Restore the channel that was selected before joining the VC.
          // Fall back to first text channel if the cached one is gone.
          if (ref.read(selectedChannelProvider) == channelId) {
            final cached = vcNotifier.preVcChannelId;
            final channels = ref.read(channelListProvider);
            if (cached != null && channels.containsKey(cached)) {
              ref.read(selectedChannelProvider.notifier).state = cached;
            } else {
              final layout = ref.read(channelLayoutProvider);
              ref.read(selectedChannelProvider.notifier).state =
                  firstTextChannelInLayout(channels, layout);
            }
          }
          vcNotifier.preVcChannelId = null;
          vcNotifier.onLocalLeft();
        } else {
          vcNotifier.onRemotePeerLeft(peerId);
        }

      case NetworkEvent_VoiceChannelSignal(
            :final serverId, :final channelId, :final peerId,
            :final signalType, :final payload):
        ref.read(voiceChannelProvider.notifier).handleSignal(
              peerId, signalType, payload, serverId, channelId);

      // -- Gossip relay tree events (Phase 5D) --
      case NetworkEvent_GossipConnect(:final peerId):
        ref.read(webRtcProvider.notifier).ensureConnection(peerId);

      case NetworkEvent_GossipDisconnect(:final peerId):
        ref.read(webRtcProvider.notifier).disconnectPeer(peerId);

      case NetworkEvent_GossipRelayFile(
            :final broadcastId, :final ttl, :final originPeerId,
            :final filePath, :final totalSize, :final kind,
            :final shardIndex, :final excludePeerId,
            :final serverId, :final channelId):
        ref.read(webRtcProvider.notifier).relayBroadcast(
          broadcastId: broadcastId,
          ttl: ttl,
          originPeerId: originPeerId,
          filePath: filePath,
          totalSize: totalSize.toInt(),
          kind: kind,
          shardIndex: shardIndex,
          excludePeerId: excludePeerId,
        );

      case NetworkEvent_VoiceChannelModeChanged(
            :final serverId, :final channelId,
            :final mode, :final gossipNeighbors):
        ref.read(voiceChannelProvider.notifier).onModeChanged(
              serverId, channelId, mode, gossipNeighbors);

      case NetworkEvent_MlsEpochChanged(
            :final serverId, :final epoch, :final sframeKey):
        ref.read(voiceChannelProvider.notifier).onEpochChanged(
              serverId, epoch.toInt(), Uint8List.fromList(sframeKey));

      // -- Recovery pool events --
      case NetworkEvent_RecoveryPoolCreated(:final serverId, :final inviteLink):
        ref.read(recoveryPoolProvider.notifier).onPoolCreated(serverId, inviteLink);
      case NetworkEvent_RecoveryPoolJoined(:final serverId):
        // Create pool state in pending mode — dashboard won't show until confirmed.
        ref.read(recoveryPoolProvider.notifier).onPoolJoinedPending(serverId);
      case NetworkEvent_RecoveryPoolJoinFailed(:final serverId, :final reason):
        debugPrint('[RECOVERY-POOL] Join failed for $serverId: $reason');
      case NetworkEvent_RecoveryPoolMemberJoined(:final serverId, :final peerId):
        ref.read(recoveryPoolProvider.notifier).onMemberJoined(serverId, peerId);
      case NetworkEvent_RecoveryPoolMemberLeft(:final serverId, :final peerId):
        ref.read(recoveryPoolProvider.notifier).onMemberLeft(serverId, peerId);
      case NetworkEvent_RecoveryPoolStatus(
            :final serverId, :final totalFiles, :final reconstructable,
            :final partial, :final noShards, :final progressPct):
        ref.read(recoveryPoolProvider.notifier).onStatus(
          serverId,
          totalFiles: totalFiles,
          reconstructable: reconstructable,
          partial: partial,
          noShards: noShards,
          progressPct: progressPct,
        );
      case NetworkEvent_RecoveryPoolShardTransferred():
        break; // Dashboard updates via status events.
      case NetworkEvent_RecoveryPoolFileRecovered(
            :final serverId, :final contentId, :final diskPath):
        ref.read(recoveryPoolProvider.notifier).onFileRecovered(serverId, contentId, diskPath);
      case NetworkEvent_RecoveryPoolStopped(:final serverId):
        ref.read(recoveryPoolProvider.notifier).onPoolStopped(serverId);
      // -- Hollow Share --
      case NetworkEvent_ShareManifestReady(
            :final rootHash, :final fileName, :final totalSize, :final chunkCount):
        debugPrint('[HOLLOW-SHARE] manifest ready: $fileName ($totalSize bytes, $chunkCount chunks) root=$rootHash');
        ref.read(shareTabProvider.notifier).handleShareManifestReady(rootHash, fileName, totalSize.toInt(), chunkCount);
      case NetworkEvent_ShareProgress(
            :final rootHash, :final chunksHave, :final chunksTotal, :final seeders, :final leechers, :final bytesPerSec):
        debugPrint('[HOLLOW-SHARE] progress $rootHash: $chunksHave/$chunksTotal chunks, $seeders seeders, $leechers leechers, $bytesPerSec B/s');
        ref.read(shareTabProvider.notifier).handleShareProgress(rootHash, chunksHave, chunksTotal, seeders, leechers, bytesPerSec.toInt());
      case NetworkEvent_ShareCompleted(:final rootHash, :final diskPath):
        debugPrint('[HOLLOW-SHARE] completed $rootHash → $diskPath');
        ref.read(shareTabProvider.notifier).handleShareCompleted(rootHash, diskPath);
      case NetworkEvent_ShareFailed(:final rootHash, :final error):
        debugPrint('[HOLLOW-SHARE] failed $rootHash: $error');
        ref.read(shareTabProvider.notifier).handleShareFailed(rootHash, error);
      case NetworkEvent_ShareSeedingChanged(
            :final rootHash, :final seeding, :final seeders, :final leechers, :final bytesUploaded):
        debugPrint('[HOLLOW-SHARE] seeding changed $rootHash: seeding=$seeding seeders=$seeders leechers=$leechers uploaded=$bytesUploaded');
        ref.read(shareTabProvider.notifier).handleShareSeedingChanged(rootHash, seeding, seeders, leechers, bytesUploaded.toInt());
      case NetworkEvent_ShareCreated(
            :final rootHash, :final link, :final fileName, :final totalSize):
        debugPrint('[HOLLOW-SHARE] created $fileName ($totalSize bytes) root=$rootHash link=$link');
        ref.read(shareTabProvider.notifier).handleShareCreated(rootHash, link, fileName, totalSize.toInt());
      case NetworkEvent_ShareList(:final entries):
        debugPrint('[HOLLOW-SHARE] list: ${entries.length} entries');
        ref.read(shareTabProvider.notifier).handleShareList(entries);
      case NetworkEvent_ShareNeedWebRtc(:final peerId):
        ref.read(webRtcProvider.notifier).ensureConnection(peerId);

    }
    } catch (e, st) {
      debugPrint('[HOLLOW] Unhandled dispatch error: $e\n$st');
    }
  }

  /// Request missing files after message sync completes.
  /// Queries messages with file_id that have no completed file on disk.
  /// Delayed to let sync pipeline settle.
  /// For 6+ member servers: only auto-requests images (non-images use vault shards).
  Future<void> _requestMissingFiles(String serverId) async {
    final memberCount = ref.read(serverMembersProvider(serverId)).valueOrNull?.length ?? 0;

    List<String> missingIds;
    if (memberCount >= 6) {
      // For 6+ servers, only auto-request images via P2P streaming.
      // Non-image files use vault erasure shards and are fetched via VaultDownloadFile.
      await Future.delayed(const Duration(milliseconds: 1500));
      try {
        missingIds = await storage_api.getMissingImageFileIdsForServer(serverId: serverId);
      } catch (e) {
        debugPrint('[HOLLOW] Failed to get missing image file ids: $e');
        return;
      }
    } else {
      await Future.delayed(const Duration(seconds: 1));
      try {
        missingIds = await storage_api.getMissingFileIds();
      } catch (e) {
        debugPrint('[HOLLOW] Failed to get missing file ids: $e');
        return;
      }
    }

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
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Request missing files after DM sync completes.
  Future<void> _requestMissingFilesForDm(String peerId) async {
    await Future.delayed(const Duration(seconds: 1));
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
        await Future.delayed(const Duration(milliseconds: 100));
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
