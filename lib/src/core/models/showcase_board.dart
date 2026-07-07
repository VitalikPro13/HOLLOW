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
import 'dart:typed_data';

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

/// A dev/publisher credit inside a game's baked details.
///
/// [logoHash] references replicated bytes in the profile's asset bundle (an
/// asset hash, NOT a URL — the composer swaps the CDN URL to a hash at
/// bake). [links] are the company's own website/social URLs, opened only on
/// explicit tap. Companies are DEDUPED server-side — one that both develops
/// and publishes appears once with role `devpub`.
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

/// Replicated game-card metadata, baked at authoring time (Steam-enriched +
/// IGDB-credited). Everything here is plain data — a viewer opening the card
/// fetches NOTHING; images (cover/key art/logos) come from the replicated
/// asset bundle, store/social links open only on tap.
///
/// Details live in the ASSET BUNDLE as a content-addressed JSON asset — the
/// block stores just the hash (`data['details']` as a String). That keeps
/// the board text tiny (it rides every profile announce) while the bulk
/// rides full profile pulls only, and lets game-shelf entries carry full
/// metadata too. Legacy blocks with an inline details MAP still parse.
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

  /// Store URLs keyed by store slug (steam/playstation/xbox/nintendo/…).
  /// Desktop platform chips link to `steam`, console chips to their own
  /// store.
  final Map<String, String> stores;
  final List<GameCompany> companies;

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
      companies.isEmpty;

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
    );
    return d.isEmpty ? null : d;
  }

  /// Resolve a block/shelf `details` field: a String = content-addressed
  /// asset hash (bytes = UTF-8 JSON in the replicated bundle); a Map =
  /// legacy inline details (v3-v6 bakes). Anything malformed → null.
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

  /// Company-logo hashes referenced from a details ASSET's bytes — used at
  /// save time so pruning keeps logos alive. Image bytes (non-UTF-8 /
  /// non-JSON) simply yield nothing.
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

  // Text block accessors.
  String get textTitle => (data['title'] as String?) ?? '';
  String get textBody => (data['body'] as String?) ?? '';

  // Game block accessors (nowPlaying / favoriteGame).
  String get gameName => (data['name'] as String?) ?? '';
  String get coverHash => (data['cover'] as String?) ?? '';

  /// Landscape key art asset hash (empty when the game has none — the card
  /// falls back to a blurred cover).
  String get artHash => (data['art'] as String?) ?? '';
  int? get gameYear => data['year'] as int?;
  String get gameBlurb => (data['blurb'] as String?) ?? '';

  /// The raw details field: String = bundle asset hash (current), Map =
  /// legacy inline details. Resolve via [GameDetails.resolve].
  dynamic get detailsField => data['details'];

  /// Details asset hash when the block uses the bundle-ref form.
  String get detailsRef =>
      data['details'] is String ? data['details'] as String : '';

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

  /// Cap on the encoded JSON (enforced at save). Text-only blocks land far
  /// below this; game blocks carry baked Steam/IGDB details (~2-4KB each), so
  /// the cap allows several enriched games while staying safely under Rust's
  /// 16KB `sanitize_incoming_showcase` absent-threshold — a valid board must
  /// never be silently dropped in transit.
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
