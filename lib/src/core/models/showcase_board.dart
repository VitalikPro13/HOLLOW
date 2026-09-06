/// The self-curated profile showcase board (reports/PROFILE_SHOWCASE_BOARD.md).
///
/// Two optional columns of composable blocks flanking the profile center card,
/// serialized to one JSON string in the profile's `showcase_board` field.
/// Everything here was PUT here by the user; nothing is auto-detected.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Block types this client knows how to render/compose. Wire ids are stable
/// strings, never renumbered; unknown ids from newer clients are preserved on
/// round-trip (see [ShowcaseBlock.unknown]).
///
/// PRIVACY RULE: NO relational/shared-graph blocks (mutual servers or friends).
enum ShowcaseBlockType {
  /// Free-form text: `{title?, body}`. Rendered via the chat text parser —
  /// NEVER remote images/fetches (receivers never phone home).
  text('text'),

  /// One manually-set present-tense game. NEVER auto-detected: the user pressed a button.
  nowPlaying('now_playing'),

  /// One game + a personal blurb: `{name, cover?, year?, blurb?}`.
  favoriteGame('favorite_game'),

  /// A cover grid: `{label?, games: [{name, cover?}]}`.
  gameShelf('game_shelf'),

  /// User-uploaded image/GIF. The image is an asset hash: replicated bytes, never a hotlink.
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

/// Steam's own review verdict, baked at authoring from the appreviews summary
/// ("Very Positive", 94% of 512,431). A snapshot, not live data.
class SteamReviews {
  final String label;
  final int positive;
  final int total;

  const SteamReviews({
    required this.label,
    required this.positive,
    required this.total,
  });

  /// 0-100, rounded.
  int get percent => total > 0 ? ((positive / total) * 100).round() : 0;

  static SteamReviews? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final label = (json['label'] as String?) ?? '';
    final total = (json['total'] as int?) ?? 0;
    if (label.isEmpty || total <= 0) return null;
    return SteamReviews(
      label: label,
      positive: (json['pos'] as int?) ?? 0,
      total: total,
    );
  }
}

/// IGDB's aggregated time-to-beat (seconds). `normally` = main story at a
/// normal pace (falls back to `hastily`), `completely` = 100% run.
class TimeToBeat {
  final int? hastily;
  final int? normally;
  final int? completely;

  const TimeToBeat({this.hastily, this.normally, this.completely});

  int? get storySeconds => normally ?? hastily;
  bool get isEmpty => storySeconds == null && completely == null;

  static TimeToBeat? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    int? sec(String k) {
      final v = json[k];
      return v is int && v > 0 ? v : null;
    }

    final t = TimeToBeat(
      hastily: sec('hastily'),
      normally: sec('normally'),
      completely: sec('completely'),
    );
    return t.isEmpty ? null : t;
  }

  /// "34h" / "12.5h" / "45m" from a seconds value.
  static String hoursLabel(int seconds) {
    if (seconds < 3600) return '${(seconds / 60).round()}m';
    final h = seconds / 3600;
    return h >= 10 ? '${h.round()}h' : '${(h * 2).round() / 2}h';
  }
}

/// A dev/publisher credit inside a game's baked details. [logoHash] references
/// replicated bytes in the profile's asset bundle, not a URL; [links] are the
/// company's own URLs, opened only on tap. Companies are DEDUPED server-side.
class GameCompany {
  final String name;

  /// "dev", "pub", or "devpub".
  final String role;

  /// Asset hash of the company logo (empty when none).
  final String logoHash;

  /// `[{kind, url}]` — kind is a link type slug (twitter/discord/official/…).
  final List<Map<String, String>> links;

  const GameCompany({
    required this.name,
    required this.role,
    this.logoHash = '',
    this.links = const [],
  });

  String get roleLabel => switch (role) {
        'devpub' => 'Developer · Publisher',
        'pub' => 'Publisher',
        _ => 'Developer',
      };

  factory GameCompany.fromJson(Map<String, dynamic> json) => GameCompany(
        name: (json['name'] as String?) ?? '',
        role: (json['role'] as String?) ?? 'dev',
        logoHash: (json['logo'] as String?) ?? '',
        links: ((json['links'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((l) => {
                  'kind': (l['kind'] as String?) ?? '',
                  'url': (l['url'] as String?) ?? '',
                })
            .where((l) => l['url']!.isNotEmpty)
            .toList(),
      );
}

/// Replicated game-card metadata, baked at authoring time. Everything is plain
/// data: a viewer opening the card fetches NOTHING.
///
/// Details live in the ASSET BUNDLE as a content-addressed JSON asset and the
/// block stores just the hash, so the board text stays tiny. Legacy inline maps parse.
class GameDetails {
  final String description;
  final String reqMin;
  final String reqRec;
  final String releaseDate;

  /// One-line copyright (Steam `legal_notice`, cleaned server-side).
  final String copyright;
  final int? metacritic;
  final int? achievements;

  /// Platform slugs: pc/mac/linux/playstation/xbox/nintendo/android/ios.
  final List<String> platforms;

  /// Genre names ("Shooter", "Adventure", …) — the card's Info row.
  final List<String> genres;

  /// Store URLs keyed by store slug; desktop chips link to `steam`.
  final Map<String, String> stores;
  final List<GameCompany> companies;

  /// Steam's review verdict at bake time (null: no Steam presence).
  final SteamReviews? steamReviews;

  /// IGDB time-to-beat aggregate (null: no community data).
  final TimeToBeat? timeToBeat;

  /// IGDB theme names ("Fantasy", "Horror", …) — chips next to genres.
  final List<String> themes;

  /// IGDB game-mode names ("Single player", "Co-operative", …).
  final List<String> modes;

  /// Series name ("Dark Souls") — IGDB franchises/collections.
  final String franchise;

  const GameDetails({
    this.description = '',
    this.reqMin = '',
    this.reqRec = '',
    this.releaseDate = '',
    this.copyright = '',
    this.metacritic,
    this.achievements,
    this.platforms = const [],
    this.genres = const [],
    this.stores = const {},
    this.companies = const [],
    this.steamReviews,
    this.timeToBeat,
    this.themes = const [],
    this.modes = const [],
    this.franchise = '',
  });

  /// True when there's genuinely nothing worth showing on a card.
  bool get isEmpty =>
      description.isEmpty &&
      reqMin.isEmpty &&
      reqRec.isEmpty &&
      releaseDate.isEmpty &&
      copyright.isEmpty &&
      metacritic == null &&
      achievements == null &&
      platforms.isEmpty &&
      genres.isEmpty &&
      stores.isEmpty &&
      companies.isEmpty &&
      steamReviews == null &&
      timeToBeat == null &&
      themes.isEmpty &&
      modes.isEmpty &&
      franchise.isEmpty;

  bool get hasRequirements => reqMin.isNotEmpty || reqRec.isNotEmpty;

  static GameDetails? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final companies = ((json['companies'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GameCompany.fromJson)
        .toList();
    // Legacy v6 bakes carried a flat developer name instead of companies.
    final flatDev = (json['developer'] as String?) ?? '';
    if (companies.isEmpty && flatDev.isNotEmpty) {
      companies.add(GameCompany(name: flatDev, role: 'dev'));
    }
    final d = GameDetails(
      description: (json['description'] as String?) ?? '',
      reqMin: (json['req_min'] as String?) ?? '',
      reqRec: (json['req_rec'] as String?) ?? '',
      releaseDate: (json['release_date'] as String?) ?? '',
      copyright: (json['legal'] as String?) ?? '',
      metacritic: json['metacritic'] as int?,
      achievements: json['achievements'] as int?,
      platforms: ((json['platforms'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      genres: ((json['genres'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      stores: {
        for (final e in ((json['stores'] as Map?) ?? const {}).entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      },
      companies: companies,
      steamReviews: SteamReviews.fromJson(
        json['steam_reviews'] is Map<String, dynamic>
            ? json['steam_reviews'] as Map<String, dynamic>
            : null,
      ),
      timeToBeat: TimeToBeat.fromJson(
        json['ttb'] is Map<String, dynamic>
            ? json['ttb'] as Map<String, dynamic>
            : null,
      ),
      themes: ((json['themes'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      modes: ((json['modes'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      franchise: (json['franchise'] as String?) ?? '',
    );
    return d.isEmpty ? null : d;
  }

  /// Resolve a block/shelf `details` field: a String is a content-addressed asset
  /// hash, a Map is legacy inline details. Anything malformed yields null.
  static GameDetails? resolve(dynamic field, Map<String, Uint8List> assets) {
    if (field is Map<String, dynamic>) return fromJson(field);
    if (field is String && field.isNotEmpty) {
      final bytes = assets[field];
      if (bytes == null || bytes.isEmpty) return null;
      try {
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is Map<String, dynamic>) return fromJson(decoded);
      } catch (_) {}
    }
    return null;
  }

  /// Company-logo hashes referenced from a details ASSET's bytes, used at save
  /// time so pruning keeps logos alive. Non-JSON bytes simply yield nothing.
  static Iterable<String> logoHashesFromBytes(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) return const [];
      return ((decoded['companies'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map((c) => (c['logo'] as String?) ?? '')
          .where((h) => h.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
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

  String get textTitle => (data['title'] as String?) ?? '';
  String get textBody => (data['body'] as String?) ?? '';

  String get gameName => (data['name'] as String?) ?? '';
  String get coverHash => (data['cover'] as String?) ?? '';

  /// Landscape key art asset hash; empty means the card falls back to a blurred cover.
  String get artHash => (data['art'] as String?) ?? '';
  int? get gameYear => data['year'] as int?;
  String get gameBlurb => (data['blurb'] as String?) ?? '';

  /// The raw details field: String = bundle asset hash (current), Map =
  /// legacy inline details. Resolve via [GameDetails.resolve].
  dynamic get detailsField => data['details'];

  /// Details asset hash when the block uses the bundle-ref form.
  String get detailsRef =>
      data['details'] is String ? data['details'] as String : '';

  String get shelfLabel => (data['label'] as String?) ?? '';
  List<Map<String, dynamic>> get shelfGames =>
      ((data['games'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  String get artworkHash => (data['image'] as String?) ?? '';
  String get artworkCaption => (data['caption'] as String?) ?? '';

  /// Asset hashes this block references (for bundle pruning at save).
  Iterable<String> get referencedAssetHashes sync* {
    switch (type) {
      case ShowcaseBlockType.nowPlaying:
      case ShowcaseBlockType.favoriteGame:
        if (coverHash.isNotEmpty) yield coverHash;
        if (artHash.isNotEmpty) yield artHash;
        if (detailsRef.isNotEmpty) yield detailsRef;
      // NOTE: company-logo hashes live INSIDE details assets — the editor
      // expands them at save via GameDetails.logoHashesFromBytes.
      case ShowcaseBlockType.gameShelf:
        for (final g in shelfGames) {
          final c = g['cover'] as String?;
          if (c != null && c.isNotEmpty) yield c;
          final a = g['art'] as String?;
          if (a != null && a.isNotEmpty) yield a;
          final d = g['details'];
          if (d is String && d.isNotEmpty) yield d;
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

  /// Cap on the encoded JSON (enforced at save). Game blocks carry baked details,
  /// so this allows several enriched games while staying under Rust's 16KB
  /// `sanitize_incoming_showcase` threshold: a valid board must never be dropped.
  static const int maxEncodedLength = 14 * 1024;

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
