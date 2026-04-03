/// Type of channel within a server.
enum ChannelType { text, voice }

/// Information about a channel within a server.
class ChannelInfo {
  final String channelId;
  final String name;
  final String? category;
  final ChannelType channelType;

  const ChannelInfo({
    required this.channelId,
    required this.name,
    this.category,
    this.channelType = ChannelType.text,
  });

  ChannelInfo copyWith({
    String? channelId,
    String? name,
    String? category,
    ChannelType? channelType,
  }) {
    return ChannelInfo(
      channelId: channelId ?? this.channelId,
      name: name ?? this.name,
      category: category ?? this.category,
      channelType: channelType ?? this.channelType,
    );
  }
}
