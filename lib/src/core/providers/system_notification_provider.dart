import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:local_notifier/local_notifier.dart';
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
  LocalNotification? _activeNativeNotification;

  @override
  List<NotificationCard> build() => [];

  /// Initialize native notifications. Call once at startup.
  Future<void> init() async {
    if (_nativeInitialized) return;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;
    try {
      await localNotifier.setup(
        appName: 'Hollow',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _nativeInitialized = true;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to init local_notifier: $e');
    }
  }

  /// Show a notification for a new DM message.
  Future<void> notifyDm({
    required String fromPeerId,
    required String text,
    required String? replyToMid,
  }) async {
    final notifSettings = ref.read(notificationSettingsProvider.notifier);
    if (!notifSettings.isDmEnabled(fromPeerId)) return;

    final profiles = ref.read(profileProvider);
    final senderName = displayNameFor(profiles, fromPeerId);

    final isHidden = await _isWindowHidden();
    final isFocused = isHidden ? false : await _isWindowFocused();

    if (isHidden) {
      // Window is hidden (tray) — use native OS notification.
      _showNativeNotification(title: senderName, body: text);
    } else if (!isFocused) {
      // Window is visible but unfocused — use in-app overlay.
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

  /// Show a notification for a new channel message.
  Future<void> notifyChannel({
    required String serverId,
    required String channelId,
    required String fromPeerId,
    required String text,
    required String? replyToMid,
    String? channelName,
  }) async {
    final notifSettings = ref.read(notificationSettingsProvider.notifier);
    final level =
        notifSettings.effectiveChannelLevel(serverId, channelId);

    if (level == NotificationLevel.nothing) return;
    if (level == NotificationLevel.mentions) {
      final localPeerId = ref.read(identityProvider).peerId ?? '';
      final profiles = ref.read(profileProvider);
      final localName = displayNameFor(profiles, localPeerId);
      final localNick =
          ref.read(serverNicknamesProvider(serverId))[localPeerId];
      final isMentioned = text.contains('@everyone') ||
          text.contains('@$localName') ||
          (localNick != null && text.contains('@$localNick')) ||
          replyToMid != null;
      if (!isMentioned) return;
    }

    final profiles = ref.read(profileProvider);
    final senderName = displayNameFor(profiles, fromPeerId);
    final servers = ref.read(serverListProvider);
    final serverName = servers[serverId]?.name ?? 'Server';
    final resolvedChannelName =
        channelName ?? _channelName(serverId, channelId);

    final isHidden = await _isWindowHidden();
    final isFocused = isHidden ? false : await _isWindowFocused();

    if (isHidden) {
      // Window is hidden (tray) — use native OS notification.
      _showNativeNotification(
        title: '$senderName in $serverName',
        body: text,
      );
    } else if (!isFocused) {
      // Window is visible but unfocused — use in-app overlay.
      _addMessage(
        sourceKey: '$serverId:$channelId',
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

  /// Dismiss all cards.
  void dismissAll() {
    state = [];
  }

  // ── In-app overlay cards ──────────────────────────────────────

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
    final cards = List<NotificationCard>.from(state);
    final existingIndex =
        cards.indexWhere((c) => c.sourceKey == sourceKey);

    if (existingIndex >= 0) {
      cards[existingIndex] = cards[existingIndex].withMessage(message);
    } else {
      if (cards.length >= 3) return;
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

  // ── Native OS notifications (tray mode) ───────────────────────

  void _showNativeNotification({
    required String title,
    required String body,
  }) {
    if (!_nativeInitialized) return;
    try {
      _activeNativeNotification?.close();
    } catch (_) {}

    final notification = LocalNotification(
      title: title,
      body: body,
    );
    notification.onClick = () {
      _bringWindowToFront();
    };
    _activeNativeNotification = notification;
    notification.show();
  }

  // ── Helpers ───────────────────────────────────────────────────

  String _channelName(String serverId, String channelId) {
    final channels = ref.read(channelListProvider);
    return channels[channelId]?.name ?? 'channel';
  }

  Future<bool> _isWindowHidden() async {
    try {
      return !(await windowManager.isVisible());
    } catch (_) {
      return false;
    }
  }

  Future<bool> _isWindowFocused() async {
    try {
      return await windowManager.isFocused();
    } catch (_) {
      return true;
    }
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
