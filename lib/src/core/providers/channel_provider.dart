import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

class ChannelListNotifier extends Notifier<Map<String, ChannelInfo>> {
  @override
  Map<String, ChannelInfo> build() => {};

  Future<void> loadForServer(String serverId) async {
    try {
      state = await fetchChannels(serverId);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load channels: $e');
    }
  }

  /// Fetch channels without publishing to state, so callers can batch updates.
  static Future<Map<String, ChannelInfo>> fetchChannels(String serverId) async {
    final channels = await crdt_api.getServerChannels(serverId: serverId);
    final map = <String, ChannelInfo>{};
    for (final ch in channels) {
      map[ch.channelId] = ChannelInfo(
        channelId: ch.channelId,
        name: ch.name,
        category: ch.category,
        channelType: ch.channelType == 'voice'
            ? ChannelType.voice
            : ChannelType.text,
        visibility: ch.visibility,
        posting: ch.posting,
        isPublic: ch.isPublic,
        slowModeSecs: ch.slowMode,
        mediaOnly: ch.mediaOnly,
        visibilityLabels: ch.visibilityLabels,
        postingLabels: ch.postingLabels,
        meCanSee: ch.meCanSee,
        meCanPost: ch.meCanPost,
      );
    }
    return map;
  }

  void setChannels(Map<String, ChannelInfo> channels) {
    state = channels;
  }

  void updateChannel(String channelId, ChannelInfo Function(ChannelInfo) updater) {
    final ch = state[channelId];
    if (ch == null) return;
    final updated = Map.of(state);
    updated[channelId] = updater(ch);
    state = updated;
  }

  void onChannelAdded(String serverId, String channelId, String name,
      {String channelType = 'text'}) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    final updated = Map.of(state);
    updated[channelId] = ChannelInfo(
      channelId: channelId,
      name: name,
      channelType:
          channelType == 'voice' ? ChannelType.voice : ChannelType.text,
    );
    state = updated;
  }

  void onChannelRemoved(String serverId, String channelId) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    state = Map.of(state)..remove(channelId);
  }

  /// Called when a ChannelRenamed event arrives. copyWith keeps every other
  /// property; rebuilding the record used to silently reset visibility/posting.
  void onChannelRenamed(String serverId, String channelId, String newName) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    final existing = state[channelId];
    if (existing == null) return;

    final updated = Map.of(state);
    updated[channelId] = existing.copyWith(name: newName);
    state = updated;
  }

  void clear() {
    state = {};
  }
}

final channelListProvider =
    NotifierProvider<ChannelListNotifier, Map<String, ChannelInfo>>(
        ChannelListNotifier.new);

/// Channels for a specific server from the local DB. Unlike
/// [channelListProvider] (the *selected* server), this works for any server.
final serverChannelsProvider = FutureProvider.autoDispose
    .family<Map<String, ChannelInfo>, String>((ref, serverId) {
  return ChannelListNotifier.fetchChannels(serverId);
});

/// Channels filtered by the user's visibility permissions. `meCanSee` is
/// computed Rust-side with the FULL predicate; never re-implement the ladder.
final visibleChannelsProvider = Provider<Map<String, ChannelInfo>>((ref) {
  final channels = ref.watch(channelListProvider);
  final selectedServer = ref.watch(selectedServerProvider);
  if (selectedServer == null) return channels;

  return Map.fromEntries(channels.entries.where((e) => e.value.meCanSee));
});

/// Whether the user can post here. `meCanPost` folds in the posting
/// tier/labels/grants and SEND_MESSAGES; mute is a separate composer check.
final canPostInChannelProvider =
    Provider.family<bool, ({String serverId, String channelId})>((ref, args) {
  final channels = ref.watch(channelListProvider);
  return channels[args.channelId]?.meCanPost ?? true;
});

/// Active mutes for a server. Invalidated on ServerUpdated via the event
/// provider's ramp, because the CrdtStore write is fire-and-forget.
final mutedMembersProvider = FutureProvider.autoDispose
    .family<List<crdt_api.MutedMemberFfi>, String>((ref, serverId) async {
  try {
    return await crdt_api.getMutedMembers(serverId: serverId);
  } catch (_) {
    return const [];
  }
});

/// My mute status in a server: null = not muted, else the FFI record
/// (permanent flag + expiry ms). Master-keyed. Invalidated on ServerUpdated.
final myMuteStatusProvider = FutureProvider.autoDispose
    .family<crdt_api.MutedMemberFfi?, String>((ref, serverId) async {
  final myDeviceId = await ref.watch(localDevicePeerIdProvider.future);
  if (myDeviceId == null) return null;
  final myMaster = ref.watch(deviceLinkProvider).identityOf(myDeviceId);
  try {
    final muted = await crdt_api.getMutedMembers(serverId: serverId);
    for (final m in muted) {
      if (m.peerId == myMaster || m.peerId == myDeviceId) {
        // Timed mute: self-invalidate past expiry so the input bar unlocks.
        if (!m.permanent) {
          final remaining =
              m.expiresAtMs - DateTime.now().millisecondsSinceEpoch;
          if (remaining <= 0) return null;
          final t = Timer(Duration(milliseconds: remaining + 500),
              () => ref.invalidateSelf());
          ref.onDispose(t.cancel);
        }
        return m;
      }
    }
  } catch (_) {
    // Node not running / server unknown — treat as not muted.
  }
  return null;
});

/// Active temporary grants for one channel. Self-invalidates just past the
/// earliest expiry, because grant expiry emits no op.
final channelGrantsProvider = FutureProvider.autoDispose
    .family<List<crdt_api.ChannelGrantFfi>,
        ({String serverId, String channelId})>((ref, args) async {
  List<crdt_api.ChannelGrantFfi> grants;
  try {
    grants = await crdt_api.getChannelGrants(
        serverId: args.serverId, channelId: args.channelId);
  } catch (_) {
    return const [];
  }
  final now = DateTime.now().millisecondsSinceEpoch;
  int? soonest;
  for (final g in grants) {
    if (g.permanent) continue;
    final remaining = g.expiresAtMs - now;
    if (remaining > 0 && (soonest == null || remaining < soonest)) {
      soonest = remaining;
    }
  }
  if (soonest != null) {
    final t = Timer(Duration(milliseconds: soonest + 500),
        () => ref.invalidateSelf());
    ref.onDispose(t.cancel);
  }
  return grants;
});

/// MY active grant for a channel (null = none). Master-keyed like mutes. On
/// expiry this also reloads the channel list so `meCanSee`/`meCanPost` flip:
/// expiry produces NO network event.
final myChannelGrantProvider = FutureProvider.autoDispose
    .family<crdt_api.ChannelGrantFfi?,
        ({String serverId, String channelId})>((ref, args) async {
  final myDeviceId = await ref.watch(localDevicePeerIdProvider.future);
  if (myDeviceId == null) return null;
  final myMaster = ref.watch(deviceLinkProvider).identityOf(myDeviceId);
  try {
    final grants = await crdt_api.getChannelGrants(
        serverId: args.serverId, channelId: args.channelId);
    for (final g in grants) {
      if (g.peerId != myMaster && g.peerId != myDeviceId) continue;
      if (!g.permanent) {
        final remaining =
            g.expiresAtMs - DateTime.now().millisecondsSinceEpoch;
        if (remaining <= 0) return null;
        final t = Timer(Duration(milliseconds: remaining + 500), () {
          // Reload so meCanSee re-evaluates (the grant just lapsed).
          ref.read(channelListProvider.notifier).loadForServer(args.serverId);
          ref.invalidate(serverChannelsProvider(args.serverId));
          ref.invalidateSelf();
        });
        ref.onDispose(t.cancel);
      }
      return g;
    }
  } catch (_) {
    // Node not running / server unknown — treat as no grant.
  }
  return null;
});

final selectedChannelProvider = StateProvider<String?>((ref) => null);

/// Remembers the last selected channel per server so switching back restores it.
final lastChannelPerServerProvider =
    StateProvider<Map<String, String>>((ref) => {});

/// Channel layout JSON for the currently selected server.
class ChannelLayoutNotifier extends Notifier<String> {
  @override
  String build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return '[]';
  }

  /// Server whose layout has an in-flight local write, and its generation. See [mutate].
  String? _pendingServerId;
  int _writeGen = 0;
  bool _disposed = false;

  /// How long a local write shields itself from a DB reload (one CRDT op round trip).
  static const _pendingWindow = Duration(milliseconds: 1500);

  Future<void> loadForServer(String serverId) async {
    // A local write for THIS server is still settling: `update_channel_layout`
    // only queues a CRDT op, so a reload here would stomp it with the older DB.
    if (_pendingServerId == serverId) return;
    try {
      final json = await fetchLayout(serverId);
      // The await gave a local write a chance to start; don't land a stale read.
      if (_disposed || _pendingServerId == serverId) return;
      state = json;
    } catch (_) {
      if (_disposed || _pendingServerId == serverId) return;
      state = '[]';
    }
  }

  static Future<String> fetchLayout(String serverId) async {
    return await crdt_api.getChannelLayout(serverId: serverId);
  }

  /// Set the layout for [serverId] directly, from a navigate flow that just read
  /// it: a read for the server whose local write is still queued is stale by
  /// construction and would undo the edit. [serverId] is optional only so a
  /// caller with no server context compiles.
  void setLayout(String json, {String? serverId}) {
    if (serverId != null && _pendingServerId == serverId) return;
    _pendingServerId = null;
    state = json;
  }

  /// THE way to change a channel layout: three things must not drift apart.
  ///
  /// 1. **Normalisation.** [mutator] receives an EFFECTIVE layout: the stored
  ///    layout plus every channel not yet in it, in sidebar order. Without it a
  ///    new category appended to `[]` named a category and no channels.
  /// 2. **Optimistic state.** The new JSON is published BEFORE the FFI call,
  ///    because the write only queues an op and a read-back returns the old value.
  /// 3. **A pending guard.** [loadForServer] is suppressed until the op lands.
  ///
  /// [channels] is the channel map for [serverId] (`channelListProvider`).
  void mutate(
    String serverId,
    Map<String, ChannelInfo> channels,
    List<LayoutItem> Function(List<LayoutItem> layout) mutator,
  ) {
    final effective = effectiveLayout(state, channels);
    final json = layoutToJson(mutator(effective));

    final gen = ++_writeGen;
    _pendingServerId = serverId;
    state = json;

    // try/catch AND catchError: an uninitialised bridge throws SYNCHRONOUSLY,
    // which catchError cannot intercept, while a later rejection escapes try/catch.
    try {
      crdt_api
          .updateChannelLayout(serverId: serverId, layoutJson: json)
          .catchError((_) {});
    } catch (_) {}

    // Release the guard once the queued op has had time to persist, unless a
    // newer write superseded this one. Deliberately NO re-read: the DB can only
    // be equal to or behind what we just wrote.
    Future<void>.delayed(_pendingWindow, () {
      if (_disposed || _writeGen != gen) return;
      if (_pendingServerId == serverId) _pendingServerId = null;
    });
  }

  void clear() {
    _pendingServerId = null;
    state = '[]';
  }
}

/// The stored layout plus any channel missing from it, appended in the order
/// the sidebar renders unplaced channels, with dead references dropped.
///
/// ONE definition, shared by the sidebar menus and the Channels settings editor.
List<LayoutItem> effectiveLayoutFrom(
    List<LayoutItem> base, Map<String, ChannelInfo> channels) {
  final layout = List<LayoutItem>.from(base)
    ..removeWhere(
        (item) => item is ChannelItem && !channels.containsKey(item.channelId));

  final placed =
      layout.whereType<ChannelItem>().map((item) => item.channelId).toSet();

  final unplaced = channels.values
      .where((ch) => !placed.contains(ch.channelId))
      .toList()
    ..sort((a, b) => a.name.compareTo(b.name));

  return [...layout, ...unplaced.map((ch) => ChannelItem(ch.channelId))];
}

List<LayoutItem> effectiveLayout(
        String layoutJson, Map<String, ChannelInfo> channels) =>
    effectiveLayoutFrom(parseLayoutJson(layoutJson), channels);

final channelLayoutProvider =
    NotifierProvider<ChannelLayoutNotifier, String>(ChannelLayoutNotifier.new);

/// The first text channel ID in visual sidebar order (placed first, then unplaced).
String? firstTextChannelInLayout(
    Map<String, ChannelInfo> channels, String layoutJson) {
  // The effective layout IS sidebar order, so "first in the sidebar" is one
  // walk, not a second copy of the ordering rule that can drift from it.
  for (final item in effectiveLayout(layoutJson, channels)) {
    if (item is! ChannelItem) continue;
    final channel = channels[item.channelId];
    if (channel != null && channel.channelType == ChannelType.text) {
      return item.channelId;
    }
  }
  return null;
}
