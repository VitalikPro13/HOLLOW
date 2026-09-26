import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;

/// The two boards a block can sit on. The wide artwork is not a side.
enum ShowcaseSide { left, right }

/// Everything the replicated asset bundle may weigh, checked at save.
const int kShowcaseAssetBudget = 1400000;

/// Longest artwork caption.
const int kShowcaseCaptionLength = 100;

/// Longest game shelf name.
const int kShowcaseShelfLabelLength = 40;

/// The board being composed, shared by the desktop dialog and the phone page.
///
/// Blocks are found by IDENTITY (ShowcaseBlock has no value equality), so a
/// background bake or an in-place edit keeps finding its block through
/// reorders, and a removed block simply stops matching.
class ShowcaseDraft extends ChangeNotifier {
  ShowcaseDraft({required this.peerId, required ShowcaseBoard initial})
    : _board = initial,
      _initialEncoded = initial.encode();

  final String peerId;
  ShowcaseBoard _board;
  final String _initialEncoded;

  /// Existing replicated assets plus anything added this session, pruned to
  /// the referenced hashes at save.
  final Map<String, Uint8List> assets = {};

  /// Save awaits these so nothing ships half-baked.
  final Set<Future<BakedGame>> _pendingBakes = {};

  /// The block each game bake patches when it lands. An edit that replaces
  /// the block moves the target along, so a line typed while the cover is
  /// still downloading keeps both.
  final Map<Future<BakedGame>, ShowcaseBlock> _bakeTargets = {};

  /// The one block open for in-place editing, and whether Cancel should
  /// remove it (it was added a moment ago and never committed).
  ShowcaseBlock? editing;
  bool editingIsNew = false;

  /// A side (or the wide slot) waiting on an artwork being processed.
  ShowcaseSide? processingSide;
  bool processingWide = false;

  bool saving = false;
  String? saveError;
  bool _disposed = false;

  /// A stable id per block across in-place replacements, for list keys.
  final Map<ShowcaseBlock, int> _ids = {};
  int _nextId = 0;

  int idOf(ShowcaseBlock block) => _ids.putIfAbsent(block, () => _nextId++);

  ShowcaseBoard get board => _board;
  bool get dirty => _board.encode() != _initialEncoded;
  bool get overSizeLimit =>
      _board.encode().length > ShowcaseBoard.maxEncodedLength;

  List<ShowcaseBlock> side(ShowcaseSide s) =>
      s == ShowcaseSide.left ? _board.left : _board.right;

  bool isFull(ShowcaseSide s) =>
      side(s).length >= ShowcaseBoard.maxBlocksPerSide;

  /// Which side holds [block], or null for the wide slot or a removed block.
  ShowcaseSide? sideOf(ShowcaseBlock block) {
    if (_board.left.contains(block)) return ShowcaseSide.left;
    if (_board.right.contains(block)) return ShowcaseSide.right;
    return null;
  }

  Future<void> loadAssets() async {
    try {
      final loaded = await showcase_api.getShowcaseAssets(peerId: peerId);
      if (_disposed) return;
      for (final a in loaded) {
        assets.putIfAbsent(a.hash, () => a.bytes);
      }
      notifyListeners();
    } catch (_) {
      // Missing pictures render as placeholders; the board still edits.
    }
  }

  void _set(ShowcaseBoard next) {
    _board = next;
    saveError = null;
    notifyListeners();
  }

  ShowcaseBoard _withSide(ShowcaseSide s, List<ShowcaseBlock> blocks) =>
      s == ShowcaseSide.left
      ? _board.copyWith(left: blocks)
      : _board.copyWith(right: blocks);

  void add(ShowcaseSide s, ShowcaseBlock block, {bool edit = false}) {
    if (isFull(s)) return;
    if (edit) {
      editing = block;
      editingIsNew = true;
    }
    _set(_withSide(s, [...side(s), block]));
  }

  void setWide(ShowcaseBlock block, {bool edit = false}) {
    if (edit) {
      editing = block;
      editingIsNew = true;
    }
    _set(_board.copyWith(wide: block));
  }

  void setWideAtTop(bool top) => _set(_board.copyWith(wideAtTop: top));

  /// Swaps [old] for [next] in place. A different game passes
  /// [keepBakes] false, so the old game's download never lands on it.
  void replace(ShowcaseBlock old, ShowcaseBlock next, {bool keepBakes = true}) {
    if (identical(editing, old)) editing = next;
    final id = _ids.remove(old);
    if (id != null) _ids[next] = id;
    for (final e in _bakeTargets.entries.toList()) {
      if (!identical(e.value, old)) continue;
      if (keepBakes) {
        _bakeTargets[e.key] = next;
      } else {
        _bakeTargets.remove(e.key);
      }
    }
    if (identical(_board.wide, old)) {
      _set(_board.copyWith(wide: next));
      return;
    }
    final s = sideOf(old);
    if (s == null) return;
    final blocks = [...side(s)];
    blocks[blocks.indexOf(old)] = next;
    _set(_withSide(s, blocks));
  }

  void remove(ShowcaseBlock block) {
    if (identical(editing, block)) {
      editing = null;
      editingIsNew = false;
    }
    if (identical(_board.wide, block)) {
      _set(_board.copyWith(clearWide: true));
      return;
    }
    final s = sideOf(block);
    if (s == null) return;
    _set(_withSide(s, [...side(s)]..remove(block)));
  }

  /// [newIndex] is already the post-removal index (ReorderableList's
  /// onReorderItem), so it is used as is.
  void reorder(ShowcaseSide s, int oldIndex, int newIndex) {
    final blocks = [...side(s)];
    final moved = blocks.removeAt(oldIndex);
    blocks.insert(newIndex.clamp(0, blocks.length), moved);
    _set(_withSide(s, blocks));
  }

  bool canMoveBy(ShowcaseBlock block, int delta) {
    final s = sideOf(block);
    if (s == null) return false;
    final i = side(s).indexOf(block) + delta;
    return i >= 0 && i < side(s).length;
  }

  void moveBy(ShowcaseBlock block, int delta) {
    final s = sideOf(block);
    if (s == null || !canMoveBy(block, delta)) return;
    final i = side(s).indexOf(block);
    reorder(s, i, i + delta);
  }

  bool canMoveAcross(ShowcaseBlock block) {
    final s = sideOf(block);
    return s != null && !isFull(_other(s));
  }

  /// Appends [block] to the other board, where it lands last.
  void moveAcross(ShowcaseBlock block) {
    final s = sideOf(block);
    if (s == null || !canMoveAcross(block)) return;
    final other = _other(s);
    final from = [...side(s)]..remove(block);
    final to = [...side(other), block];
    _set(
      s == ShowcaseSide.left
          ? _board.copyWith(left: from, right: to)
          : _board.copyWith(left: to, right: from),
    );
  }

  static ShowcaseSide _other(ShowcaseSide s) =>
      s == ShowcaseSide.left ? ShowcaseSide.right : ShowcaseSide.left;

  void beginEdit(ShowcaseBlock block) {
    if (editing != null) endEdit(committed: true);
    editing = block;
    editingIsNew = false;
    notifyListeners();
  }

  /// Leaves in-place editing. A new block that was never committed goes, and
  /// so does a text block or shelf left with nothing in it.
  void endEdit({required bool committed}) {
    final block = editing;
    final wasNew = editingIsNew;
    editing = null;
    editingIsNew = false;
    if (block != null && ((!committed && wasNew) || _holdsNothing(block))) {
      remove(block);
      return;
    }
    notifyListeners();
  }

  static bool _holdsNothing(ShowcaseBlock b) => switch (b.type) {
    ShowcaseBlockType.text => b.textTitle.isEmpty && b.textBody.isEmpty,
    ShowcaseBlockType.gameShelf => b.shelfGames.isEmpty,
    _ => false,
  };

  void stash(showcase_api.ShowcaseAsset asset) {
    assets[asset.hash] = Uint8List.fromList(asset.bytes);
  }

  /// Patches the game block [placed] with its baked cover, key art and
  /// details once they land.
  void trackBake(ShowcaseBlock placed, Future<BakedGame> bake) {
    _pendingBakes.add(bake);
    _bakeTargets[bake] = placed;
    bake.then((baked) {
      _pendingBakes.remove(bake);
      final target = _bakeTargets.remove(bake);
      if (_disposed) return;
      baked.allAssets.forEach(stash);
      final current = target == null ? null : _findByIdentity(target);
      if (current == null) {
        notifyListeners();
        return;
      }
      replace(
        current,
        ShowcaseBlock(
          type: current.type,
          data: {
            ...current.data,
            if (baked.cover != null) 'cover': baked.cover!.hash,
            if (baked.art != null) 'art': baked.art!.hash,
            if (baked.detailsAsset != null) 'details': baked.detailsAsset!.hash,
          },
        ),
      );
    });
  }

  ShowcaseBlock? _findByIdentity(ShowcaseBlock block) {
    if (identical(_board.wide, block)) return block;
    return sideOf(block) != null ? block : null;
  }

  /// Patches one shelf entry (a mutable map the shelf keeps) in place.
  void trackShelfBake(Map<String, dynamic> game, Future<BakedGame> bake) {
    _pendingBakes.add(bake);
    bake.then((baked) {
      _pendingBakes.remove(bake);
      if (_disposed) return;
      baked.allAssets.forEach(stash);
      if (baked.cover != null) game['cover'] = baked.cover!.hash;
      if (baked.art != null) game['art'] = baked.art!.hash;
      if (baked.detailsAsset != null) {
        game['details'] = baked.detailsAsset!.hash;
      }
      notifyListeners();
    });
  }

  /// Picks an image, processes it and returns the artwork block, or null when
  /// the person backed out. Throws what processing threw.
  Future<ShowcaseBlock?> pickArtwork({ShowcaseSide? forSide}) async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;
    var bytes = picked.files.single.bytes;
    final path = picked.files.single.path;
    if (bytes == null && path != null) {
      bytes = await File(path).readAsBytes();
    }
    if (bytes == null) return null;
    processingSide = forSide;
    processingWide = forSide == null;
    notifyListeners();
    try {
      final asset = await showcase_api.processShowcaseArtwork(rawBytes: bytes);
      stash(asset);
      return ShowcaseBlock(
        type: ShowcaseBlockType.artwork,
        data: {'image': asset.hash},
      );
    } finally {
      processingSide = null;
      processingWide = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Saves through [profiles]. A board that cannot ship throws a
  /// [FriendlyException] saying why.
  Future<void> save(ProfileNotifier profiles) async {
    if (editing != null) endEdit(committed: true);
    saving = true;
    saveError = null;
    notifyListeners();
    try {
      if (_pendingBakes.isNotEmpty) {
        await Future.wait(_pendingBakes.toList());
      }
      final encoded = _board.encode();
      if (encoded.length > ShowcaseBoard.maxEncodedLength) {
        throw const FriendlyException(
          'Your showcase is over its size limit. Shorten a text block to save.',
        );
      }
      // Company logos are referenced from INSIDE details assets, so the
      // expansion goes one level down or the prune drops them.
      final referenced = {..._board.referencedAssetHashes()};
      for (final h in referenced.toList()) {
        final bytes = assets[h];
        if (bytes != null) {
          referenced.addAll(GameDetails.logoHashesFromBytes(bytes));
        }
      }
      final shipped = [
        for (final e in assets.entries)
          if (referenced.contains(e.key))
            showcase_api.ShowcaseAsset(hash: e.key, bytes: e.value),
      ];
      final total = shipped.fold<int>(0, (sum, a) => sum + a.bytes.length);
      if (total > kShowcaseAssetBudget) {
        throw const FriendlyException(
          'The pictures are too large together. Remove an artwork or a game.',
        );
      }
      await profiles.updateShowcaseBoard(peerId, encoded, assets: shipped);
    } finally {
      saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// The instant result of choosing a search result: basics only. Everything
/// heavier is baked in the background by [bakeGame] and patched in.
class PickedGame {
  final int id;
  final String name;
  final int? year;
  final String? coverUrl;

  const PickedGame({
    required this.id,
    required this.name,
    this.year,
    this.coverUrl,
  });
}

/// Everything fetched for one picked game. Every stage is best-effort, so a
/// failed stage leaves its field null.
class BakedGame {
  final showcase_api.ShowcaseAsset? cover;

  /// Landscape key art, the card's hero image.
  final showcase_api.ShowcaseAsset? art;

  /// The details JSON as a content-addressed bundle asset, with the company
  /// logo URLs inside already rewritten to asset hashes.
  final showcase_api.ShowcaseAsset? detailsAsset;
  final List<showcase_api.ShowcaseAsset> logoAssets;

  const BakedGame({
    this.cover,
    this.art,
    this.detailsAsset,
    this.logoAssets = const [],
  });

  Iterable<showcase_api.ShowcaseAsset> get allAssets sync* {
    if (cover != null) yield cover!;
    if (art != null) yield art!;
    if (detailsAsset != null) yield detailsAsset!;
    yield* logoAssets;
  }
}

/// Fetches and content-addresses everything a game block replicates, while
/// the person keeps editing. CDN-only fetches, and it never throws.
Future<BakedGame> bakeGame(PickedGame game) async {
  showcase_api.ShowcaseAsset? cover;
  if (game.coverUrl != null) {
    try {
      cover = await showcase_api.showcaseFetchCover(url: game.coverUrl!);
    } catch (_) {}
  }

  showcase_api.ShowcaseAsset? art;
  showcase_api.ShowcaseAsset? detailsAsset;
  final logoAssets = <showcase_api.ShowcaseAsset>[];
  try {
    final card = await showcase_api.showcaseGameDetails(gameId: game.id);
    if (card != null) {
      final decoded = jsonDecode(card.detailsJson);
      if (decoded is Map<String, dynamic>) {
        final details = decoded;

        // Key art rides the block as its own asset: never bake a remote URL
        // into replicated data.
        details.remove('artwork');
        if (card.artworkUrl != null) {
          try {
            art = await showcase_api.showcaseFetchKeyArt(url: card.artworkUrl!);
          } catch (_) {}
        }

        final companies = details['companies'];
        if (companies is List) {
          for (final co in companies) {
            if (co is! Map) continue;
            final logoUrl = co['logo'];
            if (logoUrl is! String || logoUrl.isEmpty) continue;
            try {
              final asset = await showcase_api.showcaseFetchCover(url: logoUrl);
              logoAssets.add(asset);
              co['logo'] = asset.hash;
            } catch (_) {
              co.remove('logo'); // the credit still shows name and links
            }
          }
        }

        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(details)));
        detailsAsset = showcase_api.ShowcaseAsset(
          hash: sha256.convert(bytes).toString(),
          bytes: bytes,
        );
      }
    }
  } catch (_) {
    // Enrichment is best-effort: the game stays usable as name and cover.
  }

  return BakedGame(
    cover: cover,
    art: art,
    detailsAsset: detailsAsset,
    logoAssets: logoAssets,
  );
}

/// A game block for [game], its bake started so it downloads while the
/// person writes their line.
({ShowcaseBlock block, Future<BakedGame> bake}) gameBlockFor(
  ShowcaseBlockType type,
  PickedGame game, {
  String blurb = '',
}) => (
  block: ShowcaseBlock(
    type: type,
    data: {
      'name': game.name,
      if (game.year != null) 'year': game.year,
      if (blurb.isNotEmpty) 'blurb': blurb,
    },
  ),
  bake: bakeGame(game),
);
