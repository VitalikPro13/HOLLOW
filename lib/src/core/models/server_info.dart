/// Information about a server the user has joined.
class ServerInfo {
  final String serverId;
  final String name;
  final int memberCount;
  final int channelCount;

  const ServerInfo({
    required this.serverId,
    required this.name,
    this.memberCount = 0,
    this.channelCount = 0,
  });

  ServerInfo copyWith({
    String? serverId,
    String? name,
    int? memberCount,
    int? channelCount,
  }) {
    return ServerInfo(
      serverId: serverId ?? this.serverId,
      name: name ?? this.name,
      memberCount: memberCount ?? this.memberCount,
      channelCount: channelCount ?? this.channelCount,
    );
  }
}
