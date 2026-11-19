import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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

/// What a server whose level was never set notifies about: every channel arrives live on
/// every device, so "all" would toast each post of a busy server. Its unread badges
/// still count every post ([NotificationSettingsState.unreadLevel]).
const NotificationLevel defaultServerLevel = NotificationLevel.mentions;

/// The stored value of a server level that is back to the default (no delete call).
const String _unsetServerLevel = 'default';

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
/// - `notif:{serverId}` → "all" / "mentions" / "nothing"; absent or "default" =
///   never set ([defaultServerLevel])
/// - `notif:{serverId}:{channelId}` → "inherit" / "all" / "mentions" / "nothing"
/// - `notif:dm:{peerId}` → "true" / "false"
class NotificationSettingsNotifier
    extends Notifier<NotificationSettingsState> {
  /// Reserved relay pref key for muted DM senders; the relay reads the same
  /// key (`DM_MUTE_PREF_KEY` in ws_handler.cpp).
  static const String dmMutePrefKey = '~dm';

  /// Reserved relay pref key for the level of every server never set; the relay
  /// reads the same key (`DEFAULT_PREF_KEY` in ws_handler.cpp).
  static const String defaultPrefKey = '~default';

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
      final level = parseStoredServerLevel(stored['notif:$sid']);
      if (level != null) serverLevels[sid] = level;
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
    final prefs = pushPrefsForRelay(
      serverLevels: state.serverLevels,
      channelOverrides: state.channelOverrides,
      mutedDmDevices: {..._mutedDmDeviceIds(), ..._ownSiblingDeviceIds()},
    );
    // Node not running yet: prefs re-sync on the next loadAll or change.
    network_api.setPushPrefs(prefsJson: jsonEncode(prefs)).catchError((_) {});
  }

  /// The level a server notifies at, as its settings show it.
  NotificationLevel serverLevel(String serverId) => state.serverLevelOf(serverId);

  /// Back to the never-set default (unmute), so it follows [defaultServerLevel].
  Future<void> resetServerLevel(String serverId) async {
    await storage_api.saveSetting(key: 'notif:$serverId', value: _unsetServerLevel);
    final updated = Map<String, NotificationLevel>.from(state.serverLevels)
      ..remove(serverId);
    state = state.copyWith(serverLevels: updated);
    _syncPushPrefsToRelay();
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

  /// The level a channel NOTIFIES at (toast, sound, banner, push): its own
  /// override, else its server's.
  NotificationLevel effectiveChannelLevel(
      String serverId, String channelId) =>
      state.notifyLevel(serverId, channelId);

  /// The level a channel's unread badge counts at: as [effectiveChannelLevel],
  /// except that a never-set server counts every post.
  NotificationLevel effectiveUnreadLevel(String serverId, String channelId) =>
      state.unreadLevel(serverId, channelId);

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

  /// A level someone chose, or null for a server never set (absent, "default").
  @visibleForTesting
  static NotificationLevel? parseStoredServerLevel(String? val) {
    return switch (val) {
      'all' => NotificationLevel.all,
      'mentions' => NotificationLevel.mentions,
      'nothing' => NotificationLevel.nothing,
      _ => null,
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

}

NotificationLevel? _overrideLevel(ChannelNotificationLevel? override) {
  return switch (override) {
    ChannelNotificationLevel.all => NotificationLevel.all,
    ChannelNotificationLevel.mentions => NotificationLevel.mentions,
    ChannelNotificationLevel.nothing => NotificationLevel.nothing,
    ChannelNotificationLevel.inherit || null => null,
  };
}

/// The push filters the relay keeps for this phone: the reserved `~default`
/// entry (every server never set notifies at [defaultServerLevel]) and only the
/// servers and channels that differ from it, so the relay never holds the list
/// of servers or the channels left alone (C-RP-06). A channel set to its
/// server's level is no override. A relay older than `~default` drops that
/// entry and keeps its own default of "all" for servers it is not told about.
/// Muted DM senders ride the reserved `~dm` entry, keyed by DEVICE id because
/// a wake carries the socket's device id and the relay never learns
/// device to master.
Map<String, Map<String, dynamic>> pushPrefsForRelay({
  required Map<String, NotificationLevel> serverLevels,
  required Map<String, ChannelNotificationLevel> channelOverrides,
  required Set<String> mutedDmDevices,
}) {
  final channels = <String, Map<String, String>>{};
  for (final entry in channelOverrides.entries) {
    if (entry.value == ChannelNotificationLevel.inherit) continue;
    final sep = entry.key.indexOf(':');
    if (sep <= 0) continue;
    final sid = entry.key.substring(0, sep);
    final serverLevel = serverLevels[sid] ?? defaultServerLevel;
    if (entry.value.name == serverLevel.name) continue;
    (channels[sid] ??= <String, String>{})[entry.key.substring(sep + 1)] =
        entry.value.name;
  }
  final prefs = <String, Map<String, dynamic>>{
    NotificationSettingsNotifier.defaultPrefKey: {
      'level': defaultServerLevel.name,
      'channels': <String, String>{},
    },
  };
  for (final sid in {...serverLevels.keys, ...channels.keys}) {
    final level = serverLevels[sid] ?? defaultServerLevel;
    final overrides = channels[sid] ?? <String, String>{};
    if (!serverLevels.containsKey(sid) && overrides.isEmpty) continue;
    prefs[sid] = {'level': level.name, 'channels': overrides};
  }
  if (mutedDmDevices.isNotEmpty) {
    prefs[NotificationSettingsNotifier.dmMutePrefKey] = {
      'level': 'all',
      'channels': <String, String>{
        for (final id in mutedDmDevices) id: 'nothing',
      },
    };
  }
  return prefs;
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

  /// A server's level as its settings show it: the one chosen, else the default.
  NotificationLevel serverLevelOf(String serverId) =>
      serverLevels[serverId] ?? defaultServerLevel;

  /// What a channel notifies about: its override, else its server's level.
  NotificationLevel notifyLevel(String serverId, String channelId) =>
      _overrideLevel(channelOverrides['$serverId:$channelId']) ??
      serverLevelOf(serverId);

  /// What a channel's unread badge counts: as [notifyLevel], but a server never
  /// set counts every post, so the quieter default costs no badges.
  NotificationLevel unreadLevel(String serverId, String channelId) =>
      _overrideLevel(channelOverrides['$serverId:$channelId']) ??
      serverLevels[serverId] ??
      NotificationLevel.all;

  bool isServerMuted(String serverId) =>
      serverLevelOf(serverId) == NotificationLevel.nothing;

  bool isChannelMuted(String serverId, String channelId) =>
      notifyLevel(serverId, channelId) == NotificationLevel.nothing;
}

final notificationSettingsProvider = NotifierProvider<
    NotificationSettingsNotifier,
    NotificationSettingsState>(NotificationSettingsNotifier.new);
