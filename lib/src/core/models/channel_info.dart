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

  /// Label gate for visibility (label ids; non-empty = only holders of any
  /// listed access label, plus Admin+/Owner, see the channel).
  final List<String> visibilityLabels;

  /// Label gate for posting; same semantics as [visibilityLabels].
  final List<String> postingLabels;

  /// Whether the LOCAL user can see / post in this channel, computed by Rust
  /// with the full predicate (tier ladder + label gates + unexpired grants +
  /// SEND_MESSAGES). Dart must never re-implement that ladder. Defaults to true
  /// for optimistically-constructed instances.
  final bool meCanSee;
  final bool meCanPost;

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
    this.visibilityLabels = const [],
    this.postingLabels = const [],
    this.meCanSee = true,
    this.meCanPost = true,
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
    List<String>? visibilityLabels,
    List<String>? postingLabels,
    bool? meCanSee,
    bool? meCanPost,
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
      visibilityLabels: visibilityLabels ?? this.visibilityLabels,
      postingLabels: postingLabels ?? this.postingLabels,
      meCanSee: meCanSee ?? this.meCanSee,
      meCanPost: meCanPost ?? this.meCanPost,
    );
  }
}
