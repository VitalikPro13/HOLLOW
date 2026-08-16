import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/services/desktop_notification_service.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/core/services/push_notification_service.dart'
    as push;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:window_manager/window_manager.dart';

/// A single message within a notification card.
class NotificationMessage {
  final String senderPeerId;
  final String senderName;
  final String text;
  final DateTime timestamp;

  const NotificationMessage({
    required this.senderPeerId,
    required this.senderName,
    required this.text,
    required this.timestamp,
  });
}

/// A notification card — groups messages from the same source.
class NotificationCard {
  final String sourceKey;
  final String title;
  final String avatarId;
  final bool isDm;
  final String? serverId;
  final String? channelId;
  final String? peerId;
  final List<NotificationMessage> messages;
  final DateTime createdAt;

  NotificationCard({
    required this.sourceKey,
    required this.title,
    required this.avatarId,
    required this.isDm,
    this.serverId,
    this.channelId,
    this.peerId,
    List<NotificationMessage>? messages,
    DateTime? createdAt,
  })  : messages = messages ?? [],
        createdAt = createdAt ?? DateTime.now();

  NotificationCard withMessage(NotificationMessage msg) {
    final updated = List<NotificationMessage>.from(messages)..add(msg);
    if (updated.length > 5) {
      updated.removeRange(0, updated.length - 5);
    }
    return NotificationCard(
      sourceKey: sourceKey,
      title: title,
      avatarId: avatarId,
      isDm: isDm,
      serverId: serverId,
      channelId: channelId,
      peerId: peerId,
      messages: updated,
      createdAt: createdAt,
    );
  }
}

/// Manages notifications — in-app overlay cards when window is visible,
/// native OS notifications when window is hidden (tray mode).
class SystemNotificationNotifier
    extends Notifier<List<NotificationCard>> {
  bool _nativeInitialized = false;

  /// Cached avatar bytes per peer/server id for the native toast image. Avoids
  /// re-fetching on every message in the same burst.
  final Map<String, Uint8List?> _avatarCache = {};

  @override
  List<NotificationCard> build() => [];

  /// Initialize native notifications. Call once at startup.
  Future<void> init() async {
    if (_nativeInitialized) return;
    if (!DesktopNotificationService.isSupported) return;
    try {
      await DesktopNotificationService.instance.init();
      _nativeInitialized = true;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to init desktop notifications: $e');
    }
  }

  /// Fetch (and cache) the avatar bytes for a peer/server id via the push
  /// profile FFI — same source the mobile push banner uses.
  Future<Uint8List?> _avatarFor(String id) async {
    if (_avatarCache.containsKey(id)) return _avatarCache[id];
    Uint8List? bytes;
    try {
      final profile = await network_api.getPushProfile(peerId: id);
      bytes = profile?.avatarBytes;
    } catch (_) {}
    _avatarCache[id] = bytes;
    return bytes;
  }

  /// Show a notification for a new DM message.
  Future<void> notifyDm({
    required String fromPeerId,
    required String text,
    required String? replyToMid,
    String? messageId,
  }) async {
    final notifSettings = ref.read(notificationSettingsProvider.notifier);
    if (!notifSettings.isDmEnabled(fromPeerId)) {
      notifLog('DM suppressed — notifications muted for this conversation');
      return;
    }

    final profiles = ref.read(profileProvider);
    final senderName = displayNameFor(profiles, fromPeerId);

    // Mobile: route by lifecycle. Backgrounded-but-connected → real OS banner
    // (the live node received this over WS; in-app banners can't draw while
    // backgrounded). Foreground → fall through to the in-app card path below.
    if (Platform.isAndroid || Platform.isIOS) {
      final lifecycle = ref.read(appLifecycleProvider);
      if (lifecycle.isBackground) {
        final avatar = await _avatarFor(fromPeerId);
        await push.showLocalDmNotification(
          personKey: fromPeerId,
          displayName: senderName,
          messageId: messageId ?? '',
          text: text,
          avatarBytes: avatar,
        );
        return;
      }
      // Foreground on mobile: show the in-app card (MobileNotificationBanner /
      // MobileInChatBanner watch these).
      _addMessage(
        sourceKey: fromPeerId,
        title: senderName,
        avatarId: fromPeerId,
        isDm: true,
        peerId: fromPeerId,
        message: NotificationMessage(
          senderPeerId: fromPeerId,
          senderName: senderName,
          text: text,
          timestamp: DateTime.now(),
        ),
      );
      return;
    }

    if (await _useNativeToast()) {
      final avatar = await _avatarFor(fromPeerId);
      DesktopNotificationService.instance.showDm(
        sourceKey: fromPeerId,
        title: senderName,
        body: text,
        avatarBytes: avatar,
      );
    } else {
      _addMessage(
        sourceKey: fromPeerId,
        title: senderName,
        avatarId: fromPeerId,
        isDm: true,
        peerId: fromPeerId,
        message: NotificationMessage(
          senderPeerId: fromPeerId,
          senderName: senderName,
          text: text,
          timestamp: DateTime.now(),
        ),
      );
    }
  }

  /// Show a notification for a new channel message. `isMention` is computed
  /// ONCE at the event gate (event_provider) and passed in — this method used
  /// to re-derive it from a drifted copy of the check whose `replyToMid !=
  /// null` clause was a tautology that neutered "Mentions only" (#42).
  Future<void> notifyChannel({
    required String serverId,
    required String channelId,
    required String fromPeerId,
    required String text,
    required bool isMention,
    String? channelName,
    String? messageId,
  }) async {
    final notifSettings = ref.read(notificationSettingsProvider.notifier);
    final level =
        notifSettings.effectiveChannelLevel(serverId, channelId);

    if (level == NotificationLevel.nothing) {
      notifLog('channel suppressed — notifications off for $serverId/$channelId');
      return;
    }
    if (level == NotificationLevel.mentions && !isMention) return;

    final profiles = ref.read(profileProvider);
    final senderName = displayNameFor(profiles, fromPeerId);
    final servers = ref.read(serverListProvider);
    final serverName = servers[serverId]?.name ?? 'Server';
    final resolvedChannelName =
        channelName ?? _channelName(serverId, channelId);
    final sourceKey = '$serverId:$channelId';

    // Mobile: route by lifecycle (see notifyDm).
    if (Platform.isAndroid || Platform.isIOS) {
      final lifecycle = ref.read(appLifecycleProvider);
      if (lifecycle.isBackground) {
        await push.showLocalChannelNotification(
          serverId: serverId,
          channelId: channelId,
          serverName: serverName,
          channelName: resolvedChannelName,
          senderName: senderName,
          messageId: messageId ?? '',
          text: text,
        );
        return;
      }
      _addMessage(
        sourceKey: sourceKey,
        title: '$serverName > #$resolvedChannelName',
        avatarId: serverId,
        isDm: false,
        serverId: serverId,
        channelId: channelId,
        message: NotificationMessage(
          senderPeerId: fromPeerId,
          senderName: senderName,
          text: text,
          timestamp: DateTime.now(),
        ),
      );
      return;
    }

    if (await _useNativeToast()) {
      // Native OS toast — channel line carries the sender name (multiple people
      // post in a channel, unlike a DM). Use the SENDER's avatar (a real peer id;
      // passing the serverId to getPushProfile would never resolve).
      final avatar = await _avatarFor(fromPeerId);
      DesktopNotificationService.instance.showChannel(
        serverId: serverId,
        channelId: channelId,
        title: '$serverName • #$resolvedChannelName',
        body: '$senderName: $text',
        avatarBytes: avatar,
      );
    } else {
      _addMessage(
        sourceKey: sourceKey,
        title: '$serverName > #$resolvedChannelName',
        avatarId: serverId,
        isDm: false,
        serverId: serverId,
        channelId: channelId,
        message: NotificationMessage(
          senderPeerId: fromPeerId,
          senderName: senderName,
          text: text,
          timestamp: DateTime.now(),
        ),
      );
    }
  }

  /// Dismiss a specific card by source key.
  void dismissCard(String sourceKey) {
    state = state.where((c) => c.sourceKey != sourceKey).toList();
  }

  /// Dismiss the pending card for a DM the user just opened. Chat-open must
  /// clear its in-app card the same way it clears the OS notification —
  /// otherwise the card lingers and replays later (and occupies the card cap).
  void dismissDm(String peerId) => dismissCard(peerId);

  /// Dismiss the pending card for a channel the user just opened.
  void dismissChannel(String serverId, String channelId) =>
      dismissCard('$serverId:$channelId');

  /// Dismiss all cards.
  void dismissAll() {
    state = [];
  }

  // ── In-app overlay cards ──────────────────────────────────────

  /// In-app cards are the ONE surface that had no sound of its own: the native
  /// toast path already rings with the OS notification sound, so hooking the
  /// Hollow sound in here (rather than at the top of notifyDm/notifyChannel)
  /// keeps the one-surface-one-sound-per-message property (#55).
  void _addMessage({
    required String sourceKey,
    required String title,
    required String avatarId,
    required bool isDm,
    String? serverId,
    String? channelId,
    String? peerId,
    required NotificationMessage message,
  }) {
    SoundService.instance.play(HollowSound.notification);
    final cards = List<NotificationCard>.from(state);
    final existingIndex =
        cards.indexWhere((c) => c.sourceKey == sourceKey);

    if (existingIndex >= 0) {
      cards[existingIndex] = cards[existingIndex].withMessage(message);
    } else {
      // At capacity: evict the OLDEST card, never silently drop the newest —
      // stale cards must not starve fresh notifications.
      if (cards.length >= 3) cards.removeAt(0);
      cards.add(NotificationCard(
        sourceKey: sourceKey,
        title: title,
        avatarId: avatarId,
        isDm: isDm,
        serverId: serverId,
        channelId: channelId,
        peerId: peerId,
        messages: [message],
      ));
    }
    state = cards;
  }

  // ── Helpers ───────────────────────────────────────────────────

  /// Bring the desktop window to the foreground (used when a native toast is
  /// tapped). Public so the toast open-handler in the shell can call it.
  Future<void> bringWindowToFront() => _bringWindowToFront();

  String _channelName(String serverId, String channelId) {
    final channels = ref.read(channelListProvider);
    return channels[channelId]?.name ?? 'channel';
  }

  /// Which surface this message gets. `event_provider` already guaranteed we're
  /// NOT viewing this exact chat (visible + focused + selected + at-bottom), so
  /// exactly ONE surface fires here:
  ///  • Native OS toast when the window is hidden (tray) OR unfocused.
  ///  • In-app card only when the window is visible AND provably focused
  ///    (focused-but-other-conversation) — a toast there as well was redundant
  ///    noise.
  ///
  /// Ties go to the toast. The card is invisible whenever the window isn't on
  /// top, so guessing "focused" loses the message outright, while guessing
  /// "unfocused" only costs a redundant toast.
  Future<bool> _useNativeToast() async {
    if (await _isWindowHidden()) return true;
    if (!await _isWindowFocused()) return true;
    notifLog('window visible + focused — routing to the in-app card');
    return false;
  }

  Future<bool> _isWindowHidden() async {
    try {
      // On Linux Wayland, isVisible() returns true even when minimized to tray.
      // Use the app-level state provider as the source of truth.
      if (Platform.isLinux) {
        return !ref.read(windowVisibleProvider);
      }
      return !(await windowManager.isVisible());
    } catch (_) {
      return false;
    }
  }

  /// Whether the user is *positively established* to be looking at our window.
  ///
  /// Two independent sources, and both must agree:
  ///  • `windowFocusedProvider` — event-driven, fed by window_manager's
  ///    `onWindowFocus`/`onWindowBlur` (WM_NCACTIVATE on Windows). This is the
  ///    same source the event gate in `event_provider` uses.
  ///  • `windowManager.isFocused()` — a live `GetForegroundWindow()` compare.
  ///
  /// The two branches downstream are NOT symmetric: the native toast is always
  /// visible, the in-app card is invisible the moment another app is on top.
  /// So "focused" has to be proven, never assumed — either source saying "not
  /// focused" wins, and a query that throws counts as not focused. Before this,
  /// the `catch` returned `true` and a single lying source was enough to route
  /// a message into a card nobody could see (Flutter 3.47 field report).
  Future<bool> _isWindowFocused() async {
    final eventFocused = ref.read(windowFocusedProvider);
    bool nativeFocused;
    try {
      nativeFocused = await windowManager.isFocused();
    } catch (e) {
      notifLog('isFocused() threw ($e) — treating as unfocused');
      nativeFocused = false;
    }
    if (nativeFocused != eventFocused) {
      // Whichever source is wrong, the next field report names it.
      notifLog(
          'focus sources disagree: native=$nativeFocused event=$eventFocused');
      // One-way repair. A missed `onWindowBlur` leaves the provider stuck on
      // `true`, and the gate in event_provider (which only has the provider)
      // then reads "user is viewing this chat" and drops the message silently.
      // Writing the live native `false` back un-sticks it for the next message.
      // Deliberately never the other direction: `isFocused()` returning a wrong
      // `true` is the very failure this method exists to survive, so it must
      // not be allowed to overwrite a correct `false`.
      if (!nativeFocused) {
        ref.read(windowFocusedProvider.notifier).state = false;
      }
    }
    return nativeFocused && eventFocused;
  }

  Future<void> _bringWindowToFront() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }
}

final systemNotificationProvider = NotifierProvider<
    SystemNotificationNotifier,
    List<NotificationCard>>(SystemNotificationNotifier.new);
