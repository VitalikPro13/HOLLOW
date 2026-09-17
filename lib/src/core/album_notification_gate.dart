import 'dart:async';
import 'dart:collection';

import 'package:hollow/src/core/message_preview.dart';
import 'package:hollow/src/core/message_tokens.dart';

/// Folds an album's arrivals into ONE notification: one surface per message,
/// and an album is the message here.
///
/// The first item waits [window] for its siblings, which normally land within
/// the same second; items after the notification fired are swallowed.
class AlbumNotificationGate {
  AlbumNotificationGate({this.window = const Duration(milliseconds: 1500)});

  final Duration window;
  final Map<String, _HeldAlbum> _held = {};
  final LinkedHashSet<String> _fired = LinkedHashSet();
  static const _firedCap = 64;

  /// Notifies [text] now for a lone message. For an album item, the one
  /// notification per [conversation] (which must name the sender too) fires
  /// after the window with [textFor] given the caption and item count.
  void offer({
    required String? albumId,
    required String conversation,
    required String text,
    required void Function(String text) fire,
    String Function(String caption, int count)? textFor,
  }) {
    if (albumId == null || albumId.isEmpty) {
      fire(text);
      return;
    }
    final key = '$conversation|$albumId';
    if (_fired.contains(key)) return;
    final held = _held[key];
    if (held != null) {
      held.count++;
      held.absorb(text);
      return;
    }
    final album = _HeldAlbum(text);
    _held[key] = album;
    album.timer = Timer(window, () {
      _held.remove(key);
      _fired.add(key);
      if (_fired.length > _firedCap) _fired.remove(_fired.first);
      fire(album.count == 1
          ? album.text
          : (textFor ?? albumNotificationText)(album.text, album.count));
    });
  }

  void dispose() {
    for (final h in _held.values) {
      h.timer?.cancel();
    }
    _held.clear();
  }
}

/// "4 files", or the album's caption when it has one.
String albumNotificationText(String caption, int count) {
  final words = messagePreviewText(caption.replaceAll(fileTokenRegex, ''));
  return words.isNotEmpty ? words : '$count files';
}

class _HeldAlbum {
  _HeldAlbum(this.text);

  /// The caption when one arrived, else the first item's text.
  String text;
  int count = 1;
  Timer? timer;

  void absorb(String other) {
    bool hasWords(String t) => t.replaceAll(fileTokenRegex, '').trim().isNotEmpty;
    if (!hasWords(text) && hasWords(other)) text = other;
  }
}
