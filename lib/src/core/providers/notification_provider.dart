import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Notification level for a server or channel.
enum NotificationLevel {
  /// Notify on all messages.
  all,

  /// Only notify on replies to your messages.
  mentions,

  /// No notifications (muted).
  nothing,
}

/// Per-channel override — inherits from server default when null.
enum ChannelNotificationLevel {
  /// Use the server-level setting.
  inherit,

  /// Override: all messages.
  all,

  /// Override: mentions only.
  mentions,

  /// Override: muted.
  nothing,
}

/// Manages notification settings for servers, channels, and DMs.
///
/// Storage keys:
/// - `notif:{serverId}` → "all" / "mentions" / "nothing"
/// - `notif:{serverId}:{channelId}` → "inherit" / "all" / "mentions" / "nothing"
/// - `notif:dm:{peerId}` → "true" / "false"
class NotificationSettingsNotifier
    extends Notifier<NotificationSettingsState> {
  @override
  NotificationSettingsState build() => const NotificationSettingsState();

  /// Load all notification settings from DB.
  Future<void> loadAll(
      List<String> serverIds, Map<String, List<String>> channelIds,
      List<String> dmPeerIds) async {
    final serverLevels = <String, NotificationLevel>{};
    final channelLevels = <String, ChannelNotificationLevel>{};
    final dmEnabled = <String, bool>{};

    for (final sid in serverIds) {
      final val = await storage_api.loadSetting(key: 'notif:$sid');
      serverLevels[sid] = _parseServerLevel(val);
    }

    for (final entry in channelIds.entries) {
      for (final cid in entry.value) {
        final val = await storage_api.loadSetting(
            key: 'notif:${entry.key}:$cid');
        final level = _parseChannelLevel(val);
        if (level != ChannelNotificationLevel.inherit) {
          channelLevels['${entry.key}:$cid'] = level;
        }
      }
    }

    for (final peerId in dmPeerIds) {
      final val = await storage_api.loadSetting(key: 'notif:dm:$peerId');
      dmEnabled[peerId] = val != 'false'; // Default true.
    }

    state = NotificationSettingsState(
      serverLevels: serverLevels,
      channelOverrides: channelLevels,
      dmEnabled: dmEnabled,
    );
  }

  /// Get the effective notification level for a server.
  NotificationLevel serverLevel(String serverId) {
    return state.serverLevels[serverId] ?? NotificationLevel.all;
  }

  /// Set server-wide notification level.
  Future<void> setServerLevel(
      String serverId, NotificationLevel level) async {
    await storage_api.saveSetting(
      key: 'notif:$serverId',
      value: level.name,
    );
    final updated = Map<String, NotificationLevel>.from(state.serverLevels);
    updated[serverId] = level;
    state = state.copyWith(serverLevels: updated);
  }

  /// Get the effective notification level for a channel.
  /// Falls back to server level if channel is set to inherit.
  NotificationLevel effectiveChannelLevel(
      String serverId, String channelId) {
    final key = '$serverId:$channelId';
    final override = state.channelOverrides[key];
    if (override != null && override != ChannelNotificationLevel.inherit) {
      return _channelOverrideToLevel(override);
    }
    return serverLevel(serverId);
  }

  /// Get the raw channel override (may be inherit).
  ChannelNotificationLevel channelOverride(
      String serverId, String channelId) {
    final key = '$serverId:$channelId';
    return state.channelOverrides[key] ?? ChannelNotificationLevel.inherit;
  }

  /// Set per-channel notification override.
  Future<void> setChannelOverride(
      String serverId,
      String channelId,
      ChannelNotificationLevel level) async {
    final storageKey = 'notif:$serverId:$channelId';
    await storage_api.saveSetting(
      key: storageKey,
      value: level.name,
    );
    final updated =
        Map<String, ChannelNotificationLevel>.from(state.channelOverrides);
    if (level == ChannelNotificationLevel.inherit) {
      updated.remove('$serverId:$channelId');
    } else {
      updated['$serverId:$channelId'] = level;
    }
    state = state.copyWith(channelOverrides: updated);
  }

  /// Whether DM notifications are enabled for a peer.
  bool isDmEnabled(String peerId) {
    return state.dmEnabled[peerId] ?? true;
  }

  /// Toggle DM notifications for a peer.
  Future<void> setDmEnabled(String peerId, bool enabled) async {
    await storage_api.saveSetting(
      key: 'notif:dm:$peerId',
      value: enabled.toString(),
    );
    final updated = Map<String, bool>.from(state.dmEnabled);
    updated[peerId] = enabled;
    state = state.copyWith(dmEnabled: updated);
  }

  /// Check if a given channel is effectively muted.
  bool isChannelMuted(String serverId, String channelId) {
    return effectiveChannelLevel(serverId, channelId) ==
        NotificationLevel.nothing;
  }

  /// Check if a given server is fully muted (server-level = nothing).
  bool isServerMuted(String serverId) {
    return serverLevel(serverId) == NotificationLevel.nothing;
  }

  static NotificationLevel _parseServerLevel(String? val) {
    return switch (val) {
      'mentions' => NotificationLevel.mentions,
      'nothing' => NotificationLevel.nothing,
      _ => NotificationLevel.all,
    };
  }

  static ChannelNotificationLevel _parseChannelLevel(String? val) {
    return switch (val) {
      'all' => ChannelNotificationLevel.all,
      'mentions' => ChannelNotificationLevel.mentions,
      'nothing' => ChannelNotificationLevel.nothing,
      _ => ChannelNotificationLevel.inherit,
    };
  }

  static NotificationLevel _channelOverrideToLevel(
      ChannelNotificationLevel override) {
    return switch (override) {
      ChannelNotificationLevel.all => NotificationLevel.all,
      ChannelNotificationLevel.mentions => NotificationLevel.mentions,
      ChannelNotificationLevel.nothing => NotificationLevel.nothing,
      ChannelNotificationLevel.inherit => NotificationLevel.all,
    };
  }
}

/// Immutable state for notification settings.
class NotificationSettingsState {
  final Map<String, NotificationLevel> serverLevels;
  final Map<String, ChannelNotificationLevel> channelOverrides;
  final Map<String, bool> dmEnabled;

  const NotificationSettingsState({
    this.serverLevels = const {},
    this.channelOverrides = const {},
    this.dmEnabled = const {},
  });

  NotificationSettingsState copyWith({
    Map<String, NotificationLevel>? serverLevels,
    Map<String, ChannelNotificationLevel>? channelOverrides,
    Map<String, bool>? dmEnabled,
  }) {
    return NotificationSettingsState(
      serverLevels: serverLevels ?? this.serverLevels,
      channelOverrides: channelOverrides ?? this.channelOverrides,
      dmEnabled: dmEnabled ?? this.dmEnabled,
    );
  }

  bool isDmEnabled(String peerId) => dmEnabled[peerId] ?? true;

  bool isServerMuted(String serverId) =>
      (serverLevels[serverId] ?? NotificationLevel.all) ==
      NotificationLevel.nothing;

  bool isChannelMuted(String serverId, String channelId) {
    final key = '$serverId:$channelId';
    final override = channelOverrides[key];
    if (override != null && override != ChannelNotificationLevel.inherit) {
      return override == ChannelNotificationLevel.nothing;
    }
    return isServerMuted(serverId);
  }
}

final notificationSettingsProvider = NotifierProvider<
    NotificationSettingsNotifier,
    NotificationSettingsState>(NotificationSettingsNotifier.new);
