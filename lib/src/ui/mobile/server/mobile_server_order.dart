import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';

/// The phone's one server order (#154), shared by the Servers tab and the
/// switcher sheet so the two never disagree.

/// The servers a phone lists, id to name: never one the age gate hides here.
Map<String, String> mobileListedServers(WidgetRef ref) {
  final servers = ref.watch(serverListProvider);
  return {
    for (final MapEntry(key: id, value: server) in servers.entries)
      if (!ref.watch(serverAgeHiddenProvider(id))) id: server.name,
  };
}

/// One line of the Servers list, in dock order.
sealed class MobileServersEntry {
  const MobileServersEntry();
}

/// A dock folder's name, over the servers inside it.
class MobileServersFolder extends MobileServersEntry {
  final String folderId;
  final String name;
  const MobileServersFolder(this.folderId, this.name);
}

/// The end of a folder's servers, before servers that sit in no folder.
class MobileServersFolderEnd extends MobileServersEntry {
  final String folderId;
  const MobileServersFolderEnd(this.folderId);
}

class MobileServersServer extends MobileServersEntry {
  final String serverId;
  const MobileServersServer(this.serverId);
}

/// A join we asked for that nobody has answered yet.
class MobileServersPending extends MobileServersEntry {
  final String serverId;
  const MobileServersPending(this.serverId);
}

/// The Servers list in the dock's order: [layout] first (a folder is a header
/// over its servers), then listed servers the layout has not caught up with
/// (by name, as the switcher sheet orders them) and parked joins. Only
/// [listed] servers (id to name) show, so one the phone hides never does.
List<MobileServersEntry> mobileServersEntries({
  required List<StripItem> layout,
  required Map<String, String> listed,
  required Iterable<String> pending,
}) {
  final listedIds = listed.keys.toSet();
  final pendingIds = pending.where((id) => !listedIds.contains(id)).toSet();
  final seen = <String>{};
  final out = <MobileServersEntry>[];
  String? openFolder;

  void loose(MobileServersEntry entry) {
    if (openFolder != null) {
      out.add(MobileServersFolderEnd(openFolder!));
      openFolder = null;
    }
    out.add(entry);
  }

  for (final item in layout) {
    switch (item) {
      case ServerStripItem(:final serverId):
        if (listedIds.contains(serverId) && seen.add(serverId)) {
          loose(MobileServersServer(serverId));
        }
      case PendingStripItem(:final serverId):
        if (pendingIds.contains(serverId) && seen.add(serverId)) {
          loose(MobileServersPending(serverId));
        }
      case FolderStripItem(:final id, :final name, :final serverIds):
        final inside = [
          for (final serverId in serverIds)
            if (listedIds.contains(serverId) && seen.add(serverId)) serverId,
        ];
        if (inside.isEmpty) continue;
        out.add(MobileServersFolder(id, name));
        out.addAll(inside.map(MobileServersServer.new));
        openFolder = id;
    }
  }
  final rest = listedIds.where((id) => !seen.contains(id)).toList()
    ..sort((a, b) => listed[a]!.toLowerCase().compareTo(listed[b]!.toLowerCase()));
  for (final id in rest) {
    seen.add(id);
    loose(MobileServersServer(id));
  }
  for (final id in pendingIds) {
    if (seen.add(id)) loose(MobileServersPending(id));
  }
  return out;
}

/// The listed servers in the Servers tab's order, folders flattened and
/// parked joins left out: the switcher sheet's rows.
List<String> mobileServerOrder(WidgetRef ref) => [
      for (final entry in mobileServersEntries(
        layout: ref.watch(serverStripLayoutProvider),
        listed: mobileListedServers(ref),
        pending: const [],
      ))
        if (entry is MobileServersServer) entry.serverId,
    ];
