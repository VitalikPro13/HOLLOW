/// Information about a server the user has joined.
class ServerInfo {
  final String serverId;
  final String name;
  final int memberCount;
  final int channelCount;

  /// The owner flagged the server 18+ (shown as an NSFW badge by its name).
  final bool isNsfw;

  const ServerInfo({
    required this.serverId,
    required this.name,
    this.memberCount = 0,
    this.channelCount = 0,
    this.isNsfw = false,
  });

  ServerInfo copyWith({
    String? serverId,
    String? name,
    int? memberCount,
    int? channelCount,
    bool? isNsfw,
  }) {
    return ServerInfo(
      serverId: serverId ?? this.serverId,
      name: name ?? this.name,
      memberCount: memberCount ?? this.memberCount,
      channelCount: channelCount ?? this.channelCount,
      isNsfw: isNsfw ?? this.isNsfw,
    );
  }
}
