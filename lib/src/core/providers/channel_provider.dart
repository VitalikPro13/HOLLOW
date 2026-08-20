import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// Manages the channel list for the currently selected server.
class ChannelListNotifier extends Notifier<Map<String, ChannelInfo>> {
  @override
  Map<String, ChannelInfo> build() => {};

  /// Load channels for a server from the local DB.
  Future<void> loadForServer(String serverId) async {
    try {
      state = await fetchChannels(serverId);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load channels: $e');
    }
  }

  /// Fetch channels without publishing to state. Callers can batch
  /// multiple provider updates to avoid intermediate rebuilds.
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

  /// Set channels directly (used for batched provider updates).
  void setChannels(Map<String, ChannelInfo> channels) {
    state = channels;
  }

  /// Optimistically update a single channel's properties.
  void updateChannel(String channelId, ChannelInfo Function(ChannelInfo) updater) {
    final ch = state[channelId];
    if (ch == null) return;
    final updated = Map.of(state);
    updated[channelId] = updater(ch);
    state = updated;
  }

  /// Called when a ChannelAdded event arrives.
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

  /// Called when a ChannelRemoved event arrives.
  void onChannelRemoved(String serverId, String channelId) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    state = Map.of(state)..remove(channelId);
  }

  /// Called when a ChannelRenamed event arrives. copyWith keeps every other
  /// property — rebuilding the record from scratch used to silently reset
  /// visibility/posting/isPublic until the next full reload.
  void onChannelRenamed(String serverId, String channelId, String newName) {
    final selectedServer = ref.read(selectedServerProvider);
    if (selectedServer != serverId) return;

    final existing = state[channelId];
    if (existing == null) return;

    final updated = Map.of(state);
    updated[channelId] = existing.copyWith(name: newName);
    state = updated;
  }

  /// Clear channel list (e.g., when switching servers).
  void clear() {
    state = {};
  }
}

final channelListProvider =
    NotifierProvider<ChannelListNotifier, Map<String, ChannelInfo>>(
        ChannelListNotifier.new);

/// Channels for a specific server, read straight from the local DB.
/// Unlike [channelListProvider] (which tracks the *selected* server), this
/// works for any server — e.g. server settings opened from the chats-tab
/// long-press sheet where no server is selected.
final serverChannelsProvider = FutureProvider.autoDispose
    .family<Map<String, ChannelInfo>, String>((ref, serverId) {
  return ChannelListNotifier.fetchChannels(serverId);
});

/// Channels filtered by the user's visibility permissions.
/// `meCanSee` is computed Rust-side with the FULL predicate (tier ladder +
/// label gates + temporary grants) — never re-implement the ladder here.
final visibleChannelsProvider = Provider<Map<String, ChannelInfo>>((ref) {
  final channels = ref.watch(channelListProvider);
  final selectedServer = ref.watch(selectedServerProvider);
  if (selectedServer == null) return channels;

  return Map.fromEntries(channels.entries.where((e) => e.value.meCanSee));
});

/// Whether the user can post in a specific channel. `meCanPost` folds in the
/// posting tier/labels/grants AND the SEND_MESSAGES bit Rust-side; mute stays
/// a separate signal (myMuteStatusProvider) checked at the composers.
final canPostInChannelProvider =
    Provider.family<bool, ({String serverId, String channelId})>((ref, args) {
  final channels = ref.watch(channelListProvider);
  return channels[args.channelId]?.meCanPost ?? true;
});

/// Active mutes for a server (what the Members tab's muted section shows).
/// Invalidated on ServerUpdated via the event provider's ramp (the CrdtStore
/// write is fire-and-forget, so a single immediate reload can read stale DB).
final mutedMembersProvider = FutureProvider.autoDispose
    .family<List<crdt_api.MutedMemberFfi>, String>((ref, serverId) async {
  try {
    return await crdt_api.getMutedMembers(serverId: serverId);
  } catch (_) {
    return const [];
  }
});

/// My mute status in a server: null = not muted, otherwise the FFI record
/// (permanent flag + expiry ms). Master-keyed — collapses the local device id.
/// Invalidated on ServerUpdated (event_provider._refreshServerState).
final myMuteStatusProvider = FutureProvider.autoDispose
    .family<crdt_api.MutedMemberFfi?, String>((ref, serverId) async {
  final myDeviceId = await ref.watch(localDevicePeerIdProvider.future);
  if (myDeviceId == null) return null;
  final myMaster = ref.watch(deviceLinkProvider).identityOf(myDeviceId);
  try {
    final muted = await crdt_api.getMutedMembers(serverId: serverId);
    for (final m in muted) {
      if (m.peerId == myMaster || m.peerId == myDeviceId) {
        // Timed mute: self-invalidate right after expiry so the input bar
        // unlocks without waiting for the next ServerUpdated.
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

/// Active temporary grants for one channel (what the grants dialog shows).
/// Self-invalidates just past the earliest non-permanent expiry so
/// remaining-time labels refresh without an op (grant expiry emits none —
/// same pattern as myMuteStatusProvider). Re-fetched when the dialog listens
/// to serverChannelsProvider invalidation via the ServerUpdated ramp.
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

/// MY active grant for a channel (null = none). Master-keyed like mutes.
/// On MY grant's expiry this also reloads the channel list so `meCanSee`/
/// `meCanPost` flip and the shell evicts me — expiry produces NO network
/// event, so without this timer the channel would linger until the next
/// ServerUpdated. Composers watch this to keep the timer alive while viewing.
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

/// Currently selected channel ID.
final selectedChannelProvider = StateProvider<String?>((ref) => null);

/// Remembers the last selected channel per server so switching back restores it.
final lastChannelPerServerProvider =
    StateProvider<Map<String, String>>((ref) => {});

/// Channel layout JSON for the currently selected server.
/// Updated when channels load or server layout changes.
class ChannelLayoutNotifier extends Notifier<String> {
  @override
  String build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    return '[]';
  }

  /// Server whose layout has an in-flight local write, and the generation of
  /// that write. See [mutate].
  String? _pendingServerId;
  int _writeGen = 0;
  bool _disposed = false;

  /// How long a local write shields itself from a DB reload. Covers the
  /// queue-then-persist round trip of a CRDT op.
  static const _pendingWindow = Duration(milliseconds: 1500);

  Future<void> loadForServer(String serverId) async {
    // A local write for THIS server is still settling. `update_channel_layout`
    // only queues a CRDT op, so the DB still holds the previous layout and
    // reloading here would stomp the newer state with the older one. Server
    // events fire this on every channel change, which is exactly when a local
    // layout edit is most likely to be in flight.
    if (_pendingServerId == serverId) return;
    try {
      final json = await fetchLayout(serverId);
      // The await gave a local write a chance to start; do not land a stale
      // read on top of it.
      if (_disposed || _pendingServerId == serverId) return;
      state = json;
    } catch (_) {
      if (_disposed || _pendingServerId == serverId) return;
      state = '[]';
    }
  }

  /// Fetch layout without publishing to state.
  static Future<String> fetchLayout(String serverId) async {
    return await crdt_api.getChannelLayout(serverId: serverId);
  }

  /// Set layout directly (used for batched provider updates).
  ///
  /// Every caller is a "navigate to [serverId]" flow that just read the layout
  /// from the DB. Pass the server it was read FOR: a read for the server whose
  /// local write is still queued is stale by construction, and landing it would
  /// undo the edit. Reading for any OTHER server means we are leaving this one,
  /// so the guard is done.
  ///
  /// [serverId] is optional only so a caller with genuinely no server context
  /// still compiles; prefer passing it.
  void setLayout(String json, {String? serverId}) {
    if (serverId != null && _pendingServerId == serverId) return;
    _pendingServerId = null;
    state = json;
  }

  /// THE way to change a channel layout.
  ///
  /// Everything that edits the layout goes through this one method so the
  /// three things that must happen together cannot drift apart:
  ///
  /// 1. **Normalisation.** [mutator] receives an EFFECTIVE layout: the stored
  ///    layout plus every channel not yet in it, appended in the order the
  ///    sidebar renders them. A server that never had an explicit layout has
  ///    an empty one, so without this a new category appended to `[]` produced
  ///    a layout that named a category and no channels. The sidebar then drew
  ///    the category as empty while the settings editor, which does its own
  ///    normalisation, drew every channel underneath it.
  /// 2. **Optimistic state.** The new JSON is published BEFORE the FFI call,
  ///    because the write only queues an op and reading it back returns the
  ///    previous value.
  /// 3. **A pending guard.** [loadForServer] is suppressed for this server
  ///    until the op has had time to land, then reconciles from the DB.
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
    // before a Future exists, which catchError alone cannot intercept, while a
    // later rejection escapes a bare try/catch to the zone crash handler.
    try {
      crdt_api
          .updateChannelLayout(serverId: serverId, layoutJson: json)
          .catchError((_) {});
    } catch (_) {}

    // Release the guard once the queued op has had time to persist, unless a
    // newer write superseded this one.
    //
    // Deliberately NO re-read here. The state we just published IS what we
    // wrote, and the DB can only be equal to it or behind it, so a reconcile
    // read can never improve this value and can easily make it worse. Remote
    // changes still arrive the normal way: the next `loadForServer` from a
    // server event is no longer suppressed once the guard clears.
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
/// the sidebar renders unplaced channels (alphabetical by name), and with
/// references to channels that no longer exist dropped.
///
/// Normalising before a write is what keeps "what the sidebar shows" and
/// "what the layout says" the same thing. ONE definition, shared by the
/// sidebar's context menus and the Channels settings editor, so the two can
/// never disagree about where an unplaced channel belongs.
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

/// [effectiveLayoutFrom] over a raw layout JSON string.
List<LayoutItem> effectiveLayout(
        String layoutJson, Map<String, ChannelInfo> channels) =>
    effectiveLayoutFrom(parseLayoutJson(layoutJson), channels);

final channelLayoutProvider =
    NotifierProvider<ChannelLayoutNotifier, String>(ChannelLayoutNotifier.new);

/// Returns the first text channel ID in visual sidebar order, or null if none.
/// Mirrors the sidebar rendering: placed channels (layout order) first,
/// then unplaced channels (alphabetical).
String? firstTextChannelInLayout(
    Map<String, ChannelInfo> channels, String layoutJson) {
  // The effective layout IS sidebar order — placed channels first, then the
  // rest alphabetically — so "first in the sidebar" is one walk, not a second
  // copy of the ordering rule that can drift from it.
  for (final item in effectiveLayout(layoutJson, channels)) {
    if (item is! ChannelItem) continue;
    final channel = channels[item.channelId];
    if (channel != null && channel.channelType == ChannelType.text) {
      return item.channelId;
    }
  }
  return null;
}
