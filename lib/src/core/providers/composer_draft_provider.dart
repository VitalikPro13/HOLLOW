import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Unsent composer text per conversation, kept while its pane is off screen
/// (#110). RAM only: a draft is plaintext and never touches the disk.
///
/// Keys are the [ComposerInsert] scope strings. Text is the EXPANDED wire form,
/// so emote and asset tokens survive the composer that drew them.
class ComposerDrafts {
  /// Enough for every conversation someone juggles in one sitting; the oldest
  /// draft goes first.
  static const int capacity = 64;

  final LinkedHashMap<String, String> _byScope = LinkedHashMap();

  String? draftFor(String scope) => _byScope[scope];

  /// Stores [wireText] for [scope], or forgets the draft when nothing but
  /// whitespace is left.
  void keep(String scope, String wireText) {
    _byScope.remove(scope);
    if (wireText.trim().isEmpty) return;
    _byScope[scope] = wireText;
    while (_byScope.length > capacity) {
      _byScope.remove(_byScope.keys.first);
    }
  }
}

final composerDraftsProvider = Provider<ComposerDrafts>((_) => ComposerDrafts());
