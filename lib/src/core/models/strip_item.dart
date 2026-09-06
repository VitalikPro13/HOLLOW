/// Data model for server strip layout — servers, folders and parked joins.
sealed class StripItem {
  const StripItem();

  Map<String, dynamic> toJson();

  /// Reads one persisted entry, or null when the kind is unknown.
  ///
  /// Nullable on purpose: the layout JSON is written by whichever build wrote it
  /// last, so a newer client's kind must read as "skip this row", never as a
  /// mis-typed server whose id then gets pruned as deleted.
  static StripItem? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    switch (json['type']) {
      case 'folder':
        final servers = json['servers'];
        if (servers is! List) return null;
        return FolderStripItem(
          id: id,
          name: json['name'] as String? ?? 'Folder',
          serverIds: servers.whereType<String>().toList(),
        );
      case 'pending':
        return PendingStripItem(serverId: id);
      case 'server':
      case null:
        // `null` keeps layouts written before the type key existed readable.
        return ServerStripItem(serverId: id);
      default:
        return null;
    }
  }
}

class ServerStripItem extends StripItem {
  final String serverId;
  const ServerStripItem({required this.serverId});

  @override
  Map<String, dynamic> toJson() => {'type': 'server', 'id': serverId};
}

/// A join request that is parked: we asked to join a server whose members were
/// all offline, and Rust holds the request until one comes back.
///
/// It carries the server id and nothing else, because an invite link is only an
/// id: no name, no icon, and the tile is deliberately not selectable.
class PendingStripItem extends StripItem {
  final String serverId;
  const PendingStripItem({required this.serverId});

  @override
  Map<String, dynamic> toJson() => {'type': 'pending', 'id': serverId};
}

class FolderStripItem extends StripItem {
  final String id;
  final String name;
  final List<String> serverIds;

  const FolderStripItem({
    required this.id,
    required this.name,
    required this.serverIds,
  });

  FolderStripItem copyWith({String? name, List<String>? serverIds}) {
    return FolderStripItem(
      id: id,
      name: name ?? this.name,
      serverIds: serverIds ?? this.serverIds,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'type': 'folder',
        'id': id,
        'name': name,
        'servers': serverIds,
      };
}
