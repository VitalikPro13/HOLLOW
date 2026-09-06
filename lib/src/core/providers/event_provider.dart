import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/showcase_assets_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/device_link_sync_provider.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';

import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_anim_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/sync_progress_provider.dart';
import 'package:hollow/src/core/providers/typing_provider.dart';
import 'package:hollow/src/core/providers/pinned_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
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
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/forwarder_info_provider.dart';
import 'package:hollow/src/core/providers/ice_config_provider.dart';
import 'package:hollow/src/core/services/desktop_notification_service.dart'
    show notifLog;
import 'package:hollow/src/core/services/push_hints_cache.dart';
import 'package:hollow/src/core/providers/license_key_provider.dart';
import 'package:hollow/src/core/providers/room_budget_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/temporary_nickname_provider.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/network.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/ui/dialogs/twitch_join_dialog.dart' show showTwitchJoinDialog, handleTwitchJoinResult, showJoinRejectedDialog, showNsfwConfirmDialog;

/// Listens to the Rust event stream and dispatches to the right providers.
class EventStreamNotifier extends Notifier<bool> {
  StreamSubscription<NetworkEvent>? _subscription;
  final Map<String, Timer> _syncTimeouts = {};

  /// Tracks shares initiated by share_ref (auto-download on manifest ready).
  /// Key: rootHash, Value: {sequential, link, fileId}
  final Map<String, ({bool sequential, String link, String fileId})> _pendingAutoDownloads = {};

  /// Maps share rootHash → file ID for bridging Share events to file transfer state.
  final Map<String, String> _shareToFileId = {};

  /// Message IDs already processed via ChannelMessageReceived, so a
  /// ChannelNotificationHint for the same id is not double-counted.
  final Set<String> _processedChannelMessageIds = {};

  /// Servers that have completed their initial message sync. Share-backed files
  /// auto-download only for live messages, never during the sync burst.
  final Set<String> _serverSyncDone = {};

  @override
  bool build() {
    // Safety net: release the Rust->Dart subscription and pending sync timers so
    // they can't fire into a disposed notifier. Normal teardown goes through
    // stop(); this guards the invalidate path. Does NOT touch `state` (throws).
    ref.onDispose(() {
      _subscription?.cancel();
      _subscription = null;
      for (final t in _syncTimeouts.values) {
        t.cancel();
      }
      _syncTimeouts.clear();
    });
    return false; // streaming?
  }

  /// Refresh the iOS push-hints cache (friend name + avatar) read by the
  /// Notification Service Extension. Debounced + iOS-gated inside the cache,
  /// so a cheap no-op elsewhere.
  void _refreshPushHints() {
    final friends = ref.read(friendsProvider);
    if (friends.isEmpty) return;
    PushHintsCache.scheduleWrite(friends.keys);
  }

  bool _selfNuking = false;

  /// Step 7 self-nuke: this device was revoked. MARK a wipe and relaunch, because
  /// the live node holds open SQLCipher handles and deleting in-process fails on
  /// Windows; the next launch runs performPendingWipe() BEFORE the node starts.
  /// Idempotent, since the event can repeat.
  Future<void> _selfNuke() async {
    if (_selfNuking) return;
    _selfNuking = true;

    // Stash the wipe FIRST, before anything that can throw: a toast raised before
    // it aborted _selfNuke and the device never reset. Teardown is unconditional,
    // the toast best-effort. See feedback_toast_from_nonwidget_overlaystate.
    try {
      await storage_api.stashPendingWipe();
    } catch (e) {
      debugPrint('[HOLLOW] self-nuke stash failed: $e');
    }

    // Best-effort toast; must NEVER abort the nuke. Insert via `overlayState:`.
    try {
      final overlay = hollowNavigatorKey.currentState?.overlay;
      // Bind the context to a local so analyzers tie the mounted guard to the
      // exact context used (S7115 / use_build_context_synchronously).
      final overlayContext = overlay?.context;
      if (overlay != null && overlayContext != null && overlayContext.mounted) {
        HollowToast.show(
          overlayContext,
          'This device was removed from your identity. Resetting…',
          type: HollowToastType.error,
          overlayState: overlay,
        );
      }
    } catch (e) {
      debugPrint('[HOLLOW] self-nuke toast failed (non-fatal): $e');
    }

    // Relaunch via the shared waiter-script helper (app_relaunch.dart): a
    // directly-spawned copy dies against the native single-instance forwarder.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    await relaunchApp();
  }

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
    // Warm the device->identity map from the node's resolver so attribution is
    // correct before the first profile sync. The event stream can start BEFORE
    // the node hydrates its resolver, and nothing retries until a sibling
    // re-sends its list, so retry a few times to catch the node once ready.
    _warmDeviceMaps();
  }

  void _warmDeviceMaps() {
    ref.read(deviceLinkProvider.notifier).refresh();
    ref.read(deviceLabelProvider.notifier).refresh();
    // Cheap idempotent re-pull, in case the resolver wasn't hydrated yet.
    for (final ms in const [400, 1200, 3000]) {
      Future<void>.delayed(Duration(milliseconds: ms), () {
        if (_subscription == null) return; // stopped meanwhile
        ref.read(deviceLinkProvider.notifier).refresh();
        ref.read(deviceLabelProvider.notifier).refresh();
      });
    }
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    // Drain pending sync-timeout timers so none fires into a now-idle notifier.
    for (final t in _syncTimeouts.values) {
      t.cancel();
    }
    _syncTimeouts.clear();
    state = false;
  }

  void _refreshServerState(String serverId) {
    ref.read(serverListProvider.notifier).onServerUpdated(serverId);
    ref.invalidate(serverMembersProvider(serverId));
    ref.invalidate(serverLabelsProvider(serverId));
    ref.invalidate(serverEmotesProvider(serverId));
    ref.invalidate(serverStickersProvider(serverId));
    ref.invalidate(serverIsNsfwProvider(serverId));
    ref.invalidate(myPermissionsProvider(serverId));
    ref.invalidate(myRoleProvider(serverId));
    ref.invalidate(myMuteStatusProvider(serverId));
    // CrdtStore persists via fire-and-forget mpsc, so a DB read races the actor's
    // write and a single fixed delay was unreliable. Refresh on a ramp:
    // channelListProvider drives the desktop shell and open mobile chat route,
    // serverChannelsProvider drives the mobile Chats tab, which has no selection.
    _reloadChannelsWithRetry(serverId);
    _evictVoiceIfInvisible(serverId);
  }

  /// If we're in a VOICE channel on [serverId] that we can no longer SEE, hang
  /// up: the UI equivalent of pressing Disconnect. Belt-and-suspenders next to
  /// the Rust auto-leave, so the call genuinely ends whether or not that event
  /// lands. Re-checks on a ramp because role state lands via the CrdtStore.
  void _evictVoiceIfInvisible(String serverId) {
    const delays = [Duration(milliseconds: 150), Duration(milliseconds: 600),
        Duration(milliseconds: 1400)];
    for (final d in delays) {
      Future.delayed(d, () {
        final vc = ref.read(voiceChannelProvider);
        if (!vc.isInVoiceChannel) return;
        if (vc.currentServerId != serverId) return;
        final cid = vc.currentChannelId;
        if (cid == null) return;

        final channels = ref.read(serverChannelsProvider(serverId)).valueOrNull;
        if (channels == null) return; // not loaded yet — a later tick re-checks
        final ch = channels[cid];
        // Channel gone (deleted / kicked) or the Rust-computed predicate now
        // excludes us. This snapshot re-reads post-ramp, so meCanSee is fresh.
        final canSee = ch?.meCanSee ?? false;
        if (!canSee) {
          debugPrint('[HOLLOW-VC] Lost visibility to active voice channel $cid — hanging up');
          ref.read(voiceChannelProvider.notifier).leaveChannel();
        }
      });
    }
  }

  /// Re-read channels for a server on a short ramp to defeat the CrdtStore
  /// fire-and-forget write race. The per-server snapshot refreshes every tick;
  /// the selected-server map only while that server is still selected.
  void _reloadChannelsWithRetry(String serverId) {
    const delays = [Duration.zero, Duration(milliseconds: 120),
        Duration(milliseconds: 400), Duration(milliseconds: 1000)];
    for (final d in delays) {
      Future.delayed(d, () {
        ref.invalidate(serverChannelsProvider(serverId));
        // Mute state rides the same fire-and-forget write, so it needs the same
        // ramp: a single immediate invalidate reads stale DB.
        ref.invalidate(mutedMembersProvider(serverId));
        ref.invalidate(myMuteStatusProvider(serverId));
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(channelListProvider.notifier).loadForServer(serverId);
          ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
        }
      });
    }
  }

  void _dispatch(NetworkEvent event) {
    // SECURITY: an unhandled exception here would kill the event loop.
    try {
    switch (event) {
      case NetworkEvent_PeerDiscovered(:final peer):
        debugPrint(
            '[HOLLOW] Peer discovered: ${peer.peerId} at ${peer.addresses}');
        ref.read(peersProvider.notifier).addPeer(peer.peerId, peer.addresses);
        ref.read(connectionStatusProvider.notifier).onPeerConnected(peer.peerId);
        // A peer we are in a call with is back in the relay's rooms, so the shortened
        // hold-open window no longer applies. See CallNotifier.handlePeerDisconnected.
        ref.read(callProvider.notifier).handlePeerReconnected(peer.peerId);

      case NetworkEvent_TurnCredentials(
          :final username, :final password, :final uris):
        ref.read(iceConfigProvider.notifier).setTurnCredentials(
            username: username, password: password, uris: uris);

      case NetworkEvent_MediaForwarderInfo(:final peerId, :final online):
        ref
            .read(forwarderInfoProvider.notifier)
            .setInfo(peerId: peerId, online: online);

      case NetworkEvent_PeerExpired(:final peerId):
        ref.read(peersProvider.notifier).removePeer(peerId);
        ref.read(invisiblePeersProvider.notifier).removePeer(peerId);
        ref.read(webRtcProvider.notifier).disconnectPeer(peerId);
        // Don't deselect — friends stay visible when offline.

      case NetworkEvent_PeerDisconnected(:final peerId):
        debugPrint('[HOLLOW] Peer disconnected: $peerId');
        ref.read(peersProvider.notifier).removePeer(peerId);
        ref.read(invisiblePeersProvider.notifier).removePeer(peerId);
        ref.read(connectionStatusProvider.notifier).onPeerDisconnected(peerId);
        ref.read(webRtcProvider.notifier).disconnectPeer(peerId);
        ref.read(callProvider.notifier).handlePeerDisconnected(peerId);
        ref.read(voiceChannelProvider.notifier).onPeerDisconnected(peerId);
        // Don't deselect — friends stay visible when offline.

      case NetworkEvent_RoomCleared():
        // Fired on an active-room SWITCH, NOT on connection loss. Do NOT clearAll()
        // peers or null the selection: that blanked the chat pane during transient
        // instability and flipped every conversation to "offline". Peers repopulate
        // via PeerJoined / Members, and the relay's state is the source of truth.
        debugPrint('[HOLLOW] Room cleared (non-destructive — peers/selection preserved)');

      case NetworkEvent_Listening(:final address):
        debugPrint('[HOLLOW] Listening: $address');

      case NetworkEvent_MessageReceived(:final fromPeer, :final text, :final timestamp, :final messageId, :final replyToMid, :final linkPreview, :final signature, :final publicKey, :final isOwn, :final duplicate):
        // MULTI-DEVICE: unread counts, the seen pointer, mute and notifications key
        // on the MASTER identity. Belt-and-braces (the main receive path already
        // resolves), protecting the pill from a device-keyed entry markDmSeen misses.
        final dmMaster = ref.read(deviceLinkProvider).identityOf(fromPeer);
        ref.read(chatProvider.notifier).receiveMessage(
              fromPeer, text, timestamp, messageId, replyToMid,
              linkPreview: linkPreview,
              signature: signature,
              publicKey: publicKey,
              isOwn: isOwn,
            );
        // A sibling echo of OUR OWN sent message: outgoing, so it must NOT mark the
        // conversation unread, notify, or read as the friend typing.
        if (isOwn) {
          // We just participated from another device, so clear typing and mark read.
          ref.read(typingProvider.notifier).clearTyping(dmMaster, dmMaster);
          ref.read(unreadProvider.notifier).markDmSeen(
              dmMaster, messageId.isNotEmpty ? messageId : null);
          break;
        }
        ref.read(typingProvider.notifier).clearTyping(fromPeer, fromPeer);
        // A duplicate delivery (a sync batch or fetch-node insert beat the live
        // message): the append stays idempotent, but unread and notifications must
        // NOT re-fire or a replay double-counts the pill and re-toasts.
        if (duplicate) break;
        // Track unread DM, only if not muted. "Viewing" needs the window VISIBLE and
        // ACTIVE: alt-tabbed away or backgrounded is not reading, and without the
        // active check a backgrounded open chat suppressed its OS notification.
        final windowVisible = ref.read(windowVisibleProvider);
        final appActive = (Platform.isAndroid || Platform.isIOS)
            ? !ref.read(appLifecycleProvider).isBackground
            : ref.read(windowFocusedProvider);
        final isViewingDm = windowVisible &&
            appActive &&
            ref.read(selectedPeerProvider) == dmMaster &&
            ref.read(selectedServerProvider) == null &&
            ref.read(chatAtBottomProvider);
        final isDmMuted = !ref
            .read(notificationSettingsProvider.notifier)
            .isDmEnabled(dmMaster);
        if (!isDmMuted) {
          ref.read(unreadProvider.notifier).onDmMessage(
              dmMaster, messageId, isViewingDm);
        }
        if (!isViewingDm && !isDmMuted) {
          ref.read(systemNotificationProvider.notifier).notifyDm(
                fromPeerId: dmMaster,
                text: text,
                replyToMid: replyToMid,
                messageId: messageId,
              );
        } else if (isViewingDm && !Platform.isAndroid && !Platform.isIOS) {
          // The one path that produces NO notification and NO log downstream. If this
          // shows while the window was behind another app, `windowFocusedProvider` is
          // stuck on true (a missed onWindowBlur) and THAT is the bug.
          notifLog('DM suppressed by the viewing gate — '
              'visible=$windowVisible focused=$appActive');
        }

      case NetworkEvent_ChannelMessageReceived(
            :final serverId, :final channelId, :final fromPeer, :final text, :final timestamp, :final messageId, :final replyToMid, :final linkPreview, :final signature, :final publicKey, :final replyToOwn, :final duplicate):
        ref.read(channelChatProvider.notifier).receiveMessage(
              serverId, channelId, fromPeer, text, timestamp, messageId, replyToMid,
              linkPreview: linkPreview,
              signature: signature,
              publicKey: publicKey,
            );
        ref.read(typingProvider.notifier).clearTyping('$serverId:$channelId', fromPeer);
        // Duplicate delivery (row already in DB via a sync batch): the append keeps
        // an open pane current, but unread and notifications must not re-fire.
        if (duplicate) break;
        // Blocked sender: Rust drops DM surfaces at ingest, but channel messages
        // still flow, so they must not produce badges or notifications. Compare the
        // sender's MASTER identity (the block list is master-keyed).
        final senderMasterBlocked = ref
            .read(blockedUsersProvider)
            .contains(ref.read(deviceLinkProvider).identityOf(fromPeer));
        // Track unread channel message only if not muted, visible, viewing, scrolled
        // to bottom and app-active. See the DM gate above.
        final chAppActive = (Platform.isAndroid || Platform.isIOS)
            ? !ref.read(appLifecycleProvider).isBackground
            : ref.read(windowFocusedProvider);
        final isViewingChannel = ref.read(windowVisibleProvider) &&
            chAppActive &&
            ref.read(selectedServerProvider) == serverId &&
            ref.read(selectedChannelProvider) == channelId &&
            ref.read(chatAtBottomProvider);
        final channelNotifLevel = ref
            .read(notificationSettingsProvider.notifier)
            .effectiveChannelLevel(serverId, channelId);
        final isChannelMuted =
            channelNotifLevel == NotificationLevel.nothing;
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        final localName = displayNameFor(
            ref.read(profileProvider), localPeerId);
        final localNick =
            ref.read(serverNicknamesProvider(serverId))[localPeerId];
        // `replyToOwn` (Rust-computed), never `replyToMid`, which is non-nullable
        // ('' when not a reply): the old `!= null` was a tautology that made EVERY
        // message a mention, so "Mentions only" behaved like "All" (#42).
        final isMentioned = text.contains('@everyone') ||
            text.contains('@$localName') ||
            (localNick != null && text.contains('@$localNick')) ||
            replyToOwn;
        final isMentionFiltered = channelNotifLevel == NotificationLevel.mentions && !isMentioned;
        if (!isChannelMuted && !isMentionFiltered && !senderMasterBlocked) {
          ref.read(unreadProvider.notifier).onChannelMessage(
              serverId, channelId, messageId, isViewingChannel,
              isMention: isMentioned);
        }
        // Track message ID for hint dedup (even if mention-filtered).
        _processedChannelMessageIds.add(messageId);
        if (_processedChannelMessageIds.length > 500) {
          final toRemove = _processedChannelMessageIds.take(250).toList();
          _processedChannelMessageIds.removeAll(toRemove);
        }
        if (!isViewingChannel &&
            !isChannelMuted &&
            !isMentionFiltered &&
            !senderMasterBlocked) {
          _notifyChannelWithName(
              serverId, channelId, fromPeer, text, isMentioned, messageId);
        } else if (isViewingChannel &&
            !Platform.isAndroid &&
            !Platform.isIOS) {
          // See the DM gate above — this is the silent branch.
          notifLog('channel suppressed by the viewing gate — '
              'focused=$chAppActive');
        }

      case NetworkEvent_SessionEstablished(:final peerId):
        ref.read(peersProvider.notifier).markEncrypted(peerId);
        ref.read(connectionStatusProvider.notifier).onSessionEstablished(peerId);
        // After re-key, clear "Sync failed" for servers where this peer is a member.
        _clearFailedSyncForPeer(peerId);
        ref.read(webRtcProvider.notifier).ensureConnection(peerId);

      case NetworkEvent_MessageSent(
            :final toPeer, :final messageId, :final timestamp, :final signature, :final publicKey):
        // Hydrate the optimistic entry with Rust's signed timestamp + sig/pk so the
        // Message Proof dialog shows VERIFIED on fresh sends: Dart's DateTime.now()
        // can differ from Rust's by a few ms, breaking canonical payload parity.
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

      case NetworkEvent_ServerCreated(:final serverId, :final name):
        debugPrint('[HOLLOW] Server created: $name ($serverId)');
        ref.read(serverListProvider.notifier).onServerCreated(serverId, name);
        ref.read(serverStripLayoutProvider.notifier).onServerCreated(serverId);

      case NetworkEvent_ServerUpdated(:final serverId):
        debugPrint('[HOLLOW] Server updated: $serverId');
        ref.read(serverAvatarProvider.notifier).loadAvatar(serverId);
        ref.read(serverAvatarAnimProvider.notifier).loadAnim(serverId);
        ref.read(serverBannerProvider.notifier).loadBanner(serverId);
        _refreshServerState(serverId);

      case NetworkEvent_EmoteAssetsReceived(:final hashes):
        debugPrint('[HOLLOW] Emote assets received: ${hashes.length}');
        clearRequestedEmotes(hashes);
        for (final hash in hashes) {
          ref.invalidate(emoteBytesProvider(hash));
        }
        ref.read(serverBannerProvider.notifier).onAssetsReceived(hashes);
        ref.read(serverAvatarAnimProvider.notifier).onAssetsReceived(hashes);
        ref.read(avatarFrameProvider.notifier).onAssetsReceived(hashes);
        ref.read(profileAnimProvider.notifier).onAssetsReceived(hashes);
        // GIF-sized blobs grow the asset cache fast, so the cap applies here too.
        _enforceStorageCaps();

      case NetworkEvent_ChannelAdded(
            :final serverId, :final channelId, :final name, :final channelType):
        debugPrint('[HOLLOW] Channel added: $name ($channelId) type=$channelType in $serverId');
        ref
            .read(channelListProvider.notifier)
            .onChannelAdded(serverId, channelId, name, channelType: channelType);
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);

      case NetworkEvent_ChannelRemoved(:final serverId, :final channelId):
        debugPrint('[HOLLOW] Channel removed: $channelId in $serverId');
        ref
            .read(channelListProvider.notifier)
            .onChannelRemoved(serverId, channelId);
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);

      case NetworkEvent_ChannelRenamed(
            :final serverId, :final channelId, :final newName):
        debugPrint(
            '[HOLLOW] Channel renamed: $channelId to $newName in $serverId');
        ref
            .read(channelListProvider.notifier)
            .onChannelRenamed(serverId, channelId, newName);
        ref.read(serverListProvider.notifier).onServerUpdated(serverId);

      case NetworkEvent_ServerDeleted(:final serverId):
        debugPrint('[HOLLOW] Server deleted: $serverId');
        ref.read(serverListProvider.notifier).onServerDeleted(serverId);
        ref.read(serverStripLayoutProvider.notifier).onServerDeleted(serverId);
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
        ref.read(serverAvatarAnimProvider.notifier).loadAnim(serverId);
        ref.read(serverBannerProvider.notifier).loadBanner(serverId);
        ref.invalidate(serverMembersProvider(serverId));
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(channelListProvider.notifier).loadForServer(serverId);
          ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
        }
        // Recompute server unread counts for ALL servers (including selected) to
        // pick up messages that arrived while offline.
        crdt_api.getServerChannels(serverId: serverId).then((channels) {
          final channelIds = channels.map((c) => c.channelId).toList();
          ref.read(unreadProvider.notifier).recomputeServerUnread(
              serverId, channelIds);
        }).catchError((_) {});

      case NetworkEvent_ServerJoined(:final serverId, :final name):
        debugPrint('[HOLLOW] Server joined: $name ($serverId)');
        handleTwitchJoinResult(success: true);
        ref.read(serverListProvider.notifier).onServerCreated(serverId, name);
        // Order matters for a PARKED join: onServerCreated turns the pending tile
        // into the real server IN PLACE, so it must run while that tile exists.
        // Dropping the row first would append the server at the end of the strip.
        ref.read(serverStripLayoutProvider.notifier).onServerCreated(serverId);
        ref.read(pendingJoinsProvider.notifier).remove(serverId);
        // Close any centre tab first: joining out of Browse Public Channels is a
        // normal flow and the tab would sit on top of the server we just selected (#28).
        setShellTab(ref.read, null);
        ref.read(selectedServerProvider.notifier).state = serverId;
        ref.read(selectedPeerProvider.notifier).state = null;
        ref.read(serverSettingsOpenProvider.notifier).state = false;
        ref.read(channelListProvider.notifier).loadForServer(serverId).then((_) async {
          await ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
          final joinedChannels = ref.read(channelListProvider);
          if (joinedChannels.isNotEmpty) {
            final layout = ref.read(channelLayoutProvider);
            ref.read(selectedChannelProvider.notifier).state =
                firstTextChannelInLayout(joinedChannels, layout)
                    ?? joinedChannels.keys.first;
          }
        });
        final joinCtx = hollowNavigatorKey.currentContext;
        if (joinCtx != null) {
          HollowToast.show(joinCtx, 'Joined $name',
              type: HollowToastType.success);
        }

      // Rust no longer emits this on the 15 second timeout (that path PARKS the
      // join). The arm stays for other emitters and older nodes.
      case NetworkEvent_ServerJoinFailed(:final serverId, :final reason):
        debugPrint('[HOLLOW] Server join failed: $serverId — $reason');
        final failCtx = hollowNavigatorKey.currentContext;
        if (failCtx != null) {
          HollowToast.show(failCtx, 'Failed to join server: $reason',
              type: HollowToastType.error);
        }

      // Nobody was online to answer: the request is parked, not failed.
      case NetworkEvent_ServerJoinParked(:final serverId):
        onServerJoinParked(ref, serverId);

      case NetworkEvent_PendingJoinUpdated(
            :final serverId, :final state, :final reason):
        onPendingJoinUpdated(ref, serverId, state, reason);

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
        _serverSyncDone.add(serverId);
        _syncTimeouts[serverId]?.cancel();
        _syncTimeouts.remove(serverId);
        ref.read(syncingPeersProvider.notifier).clearServer(serverId);
        ref.read(syncProgressProvider.notifier).clearServer(serverId);
        ref.read(syncStatusProvider.notifier).setStatus(
            serverId, ServerSyncStatus.synced);
        final selectedServer = ref.read(selectedServerProvider);
        final selectedChannel = ref.read(selectedChannelProvider);
        if (newMessageCount > 0) {
          // New messages arrived: clear the cache so the next view loads fresh from DB.
          ref
              .read(channelChatProvider.notifier)
              .clearServerCache(serverId);
          if (selectedServer == serverId && selectedChannel != null) {
            ref
                .read(channelChatProvider.notifier)
                .mergeFromDb(serverId, selectedChannel);
          }
        } else if (selectedServer == serverId && selectedChannel != null) {
          // No new messages, but reactions may have synced; refresh those only.
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

        // Files are downloaded on demand when visible (channel_chat_pane.dart).

        // Recompute unread counts from DB only when the sync actually inserted
        // something: every channel open fires a sync, and an unconditional recount
        // on a no-op completion resurrected stale counts for untouched channels.
        if (newMessageCount > 0) {
          debugPrint('[HOLLOW] Triggering recomputeServerUnread for $serverId (newMsgCount=$newMessageCount)');
          crdt_api.getServerChannels(serverId: serverId).then((channels) {
            final channelIds = channels.map((c) => c.channelId).toList();
            debugPrint('[HOLLOW] recomputeServerUnread: ${channelIds.length} channels for $serverId');
            ref.read(unreadProvider.notifier).recomputeServerUnread(
                serverId, channelIds);
          }).catchError((e) {
            debugPrint('[HOLLOW] recomputeServerUnread failed: $e');
          });
        }

      case NetworkEvent_MessageSyncFailed(:final serverId, :final error):
        debugPrint('[HOLLOW] Message sync failed for $serverId: $error');
        _syncTimeouts[serverId]?.cancel();
        _syncTimeouts.remove(serverId);
        ref.read(syncingPeersProvider.notifier).clearServer(serverId);
        ref.read(syncProgressProvider.notifier).clearServer(serverId);
        // Transient decrypt failures during re-key show "Retrying", not "Failed".
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
        _refreshServerState(serverId);

      case NetworkEvent_DmSyncCompleted(:final peerId, :final newMessageCount):
        debugPrint('[HOLLOW] DM sync completed for $peerId: $newMessageCount new messages');
        final chatNotifier = ref.read(chatProvider.notifier);
        if (newMessageCount > 0) {
          // New messages arrived via sync: reload from DB. loadHistory replaces state
          // atomically, so live-delivered messages are never briefly wiped.
          chatNotifier.loadHistory(peerId).catchError((e) {
            debugPrint('[HOLLOW] Failed to load DM history after sync for $peerId: $e');
          });
          ref.read(unreadProvider.notifier).recomputeDmUnread(peerId);
          _requestMissingFilesForDm(peerId);
        }
        // newMessageCount == 0: do nothing. Live-delivered messages are already in
        // memory, and clearing the cache would destroy them.

      case NetworkEvent_ProfileUpdated(:final peerId):
        debugPrint('[HOLLOW] Profile updated: $peerId');
        ref.read(profileProvider.notifier).reloadProfile(peerId);
        ref.read(avatarProvider.notifier).invalidate(peerId);
        ref.invalidate(bannerProvider(peerId));
        ref.invalidate(showcaseAssetsProvider(peerId));
        // A re-announce is our one signal that this peer is reachable again, which
        // is when a frame asked for while they were offline can finally be pulled.
        ref.read(avatarFrameProvider.notifier).onProfileUpdated(peerId);
        ref.read(profileAnimProvider.notifier).onProfileUpdated(peerId);
        _refreshPushHints();

      case NetworkEvent_DeviceListUpdated(:final masterPeerId):
        // Refresh the Dart device->identity map so attribution picks the list up.
        debugPrint('[HOLLOW] Device list updated: $masterPeerId');
        ref.read(deviceLinkProvider.notifier).refresh();
        ref.read(deviceLabelProvider.notifier).refresh();
        // The ingest may have RE-KEYED a friend row from a device id to this master
        // (a friend added by temporary nickname was stranded under the device id).
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_SecurityAlert(:final peerId, :final kind):
        // A contact's identity changed in a way worth showing. Rust already persisted
        // and deduped it; the banner in their conversation is the durable surface,
        // deliberately NOT a toast (missable, and does not survive scrollback).
        debugPrint('[HOLLOW] Security alert for $peerId: $kind');
        ref.read(securityAlertsProvider.notifier).refresh();

      case NetworkEvent_SelfRevoked():
        // THIS device was revoked: wipe the data dir and relaunch to a clean Welcome.
        // The cryptographic cutoff already happened; this is the honest teardown.
        debugPrint('[HOLLOW] This device was REVOKED — self-nuking');
        _selfNuke();

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

      // A link preview landed on a message sent before its fetch finished (#45).
      // Deliberately NOT applyEdit: text is unchanged and editedAt stays null.
      case NetworkEvent_ChannelLinkPreviewUpdated(
            :final serverId, :final channelId, :final messageId, :final preview):
        debugPrint('[HOLLOW] Link preview for $messageId in $serverId/$channelId');
        ref.read(channelChatProvider.notifier).applyLinkPreview(
            serverId, channelId, messageId, preview);

      case NetworkEvent_DmLinkPreviewUpdated(
            :final peerId, :final messageId, :final preview):
        debugPrint('[HOLLOW] Link preview for DM $messageId from $peerId');
        ref.read(chatProvider.notifier).applyLinkPreview(peerId, messageId, preview);

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

      case NetworkEvent_FriendRequestReceived(:final peerId):
        debugPrint('[HOLLOW] Friend request received from $peerId');
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_FriendRequestAccepted(:final peerId):
        debugPrint('[HOLLOW] Friend accepted by $peerId');
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_FriendRequestRejected(:final peerId):
        debugPrint('[HOLLOW] Friend rejected by $peerId');
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_FriendsBackfilled(:final count):
        // Multi-device: a sibling shared our identity's friend list and the node
        // inserted rows. Reload so device-collapse online status can resolve them.
        debugPrint('[HOLLOW] Friends backfilled from sibling device: $count');
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_FriendRemoved(:final peerId):
        debugPrint('[HOLLOW] Friend removed: $peerId');
        ref.read(friendsProvider.notifier).loadAll();
        if (ref.read(selectedPeerProvider) == peerId) {
          ref.read(selectedPeerProvider.notifier).state = null;
        }
        final splitState = ref.read(splitViewProvider);
        if (splitState.isSplit && splitState.rightPane?.peerId == peerId) {
          ref.read(splitViewProvider.notifier).closeSplit();
        }

      case NetworkEvent_NicknameClaimed(:final nickname):
        ref.read(temporaryNicknameProvider.notifier).onClaimed(nickname);

      case NetworkEvent_NicknameReleased():
        ref.read(temporaryNicknameProvider.notifier).onReleased();

      case NetworkEvent_NicknameClaimFailed(:final error):
        ref.read(temporaryNicknameProvider.notifier).onClaimFailed(error);

      case NetworkEvent_NicknameResolveFailed(:final nickname, :final error):
        debugPrint('[HOLLOW] Nickname resolve failed: $nickname — $error');
        // User-visible failure: the add-friend UIs show an optimistic "Looking up
        // nickname..." toast, so without this a bad nickname fails in total silence.
        final overlay = hollowNavigatorKey.currentState?.overlay;
        final overlayContext = overlay?.context;
        if (overlay != null && overlayContext != null && overlayContext.mounted) {
          HollowToast.show(
            overlayContext,
            error == 'not_found'
                ? "Nickname '$nickname' not found. It may have expired"
                : "Couldn't look up '$nickname': $error",
            type: HollowToastType.error,
            overlayState: overlay,
          );
        }

      case NetworkEvent_LinkCodeClaimed(:final code):
        ref.read(deviceLinkSyncProvider.notifier).onCodeClaimed(code);

      case NetworkEvent_LinkCodeError(:final error, :final code):
        ref.read(deviceLinkSyncProvider.notifier).onCodeError(error, code);

      case NetworkEvent_SiblingLinkAvailable(
          :final peerId,
          :final theirMsgCount,
          :final theirFriendCount,
          :final theirHasProfile,
        ):
        ref.read(deviceLinkSyncProvider.notifier).onSiblingLinkAvailable(
              peerId,
              theirMsgCount,
              theirFriendCount,
              theirHasProfile,
            );

      case NetworkEvent_LinkProgress(:final bytesReceived, :final totalBytes):
        ref.read(deviceLinkSyncProvider.notifier).onLinkProgress(
              bytesReceived.toInt(),
              totalBytes.toInt(),
            );

      case NetworkEvent_LinkComplete(
          :final msgCount,
          :final friendCount,
          :final serverCount,
        ):
        ref.read(deviceLinkSyncProvider.notifier).onLinkComplete(
              msgCount,
              friendCount,
              serverCount,
            );
        // The DB was replaced — refresh friends/profiles so the UI populates.
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_LinkFailed(:final error):
        ref.read(deviceLinkSyncProvider.notifier).onLinkFailed(error);

      case NetworkEvent_LinkPushComplete():
        ref.read(deviceLinkSyncProvider.notifier).onPushComplete();

      case NetworkEvent_RelayDisconnected():
        ref.read(temporaryNicknameProvider.notifier).onDisconnected();
        ref.read(deviceLinkSyncProvider.notifier).onDisconnected();
        ref
            .read(connectionStatusProvider.notifier)
            .onRelayStatusChanged('disconnected');

      case NetworkEvent_RelayConnected():
        ref
            .read(connectionStatusProvider.notifier)
            .onRelayStatusChanged('connected');
        // A hangup we could not deliver while the relay was down: say it now.
        ref.read(callProvider.notifier).handleRelayReconnected();

      case NetworkEvent_RelayConnecting(:final reconnecting):
        ref
            .read(connectionStatusProvider.notifier)
            .onRelayStatusChanged(reconnecting ? 'reconnecting' : 'connecting');

      case NetworkEvent_ChannelNotificationHint(
            :final serverId, :final channelId, :final fromPeer,
            :final messageId,
            :final hasEveryone, :final mentionedNames, :final isReplyToOwn):
        final localPeerId = ref.read(identityProvider).peerId ?? '';
        if (fromPeer == localPeerId) break;
        // Blocked sender — no unread badges from blocked users (master-keyed).
        if (ref
            .read(blockedUsersProvider)
            .contains(ref.read(deviceLinkProvider).identityOf(fromPeer))) {
          break;
        }
        // Skip if viewing this channel (live messages handle it).
        final isViewingChannel =
            ref.read(selectedServerProvider) == serverId &&
            ref.read(selectedChannelProvider) == channelId;
        if (isViewingChannel) break;
        // Deterministic dedup against ChannelMessageReceived on a subscribed channel.
        if (messageId.isNotEmpty && _processedChannelMessageIds.contains(messageId)) break;
        final channelNotifLevel = ref
            .read(notificationSettingsProvider.notifier)
            .effectiveChannelLevel(serverId, channelId);
        if (channelNotifLevel == NotificationLevel.nothing) break;
        final localName = displayNameFor(
            ref.read(profileProvider), localPeerId);
        final localNick =
            ref.read(serverNicknamesProvider(serverId))[localPeerId];
        final isMentioned = hasEveryone ||
            mentionedNames.contains(localName) ||
            (localNick != null && mentionedNames.contains(localNick)) ||
            isReplyToOwn;
        if (channelNotifLevel == NotificationLevel.mentions && !isMentioned) break;
        // Use the real message ID (not a synthetic hint- ID).
        final hintMid = messageId.isNotEmpty
            ? messageId
            : 'hint-${DateTime.now().millisecondsSinceEpoch}';
        _processedChannelMessageIds.add(hintMid);
        ref.read(unreadProvider.notifier).onChannelMessage(
            serverId, channelId, hintMid,
            false, isMention: isMentioned);

      case NetworkEvent_TypingStarted(
            :final peerId, :final serverId, :final channelId):
        // Multi-device: the typing event carries the sender's raw DEVICE id, but DM
        // threads key on the MASTER identity, so resolve it or a multi-device
        // friend's "typing..." never shows. Channel keys are unchanged.
        final typist = ref.read(deviceLinkProvider).identityOf(peerId);
        final key = serverId.isEmpty ? typist : '$serverId:$channelId';
        ref.read(typingProvider.notifier).setTyping(key, typist);

      case NetworkEvent_PeerStatusChanged(:final peerId, :final status):
        if (status == 'invisible') {
          ref.read(invisiblePeersProvider.notifier).setInvisible(peerId);
        } else {
          ref.read(invisiblePeersProvider.notifier).setOnline(peerId);
        }

      case NetworkEvent_MessagePinned(
            :final serverId, :final channelId, :final messageId):
        debugPrint('[HOLLOW] Message pinned: $messageId in $serverId/$channelId');
        ref.read(pinnedProvider.notifier).applyPin(serverId, channelId, messageId);

      case NetworkEvent_MessageUnpinned(
            :final serverId, :final channelId, :final messageId):
        debugPrint('[HOLLOW] Message unpinned: $messageId in $serverId/$channelId');
        ref.read(pinnedProvider.notifier).applyUnpin(serverId, channelId, messageId);

      case NetworkEvent_FileHeaderReceived(
            :final fileId, :final fileName, :final sizeBytes,
            :final isImage, :final width, :final height,
            :final messageId, senderId: _,
            :final serverId, :final channelId,
            :final videoThumb,
            :final shareRootHash, :final shareKeyHex, :final thumbB64):
        debugPrint('[HOLLOW] File header: $fileId ($fileName, $sizeBytes bytes)${shareRootHash != null ? ' [share-backed]' : ''}');
        // In erasure coding mode (6+ members), file data comes via vault shards,
        // not P2P streaming — so don't mark as "downloading".
        final isVaultMode = serverId.isNotEmpty &&
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
              shareRootHash: shareRootHash,
            );
        // Guest live path: the public-channel file message's metadata arrives right
        // after the row, so attach it (a RAM-only no-op for rows that carry one).
        if (serverId.isNotEmpty && channelId.isNotEmpty && messageId.isNotEmpty) {
          final dotExt = fileName.contains('.') ? fileName.split('.').last : '';
          ref.read(channelChatProvider.notifier).attachFileMeta(
                serverId, channelId, messageId,
                FileAttachment(
                  fileId: fileId,
                  fileName: fileName,
                  fileExt: dotExt,
                  mimeType: '',
                  sizeBytes: sizeBytes.toInt(),
                  isImage: isImage,
                  width: width?.toInt(),
                  height: height?.toInt(),
                  totalChunks: 0,
                  videoThumb: videoThumb,
                  shareRootHash: shareRootHash,
                  shareKeyHex: shareKeyHex,
                  thumbB64: thumbB64,
                ),
              );
        }
        _reloadChatForFile(fileId);

        if (shareRootHash != null && shareKeyHex != null) {
          if (!_serverSyncDone.contains(serverId)) {
            debugPrint('[HOLLOW] Share-backed file during sync — skipping auto-download for $fileId');
          } else {
          // Per-conversation override then global threshold; 0 = off (#41).
          final thresholdMb =
              effectiveAutoDownloadMbRead(ref, 'server:$serverId');
          final autoDownloadThreshold = thresholdMb * 1024 * 1024;
          final autoDownload =
              thresholdMb > 0 && sizeBytes.toInt() <= autoDownloadThreshold;
          final isVideo = const {'mp4', 'webm', 'mov', 'mkv', 'avi', 'm4v'}
              .contains(fileName.split('.').last.toLowerCase());

          _shareToFileId[shareRootHash] = fileId;

          if (autoDownload) {
            debugPrint('[HOLLOW] Share-backed file <=${thresholdMb}MB — auto-downloading $fileId');
            _pendingAutoDownloads[shareRootHash] = (
              sequential: isVideo,
              link: 'hollow://share/$shareRootHash',
              fileId: fileId,
            );
            share_api.shareStartFromRef(
              rootHash: shareRootHash,
              keyHex: shareKeyHex,
              saveDir: '',
              sequential: isVideo,
              serverId: serverId,
              contextType: 'channel',
            ).catchError((e) {
              debugPrint('[HOLLOW] Failed to initiate share: $e');
              _pendingAutoDownloads.remove(shareRootHash);
            });
          } else {
            debugPrint('[HOLLOW] Share-backed file >${thresholdMb}MB — manual download required for $fileId');
          }
          } // end sync-done else
        }

      case NetworkEvent_FileProgress(
            :final fileId, :final chunksReceived, :final totalChunks):
        ref.read(fileTransferProvider.notifier).onFileProgress(
              fileId, chunksReceived, totalChunks);

      case NetworkEvent_FileCompleted(:final fileId, :final diskPath):
        debugPrint('[HOLLOW] File completed: $fileId at $diskPath');
        // Completed bytes reset the missing-file throttle, so a later stale file retries.
        _fileRequestLast.remove(fileId);
        _fileRequestAttempts.remove(fileId);
        ref.read(fileTransferProvider.notifier).onFileCompleted(
              fileId, diskPath);
        _reloadChatForFile(fileId);
        // Enforce the disk caps so the user-set limits are honored. Signed headers
        // are kept; only the oldest heavy bytes are evicted.
        _enforceStorageCaps();

      case NetworkEvent_FileFailed(:final fileId, :final error):
        debugPrint('[HOLLOW] File failed: $fileId — $error');
        if (error == 'auto_download_off') {
          // Auto-download gate decline (issue #41), not a real failure: pin the bubble
          // on its manual Download button so neither the Rust WS poll nor the Dart
          // WebRTC receive flips it into a spinner while the push is discarded.
          ref.read(fileTransferProvider.notifier).markDeclined(fileId);
        } else {
          ref.read(fileTransferProvider.notifier).onFileFailed(fileId, error);
        }

      // Honest file card states: why the bytes are not here yet, so the card can
      // say it instead of offering a button that would do nothing.
      case NetworkEvent_FileAvailability(
            :final fileId, :final state, :final peerId):
        debugPrint('[HOLLOW] File availability: $fileId — $state ($peerId)');
        ref
            .read(fileTransferProvider.notifier)
            .onFileAvailability(fileId, state, peerId);
        if (state == FileAvailabilityState.expired) {
          // Rust stamped expired_at on our own row; reload so the message re-renders
          // from the DB as the expired card rather than a caption a rebuild could lose.
          _reloadChatForFile(fileId);
        }

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
        ref.read(fileTransferProvider.notifier).onVaultDownloadProgress(
              contentId, phase, progress);
      case NetworkEvent_VaultDownloadComplete(:final serverId,
            :final contentId, :final diskPath):
        ref.read(vaultStatusProvider.notifier).onDownloadComplete(
              serverId, contentId);
        ref.read(fileTransferProvider.notifier).onVaultDownloadComplete(
              contentId, diskPath);
        // Bridge to recovery pool: an active pool means recovery shard transfer.
        final activePool = ref.read(recoveryPoolProvider);
        if (activePool != null && activePool.isActive && activePool.serverId == serverId) {
          ref.read(recoveryPoolProvider.notifier).onFileRecovered(
                serverId, contentId, diskPath);
        }
      case NetworkEvent_VaultDownloadFailed(:final serverId,
            :final contentId, :final error):
        ref.read(vaultStatusProvider.notifier).onDownloadFailed(
              serverId, contentId, error);

      case NetworkEvent_RebalanceStarted(:final serverId, :final shardsToMove):
        ref.read(downloadManagerStateProvider.notifier)
            .onRebalanceStarted(serverId, shardsToMove);
      case NetworkEvent_RebalanceProgress(:final serverId, :final moved, :final total):
        ref.read(downloadManagerStateProvider.notifier)
            .onRebalanceProgress(serverId, moved, total);
      case NetworkEvent_RebalanceCompleted(:final serverId):
        ref.read(downloadManagerStateProvider.notifier)
            .onRebalanceCompleted(serverId);

      case NetworkEvent_KeyExchangeStarted(:final peerId):
        ref
            .read(connectionStatusProvider.notifier)
            .onKeyExchangeStarted(peerId);

      case NetworkEvent_KeyExchangeProgress(
            :final peerId, :final stage):
        ref
            .read(connectionStatusProvider.notifier)
            .onKeyExchangeProgress(peerId, stage);

      case NetworkEvent_VaultUploadReplicationFallback(
            :final serverId, :final contentId, :final online, :final needed):
        debugPrint('[HOLLOW] Vault upload fallback: $online online < $needed needed for $contentId in $serverId — using replication');

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

      case NetworkEvent_CallSignal(
            :final peerId, :final signalType, :final payload):
        // Multi-device: the relay reports the caller's DEVICE id, but the call UI
        // keys on the MASTER like every other per-person view, or a call from a
        // multi-device friend shows under a "different DM" than the conversation.
        final callMaster =
            ref.read(deviceLinkProvider).identityOf(peerId);
        ref.read(callProvider.notifier).handleCallSignal(
              callMaster, signalType, payload);

      case NetworkEvent_VoiceChannelJoined(
            :final serverId, :final channelId, :final peerId, :final isSelf):
        final vcNotifier = ref.read(voiceChannelProvider.notifier);
        final isNewArrival =
            vcNotifier.onPeerJoined(serverId, channelId, peerId);
        // Conferences are virtual servers ('conf:...') with no channel list, so
        // never touch the selected-channel providers for them.
        final isConferenceJoin = serverId.startsWith('conf:');
        // Self vs remote comes from RUST, never from comparing peerId to a local id:
        // the id is the ROUTABLE DEVICE form and every local guess has self-dialed.
        if (isSelf) {
          if (!isConferenceJoin) {
            vcNotifier.preVcChannelId = ref.read(selectedChannelProvider);
          }
          vcNotifier.onLocalJoined(serverId, channelId);
          if (!isConferenceJoin) {
            ref.read(selectedChannelProvider.notifier).state = channelId;
          }
        } else {
          // Remote peer joined — initiate WebRTC if we're in the same channel.
          final vcState = ref.read(voiceChannelProvider);
          if (vcState.currentServerId == serverId &&
              vcState.currentChannelId == channelId) {
            vcNotifier.onRemotePeerJoined(peerId,
                isNewArrival: isNewArrival);
          }
        }

      case NetworkEvent_VoiceChannelLeft(
            :final serverId, :final channelId, :final peerId, :final isSelf):
        final vcNotifier = ref.read(voiceChannelProvider.notifier);
        vcNotifier.onPeerLeft(serverId, channelId, peerId);
        if (isSelf) {
          // Restore the channel selected before joining, falling back to the first text
          // channel. Conference leaves never touched channel selection.
          if (!serverId.startsWith('conf:') &&
              ref.read(selectedChannelProvider) == channelId) {
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
          final vcState = ref.read(voiceChannelProvider);
          vcNotifier.onRemotePeerLeft(
            peerId,
            inOurChannel: vcState.currentServerId == serverId &&
                vcState.currentChannelId == channelId,
          );
        }

      case NetworkEvent_VoiceChannelSignal(
            :final serverId, :final channelId, :final peerId,
            :final signalType, :final payload):
        ref.read(voiceChannelProvider.notifier).handleSignal(
              peerId, signalType, payload, serverId, channelId);

      // Media forwarder control plane: fwd_* frames from the forwarder's Olm-direct
      // lane. The provider gates on sender == the discovered forwarder + assignment.
      case NetworkEvent_ForwarderSignal(
            :final fromPeer, :final signalType, :final payload):
        ref
            .read(voiceChannelProvider.notifier)
            .handleForwarderSignal(fromPeer, signalType, payload);

      case NetworkEvent_ConferenceJoinRequestReceived(
            :final confId, :final peerId, :final displayName,
            :final avatarHash):
        ref.read(conferenceProvider.notifier).onJoinRequest(
              confId, peerId, displayName, avatarHash);

      case NetworkEvent_ConferenceJoinDenied(:final confId, :final reason):
        ref.read(conferenceProvider.notifier).onDenied(confId, reason);

      case NetworkEvent_ConferenceLobbyInfo(
            :final confId, :final hostPeerId, :final hostName,
            :final hostAvatarHash):
        ref.read(conferenceProvider.notifier).onLobbyInfo(
              confId, hostPeerId, hostName, hostAvatarHash);

      case NetworkEvent_ConferenceAdmitted(:final confId):
        unawaited(ref.read(conferenceProvider.notifier).onAdmitted(confId));

      case NetworkEvent_ConferenceChatMessage(
            :final confId, :final senderPeerId, :final text,
            :final timestamp):
        // Conference chat renders in the SAME ChannelChatPane under the RAM-only
        // 'conf:<id>:main' key: never persisted, never touches unread machinery.
        // The message id derives from sender+stamp so an optimistic echo dedups.
        ref.read(channelChatProvider.notifier).receiveMessage(
              conferenceServerId(confId),
              kConferenceChannelId,
              senderPeerId,
              text,
              timestamp.toInt(),
              'conf-$senderPeerId-$timestamp',
              '',
            );

      case NetworkEvent_ConferenceEnded(:final confId, :final byPeerId):
        unawaited(
            ref.read(conferenceProvider.notifier).onEnded(confId, byPeerId));

      case NetworkEvent_ConferenceKicked(:final confId, :final byPeerId):
        unawaited(
            ref.read(conferenceProvider.notifier).onKicked(confId, byPeerId));

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

      case NetworkEvent_GossipRelayOp(:final targets, :final payload):
        // Tier 2 scaling: fan a CRDT-op frame to mesh neighbors over data channels.
        ref.read(webRtcProvider.notifier).relayGossipOp(
              targets: targets,
              payload: Uint8List.fromList(payload),
            );

      case NetworkEvent_VoiceChannelModeChanged(
            :final serverId, :final channelId,
            :final mode, :final gossipNeighbors):
        ref.read(voiceChannelProvider.notifier).onModeChanged(
              serverId, channelId, mode, gossipNeighbors);

      case NetworkEvent_MlsEpochChanged(
            :final serverId, :final epoch, :final sframeKey, :final channelId):
        ref.read(voiceChannelProvider.notifier).onEpochChanged(
              serverId, epoch.toInt(), Uint8List.fromList(sframeKey),
              channelId: channelId);

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
      case NetworkEvent_ShareManifestReady(
            :final rootHash, :final fileName, :final totalSize, :final chunkCount):
        debugPrint('[HOLLOW-SHARE] manifest ready: $fileName ($totalSize bytes, $chunkCount chunks) root=$rootHash');
        ref.read(shareTabProvider.notifier).handleShareManifestReady(rootHash, fileName, totalSize.toInt(), chunkCount);

        final pending = _pendingAutoDownloads.remove(rootHash);
        if (pending != null) {
          debugPrint('[HOLLOW-SHARE] Auto-starting download for share-backed file $rootHash');
          share_api.shareStartDownload(
            rootHash: rootHash,
            saveDir: '',
            link: pending.link,
            sequential: pending.sequential,
          ).catchError((e) {
            debugPrint('[HOLLOW] Auto-download failed: $e');
          });
        }
      case NetworkEvent_ShareProgress(
            :final rootHash, :final chunksHave, :final chunksTotal, :final seeders, :final leechers, :final bytesPerSec):
        debugPrint('[HOLLOW-SHARE] progress $rootHash: $chunksHave/$chunksTotal chunks, $seeders seeders, $leechers leechers, $bytesPerSec B/s');
        ref.read(shareTabProvider.notifier).handleShareProgress(rootHash, chunksHave, chunksTotal, seeders, leechers, bytesPerSec.toInt());
        final progressFileId = _shareToFileId[rootHash];
        if (progressFileId != null) {
          ref.read(fileTransferProvider.notifier).onFileProgress(
            progressFileId, chunksHave, chunksTotal,
          );
          ref.read(fileTransferProvider.notifier).onSeedersUpdate(
            progressFileId, seeders,
          );
        }
      case NetworkEvent_ShareCompleted(:final rootHash, :final diskPath):
        debugPrint('[HOLLOW-SHARE] completed $rootHash → $diskPath');
        ref.read(shareTabProvider.notifier).handleShareCompleted(rootHash, diskPath);
        final completedFileId = _shareToFileId.remove(rootHash);
        if (completedFileId != null) {
          debugPrint('[HOLLOW-SHARE] Bridging share completion to file $completedFileId → $diskPath');
          storage_api.markFileComplete(fileId: completedFileId, diskPath: diskPath).catchError((e) {
            debugPrint('[HOLLOW] markFileComplete failed: $e');
          });
          ref.read(fileTransferProvider.notifier).onFileCompleted(completedFileId, diskPath);
          _reloadChatForFile(completedFileId);
        }
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
        ref.read(fileTransferProvider.notifier).onShareCreatedForFile(link, fileName, rootHash);
      case NetworkEvent_ShareCreatedHidden(
            :final rootHash, :final keyHex, :final fileName, :final totalSize):
        debugPrint('[HOLLOW-SHARE] hidden share created $fileName ($totalSize bytes) root=$rootHash key=${keyHex.substring(0, 8)}...');
      case NetworkEvent_ShareList(:final entries):
        debugPrint('[HOLLOW-SHARE] list: ${entries.length} entries');
        ref.read(shareTabProvider.notifier).handleShareList(entries);
      case NetworkEvent_ShareNeedWebRtc(:final peerId, :final hidden):
        // Share rides its OWN peer connection: the general one carries TURN (and is
        // TURN-only under "Always relay calls"), and Share must stay off the relay.
        ref.read(webRtcProvider.notifier).ensureShareConnection(
              peerId,
              hidden
                  ? ref.read(streamIceConfigProvider)
                  : ref.read(shareIceConfigProvider),
            );

      case NetworkEvent_LicenseError(:final reason):
        ref.read(licenseErrorProvider.notifier).state = reason;

      case NetworkEvent_RoomBudgetUpdate(:final joined, :final limit):
        ref.read(roomBudgetProvider.notifier).state =
            RoomBudget(joined: joined, limit: limit);

      case NetworkEvent_RoomCapHit(:final room):
        debugPrint('[HOLLOW] Room cap hit: $room');
        final ctx = hollowNavigatorKey.currentContext;
        if (ctx != null) {
          final kind = room.startsWith('share:')
              ? 'Share'
              : room.startsWith('inbox:')
                  ? 'Inbox'
                  : 'Connection';
          HollowToast.show(
            ctx,
            '$kind limit reached. Try leaving unused servers or stopping share seeds.',
            type: HollowToastType.error,
          );
        }

      case NetworkEvent_TwitchJoinRejected(:final serverId, :final reason):
        debugPrint('[HOLLOW] Twitch join rejected for $serverId: $reason');
        final ctx = hollowNavigatorKey.currentContext;
        if (ctx == null) break;

        if (reason.startsWith('twitch_required:')) {
          // Format: "twitch_required:{channel_id}:{channel_name}:{server_name}:{min_follow_days}:{require_sub}"
          final parts = reason.split(':');
          final channelId = parts.length > 1 ? parts[1] : '';
          final channelName = parts.length > 2 ? parts[2] : '';
          final serverName = parts.length > 3 ? parts[3] : 'this server';
          final minFollowDays = parts.length > 4 ? int.tryParse(parts[4]) ?? 0 : 0;
          final requireSub = parts.length > 5 && parts[5] == 'true';
          // If dialog is already open (retry failed), route to it instead of opening a new one.
          final handled = handleTwitchJoinResult(success: false, error: 'Twitch verification required');
          if (!handled) {
            showTwitchJoinDialog(
              ctx,
              serverId: serverId,
              channelId: channelId,
              channelName: channelName,
              serverName: serverName,
              minFollowDays: minFollowDays,
              requireSub: requireSub,
            );
          }
        } else if (reason.startsWith('twitch_failed:')) {
          // Format: "twitch_failed:{channel_name}:{server_name}:{human reason}"
          final parts = reason.split(':');
          final humanReason = parts.length > 3 ? parts.sublist(3).join(':') : reason;
          final handled = handleTwitchJoinResult(success: false, error: humanReason);
          if (!handled) {
            showTwitchJoinDialog(
              ctx,
              serverId: serverId,
              channelId: '',
              channelName: parts.length > 1 ? parts[1] : '',
              serverName: parts.length > 2 ? parts[2] : 'this server',
              minFollowDays: 0,
              requireSub: false,
              failureReason: humanReason,
            );
          }
        } else if (reason.startsWith('twitch_owner_offline:')) {
          final serverName = reason.substring('twitch_owner_offline:'.length);
          final msg = 'Server owner of $serverName is offline. Owner-verified servers require the owner to be online to accept joins. Try again later.';
          final handled = handleTwitchJoinResult(success: false, error: msg);
          if (!handled) {
            HollowToast.show(ctx, msg, type: HollowToastType.error);
          }
        } else if (reason.startsWith('server_private:')) {
          // Format: "server_private:{server_name}"
          final serverName = reason.substring('server_private:'.length);
          final handled = handleTwitchJoinResult(
              success: false, error: 'This server is private.');
          if (!handled) {
            showJoinRejectedDialog(
              ctx,
              title: 'Server is private',
              message:
                  '${serverName.isEmpty ? 'This server' : '“$serverName”'} is '
                  'private and doesn\'t accept new members.',
            );
          }
        } else if (reason.startsWith('server_full:')) {
          // Format: "server_full:{server_name}:{max}"
          final parts = reason.split(':');
          final serverName = parts.length > 1 ? parts[1] : '';
          final max = parts.length > 2 ? parts[2] : '';
          final handled = handleTwitchJoinResult(
              success: false, error: 'This server is full.');
          if (!handled) {
            showJoinRejectedDialog(
              ctx,
              title: 'Server is full',
              message:
                  '${serverName.isEmpty ? 'This server' : '“$serverName”'} has '
                  'reached its member limit${max.isEmpty ? '' : ' ($max members)'}.',
            );
          }
        } else if (reason.startsWith('nsfw_confirm:')) {
          // Format: "nsfw_confirm:{server_name}". A consent gate, not a rejection.
          final serverName = reason.substring('nsfw_confirm:'.length);
          showNsfwConfirmDialog(
            ctx,
            serverName: serverName.isEmpty ? 'This server' : serverName,
            onProceed: () {
              crdt_api.joinServer(serverId: serverId, nsfwConfirmed: true);
            },
          );
        } else {
          final handled = handleTwitchJoinResult(success: false, error: reason);
          if (!handled) {
            HollowToast.show(ctx, reason, type: HollowToastType.error);
          }
        }

      case NetworkEvent_PublicChannelListReceived(
            :final serverId, :final serverName, :final channels, :final serverAvatar,
            :final serverBannerThumb):
        debugPrint('[HOLLOW] Guest: received ${channels.length} public channels for $serverName ($serverId)');
        ref.read(savedGuestServersProvider.notifier).updateServerName(serverId, serverName);
        if (serverAvatar != null && serverAvatar.isNotEmpty) {
          final avatarMap = Map<String, List<int>>.from(ref.read(guestServerAvatarProvider));
          avatarMap[serverId] = serverAvatar;
          ref.read(guestServerAvatarProvider.notifier).state = avatarMap;
        }
        if (serverBannerThumb != null && serverBannerThumb.isNotEmpty) {
          final bannerMap = Map<String, List<int>>.from(ref.read(guestServerBannerProvider));
          bannerMap[serverId] = serverBannerThumb;
          ref.read(guestServerBannerProvider.notifier).state = bannerMap;
        }
        ref.read(guestChannelMapProvider.notifier).setChannels(
          serverId,
          channels
              .map((c) => GuestChannelEntry(
                    channelId: c.channelId,
                    name: c.name,
                    category: c.category,
                  ))
              .toList(),
        );
        final guestLoading = Set<String>.from(ref.read(guestLoadingProvider));
        guestLoading.remove(serverId);
        ref.read(guestLoadingProvider.notifier).state = guestLoading;

      case NetworkEvent_PublicChannelSyncReceived(
            :final serverId, :final channelId, :final messages, :final hasMore, :final senderProfiles):
        debugPrint('[HOLLOW] Guest: received ${messages.length} messages for $channelId in $serverId');
        final guestHasMoreMap = Map<String, bool>.from(ref.read(guestHasMoreProvider));
        guestHasMoreMap['$serverId:$channelId'] = hasMore;
        ref.read(guestHasMoreProvider.notifier).state = guestHasMoreMap;
        final chatMessages = messages.map((m) {
          final reactions = <String, List<String>>{};
          for (final r in m.reactions) {
            reactions.putIfAbsent(r.emoji, () => []).add(r.peerId);
          }
          // Metadata attachment: the card renders name/size/type and bytes arrive via
          // requestPublicFile. `diskPath` is set ONLY when previewing our own server,
          // so the owner's preview renders instantly with no peer fetch.
          final fm = m.fileMeta;
          final attachment = fm == null
              ? null
              : FileAttachment(
                  fileId: fm.fileId,
                  fileName: fm.fileName,
                  fileExt: fm.fileExt,
                  mimeType: fm.mimeType,
                  sizeBytes: fm.sizeBytes.toInt(),
                  isImage: fm.isImage,
                  width: fm.width?.toInt(),
                  height: fm.height?.toInt(),
                  totalChunks: 0,
                  chunksReceived: 0,
                  isComplete: fm.diskPath != null,
                  diskPath: fm.diskPath,
                );
          return ChannelChatMessage(
            senderId: m.senderId,
            text: m.text,
            isMe: false,
            timestamp: DateTime.fromMillisecondsSinceEpoch(m.timestamp.toInt()),
            signature: m.signature,
            publicKey: m.publicKey,
            messageId: m.messageId,
            editedAt: m.editedAt != null
                ? DateTime.fromMillisecondsSinceEpoch(m.editedAt!.toInt())
                : null,
            hiddenAt: m.hiddenAt != null
                ? DateTime.fromMillisecondsSinceEpoch(m.hiddenAt!.toInt())
                : null,
            replyToMid: m.replyTo,
            reactions: reactions,
            fileAttachment: attachment,
            // Signature-covered on the Rust side before it reached us, so this renders
            // like any member's card and still fetches nothing.
            linkPreview: m.linkPreview,
          );
        }).toList();
        ref.read(channelChatProvider.notifier).setGuestMessages(
              serverId, channelId, chatMessages);

        // Inject sender profiles so guest-synced peers get names/avatars.
        if (senderProfiles.isNotEmpty) {
          final currentGuest = Map<String, GuestSenderProfile>.from(
              ref.read(guestSenderProfilesProvider));
          final currentProfiles = Map<String, storage_api.UserProfile>.from(
              ref.read(profileProvider));
          for (final p in senderProfiles) {
            final avatar = p.avatar != null && p.avatar!.isNotEmpty
                ? Uint8List.fromList(p.avatar!)
                : null;
            currentGuest[p.peerId] = GuestSenderProfile(
              name: p.name ?? '',
              avatar: avatar,
            );
            if (avatar != null) {
              ref.read(avatarProvider.notifier).setAvatar(p.peerId, avatar);
            }
            final existing = currentProfiles[p.peerId];
            if (p.name != null && p.name!.isNotEmpty &&
                (existing == null || existing.displayName.isEmpty)) {
              currentProfiles[p.peerId] = storage_api.UserProfile(
                peerId: p.peerId,
                displayName: p.name!,
                status: existing?.status ?? '',
                aboutMe: existing?.aboutMe ?? '',
                updatedAt: existing?.updatedAt ?? 0,
                avatarBytes: null,
                bannerBytes: null,
                twitchUsername: existing?.twitchUsername ?? '',
                showcaseBoard: existing?.showcaseBoard ?? '',
                // Frames stay OFF the guest sync path (it ships a 64px avatar thumb), so
                // this only carries a frame we already knew. Same for the animated hashes.
                avatarFrame: existing?.avatarFrame ?? '',
                avatarAnim: existing?.avatarAnim ?? '',
                bannerAnim: existing?.bannerAnim ?? '',
                supportCreds: existing?.supportCreds ?? '',
              );
            }
          }
          ref.read(guestSenderProfilesProvider.notifier).state = currentGuest;
          ref.read(profileProvider.notifier).state = currentProfiles;
        }

      case NetworkEvent_PublicChannelConfigChanged(
            :final serverId, :final channelId, :final isPublic, :final channelName, :final category):
        debugPrint('[HOLLOW] Guest: channel config changed: $channelId in $serverId is_public=$isPublic');
        if (isPublic) {
          ref.read(guestChannelMapProvider.notifier).addChannel(
            serverId,
            GuestChannelEntry(channelId: channelId, name: channelName, category: category),
          );
        } else {
          ref.read(guestChannelMapProvider.notifier).removeChannel(serverId, channelId);
          ref.read(channelChatProvider.notifier).clearGuestChannel(serverId, channelId);
          if (ref.read(guestSelectedChannelProvider) == channelId &&
              ref.read(guestSelectedServerProvider) == serverId) {
            ref.read(guestSelectedChannelProvider.notifier).state = null;
          }
        }

    }
    } catch (e, st) {
      debugPrint('[HOLLOW] Unhandled dispatch error: $e\n$st');
    }
  }

  /// Per-file throttle for the missing-file sweeps: a request that produced no
  /// bytes must not re-fire on every chat open. RAM-only, cleared on
  /// FileCompleted; every answered ask re-streams the FULL file both ways.
  static final Map<String, DateTime> _fileRequestLast = {};
  static final Map<String, int> _fileRequestAttempts = {};
  static const _fileRequestCooldown = Duration(minutes: 10);
  static const _fileRequestMaxAttempts = 3;

  /// Returns true when this file id should NOT be requested right now.
  /// Records the attempt otherwise.
  bool _throttleFileRequest(String fileId) {
    final now = DateTime.now();
    final last = _fileRequestLast[fileId];
    if (last != null && now.difference(last) < _fileRequestCooldown) {
      return true;
    }
    final attempts = _fileRequestAttempts[fileId] ?? 0;
    if (attempts >= _fileRequestMaxAttempts) return true;
    _fileRequestLast[fileId] = now;
    _fileRequestAttempts[fileId] = attempts + 1;
    return false;
  }

  /// The peer_ids of OUR OWN other (sibling) devices currently online. A sibling
  /// is a valid P2P source for any file we're missing (same `file_id` on its own
  /// disk), used as a fallback when the conversation peer is offline. Empty on a
  /// single-device install.
  List<String> _onlineSiblingDevices() {
    final myMaster = ref.read(identityProvider).peerId ?? '';
    if (myMaster.isEmpty) return const [];
    final links = ref.read(deviceLinkProvider);
    final peers = ref.read(peersProvider);
    final out = <String>[];
    for (final devicePeerId in peers.keys) {
      // Online device that resolves to our master, but isn't *us*.
      if (devicePeerId != myMaster &&
          links.identityOf(devicePeerId) == myMaster) {
        out.add(devicePeerId);
      }
    }
    return out;
  }

  /// Public entry: re-request missing DM file bytes when a thread is opened.
  /// Closes the gap where a file whose LIVE WebRTC transfer failed is never
  /// retried. Sourced from the friend AND our own online sibling devices.
  Future<void> requestMissingDmFilesOnOpen(String peerId) =>
      _requestMissingFilesForDm(peerId);

  /// Manually start a share-backed download (issue #41). Registers the same
  /// bridging state as the auto-download path. The share ref comes from the
  /// persisted `files.share_ref_json`, so this works after a restart, which a
  /// direct FileRequest cannot (its response is share-less and hits the size cap).
  Future<void> startManualShareDownload({
    required String fileId,
    required String rootHash,
    required String keyHex,
    required String serverId,
    required bool sequential,
  }) async {
    ref.read(fileTransferProvider.notifier).clearDeclined(fileId);
    _shareToFileId[rootHash] = fileId;
    _pendingAutoDownloads[rootHash] = (
      sequential: sequential,
      link: 'hollow://share/$rootHash',
      fileId: fileId,
    );
    try {
      await share_api.shareStartFromRef(
        rootHash: rootHash,
        keyHex: keyHex,
        saveDir: '',
        sequential: sequential,
        serverId: serverId,
        contextType: 'channel',
      );
    } catch (e) {
      _pendingAutoDownloads.remove(rootHash);
      debugPrint('[HOLLOW] Manual share download failed to start: $e');
      rethrow;
    }
  }

  /// Request missing files after DM sync, scoped to THIS conversation: the
  /// account-global sweep leaked unrelated file ids to the DM peer.
  Future<void> _requestMissingFilesForDm(String peerId) async {
    await Future.delayed(const Duration(seconds: 1));
    try {
      // Auto-download off for this DM (#41): the sweep IS the auto-download for
      // offline-sent files, so skip it and offer a manual Download button. VOICE
      // NOTES stay exempt, since they behave like text.
      final gated = effectiveAutoDownloadMbRead(ref, 'dm:$peerId') == 0;
      var missingIds =
          await storage_api.getMissingFileIdsForDm(peerId: peerId);
      if (gated) {
        final voiceIds = <String>[];
        for (final id in missingIds) {
          final info = await storage_api.getFileMetadata(fileId: id);
          // Name, extension and size must all agree before a gated sweep pulls a
          // file: the sender picks the name, so on its own it invites smuggling. The
          // wire header's `voice` flag does not reach Dart yet (isGenuineVoiceNote).
          if (info != null &&
              isGenuineVoiceNote(
                voice: true,
                name: info.fileName,
                ext: info.fileExt,
                sizeBytes: info.sizeBytes.toInt(),
              )) {
            voiceIds.add(id);
          }
        }
        missingIds = voiceIds;
      }
      if (missingIds.isEmpty) return;
      // ONE source per sweep: the conversation peer when reachable, else an online
      // sibling that backfilled the file. NEVER both in parallel: each holder
      // re-encrypts with its OWN AES key so a second stream can only fail decrypt,
      // and a duplicate full-byte stream counts against the relay budget twice.
      final links = ref.read(deviceLinkProvider);
      final onlinePeers = ref.read(peersProvider);
      final friendOnline = onlinePeers.keys
          .any((d) => d == peerId || links.identityOf(d) == peerId);
      final siblings = _onlineSiblingDevices();
      final source =
          friendOnline ? peerId : (siblings.isEmpty ? null : siblings.first);
      if (source == null) return;
      final activeTransfers = ref.read(fileTransferProvider);
      final toRequest = missingIds.where((id) {
        final t = activeTransfers[id];
        return t == null || (!t.isDownloading && !t.isComplete);
      }).where((id) => !_throttleFileRequest(id)).toList();
      if (toRequest.isEmpty) return;
      debugPrint('[HOLLOW] ${toRequest.length} missing DM files, '
          'requesting from ${friendOnline ? "friend" : "sibling"}');
      for (final fileId in toRequest) {
        try {
          await requestFileFromPeer(
            fileId: fileId,
            peerId: source,
            chunks: [],
          );
        } catch (_) {}
        await Future.delayed(const Duration(milliseconds: 100));
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to request missing DM files: $e');
    }
  }

  /// Reload the chat containing this file so the image preview renders, then
  /// enforce the downloaded-files + vault cache caps. Signed headers are kept,
  /// so messages stay re-downloadable. Best-effort.
  void _enforceStorageCaps() {
    final filesCap = ref.read(filesCacheCapProvider).valueOrNull ?? 5120;
    final vaultCap = ref.read(vaultCacheCapProvider).valueOrNull ?? 1024;
    final assetCap = ref.read(assetCacheCapProvider).valueOrNull ?? 512;
    storage_api
        .enforceStorageCaps(
          filesCapMb: BigInt.from(filesCap),
          vaultCacheCapMb: BigInt.from(vaultCap),
          assetCapMb: BigInt.from(assetCap),
          exemptPaths: const [],
        )
        .then<void>((freed) {
      if (freed > BigInt.zero) {
        debugPrint('[HOLLOW-STORAGE] cap enforcement freed $freed bytes');
      }
    }).catchError((Object e) {
      debugPrint('[HOLLOW-STORAGE] enforceStorageCaps failed: $e');
    });
  }

  Future<void> _reloadChatForFile(String fileId) async {
    try {
      final fileInfo = await storage_api.getFileMetadata(fileId: fileId);
      if (fileInfo == null) return;
      if (fileInfo.contextType == 'dm') {
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

  /// Resolve channel name and show notification. `isMention` is the ONE
  /// authoritative mention decision, computed at the event gate (#42).
  Future<void> _notifyChannelWithName(String serverId, String channelId,
      String fromPeer, String text, bool isMention, String messageId) async {
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
          isMention: isMention,
          channelName: chName,
          messageId: messageId,
        );
  }

  /// When a session is (re-)established with a peer, clear "Sync failed" for
  /// servers where that peer is a member and re-trigger sync for the active channel.
  void _clearFailedSyncForPeer(String peerId) {
    final syncStatuses = ref.read(syncStatusProvider);
    final servers = ref.read(serverListProvider);

    for (final serverId in servers.keys) {
      final status = syncStatuses[serverId];
      if (status != ServerSyncStatus.failed) continue;

      final membersAsync = ref.read(serverMembersProvider(serverId));
      final isMember = membersAsync.whenOrNull(
        data: (members) => members.any((m) => m.peerId == peerId),
      ) ?? false;

      if (isMember) {
        ref.read(syncStatusProvider.notifier).setStatus(
            serverId, ServerSyncStatus.idle);

        final selectedServer = ref.read(selectedServerProvider);
        final selectedChannel = ref.read(selectedChannelProvider);
        if (selectedServer == serverId && selectedChannel != null) {
          // .catchError, not try/catch: the call is fire-and-forget, so an async
          // rejection would escape a sync try/catch into the zone crash handler.
          requestChannelSync(
            serverId: serverId,
            channelId: selectedChannel,
          ).catchError((_) {});
        }
      }
    }
  }
}

final eventStreamProvider =
    NotifierProvider<EventStreamNotifier, bool>(EventStreamNotifier.new);
