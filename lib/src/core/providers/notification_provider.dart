import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Notification level for a server or channel.
enum NotificationLevel {
  /// Notify on all messages.
  all,

  /// Only notify on mentions (@you, @everyone) and replies to YOUR messages.
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
  /// Reserved relay pref key for muted DM senders; the relay reads the same
  /// key (`DM_MUTE_PREF_KEY` in ws_handler.cpp).
  static const String dmMutePrefKey = '~dm';

  /// Set by [loadAll]. A sync before it would replace the relay's filters with
  /// an empty set.
  bool _loaded = false;

  @override
  NotificationSettingsState build() {
    // A newly linked device, a muted friend's or our own, must join the relay
    // filter.
    ref.listen(deviceLinkProvider, (_, _) {
      if (_loaded) _syncPushPrefsToRelay();
    });
    ref.listen(localDevicePeerIdProvider, (_, _) {
      if (_loaded) _syncPushPrefsToRelay();
    });
    return const NotificationSettingsState();
  }

  /// Our own other devices. The copy of a message WE sent that one of them
  /// leaves for us while we are offline must never wake us.
  Set<String> _ownSiblingDeviceIds() {
    final me = ref.read(localDevicePeerIdProvider).valueOrNull;
    if (me == null) return const {};
    final links = ref.read(deviceLinkProvider);
    final master = links.identityOf(me);
    return {
      for (final e in links.links.entries)
        if (e.value == master && e.key != me && e.key != master) e.key,
    };
  }

  /// Every device id a muted DM key can wake us from: the stored key, its
  /// master, and every device linked to that master.
  Set<String> _mutedDmDeviceIds() {
    final links = ref.read(deviceLinkProvider);
    final out = <String>{};
    for (final entry in state.dmEnabled.entries) {
      if (entry.value) continue;
      final master = links.identityOf(entry.key);
      out.add(entry.key);
      out.add(master);
      for (final l in links.links.entries) {
        if (l.value == master) out.add(l.key);
      }
    }
    return out;
  }

  /// Load all notification settings from DB.
  ///
  /// One batched `notif:` prefix read, not a serial `loadSetting` per server,
  /// channel and DM (hundreds of round-trips in front of the startup spinner).
  Future<void> loadAll(
      List<String> serverIds, Map<String, List<String>> channelIds,
      List<String> dmPeerIds) async {
    final serverLevels = <String, NotificationLevel>{};
    final channelLevels = <String, ChannelNotificationLevel>{};
    final dmEnabled = <String, bool>{};

    final stored = <String, String>{};
    try {
      for (final e
          in await storage_api.loadSettingsWithPrefix(prefix: 'notif:')) {
        stored[e.key] = e.value;
      }
    } catch (_) {
      // Store not open / transient FFI error — fall through with defaults.
    }

    for (final sid in serverIds) {
      serverLevels[sid] = _parseServerLevel(stored['notif:$sid']);
    }

    for (final entry in channelIds.entries) {
      for (final cid in entry.value) {
        final level = _parseChannelLevel(stored['notif:${entry.key}:$cid']);
        if (level != ChannelNotificationLevel.inherit) {
          channelLevels['${entry.key}:$cid'] = level;
        }
      }
    }

    for (final peerId in dmPeerIds) {
      dmEnabled[peerId] = stored['notif:dm:$peerId'] != 'false'; // Default true.
    }

    state = NotificationSettingsState(
      serverLevels: serverLevels,
      channelOverrides: channelLevels,
      dmEnabled: dmEnabled,
    );
    _loaded = true;
    _syncPushPrefsToRelay();
  }

  /// Register the current server/channel levels with the relay as channel-push
  /// filters. The relay checks these BEFORE firing a push, which is required on
  /// iOS where an alert push can't be suppressed after delivery. Mobile only: a
  /// desktop sync would overwrite the phone's filters. Fire-and-forget, since
  /// the node caches the prefs and the next loadAll() retries.
  void _syncPushPrefsToRelay() {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;
    final prefs = <String, Map<String, dynamic>>{};
    for (final entry in state.serverLevels.entries) {
      prefs[entry.key] = {
        'level': entry.value.name,
        'channels': <String, String>{},
      };
    }
    for (final entry in state.channelOverrides.entries) {
      if (entry.value == ChannelNotificationLevel.inherit) continue;
      final sep = entry.key.indexOf(':');
      if (sep <= 0) continue;
      final sid = entry.key.substring(0, sep);
      final cid = entry.key.substring(sep + 1);
      final server = prefs.putIfAbsent(
          sid, () => {'level': 'all', 'channels': <String, String>{}});
      (server['channels'] as Map<String, String>)[cid] = entry.value.name;
    }
    // Muted DMs ride the reserved `~dm` entry in the same server-pref shape,
    // keyed by the sender's DEVICE ids because the relay never learns
    // device→master; a wake carries the socket's device id.
    final muted = {..._mutedDmDeviceIds(), ..._ownSiblingDeviceIds()};
    if (muted.isNotEmpty) {
      prefs[dmMutePrefKey] = {
        'level': 'all',
        'channels': <String, String>{for (final id in muted) id: 'nothing'},
      };
    }
    try {
      network_api.setPushPrefs(prefsJson: jsonEncode(prefs));
    } catch (_) {
      // Node not running yet — prefs re-sync on the next loadAll/change.
    }
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
    _syncPushPrefsToRelay();
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
    _syncPushPrefsToRelay();
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
    _syncPushPrefsToRelay();
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
