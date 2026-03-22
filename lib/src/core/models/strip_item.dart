/// Data model for server strip layout — servers and folders.
sealed class StripItem {
  const StripItem();

  Map<String, dynamic> toJson();

  static StripItem fromJson(Map<String, dynamic> json) {
    if (json['type'] == 'folder') {
      return FolderStripItem(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Folder',
        serverIds: List<String>.from(json['servers'] as List),
      );
    }
    return ServerStripItem(serverId: json['id'] as String);
  }
}

class ServerStripItem extends StripItem {
  final String serverId;
  const ServerStripItem({required this.serverId});

  @override
  Map<String, dynamic> toJson() => {'type': 'server', 'id': serverId};
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
