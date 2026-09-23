import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The latest message that mentioned us in one channel, for Home's inbox.
class MentionPreview {
  final String serverId;
  final String channelId;

  /// The sender's MASTER id.
  final String senderId;
  final String text;
  final DateTime at;

  const MentionPreview({
    required this.serverId,
    required this.channelId,
    required this.senderId,
    required this.text,
    required this.at,
  });
}

/// Keyed `"serverId:channelId"`, like `UnreadState.channelMentionCounts`.
///
/// In memory only. The mention COUNT is the source of truth for whether a
/// channel belongs in the inbox; this only adds the words and the time, so a
/// count that survives a restart without its preview still shows, just without
/// them. Readers pair the two rather than this ever being cleared.
class MentionPreviewNotifier extends Notifier<Map<String, MentionPreview>> {
  @override
  Map<String, MentionPreview> build() => const {};

  void record(MentionPreview preview) {
    state = {
      ...state,
      '${preview.serverId}:${preview.channelId}': preview,
    };
  }
}

final mentionPreviewProvider =
    NotifierProvider<MentionPreviewNotifier, Map<String, MentionPreview>>(
        MentionPreviewNotifier.new);
