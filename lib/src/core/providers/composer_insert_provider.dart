import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A one-shot request to drop text into a chat composer (issue #61, phase 3).
///
/// The "Mention" row of the user context menu is opened from surfaces that
/// have no reference to the composer at all — the member panel, a voice
/// participant row, a sender name inside a message. Rather than thread a
/// controller through all of them, the menu posts a request here and whichever
/// composer owns [scope] picks it up.
///
/// [scope] is what keeps it from landing in the wrong box: a channel composer
/// accepts only `serverId:channelId`, a DM composer only `dm:peerId`. In split
/// view two composers are mounted at once and exactly one of them matches.
@immutable
class ComposerInsert {
  /// `serverId:channelId` for a channel, `dm:peerId` for a direct message.
  final String scope;

  /// Text to append, already including any trailing space it wants.
  final String text;

  /// Bumped on every request so two identical mentions in a row are two
  /// events rather than one no-op — the composer compares this, not the text.
  final int seq;

  const ComposerInsert({
    required this.scope,
    required this.text,
    required this.seq,
  });

  /// The scope string for a channel composer.
  static String channelScope(String serverId, String channelId) =>
      '$serverId:$channelId';

  /// The scope string for a DM composer.
  static String dmScope(String peerId) => 'dm:$peerId';
}

class ComposerInsertNotifier extends Notifier<ComposerInsert?> {
  int _seq = 0;

  @override
  ComposerInsert? build() => null;

  /// Asks the composer owning [scope] to append [text].
  ///
  /// Fire and forget: nothing happens when no composer matches, which is the
  /// right outcome for a menu row opened while the chat is not on screen.
  void request(String scope, String text) {
    state = ComposerInsert(scope: scope, text: text, seq: ++_seq);
  }
}

final composerInsertProvider =
    NotifierProvider<ComposerInsertNotifier, ComposerInsert?>(
  ComposerInsertNotifier.new,
);
