/// The self-curated profile showcase board (see reports/PROFILE_SHOWCASE_BOARD.md).
///
/// A board is two optional columns of composable blocks flanking the profile
/// center card. The whole structure serializes to one JSON string stored in
/// the user's profile (`showcase_board` field) and replicates with it —
/// everything here was PUT here by the user; nothing is auto-detected.
///
/// Layout rule: neither side filled → center card only; right only →
/// two-column; both → three-column.
library;

import 'dart:convert';

/// Block types this client knows how to render/compose.
///
/// Wire ids are stable strings — never renumber. Unknown ids from newer
/// clients are preserved on round-trip (see [ShowcaseBlock.unknown]) so an
/// older client editing its own board can't destroy newer blocks.
///
/// PRIVACY RULE (Vitalik, 2026-07-07): NO relational/shared-graph blocks
/// (mutual servers, mutual friends, or anything enumerating what a viewer
/// shares with the owner) — same surveillance species as Discovery. Any such
/// block needs his explicit sign-off first.
enum ShowcaseBlockType {
  /// Free-form text: `{title?, body}`. Rendered via the chat text parser —
  /// NEVER remote images/fetches (receivers never phone home).
  text('text'),

  /// One manually-set present-tense game: `{name, cover?, year?}`.
  /// NEVER auto-detected — the user pressed a button.
  nowPlaying('now_playing'),

  /// One game + a personal blurb: `{name, cover?, year?, blurb?}`.
  favoriteGame('favorite_game'),

  /// A cover grid: `{label?, games: [{name, cover?}]}`.
  gameShelf('game_shelf'),

  /// User-uploaded image/GIF: `{image, caption?}`. The image is an asset
  /// hash — replicated bytes, never a remote hotlink.
  artwork('artwork'),

  /// A block id this client version doesn't understand (newer client).
  unknown('');

  final String wireId;
  const ShowcaseBlockType(this.wireId);

  static ShowcaseBlockType fromWireId(String id) {
    for (final t in values) {
      if (t != unknown && t.wireId == id) return t;
    }
    return unknown;
  }
}

/// One composed block. [data] is the type-specific payload; for [unknown]
/// blocks [raw] holds the untouched JSON map so it survives re-encoding.
class ShowcaseBlock {
  final ShowcaseBlockType type;
  final Map<String, dynamic> data;

  /// Original JSON for unknown types (round-trip preservation).
  final Map<String, dynamic>? raw;

  const ShowcaseBlock({required this.type, this.data = const {}, this.raw});

  factory ShowcaseBlock.fromJson(Map<String, dynamic> json) {
    final type = ShowcaseBlockType.fromWireId(json['t'] as String? ?? '');
    if (type == ShowcaseBlockType.unknown) {
      return ShowcaseBlock(type: type, raw: json);
    }
    return ShowcaseBlock(
      type: type,
      data: (json['d'] as Map<String, dynamic>?) ?? const {},
    );
  }

  Map<String, dynamic> toJson() {
    if (type == ShowcaseBlockType.unknown) return raw ?? const {'t': ''};
    return {'t': type.wireId, if (data.isNotEmpty) 'd': data};
  }

  // Text block accessors.
  String get textTitle => (data['title'] as String?) ?? '';
  String get textBody => (data['body'] as String?) ?? '';

  // Game block accessors (nowPlaying / favoriteGame).
  String get gameName => (data['name'] as String?) ?? '';
  String get coverHash => (data['cover'] as String?) ?? '';
  int? get gameYear => data['year'] as int?;
  String get gameBlurb => (data['blurb'] as String?) ?? '';

  // Game shelf accessors.
  String get shelfLabel => (data['label'] as String?) ?? '';
  List<Map<String, dynamic>> get shelfGames =>
      ((data['games'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  // Artwork accessors.
  String get artworkHash => (data['image'] as String?) ?? '';
  String get artworkCaption => (data['caption'] as String?) ?? '';

  /// Asset hashes this block references (for bundle pruning at save).
  Iterable<String> get referencedAssetHashes sync* {
    switch (type) {
      case ShowcaseBlockType.nowPlaying:
      case ShowcaseBlockType.favoriteGame:
        if (coverHash.isNotEmpty) yield coverHash;
      case ShowcaseBlockType.gameShelf:
        for (final g in shelfGames) {
          final c = g['cover'] as String?;
          if (c != null && c.isNotEmpty) yield c;
        }
      case ShowcaseBlockType.artwork:
        if (artworkHash.isNotEmpty) yield artworkHash;
      case ShowcaseBlockType.text:
      case ShowcaseBlockType.unknown:
        break;
    }
  }
}

class ShowcaseBoard {
  /// Hard bounds keeping the dialog sane and the profile blob small.
  static const int maxBlocksPerSide = 4;
  static const int maxTextTitleLength = 64;
  static const int maxTextBodyLength = 1000;

  /// Cap on the encoded JSON (enforced at save). Text-only blocks land far
  /// below this; it's a guard against a hand-crafted profile bloating the
  /// announce path.
  static const int maxEncodedLength = 8 * 1024;

  /// Max games in one shelf block.
  static const int maxShelfGames = 8;

  final List<ShowcaseBlock> left;
  final List<ShowcaseBlock> right;

  const ShowcaseBoard({this.left = const [], this.right = const []});

  /// All asset hashes referenced by any block on either side.
  Set<String> referencedAssetHashes() => {
        for (final b in left) ...b.referencedAssetHashes,
        for (final b in right) ...b.referencedAssetHashes,
      };

  bool get isEmpty => left.isEmpty && right.isEmpty;
  bool get hasLeft => left.isNotEmpty;
  bool get hasRight => right.isNotEmpty;

  /// Tolerant decode: empty/invalid input → empty board (today's profile).
  static ShowcaseBoard decode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const ShowcaseBoard();
    try {
      final json = jsonDecode(encoded);
      if (json is! Map<String, dynamic>) return const ShowcaseBoard();
      List<ShowcaseBlock> side(String key) {
        final list = json[key];
        if (list is! List) return const [];
        return list
            .whereType<Map<String, dynamic>>()
            .map(ShowcaseBlock.fromJson)
            .take(maxBlocksPerSide)
            .toList();
      }

      return ShowcaseBoard(left: side('left'), right: side('right'));
    } catch (_) {
      return const ShowcaseBoard();
    }
  }

  String encode() {
    if (isEmpty) return '';
    return jsonEncode({
      'v': 1,
      if (left.isNotEmpty) 'left': left.map((b) => b.toJson()).toList(),
      if (right.isNotEmpty) 'right': right.map((b) => b.toJson()).toList(),
    });
  }

  ShowcaseBoard copyWith({List<ShowcaseBlock>? left, List<ShowcaseBlock>? right}) =>
      ShowcaseBoard(left: left ?? this.left, right: right ?? this.right);
}
