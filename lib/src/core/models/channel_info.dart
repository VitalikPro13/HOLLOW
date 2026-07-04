/// Type of channel within a server.
enum ChannelType { text, voice }

/// Information about a channel within a server.
class ChannelInfo {
  final String channelId;
  final String name;
  final String? category;
  final ChannelType channelType;
  final String visibility;
  final String posting;
  final bool isPublic;

  /// Slow mode: minimum seconds between messages per member (0 = off).
  final int slowModeSecs;

  /// Media-only: only images/GIFs/videos (with optional captions) allowed.
  final bool mediaOnly;

  const ChannelInfo({
    required this.channelId,
    required this.name,
    this.category,
    this.channelType = ChannelType.text,
    this.visibility = 'everyone',
    this.posting = 'everyone',
    this.isPublic = false,
    this.slowModeSecs = 0,
    this.mediaOnly = false,
  });

  ChannelInfo copyWith({
    String? channelId,
    String? name,
    String? category,
    ChannelType? channelType,
    String? visibility,
    String? posting,
    bool? isPublic,
    int? slowModeSecs,
    bool? mediaOnly,
  }) {
    return ChannelInfo(
      channelId: channelId ?? this.channelId,
      name: name ?? this.name,
      category: category ?? this.category,
      channelType: channelType ?? this.channelType,
      visibility: visibility ?? this.visibility,
      posting: posting ?? this.posting,
      isPublic: isPublic ?? this.isPublic,
      slowModeSecs: slowModeSecs ?? this.slowModeSecs,
      mediaOnly: mediaOnly ?? this.mediaOnly,
    );
  }
}
