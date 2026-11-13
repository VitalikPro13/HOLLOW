import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;

/// [serverListProvider]'s load, kept apart so its many readers keep the map.
/// The same shape as `ListLoadState` in friends_provider.dart.
final serverListLoadStateProvider =
    StateProvider<({bool loaded, Object? error})>(
        (_) => (loaded: false, error: null));

/// Manages the list of servers the user has joined.
class ServerListNotifier extends Notifier<Map<String, ServerInfo>> {
  @override
  Map<String, ServerInfo> build() {
    // A phone's hold drops flagged servers at once and lists them again from
    // Rust once it ends.
    ref.listen(ageGateProvider.select((g) => g.held), (was, held) {
      if (held) {
        refilter();
      } else if (was == true) {
        loadFromDb();
      }
    });
    return {};
  }

  /// Whether a server may be listed on this device. Rust already leaves hidden
  /// servers out; this is the second layer for anything that inserts on an event.
  bool _shown(String serverId, {bool isNsfw = false}) =>
      ref.read(ageGateProvider).lists(serverId, isNsfw: isNsfw);

  Map<String, ServerInfo> get _unlisted => ref.read(_unlistedServersProvider);

  set _unlisted(Map<String, ServerInfo> next) =>
      ref.read(_unlistedServersProvider.notifier).state = next;

  /// Drop what the gate no longer lists, at once and without a database read, so
  /// the next frame (or the app switcher's snapshot) never shows it.
  void refilter() {
    final unlisted = Map.of(_unlisted);
    final kept = Map.of(state)
      ..removeWhere((id, s) {
        if (_shown(id, isNsfw: s.isNsfw)) return false;
        unlisted[id] = s;
        return true;
      });
    if (kept.length == state.length) return;
    // Held before listed-no-more, so no reader sees the server in neither.
    _unlisted = unlisted;
    state = kept;
  }

  /// A server's name for a notification. The hold is about what the screen shows,
  /// so a server only the hold keeps off the list is still named.
  String? nameOf(String serverId) {
    final listed = state[serverId];
    if (listed != null) return listed.name;
    final held = _unlisted[serverId];
    if (held == null) return null;
    final unheld = ref.read(ageGateProvider).withHeld(false);
    return unheld.lists(serverId, isNsfw: held.isNsfw) ? held.name : null;
  }

  /// Load servers from the local DB (called on startup).
  Future<void> loadFromDb() async {
    final load = ref.read(serverListLoadStateProvider.notifier);
    // A retry reads as loading again, not as the failure it follows.
    if (load.state.error != null) load.state = (loaded: false, error: null);
    try {
      await ref.read(ageGateProvider.notifier).load();
      final servers = await crdt_api.getJoinedServers();
      final map = <String, ServerInfo>{};
      final unlisted = <String, ServerInfo>{};
      for (final s in servers) {
        final info = ServerInfo(
          serverId: s.serverId,
          name: s.name,
          memberCount: s.memberCount,
          channelCount: s.channelCount,
          isNsfw: s.isNsfw,
        );
        (_shown(s.serverId, isNsfw: s.isNsfw) ? map : unlisted)[s.serverId] = info;
      }
      _unlisted = unlisted;
      state = map;
      load.state = (loaded: true, error: null);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load servers: $e');
      // A list already on screen stays; only one never read fails.
      if (!load.state.loaded) load.state = (loaded: false, error: e);
    }
  }

  /// Called when a ServerCreated/ServerJoined event arrives.
  ///
  /// Inserts UNCONDITIONALLY, never depending on a DB read finding it (that weak
  /// path failed when a sibling re-synced). Optimistic 1/1 counts show at once so
  /// the icon appears; a background DB read then corrects them.
  void onServerCreated(String serverId, String name) {
    // A phone that hides age-restricted servers lists one only once Rust does: it
    // cannot know yet what a server it just joined is.
    final gate = ref.read(ageGateProvider);
    if (!gate.allowedHere || gate.held) {
      onServerUpdated(serverId);
      return;
    }
    final updated = Map.of(state);
    final existing = updated[serverId];
    updated[serverId] = ServerInfo(
      serverId: serverId,
      name: name,
      // Keep real counts if we already had them; else optimistic 1/1.
      memberCount: existing?.memberCount ?? 1,
      channelCount: existing?.channelCount ?? 1, // #general
      isNsfw: existing?.isNsfw ?? false,
    );
    state = updated;
    // Correct the counts (and name) from the DB without blocking the insert.
    _refreshCountsFromDb(serverId, name);
  }

  /// Background: pull real member/channel counts for [serverId] from the DB and
  /// patch the list entry. No-op if the server isn't (yet) in the DB.
  Future<void> _refreshCountsFromDb(String serverId, String fallbackName) async {
    try {
      final servers = await crdt_api.getJoinedServers();
      final match = servers.where((s) => s.serverId == serverId).firstOrNull;
      if (match == null) return; // not in DB yet — keep optimistic entry
      final updated = Map.of(state);
      updated[serverId] = ServerInfo(
        serverId: match.serverId,
        name: match.name.isNotEmpty ? match.name : fallbackName,
        memberCount: match.memberCount,
        channelCount: match.channelCount,
        isNsfw: match.isNsfw,
      );
      state = updated;
    } catch (_) {
      // Keep the optimistic entry on any failure.
    }
  }

  /// Called when a ServerUpdated event arrives — full reload from DB.
  Future<void> onServerUpdated(String serverId) async {
    try {
      final servers = await crdt_api.getJoinedServers();
      final match = servers.where((s) => s.serverId == serverId).firstOrNull;
      final listed = Map.of(state)..remove(serverId);
      final unlisted = Map.of(_unlisted)..remove(serverId);
      // A server gone from Rust's list was left, kicked or deleted while offline.
      if (match != null) {
        final info = ServerInfo(
          serverId: match.serverId,
          name: match.name,
          memberCount: match.memberCount,
          channelCount: match.channelCount,
          isNsfw: match.isNsfw,
        );
        (_shown(serverId, isNsfw: match.isNsfw) ? listed : unlisted)[serverId] =
            info;
      }
      _unlisted = unlisted;
      state = listed;
    } catch (e) {
      debugPrint('[HOLLOW] Failed to refresh server $serverId: $e');
    }
  }

  /// Called when a ServerDeleted event arrives.
  void onServerDeleted(String serverId) {
    _unlisted = Map.of(_unlisted)..remove(serverId);
    state = Map.of(state)..remove(serverId);
  }
}

/// What [ServerListNotifier] holds but does not list; written only by it.
final _unlistedServersProvider =
    StateProvider<Map<String, ServerInfo>>((ref) => const {});

/// Joined servers only the phone's hold keeps off the list: the gate itself
/// would list them, so the person never left them and they still count.
final heldServersProvider = Provider<Map<String, ServerInfo>>((ref) {
  final unheld = ref.watch(ageGateProvider).withHeld(false);
  return {
    for (final e in ref.watch(_unlistedServersProvider).entries)
      if (unheld.lists(e.key, isNsfw: e.value.isNsfw)) e.key: e.value,
  };
});

/// The servers the person is in on this device: listed or held. Read this, not
/// [serverListProvider], where a held server must not look left (a page open
/// on it, first-run checks, per-server settings, the call bar).
final keptServersProvider = Provider<Map<String, ServerInfo>>((ref) {
  final held = ref.watch(heldServersProvider);
  final listed = ref.watch(serverListProvider);
  return held.isEmpty ? listed : {...listed, ...held};
});

/// The phone is holding back a flagged server it would otherwise list.
final ageHoldHidesServersProvider = Provider<bool>((ref) =>
    ref.watch(ageGateProvider.select((g) => g.held)) &&
    ref.watch(heldServersProvider).values.any((s) => s.isNsfw));

final serverListProvider =
    NotifierProvider<ServerListNotifier, Map<String, ServerInfo>>(
        ServerListNotifier.new);

/// Currently selected server ID.
final selectedServerProvider = StateProvider<String?>((ref) => null);

/// Whether the server settings panel is open (replaces chat pane).
final serverSettingsOpenProvider = StateProvider<bool>((ref) => false);

/// Sync status for a server's message sync process.
enum ServerSyncStatus { idle, connecting, syncing, synced, retrying, failed }

/// Manages per-server sync status.
class SyncStatusNotifier extends Notifier<Map<String, ServerSyncStatus>> {
  @override
  Map<String, ServerSyncStatus> build() => {};

  void setStatus(String serverId, ServerSyncStatus status) {
    final updated = Map.of(state);
    updated[serverId] = status;
    state = updated;
  }
}

final syncStatusProvider =
    NotifierProvider<SyncStatusNotifier, Map<String, ServerSyncStatus>>(
        SyncStatusNotifier.new);

/// Convenience: read the sync status for a single server.
final serverSyncStatusProvider =
    Provider.family<ServerSyncStatus, String>((ref, serverId) {
  return ref.watch(syncStatusProvider)[serverId] ?? ServerSyncStatus.idle;
});

/// Fetches server members on demand. Invalidate to force refresh.
final serverMembersProvider =
    FutureProvider.family<List<crdt_api.MemberFfi>, String>(
  (ref, serverId) => crdt_api.getServerMembers(serverId: serverId),
);

/// How full a server is as join admission counts it (Rust `member_cap`): its
/// members, the limit in force and the hard cap. Null without the Rust library.
final serverCapacityProvider = Provider.autoDispose
    .family<crdt_api.ServerCapacityFfi?, String>((ref, serverId) {
  ref.watch(serverMembersProvider(serverId));
  try {
    return crdt_api.serverCapacity(serverId: serverId);
  } catch (_) {
    return null;
  }
});

/// Whether [capacity] says the server takes nobody new.
bool serverIsFull(crdt_api.ServerCapacityFfi? capacity) =>
    capacity != null && capacity.members >= capacity.limit;

/// All labels defined in a server (cosmetic + access). Invalidated on
/// ServerUpdated via the event provider (label CRUD emits it).
final serverLabelsProvider =
    FutureProvider.autoDispose.family<List<crdt_api.LabelFfi>, String>(
  (ref, serverId) => crdt_api.getServerLabels(serverId: serverId),
);

/// Whether a server is flagged NSFW (from CRDT settings). Drives the header
/// badge. Invalidated on ServerUpdated so it reflects a live toggle.
final serverIsNsfwProvider = FutureProvider.family<bool, String>(
  (ref, serverId) async {
    final v = await crdt_api.getServerSetting(serverId: serverId, key: 'is_nsfw');
    return v == 'true';
  },
);

/// Returns the set of online member peer IDs for a server.
///
/// Server members are master-keyed while presence is device-keyed;
/// `onlineIdentitiesProvider` collapses devices to masters and excludes
/// invisible peers, so a member counts as online via any of their devices.
final onlineMembersProvider =
    Provider.family<Set<String>, String>((ref, serverId) {
  final online = ref.watch(onlineIdentitiesProvider);
  final membersAsync = ref.watch(serverMembersProvider(serverId));
  return membersAsync.when(
    data: (members) =>
        members.where((m) => online.contains(m.peerId)).map((m) => m.peerId).toSet(),
    loading: () => {},
    error: (_, _) => {},
  );
});

/// How many members show online, us included the way the member list shows us:
/// our own devices never appear in [onlineIdentitiesProvider].
final onlineMemberCountProvider = Provider.family<int, String>((ref, serverId) {
  final me = ref.watch(identityProvider).peerId;
  final others = ref.watch(onlineMembersProvider(serverId)).where((p) => p != me);
  final members =
      ref.watch(serverMembersProvider(serverId)).valueOrNull ?? const [];
  final meShown = !ref.watch(invisibleModeProvider) &&
      members.any((m) => m.peerId == me);
  return others.length + (meShown ? 1 : 0);
});

/// The local user's role in a server. Invalidated on RoleChanged events.
final myRoleProvider = FutureProvider.family<String, String>(
  (ref, serverId) => crdt_api.getMyRole(serverId: serverId),
);

/// The local user's permissions bitmask in a server.
final myPermissionsProvider = FutureProvider.family<int, String>(
  (ref, serverId) => crdt_api.getMyPermissions(serverId: serverId),
);

/// Extracts nicknames from server members: peerId → nickname (non-empty only).
final serverNicknamesProvider =
    Provider.family<Map<String, String>, String>((ref, serverId) {
  final membersAsync = ref.watch(serverMembersProvider(serverId));
  return membersAsync.when(
    data: (members) {
      final map = <String, String>{};
      for (final m in members) {
        if (m.nickname.isNotEmpty) {
          map[m.peerId] = m.nickname;
        }
      }
      return map;
    },
    loading: () => {},
    error: (_, _) => {},
  );
});

/// Memoized set of display names for all members in a server, used by
/// MessageText for @mention highlighting. Computed once per server.
final serverMemberNamesProvider =
    Provider.family<Set<String>?, String>((ref, serverId) {
  final membersAsync = ref.watch(serverMembersProvider(serverId));
  final profiles = ref.watch(profileProvider);
  final nicknames = ref.watch(serverNicknamesProvider(serverId));
  return membersAsync.whenOrNull(
    data: (members) {
      final names = <String>{};
      for (final m in members) {
        final displayName = serverDisplayNameFor(
          profiles,
          m.peerId,
          nickname: nicknames[m.peerId] ?? '',
        );
        names.add(displayName);
        if (m.nickname.isNotEmpty) names.add(m.nickname);
        final profile = profiles[m.peerId];
        if (profile != null && profile.displayName.isNotEmpty) {
          names.add(profile.displayName);
        }
      }
      return names;
    },
  );
});

/// Permission bitmask constants (must match Rust Permission struct).
class Permission {
  static const int manageServer = 1 << 0;
  static const int manageChannels = 1 << 1;
  static const int manageRoles = 1 << 2;
  static const int kickMembers = 1 << 4;
  static const int sendMessages = 1 << 5;
  static const int readMessages = 1 << 6;
  static const int manageEmotes = 1 << 7;
  static const int all = manageServer |
      manageChannels |
      manageRoles |
      kickMembers |
      sendMessages |
      readMessages |
      manageEmotes;
}
