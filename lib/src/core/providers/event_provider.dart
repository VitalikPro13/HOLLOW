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
import 'package:hollow/src/core/providers/security_alerts_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_anim_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
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
import 'package:hollow/src/core/providers/relay_bandwidth_provider.dart';
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

/// Listens to the Rust event stream and dispatches events
/// to the appropriate providers.
class EventStreamNotifier extends Notifier<bool> {
  StreamSubscription<NetworkEvent>? _subscription;
  final Map<String, Timer> _syncTimeouts = {};

  /// Tracks shares initiated by share_ref (auto-download on manifest ready).
  /// Key: rootHash, Value: {sequential, link, fileId}
  final Map<String, ({bool sequential, String link, String fileId})> _pendingAutoDownloads = {};

  /// Maps share rootHash → file ID for bridging Share events to file transfer state.
  final Map<String, String> _shareToFileId = {};

  /// Dedup: message IDs already processed via ChannelMessageReceived.
  /// When a ChannelNotificationHint arrives with a message_id we've
  /// already counted, we skip it to prevent double-counting.
  final Set<String> _processedChannelMessageIds = {};

  /// Servers that have completed their initial message sync.
  /// Share-backed files are only auto-downloaded for live messages (post-sync),
  /// not during the sync burst — prevents cache thrash on reconnection.
  final Set<String> _serverSyncDone = {};


  @override
  bool build() {
    // Safety net: if this provider is ever disposed, release the Rust→Dart event
    // subscription and any pending sync-timeout timers so they can't fire into a
    // disposed notifier or keep the stream alive. (Normal teardown still goes
    // through stop() via NodeNotifier.stop(); this guards the invalidate path.)
    // Does NOT touch `state` — that throws post-dispose.
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
  /// Notification Service Extension. Debounced + iOS-gated inside the cache, so
  /// this is a cheap no-op on other platforms / under bursts. Sources the friend
  /// list from `friendsProvider` (all known peers; the extension only ever looks
  /// up the actual sender).
  void _refreshPushHints() {
    final friends = ref.read(friendsProvider);
    if (friends.isEmpty) return;
    PushHintsCache.scheduleWrite(friends.keys);
  }

  bool _selfNuking = false;

  /// Step 7 self-nuke: this device was revoked. Wipe the data dir + relaunch to a
  /// clean Welcome. Mirrors the link "go back" flow (hollow_shell): we MARK a wipe
  /// (the live node holds open SQLCipher handles, so deleting in-process fails on
  /// Windows) and relaunch — the next launch's _bootstrap runs performPendingWipe()
  /// BEFORE the node starts. Idempotent (guarded) since the event could repeat.
  Future<void> _selfNuke() async {
    if (_selfNuking) return;
    _selfNuking = true;

    // CRITICAL — stash the wipe FIRST, before anything that can throw. A previous
    // version showed the toast first via the plain `HollowToast.show(ctx, …)` form,
    // which calls `Overlay.of(navKey.currentContext)` → throws "Null check operator
    // used on a null value" (the Navigator's own context has no Overlay ANCESTOR;
    // the Overlay is its CHILD). That exception aborted _selfNuke before the wipe was
    // ever stashed, so the device never reset. Teardown is now unconditional and the
    // toast is best-effort. See feedback_toast_from_nonwidget_overlaystate.
    try {
      await storage_api.stashPendingWipe();
    } catch (e) {
      debugPrint('[HOLLOW] self-nuke stash failed: $e');
    }

    // Best-effort toast — must NEVER abort the nuke. Insert directly into the root
    // navigator's Overlay via `overlayState:` (the positional context is unused then).
    try {
      final overlay = hollowNavigatorKey.currentState?.overlay;
      // overlay is freshly obtained AFTER the awaits above; binding the
      // context to a local lets analyzers tie the mounted guard to the
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

    // Give the toast a beat, then shut the node down and relaunch via the
    // shared waiter-script helper (app_relaunch.dart) — a directly-spawned
    // copy dies against the native single-instance forwarder while we're
    // still shutting down.
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
    // Warm the device→identity map from the node's resolver (persisted links +
    // our own devices) so attribution is correct before the first profile sync.
    // The event stream can start BEFORE the node has finished hydrating its
    // resolver from the DB, so a single immediate refresh can race and come back
    // empty — and nothing would retry until a DeviceListUpdated event arrives
    // (which only fires when a sibling re-sends its list over the network). That
    // left the device list + multi-device presence/attribution stale after every
    // app restart. Retry a few times so the warm-up catches the node once ready.
    _warmDeviceMaps();
  }

  void _warmDeviceMaps() {
    ref.read(deviceLinkProvider.notifier).refresh();
    ref.read(deviceLabelProvider.notifier).refresh();
    // Re-pull shortly after in case the node's resolver wasn't hydrated yet on
    // the first attempt. Cheap in-memory snapshots; idempotent.
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
    // Drain pending sync-timeout timers so they don't fire after the stream
    // stops (each fires a ref.read into a now-idle notifier).
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
    // CrdtStore persists via fire-and-forget mpsc, so getServerChannels (a DB
    // read) races the actor's write — a single fixed delay was unreliable (worked
    // on join because that path re-reads after the write lands, but flaky for a
    // LIVE remote ChannelVisibilityChanged/ChannelPostingChanged). Refresh both
    // the selected-server map AND the per-server snapshot on a ramp:
    //   - channelListProvider: drives desktop shell + the open mobile chat route.
    //   - serverChannelsProvider: drives the mobile Chats-tab list, which has NO
    //     selected server (so channelListProvider can't help it). Both target the
    //     same DB; the ramp lets the eventually-consistent write land.
    _reloadChannelsWithRetry(serverId);
    _evictVoiceIfInvisible(serverId);
  }

  /// If we're currently in a VOICE channel on [serverId] that we can no longer
  /// SEE (visibility tier raised, or we were demoted/kicked), hang up the call —
  /// the UI equivalent of pressing Disconnect. Belt-and-suspenders next to the
  /// Rust-side auto-leave: this runs the exact `leaveChannel()` teardown the
  /// button does, so the call genuinely ends (closes PCs, stops mic/audio),
  /// regardless of whether the Rust force-leave event lands. Re-checks on a short
  /// ramp because role/channel state lands via the fire-and-forget CrdtStore.
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
        // Channel gone (deleted / we were kicked so we hold no channels) OR
        // the Rust-computed predicate (tier + label gates + grants) now
        // excludes us → leave. This snapshot re-reads post-ramp, so meCanSee
        // is fresh.
        final canSee = ch?.meCanSee ?? false;
        if (!canSee) {
          debugPrint('[HOLLOW-VC] Lost visibility to active voice channel $cid — hanging up');
          ref.read(voiceChannelProvider.notifier).leaveChannel();
        }
      });
    }
  }

  /// Re-read channels for a server on a short ramp to defeat the CrdtStore
  /// fire-and-forget write race. Refreshes the per-server snapshot (Chats-tab
  /// list, any server) every tick; refreshes the selected-server map only while
  /// that server is still selected. Cheap: each tick is one DB read.
  void _reloadChannelsWithRetry(String serverId) {
    const delays = [Duration.zero, Duration(milliseconds: 120),
        Duration(milliseconds: 400), Duration(milliseconds: 1000)];
    for (final d in delays) {
      Future.delayed(d, () {
        // Per-server snapshot — refresh regardless of selection (Chats tab).
        ref.invalidate(serverChannelsProvider(serverId));
        // Mute state rides the same fire-and-forget CrdtStore write, so it
        // needs the same ramp — a single immediate invalidate reads stale DB
        // (the "switch tabs and it finally shows" bug).
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
    // SECURITY: Wrap dispatch in try-catch to prevent unhandled exceptions
    // from killing the event loop.
    try {
    switch (event) {
      case NetworkEvent_PeerDiscovered(:final peer):
        debugPrint(
            '[HOLLOW] Peer discovered: ${peer.peerId} at ${peer.addresses}');
        ref.read(peersProvider.notifier).addPeer(peer.peerId, peer.addresses);
        ref.read(connectionStatusProvider.notifier).onPeerConnected(peer.peerId);

      case NetworkEvent_TurnCredentials(
          :final username, :final password, :final uris):
        ref.read(iceConfigProvider.notifier).setTurnCredentials(
            username: username, password: password, uris: uris);

      case NetworkEvent_MediaForwarderInfo(:final peerId, :final online):
        ref
            .read(forwarderInfoProvider.notifier)
            .setInfo(peerId: peerId, online: online);

      case NetworkEvent_BandwidthStatus(
          :final usedBytes, :final budgetBytes, :final resetInSecs):
        ref.read(relayBandwidthProvider.notifier).onStatus(
            usedBytes: usedBytes.toInt(),
            budgetBytes: budgetBytes.toInt(),
            resetInSecs: resetInSecs.toInt());

      case NetworkEvent_BandwidthLimited():
        ref.read(relayBandwidthProvider.notifier).onLimited();
        // Best-effort toast via the root navigator's Overlay (`overlayState:`
        // — a plain context lookup throws from non-widget code). The relay
        // NEVER silently drops on budget exhaustion; this is the user-visible
        // surface for its explicit "bandwidth_limit" close.
        final overlay = hollowNavigatorKey.currentState?.overlay;
        if (overlay != null) {
          HollowToast.show(
            overlay.context,
            'Daily relay data limit reached. Resets at midnight UTC.',
            type: HollowToastType.error,
            overlayState: overlay,
          );
        }

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
        // Fired on an active-room SWITCH (legacy signaling-room model), NOT on
        // connection loss. Do NOT clearAll() peers or null the selection: that
        // blanked the mobile Chats tab / desktop chat pane during transient
        // instability and flipped every conversation to "offline". Peers
        // repopulate naturally via PeerJoined / Members on (re)join, and we keep
        // the open conversation visible — consistent with PeerDisconnected /
        // PeerExpired above ("friends stay visible when offline"). The relay's
        // own state is the source of truth for who's online.
        debugPrint('[HOLLOW] Room cleared (non-destructive — peers/selection preserved)');

      case NetworkEvent_Listening(:final address):
        debugPrint('[HOLLOW] Listening: $address');

      case NetworkEvent_MessageReceived(:final fromPeer, :final text, :final timestamp, :final messageId, :final replyToMid, :final linkPreview, :final signature, :final publicKey, :final isOwn, :final duplicate):
        // MULTI-DEVICE: unread counts, the "seen" pointer, mute settings, and
        // notifications all key on the MASTER identity (a conversation is with a
        // person, not a device). NOTE: since the Rust `convo_peer` work, the main
        // DM receive path already emits `fromPeer` RESOLVED to the master — only
        // the legacy unsigned raw-text fallback (swarm.rs) still emits a device
        // id. This resolve is therefore belt-and-braces (identityOf is a no-op on
        // an already-master id); keeping it protects the unread pill against any
        // future emit site that forgets to resolve (the original bug: a
        // device-keyed `dmUnreadCounts` entry that `markDmSeen(master)` never
        // cleared → a permanently-stuck pill).
        final dmMaster = ref.read(deviceLinkProvider).identityOf(fromPeer);
        ref.read(chatProvider.notifier).receiveMessage(
              fromPeer, text, timestamp, messageId, replyToMid,
              linkPreview: linkPreview,
              signature: signature,
              publicKey: publicKey,
              isOwn: isOwn,
            );
        // A sibling echo of OUR OWN sent message: it's outgoing, so it must NOT
        // mark the conversation unread, raise a notification, or be treated as
        // the friend typing. Mirror it into the thread (above) and stop.
        if (isOwn) {
          // Our own send clears any lingering "friend is typing" + marks the DM
          // read up to here (we just participated in it from another device).
          ref.read(typingProvider.notifier).clearTyping(dmMaster, dmMaster);
          ref.read(unreadProvider.notifier).markDmSeen(
              dmMaster, messageId.isNotEmpty ? messageId : null);
          break;
        }
        ref.read(typingProvider.notifier).clearTyping(fromPeer, fromPeer);
        // A duplicate delivery (the row already existed in the DB — a sync
        // batch or fetch-node insert beat the live message): the append above
        // keeps an OPEN chat current (in-memory dedup by message_id makes it
        // idempotent), but unread/notifications must NOT re-fire — a replay
        // would double-count the pill and re-toast an already-seen message.
        if (duplicate) break;
        // Track unread DM — only if not muted.
        // Window must be visible AND viewing this DM to count as "viewing".
        // "Active" = desktop focused (alt-tabbed away ≠ reading) / mobile
        // foreground (backgrounded ≠ reading, even if a chat is open — without
        // this, sitting in a chat then backgrounding suppressed its OS notif).
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
        // System notification for DM.
        if (!isViewingDm && !isDmMuted) {
          ref.read(systemNotificationProvider.notifier).notifyDm(
                fromPeerId: dmMaster,
                text: text,
                replyToMid: replyToMid,
                messageId: messageId,
              );
        } else if (isViewingDm && !Platform.isAndroid && !Platform.isIOS) {
          // The one path that produces NO notification and NO log downstream,
          // because the notifier is never called. If this line shows up while
          // the window was actually behind another app, `windowFocusedProvider`
          // is stuck on true (a missed onWindowBlur) and THAT is the bug — not
          // anything in the toast backend.
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
        // Duplicate delivery (row already in DB via a sync batch) — the append
        // above keeps an open pane current; unread/notifications must not
        // re-fire. See the DM case.
        if (duplicate) break;
        // Blocked sender: Rust already drops DM surfaces at ingest, but
        // channel messages still flow (the pane hides them) — they must not
        // produce unread badges or notification surfaces. Compare the
        // sender's MASTER identity (block list is master-keyed).
        final senderMasterBlocked = ref
            .read(blockedUsersProvider)
            .contains(ref.read(deviceLinkProvider).identityOf(fromPeer));
        // Track unread channel message — only if not muted.
        // Must be visible, viewing this channel, AND scrolled to bottom. Also
        // require the app to be active (desktop focused / mobile foreground) —
        // see the DM gate above.
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
        // `replyToOwn` (Rust-computed: parent row's author is US) — never
        // `replyToMid`, which is a non-nullable String ('' when not a reply);
        // the old `replyToMid != null` was a tautology that made EVERY message
        // count as a mention, so "Mentions only" behaved like "All" (#42).
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
        // System notification for channel message.
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
        // GIF-sized blobs can grow the asset cache quickly — enforce the
        // cap here too, not just on file downloads.
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
        ref.read(serverAvatarAnimProvider.notifier).loadAnim(serverId);
        ref.read(serverBannerProvider.notifier).loadBanner(serverId);
        ref.invalidate(serverMembersProvider(serverId));
        // Reload channels in case they changed while offline.
        if (ref.read(selectedServerProvider) == serverId) {
          ref.read(channelListProvider.notifier).loadForServer(serverId);
          ref.read(channelLayoutProvider.notifier).loadForServer(serverId);
        }
        // Recompute server unread counts after CRDT sync. Runs for ALL
        // servers (including selected) to pick up messages that arrived
        // while the app was offline.
        crdt_api.getServerChannels(serverId: serverId).then((channels) {
          final channelIds = channels.map((c) => c.channelId).toList();
          ref.read(unreadProvider.notifier).recomputeServerUnread(
              serverId, channelIds);
        }).catchError((_) {});

      case NetworkEvent_ServerJoined(:final serverId, :final name):
        debugPrint('[HOLLOW] Server joined: $name ($serverId)');
        handleTwitchJoinResult(success: true);
        ref.read(serverListProvider.notifier).onServerCreated(serverId, name);
        ref.read(serverStripLayoutProvider.notifier).onServerCreated(serverId);
        // Auto-select the newly joined server and load its channels. Close any
        // centre tab first — joining straight out of Browse Public Channels is
        // a normal flow, and the tab would sit on top of the server we just
        // selected (issue #28).
        setShellTab(ref.read, null);
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
        // Toast feedback (skip if Twitch dialog already showing success)
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

        // Files are now downloaded on-demand when visible in viewport.
        // See channel_chat_pane.dart _requestViewportFiles().

        // Recompute unread counts from DB after sync — respects notification
        // levels. ONLY when the sync actually inserted something: every
        // channel-open fires a sync request, and an unconditional server-wide
        // recount on the resulting no-op completion kept resurrecting stale
        // counts for channels the user never touched (the "ghost unread on a
        // sibling channel" cycle).
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
        _refreshServerState(serverId);

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
        ref.read(avatarProvider.notifier).invalidate(peerId);
        ref.invalidate(bannerProvider(peerId));
        ref.invalidate(showcaseAssetsProvider(peerId));
        _refreshPushHints();

      case NetworkEvent_DeviceListUpdated(:final masterPeerId):
        // A friend's signed device list was ingested — refresh the Dart
        // device→identity map so attribution/presence collapse picks it up.
        debugPrint('[HOLLOW] Device list updated: $masterPeerId');
        ref.read(deviceLinkProvider.notifier).refresh();
        ref.read(deviceLabelProvider.notifier).refresh();
        // The ingest may have RE-KEYED a friend row from a device id to this
        // master (a friend added by temporary nickname was stranded under the
        // device id). Reload so the now-master-keyed friend surfaces with the
        // correct name/presence instead of a raw device id.
        ref.read(friendsProvider.notifier).loadAll();

      case NetworkEvent_SecurityAlert(:final peerId, :final kind):
        // Issue 1-C: a contact's identity changed in a way worth showing. Rust
        // has already persisted + deduped it, so this only has to re-pull —
        // the banner in their conversation is the durable surface, deliberately
        // NOT a toast (a toast is missable and does not survive scrollback).
        debugPrint('[HOLLOW] Security alert for $peerId: $kind');
        ref.read(securityAlertsProvider.notifier).refresh();

      case NetworkEvent_SelfRevoked():
        // Step 7: THIS device was revoked by the identity. Self-nuke — wipe the
        // data dir + relaunch to a clean Welcome (mirrors the link "go back" flow
        // in hollow_shell). The cryptographic cutoff already happened elsewhere;
        // this is the honest teardown so no half-baked identity lingers.
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

      // A link preview landed on a message that was sent before its fetch
      // finished (issue #45). Deliberately NOT routed through applyEdit: the
      // text is unchanged and editedAt stays null, so no "(edited)" badge.
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

      case NetworkEvent_FriendsBackfilled(:final count):
        // Multi-device: a sibling device shared our identity's friend list and
        // the node inserted `count` new friend rows. Reload so they appear and
        // the device-collapse online status can resolve them (Phase 6).
        debugPrint('[HOLLOW] Friends backfilled from sibling device: $count');
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

      // -- Temporary nickname events --
      case NetworkEvent_NicknameClaimed(:final nickname):
        ref.read(temporaryNicknameProvider.notifier).onClaimed(nickname);

      case NetworkEvent_NicknameReleased():
        ref.read(temporaryNicknameProvider.notifier).onReleased();

      case NetworkEvent_NicknameClaimFailed(:final error):
        ref.read(temporaryNicknameProvider.notifier).onClaimFailed(error);

      case NetworkEvent_NicknameResolveFailed(:final nickname, :final error):
        debugPrint('[HOLLOW] Nickname resolve failed: $nickname — $error');
        // User-visible failure: the add-friend UIs show an optimistic
        // "Looking up nickname..." toast at send time — without this, a bad
        // or expired nickname fails in total silence.
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

      // -- Multi-device device linking (Step 4) --
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

      // -- Relay connection events --
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

      case NetworkEvent_RelayConnecting(:final reconnecting):
        ref
            .read(connectionStatusProvider.notifier)
            .onRelayStatusChanged(reconnecting ? 'reconnecting' : 'connecting');

      // -- Channel notification hints (unsubscribed channel awareness) --
      case NetworkEvent_ChannelNotificationHint(
            :final serverId, :final channelId, :final fromPeer,
            :final messageId,
            :final hasEveryone, :final mentionedNames, :final isReplyToOwn):
        // Ignore own hints.
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
        // Deterministic dedup: skip if we already processed this message
        // via ChannelMessageReceived (subscribed channel).
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

      // -- Typing indicator events (Phase 3.5) --
      case NetworkEvent_TypingStarted(
            :final peerId, :final serverId, :final channelId):
        // Multi-device (Phase 6): the typing event carries the sender's raw
        // DEVICE peer_id, but DM threads (and the chat view's lookup) key on the
        // sender's MASTER identity. Resolve it so the indicator matches the
        // conversation key — otherwise a multi-device friend's "typing…" never
        // shows. Single-device resolves to itself (no-op). Channel key is
        // unchanged (serverId:channelId), but the stored typist is also collapsed
        // to master so per-person channel typing attributes correctly.
        final typist = ref.read(deviceLinkProvider).identityOf(peerId);
        final key = serverId.isEmpty ? typist : '$serverId:$channelId';
        ref.read(typingProvider.notifier).setTyping(key, typist);

      // -- Presence events (Phase 6.75) --
      case NetworkEvent_PeerStatusChanged(:final peerId, :final status):
        if (status == 'invisible') {
          ref.read(invisiblePeersProvider.notifier).setInvisible(peerId);
        } else {
          ref.read(invisiblePeersProvider.notifier).setOnline(peerId);
        }

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
        // Guest live path: the public-channel file message's metadata arrives
        // as this event right after the row itself — attach it so the card
        // renders (a RAM-only no-op for rows that already carry one; member
        // rows are rebuilt from the DB by _reloadChatForFile below anyway).
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
        // Completed bytes reset the missing-file request throttle, so a file
        // that later goes stale again gets fresh retry attempts.
        _fileRequestLast.remove(fileId);
        _fileRequestAttempts.remove(fileId);
        ref.read(fileTransferProvider.notifier).onFileCompleted(
              fileId, diskPath);
        // Reload the chat that contains this file to show the image.
        _reloadChatForFile(fileId);
        // Enforce the disk caps so the user-set limits are actually honored
        // (both sliders were no-ops before this). Keeps signed headers — only
        // the oldest heavy bytes are evicted. Fire-and-forget.
        _enforceStorageCaps();

      case NetworkEvent_FileFailed(:final fileId, :final error):
        debugPrint('[HOLLOW] File failed: $fileId — $error');
        if (error == 'auto_download_off') {
          // Auto-download gate decline (issue #41), not a real failure: pin
          // the bubble on its manual Download button so neither the Rust WS
          // poll nor the Dart WebRTC receive can flip it into a spinner
          // while the unwanted push transits and is discarded.
          ref.read(fileTransferProvider.notifier).markDeclined(fileId);
        } else {
          ref.read(fileTransferProvider.notifier).onFileFailed(fileId, error);
        }

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
        // Multi-device: the relay reports the caller's DEVICE id, but the call UI
        // (the floating pill, the DM the call belongs to) keys on the MASTER —
        // same as every other per-person view. Without collapsing, a call from a
        // multi-device friend showed under the raw device id (a "different DM"
        // than the conversation you're in). Resolve to the master so all call
        // state is master-consistent; replies go to the master and the Rust
        // `pick_online_device` routes them back to the caller's online device.
        // Single-device → identityOf returns the id unchanged (no-op).
        final callMaster =
            ref.read(deviceLinkProvider).identityOf(peerId);
        ref.read(callProvider.notifier).handleCallSignal(
              callMaster, signalType, payload);

      // -- Voice channel events (Phase 5C) --
      case NetworkEvent_VoiceChannelJoined(
            :final serverId, :final channelId, :final peerId, :final isSelf):
        final vcNotifier = ref.read(voiceChannelProvider.notifier);
        vcNotifier.onPeerJoined(serverId, channelId, peerId);
        // Conferences are virtual servers ('conf:...') with no channel list —
        // their call renders in the Conferences tab, so never touch the
        // selected-channel providers for them.
        final isConferenceJoin = serverId.startsWith('conf:');
        // Self vs remote comes from RUST (the emitting handler knows) — never
        // from comparing peerId to a local id: the id is the ROUTABLE DEVICE
        // form and every local id-form guess here has self-dialed (self-ghost).
        if (isSelf) {
          if (!isConferenceJoin) {
            // Cache the currently selected channel so we can restore it on leave.
            vcNotifier.preVcChannelId = ref.read(selectedChannelProvider);
          }
          vcNotifier.onLocalJoined(serverId, channelId);
          if (!isConferenceJoin) {
            // Auto-select the voice channel for the main pane.
            ref.read(selectedChannelProvider.notifier).state = channelId;
          }
        } else {
          // Remote peer joined — initiate WebRTC if we're in the same channel.
          final vcState = ref.read(voiceChannelProvider);
          if (vcState.currentServerId == serverId &&
              vcState.currentChannelId == channelId) {
            vcNotifier.onRemotePeerJoined(peerId);
          }
        }

      case NetworkEvent_VoiceChannelLeft(
            :final serverId, :final channelId, :final peerId, :final isSelf):
        final vcNotifier = ref.read(voiceChannelProvider.notifier);
        vcNotifier.onPeerLeft(serverId, channelId, peerId);
        if (isSelf) {
          // Restore the channel that was selected before joining the VC.
          // Fall back to first text channel if the cached one is gone.
          // Conference leaves never touched channel selection on join, so
          // there's nothing to restore ('conf:...' virtual servers).
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

      // Media forwarder control plane (step 3): fwd_ingest_answer /
      // fwd_egress_offer / fwd_error from the forwarder's Olm-direct lane.
      // The provider gates on "fromPeer == the discovered forwarder AND the
      // origin is watched + assigned".
      case NetworkEvent_ForwarderSignal(
            :final fromPeer, :final signalType, :final payload):
        ref
            .read(voiceChannelProvider.notifier)
            .handleForwarderSignal(fromPeer, signalType, payload);

      // -- Conference events (Zoom-style rooms) --
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
        // Conference chat renders in the SAME ChannelChatPane as screen-share
        // chat, under the RAM-only 'conf:<id>:main' key — never persisted,
        // never touches unread machinery. senderPeerId is the authenticated
        // MLS leaf credential (a device id); the pane collapses it to master
        // for display. Message id derives from sender+stamp so an echo of an
        // optimistic send dedups by message_id like every other chat surface.
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

      case NetworkEvent_GossipRelayOp(:final targets, :final payload):
        // Tier 2 large-server scaling: fan a small CRDT-op frame to mesh
        // neighbors over data channels (relay egress stays untouched).
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

        // Auto-start download if this was triggered by a share_ref (hidden share).
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
        // Bridge to file transfer state for share-backed files.
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
        // Bridge to file transfer state for share-backed files.
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
        // Share rides its OWN peer connection, never the general hollow-data
        // one — that connection carries TURN (and is TURN-only while "Always
        // relay calls" is on), and Share must stay off the relay entirely.
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
          // Format: "nsfw_confirm:{server_name}". Not a hard rejection — show
          // the consent gate; on "Proceed" re-join with nsfwConfirmed: true.
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

      // -- Guest sync events (Public Channels Phase 3) --
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
          // Metadata attachment — the card renders name/size/type; bytes
          // arrive via requestPublicFile and light it up through
          // fileTransferProvider state. `diskPath` is set ONLY when
          // previewing our own server (the file is already on OUR disk), so
          // the owner's preview renders instantly with no peer fetch.
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
            // Signature-covered on the Rust side before it reached us
            // (guest_item_accepted binds the card into the check), so this
            // renders like any member's card — and still fetches nothing.
            linkPreview: m.linkPreview,
          );
        }).toList();
        ref.read(channelChatProvider.notifier).setGuestMessages(
              serverId, channelId, chatMessages);

        // Process sender profiles — inject into profileProvider so ChannelMessageBubble
        // can display names/avatars for guest-synced peers.
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
            // Inject into profileProvider if not already present (or has no display name)
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
          // Clear cached messages for the removed channel
          ref.read(channelChatProvider.notifier).clearGuestChannel(serverId, channelId);
          // Deselect if active
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
  /// bytes must not re-fire on every chat open / sync. RAM-only (fresh attempts
  /// after an app restart); cleared per file on FileCompleted. Without this, an
  /// id nobody holds anymore loops forever — and every answered ask makes the
  /// holder re-stream the FULL file, which counts against the relay byte
  /// budget in both directions.
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

  /// The peer_ids of OUR OWN other (sibling) devices that are currently online
  /// (multi-device, Phase 6 / Step 5.1). A sibling is a valid P2P source for any
  /// file we're missing — it holds the same `file_id` on its own disk. Used as a
  /// fallback/parallel source for missing DM files so an image syncs even when the
  /// conversation peer (friend) is offline. Empty on a single-device install
  /// (no device resolves to our master but ourselves) → byte-for-byte old
  /// behavior.
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

  /// Public entry: re-request any missing DM file bytes for a conversation when
  /// its thread is opened. Closes the gap where a file whose LIVE WebRTC transfer
  /// failed (ICE glare, drop) is never retried — the post-sync retry only fires
  /// after a message-bearing `DmSyncCompleted`, so a file with metadata-but-no-
  /// bytes stayed an empty bubble until something else triggered a sync. Sourced
  /// from the friend AND our own online sibling devices (multi-device).
  Future<void> requestMissingDmFilesOnOpen(String peerId) =>
      _requestMissingFilesForDm(peerId);

  /// Manually start a share-backed download (issue #41): the Download button
  /// on an over-threshold or auto-download-off share-backed file. Registers
  /// the same bridging state as the auto-download path so ShareManifestReady /
  /// ShareProgress / ShareCompleted flow into the file-transfer UI. The share
  /// ref comes from the persisted `files.share_ref_json` column, so this works
  /// after a restart (a direct FileRequest cannot — its response is share-less
  /// and our own size cap rejects it).
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

  /// Request missing files after DM sync completes — scoped to THIS
  /// conversation only (the account-global sweep re-requested every missing id
  /// from the DM peer on every chat open, and leaked unrelated file ids to
  /// them).
  Future<void> _requestMissingFilesForDm(String peerId) async {
    await Future.delayed(const Duration(seconds: 1));
    try {
      // Auto-download off for this DM (#41): the sweep IS the auto-download
      // for offline-sent files — skip it; every file card offers a manual
      // Download button instead. VOICE NOTES stay exempt (they behave like
      // text), so a gated sweep still pulls those and nothing else.
      final gated = effectiveAutoDownloadMbRead(ref, 'dm:$peerId') == 0;
      var missingIds =
          await storage_api.getMissingFileIdsForDm(peerId: peerId);
      if (gated) {
        final voiceIds = <String>[];
        for (final id in missingIds) {
          final info = await storage_api.getFileMetadata(fileId: id);
          if (info != null && isVoiceMessageFile(info.fileName)) {
            voiceIds.add(id);
          }
        }
        missingIds = voiceIds;
      }
      if (missingIds.isEmpty) return;
      // ONE source per sweep: the conversation peer (friend) when reachable —
      // the canonical holder — else an online sibling device that backfilled
      // the file (it holds the same bytes; covers the friend-offline gap where
      // a synced image card stayed a placeholder forever). NEVER both in
      // parallel: each holder re-encrypts its stream with its OWN AES key, so
      // a second stream can only fail decrypt (see Rust handle_request_file),
      // and every duplicate full-byte stream counts against the relay byte
      // budget twice.
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



  /// When a file transfer completes, reload the chat that contains
  /// the file message so the image preview renders.
  /// Enforce the downloaded-files + vault cache caps after a download completes.
  /// Reads the user-set caps and evicts oldest bytes over the limit (signed
  /// headers are kept, so messages stay re-downloadable). Best-effort.
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
  /// Resolve channel name and show notification (async helper). `isMention`
  /// is the ONE authoritative mention decision (computed at the event gate) —
  /// notifyChannel used to re-derive it with a drifted copy of the check (#42).
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
          // .catchError, not try/catch: the call is fire-and-forget, so an
          // async rejection (e.g. "Node is not running") would escape a sync
          // try/catch and land in the zone crash handler.
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
