/// Information about a channel within a server.
class ChannelInfo {
  final String channelId;
  final String name;
  final String? category;

  const ChannelInfo({
    required this.channelId,
    required this.name,
    this.category,
  });

  ChannelInfo copyWith({
    String? channelId,
    String? name,
    String? category,
  }) {
    return ChannelInfo(
      channelId: channelId ?? this.channelId,
      name: name ?? this.name,
      category: category ?? this.category,
    );
  }
}
