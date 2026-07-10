import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the showcase board composer for the LOCAL user.
void showShowcaseEditorDialog(BuildContext context, WidgetRef ref) {
  showHollowDialog(
    context: context,
    builder: (_) => const _ShowcaseEditorDialog(),
  );
}

class _ShowcaseEditorDialog extends ConsumerStatefulWidget {
  const _ShowcaseEditorDialog();

  @override
  ConsumerState<_ShowcaseEditorDialog> createState() =>
      _ShowcaseEditorDialogState();
}

class _ShowcaseEditorDialogState extends ConsumerState<_ShowcaseEditorDialog> {
  late ShowcaseBoard _board;

  /// Working asset set: existing replicated assets + anything added this
  /// session. Pruned to referenced hashes at save.
  final Map<String, Uint8List> _assets = {};

  /// In-flight background bakes (cover/art/details per picked game). Blocks
  /// appear instantly with name+year; each bake patches its block in place
  /// when done. Save AWAITS these so nothing ships half-baked.
  final Set<Future<BakedGame>> _pendingBakes = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final peerId = ref.read(identityProvider).peerId ?? '';
    final profile = ref.read(profileProvider)[peerId];
    _board = ShowcaseBoard.decode(profile?.showcaseBoard);
    showcase_api.getShowcaseAssets(peerId: peerId).then((assets) {
      if (!mounted) return;
      setState(() {
        for (final a in assets) {
          _assets.putIfAbsent(a.hash, () => a.bytes);
        }
      });
    }).catchError((_) {});
  }

  Future<void> _save() async {
    if (_busy) return;
    // The Save button spins for the WHOLE save: in-flight bakes + the FFI
    // write (big asset bundles take a moment — a silent frozen dialog reads
    // as "nothing happened").
    setState(() => _busy = true);

    // Let in-flight background bakes land first (usually already done —
    // they run while the user composes). Their .then patches registered
    // earlier fire before this await resumes, so the board is enriched.
    if (_pendingBakes.isNotEmpty) {
      await Future.wait(_pendingBakes.toList());
      if (!mounted) return;
    }

    final encoded = _board.encode();
    if (encoded.length > ShowcaseBoard.maxEncodedLength) {
      setState(() => _busy = false);
      HollowToast.show(
        context,
        'Showcase is too large — shorten a text block',
        type: HollowToastType.error,
      );
      return;
    }
    // The board is the source of truth: ship exactly the assets it
    // references (pruning anything orphaned by removed blocks). Company
    // logos are referenced from INSIDE details assets — expand one level so
    // they survive the prune.
    final referenced = {..._board.referencedAssetHashes()};
    for (final h in referenced.toList()) {
      final bytes = _assets[h];
      if (bytes != null) {
        referenced.addAll(GameDetails.logoHashesFromBytes(bytes));
      }
    }
    final assets = [
      for (final e in _assets.entries)
        if (referenced.contains(e.key))
          showcase_api.ShowcaseAsset(hash: e.key, bytes: e.value),
    ];
    final totalBytes =
        assets.fold<int>(0, (sum, a) => sum + a.bytes.length);
    if (totalBytes > 1_400_000) {
      setState(() => _busy = false);
      HollowToast.show(
        context,
        'Showcase images too large — remove an artwork or game',
        type: HollowToastType.error,
      );
      return;
    }
    final peerId = ref.read(identityProvider).peerId ?? '';
    final navigator = Navigator.of(context);
    try {
      await ref
          .read(profileProvider.notifier)
          .updateShowcaseBoard(peerId, encoded, assets: assets);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      HollowToast.show(
        context,
        'Couldn\'t save the showcase — try again',
        type: HollowToastType.error,
      );
      return;
    }
    if (!mounted) return;
    navigator.pop();
    HollowToast.show(
      context,
      'Showcase updated',
      type: HollowToastType.success,
    );
  }

  void _stashAsset(showcase_api.ShowcaseAsset asset) {
    _assets[asset.hash] = Uint8List.fromList(asset.bytes);
  }

  /// Register a background bake for a just-placed game block: when it
  /// completes, stash its assets and patch the block in place (found by
  /// identity — reorders keep instances, deletion just drops the patch).
  void _trackBake(ShowcaseBlock placed, Future<BakedGame> bake) {
    _pendingBakes.add(bake);
    bake.then((baked) {
      _pendingBakes.remove(bake);
      if (!mounted) return;
      setState(() {
        for (final a in baked.allAssets) {
          _stashAsset(a);
        }
        _patchGameBlock(placed, baked);
      });
    });
  }

  void _patchGameBlock(ShowcaseBlock placed, BakedGame baked) {
    ShowcaseBlock enrich(ShowcaseBlock b) => ShowcaseBlock(type: b.type, data: {
          ...b.data,
          if (baked.cover != null) 'cover': baked.cover!.hash,
          if (baked.art != null) 'art': baked.art!.hash,
          if (baked.detailsAsset != null) 'details': baked.detailsAsset!.hash,
        });
    final li = _board.left.indexOf(placed);
    if (li >= 0) {
      final next = [..._board.left];
      next[li] = enrich(placed);
      _board = _board.copyWith(left: next);
      return;
    }
    final ri = _board.right.indexOf(placed);
    if (ri >= 0) {
      final next = [..._board.right];
      next[ri] = enrich(placed);
      _board = _board.copyWith(right: next);
    }
    // Block deleted meanwhile → nothing to patch; orphaned assets are
    // pruned at save.
  }

  /// The full add-block flow for one side: picker → type-specific editor.
  Future<void> _addBlockTo({required bool left}) async {
    final type = await _showBlockPicker(context);
    if (type == null || !mounted) return;

    ShowcaseBlock? block;
    Future<BakedGame>? pendingBake;
    switch (type) {
      case ShowcaseBlockType.text:
        block = await showTextBlockEditor(context);

      case ShowcaseBlockType.nowPlaying:
      case ShowcaseBlockType.favoriteGame:
        final game = await showGamePickerDialog(context);
        if (game == null || !mounted) break;
        // Enrichment starts NOW and downloads while the user types their
        // blurb; the block lands instantly and gets patched when ready.
        pendingBake = bakeGame(game);
        String blurb = '';
        if (type == ShowcaseBlockType.favoriteGame) {
          blurb = (await _promptText(
                context,
                title: 'Why this game?',
                hint: 'A short personal blurb (optional)',
                maxLength: 200,
              )) ??
              '';
          if (!mounted) break;
        }
        block = ShowcaseBlock(type: type, data: {
          'name': game.name,
          if (game.year != null) 'year': game.year,
          if (blurb.isNotEmpty) 'blurb': blurb,
        });

      case ShowcaseBlockType.gameShelf:
        final shelf = await showShelfEditorDialog(context);
        if (shelf == null) break;
        for (final a in shelf.assets) {
          _stashAsset(a);
        }
        block = ShowcaseBlock(type: type, data: {
          if (shelf.label.isNotEmpty) 'label': shelf.label,
          'games': shelf.games,
        });

      case ShowcaseBlockType.artwork:
        block = await _pickArtwork();

      case ShowcaseBlockType.unknown:
        break;
    }

    if (block == null || !mounted) return;
    setState(() {
      _board = left
          ? _board.copyWith(left: [..._board.left, block!])
          : _board.copyWith(right: [..._board.right, block!]);
    });
    if (pendingBake != null) _trackBake(block, pendingBake);
  }

  Future<ShowcaseBlock?> _pickArtwork() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return null;
    var bytes = picked.files.single.bytes;
    final path = picked.files.single.path;
    if (bytes == null && path != null) {
      try {
        bytes = await File(path).readAsBytes();
      } catch (_) {}
    }
    if (bytes == null || !mounted) return null;

    setState(() => _busy = true);
    showcase_api.ShowcaseAsset asset;
    try {
      asset = await showcase_api.processShowcaseArtwork(rawBytes: bytes);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(context, '$e', type: HollowToastType.error);
      }
      return null;
    }
    if (!mounted) return null;
    setState(() => _busy = false);

    final caption = (await _promptText(
          context,
          title: 'Caption',
          hint: 'Optional caption',
          maxLength: 100,
        )) ??
        '';
    _stashAsset(asset);
    return ShowcaseBlock(type: ShowcaseBlockType.artwork, data: {
      'image': asset.hash,
      if (caption.isNotEmpty) 'caption': caption,
    });
  }

  /// Edit any block in place with its own dialog, replacing it on save.
  Future<void> _editBlock(bool left, int index) async {
    final side = left ? _board.left : _board.right;
    final block = side[index];

    ShowcaseBlock? edited;
    Future<BakedGame>? pendingBake;
    switch (block.type) {
      case ShowcaseBlockType.text:
        edited = await showTextBlockEditor(context, existing: block);

      case ShowcaseBlockType.nowPlaying:
        final game = await showGamePickerDialog(context);
        if (game == null) break;
        pendingBake = bakeGame(game);
        edited = ShowcaseBlock(type: block.type, data: {
          'name': game.name,
          if (game.year != null) 'year': game.year,
        });

      case ShowcaseBlockType.favoriteGame:
        final game = await showGamePickerDialog(context);
        if (game == null || !mounted) break;
        // Bake in parallel with the blurb prompt.
        pendingBake = bakeGame(game);
        final blurb = (await _promptText(
              context,
              title: 'Why this game?',
              hint: 'A short personal blurb (optional)',
              maxLength: 200,
              initial: block.gameBlurb,
            )) ??
            block.gameBlurb;
        edited = ShowcaseBlock(type: block.type, data: {
          'name': game.name,
          if (game.year != null) 'year': game.year,
          if (blurb.isNotEmpty) 'blurb': blurb,
        });

      case ShowcaseBlockType.gameShelf:
        final shelf = await showShelfEditorDialog(context, existing: block);
        if (shelf == null) break;
        for (final a in shelf.assets) {
          _stashAsset(a);
        }
        edited = ShowcaseBlock(type: block.type, data: {
          if (shelf.label.isNotEmpty) 'label': shelf.label,
          'games': shelf.games,
        });

      case ShowcaseBlockType.artwork:
        // Editing artwork = editing the caption; the image itself is
        // replaced by removing the block and adding a new one.
        final caption = await _promptText(
          context,
          title: 'Caption',
          hint: 'Optional caption',
          maxLength: 100,
          initial: block.artworkCaption,
        );
        if (caption == null) break;
        edited = ShowcaseBlock(type: block.type, data: {
          'image': block.artworkHash,
          if (caption.isNotEmpty) 'caption': caption,
        });

      case ShowcaseBlockType.unknown:
        break;
    }

    if (edited == null || !mounted) return;
    final next = [...side];
    next[index] = edited;
    setState(() {
      _board = left
          ? _board.copyWith(left: next)
          : _board.copyWith(right: next);
    });
    if (pendingBake != null) _trackBake(edited, pendingBake);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Edit Showcase',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Compose blocks on either side of your profile. Only what you '
            'put here is shown — fill one side, both, or neither.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          _SideEditor(
            label: 'LEFT BOARD',
            blocks: _board.left,
            busy: _busy,
            onChanged: (blocks) =>
                setState(() => _board = _board.copyWith(left: blocks)),
            onAddBlock: () => _addBlockTo(left: true),
            onEditBlock: (i) => _editBlock(true, i),
          ),
          const SizedBox(height: HollowSpacing.lg),
          _SideEditor(
            label: 'RIGHT BOARD',
            blocks: _board.right,
            busy: _busy,
            onChanged: (blocks) =>
                setState(() => _board = _board.copyWith(right: blocks)),
            onAddBlock: () => _addBlockTo(left: false),
            onEditBlock: (i) => _editBlock(false, i),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _busy ? null : _save,
          child: _busy ? _savingSpinner(hollow) : const Text('Save'),
        ),
      ],
    );
  }
}

/// In-button progress for a filled Save that's finishing background bakes /
/// the profile write — the visible "it's working" the frozen dialog lacked.
Widget _savingSpinner(HollowTheme hollow) => SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: hollow.textOnAccent,
      ),
    );

/// One side's block list: reorder (drag), edit, remove, add.
class _SideEditor extends StatelessWidget {
  final String label;
  final List<ShowcaseBlock> blocks;
  final bool busy;
  final ValueChanged<List<ShowcaseBlock>> onChanged;
  final VoidCallback onAddBlock;
  final void Function(int index) onEditBlock;

  const _SideEditor({
    required this.label,
    required this.blocks,
    required this.busy,
    required this.onChanged,
    required this.onAddBlock,
    required this.onEditBlock,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                fontSize: 10,
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              '${blocks.length}/${ShowcaseBoard.maxBlocksPerSide}',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary.withValues(alpha: 0.6),
                fontSize: 10,
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),
        if (blocks.isEmpty)
          Text(
            'Empty — this side isn\'t shown.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary.withValues(alpha: 0.6),
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: blocks.length,
            buildDefaultDragHandles: false,
            proxyDecorator: (child, index, animation) {
              return AnimatedBuilder(
                animation: animation,
                builder: (ctx, child) => Material(
                  color: Colors.transparent,
                  elevation: 4,
                  shadowColor: Colors.black26,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  child: child,
                ),
                child: child,
              );
            },
            onReorderItem: (oldIndex, newIndex) {
              final next = [...blocks];
              if (newIndex > oldIndex) newIndex--;
              final moved = next.removeAt(oldIndex);
              next.insert(newIndex, moved);
              onChanged(next);
            },
            itemBuilder: (context, index) {
              final block = blocks[index];
              return Padding(
                key: ValueKey('$label-$index-${block.hashCode}'),
                padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                child: _BlockRow(
                  block: block,
                  index: index,
                  onEdit: block.type != ShowcaseBlockType.unknown
                      ? () => onEditBlock(index)
                      : null,
                  onRemove: () {
                    final next = [...blocks]..removeAt(index);
                    onChanged(next);
                  },
                ),
              );
            },
          ),
        const SizedBox(height: HollowSpacing.xs),
        HollowButton.ghost(
          onPressed: busy || blocks.length >= ShowcaseBoard.maxBlocksPerSide
              ? null
              : onAddBlock,
          compact: true,
          icon: busy
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(LucideIcons.plus),
          child: const Text('Add Block'),
        ),
      ],
    );
  }
}

IconData _blockIcon(ShowcaseBlockType type) => switch (type) {
      ShowcaseBlockType.text => LucideIcons.type,
      ShowcaseBlockType.nowPlaying => LucideIcons.play,
      ShowcaseBlockType.favoriteGame => LucideIcons.heart,
      ShowcaseBlockType.gameShelf => LucideIcons.libraryBig,
      ShowcaseBlockType.artwork => LucideIcons.image,
      ShowcaseBlockType.unknown => LucideIcons.box,
    };

class _BlockRow extends StatelessWidget {
  final ShowcaseBlock block;
  final int index;
  final VoidCallback? onEdit;
  final VoidCallback onRemove;

  const _BlockRow({
    required this.block,
    required this.index,
    required this.onRemove,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final summary = switch (block.type) {
      ShowcaseBlockType.text => block.textTitle.isNotEmpty
          ? block.textTitle
          : (block.textBody.isNotEmpty ? block.textBody : 'Text block'),
      ShowcaseBlockType.nowPlaying => 'Now Playing — ${block.gameName}',
      ShowcaseBlockType.favoriteGame => 'Favorite — ${block.gameName}',
      ShowcaseBlockType.gameShelf => block.shelfLabel.isNotEmpty
          ? '${block.shelfLabel} (${block.shelfGames.length} games)'
          : 'Game Shelf (${block.shelfGames.length} games)',
      ShowcaseBlockType.artwork => block.artworkCaption.isNotEmpty
          ? 'Artwork — ${block.artworkCaption}'
          : 'Artwork',
      ShowcaseBlockType.unknown => 'Block from a newer version',
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Icon(LucideIcons.gripVertical,
                size: 16, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Icon(_blockIcon(block.type), size: 14, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 12,
              ),
            ),
          ),
          if (onEdit != null)
            HollowPressable(
              onTap: onEdit,
              semanticLabel: 'Edit block',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.pencil,
                  size: 13, color: hollow.textSecondary),
            ),
          HollowPressable(
            onTap: onRemove,
            semanticLabel: 'Remove block',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child:
                Icon(LucideIcons.x, size: 13, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}

// ── Block picker ──────────────────────────────────────────────────────

Future<ShowcaseBlockType?> _showBlockPicker(BuildContext context) {
  return showHollowDialog<ShowcaseBlockType>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Add Block',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _pickerOption(ctx, ShowcaseBlockType.nowPlaying, 'Now Playing',
              'One game, present tense — set by you, never auto-detected'),
          _pickerOption(ctx, ShowcaseBlockType.favoriteGame, 'Favorite Game',
              'A big cover with your personal blurb'),
          _pickerOption(ctx, ShowcaseBlockType.gameShelf, 'Game Shelf',
              'A cover grid — backlog, all-time favorites, whatever'),
          _pickerOption(ctx, ShowcaseBlockType.artwork, 'Artwork / GIF',
              'An image of your choosing'),
          _pickerOption(ctx, ShowcaseBlockType.text, 'Text',
              'Free-form — bold, italic, code, spoilers, links'),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}

Widget _pickerOption(BuildContext ctx, ShowcaseBlockType type, String title,
    String description) {
  final hollow = HollowTheme.of(ctx);
  return Padding(
    padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
    child: HollowPressable(
      onTap: () => Navigator.of(ctx).pop(type),
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.all(HollowSpacing.md),
      child: Row(
        children: [
          Icon(_blockIcon(type), size: 18, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                Text(
                  description,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

// ── Game picker (IGDB search via the website's cached endpoint) ───────

/// The instant result of tapping a search row — basics only, so the picker
/// closes with ZERO latency. Everything heavier (cover, key art, details,
/// logos) is baked in the background via [bakeGame] and patched into the
/// placed block when ready.
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

/// Everything fetched for one picked game. Baked in the BACKGROUND after
/// the picker closes; every stage is best-effort, so the future NEVER
/// throws — a failed stage just leaves its field null.
class BakedGame {
  final showcase_api.ShowcaseAsset? cover;

  /// Landscape key art — the card's hero image.
  final showcase_api.ShowcaseAsset? art;

  /// The details JSON as a content-addressed bundle asset. Company logo
  /// URLs inside are already rewritten to asset hashes ([logoAssets]).
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

/// Fetch + content-address everything a game block replicates: cover, key
/// art, the details JSON, company logos. Called right after the picker pops
/// (it downloads while the user types their blurb); callers patch the placed
/// block when it completes. All CDN-only fetches; never throws.
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

        // Key art rides the block as its own asset (`data['art']`) —
        // never bake a remote URL into replicated data.
        details.remove('artwork');
        if (card.artworkUrl != null) {
          try {
            art = await showcase_api.showcaseFetchKeyArt(url: card.artworkUrl!);
          } catch (_) {}
        }

        // Company logos: CDN URL → content-addressed asset hash.
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
              co.remove('logo'); // credit still shows name + links
            }
          }
        }

        // The details JSON itself becomes a content-addressed bundle
        // asset — the block stores just the hash, keeping the board tiny.
        final bytes = Uint8List.fromList(utf8.encode(jsonEncode(details)));
        detailsAsset = showcase_api.ShowcaseAsset(
          hash: sha256.convert(bytes).toString(),
          bytes: bytes,
        );
      }
    }
  } catch (_) {
    // Enrichment is best-effort — the game stays usable as name+cover.
  }

  return BakedGame(
    cover: cover,
    art: art,
    detailsAsset: detailsAsset,
    logoAssets: logoAssets,
  );
}

Future<PickedGame?> showGamePickerDialog(BuildContext context) {
  return showHollowDialog<PickedGame>(
    context: context,
    builder: (_) => const _GamePickerDialog(),
  );
}

class _GamePickerDialog extends StatefulWidget {
  const _GamePickerDialog();

  @override
  State<_GamePickerDialog> createState() => _GamePickerDialogState();
}

class _GamePickerDialogState extends State<_GamePickerDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<showcase_api.GameSearchResult> _results = const [];
  bool _searching = false;
  String? _error;

  /// Query of the last COMPLETED search — gates the "no games found" state
  /// so it only shows for what the user is currently looking at (never a
  /// flash of "nothing found" while the debounce is still pending).
  String _searchedFor = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onQueryChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
        _searchedFor = '';
      });
      return;
    }
    setState(() { _searching = true; _error = null; });
    try {
      final results = await showcase_api.showcaseGameSearch(query: q);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        _searchedFor = q.trim();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'Search unavailable — check your connection and try again';
      });
    }
  }

  bool get _showNoResults =>
      _results.isEmpty &&
      _searchedFor.isNotEmpty &&
      _searchedFor == _controller.text.trim();

  /// Instant: the heavy enrichment happens in the BACKGROUND after the
  /// picker closes (see [bakeGame]) — no spinner between tap and editor.
  void _pick(showcase_api.GameSearchResult game) {
    Navigator.of(context).pop(PickedGame(
      id: game.id,
      name: game.name,
      year: game.year,
      coverUrl: game.coverUrl,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Find a Game',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowTextField(
            controller: _controller,
            hintText: 'Search games…',
            autofocus: true,
            onChanged: _onQueryChanged,
          ),
          const SizedBox(height: HollowSpacing.sm),
          if (_searching)
            const Padding(
              padding: EdgeInsets.all(HollowSpacing.lg),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_error != null)
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.md),
              child: Row(
                children: [
                  Icon(LucideIcons.wifiOff, size: 14, color: hollow.error),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.error,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (_showNoResults)
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.lg),
              child: Column(
                children: [
                  Icon(
                    LucideIcons.searchX,
                    size: 22,
                    color: hollow.textSecondary.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  Text(
                    'No games found for “$_searchedFor”',
                    textAlign: TextAlign.center,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Check the spelling or try a shorter name.',
                    textAlign: TextAlign.center,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _results.length,
                itemBuilder: (context, index) {
                  final game = _results[index];
                  return HollowPressable(
                    onTap: () => _pick(game),
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.sm,
                      vertical: HollowSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        // Authoring-time thumbnail from OUR CDN only.
                        ClipRRect(
                          borderRadius:
                              BorderRadius.circular(hollow.radiusSm),
                          child: game.coverUrl != null
                              ? Image.network(
                                  game.coverUrl!,
                                  width: 32,
                                  height: 43,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => _thumbFallback(
                                      hollow),
                                )
                              : _thumbFallback(hollow),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: Text(
                            game.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HollowTypography.body.copyWith(
                              color: hollow.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (game.gameType != null) ...[
                          const SizedBox(width: HollowSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: hollow.textSecondary
                                  .withValues(alpha: 0.12),
                              borderRadius:
                                  BorderRadius.circular(hollow.radiusSm),
                            ),
                            child: Text(
                              game.gameType!,
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                                fontWeight: FontWeight.w600,
                                fontSize: 9,
                              ),
                            ),
                          ),
                        ],
                        if (game.year != null) ...[
                          const SizedBox(width: HollowSpacing.sm),
                          Text(
                            '${game.year}',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Game data from IGDB',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary.withValues(alpha: 0.5),
              fontSize: 9,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _thumbFallback(HollowTheme hollow) => Container(
        width: 32,
        height: 43,
        color: hollow.elevated,
        child: Icon(
          LucideIcons.gamepad2,
          size: 14,
          color: hollow.textSecondary.withValues(alpha: 0.5),
        ),
      );
}

// ── Game shelf editor ─────────────────────────────────────────────────

class ShelfResult {
  final String label;
  final List<Map<String, dynamic>> games;
  final List<showcase_api.ShowcaseAsset> assets;

  const ShelfResult({
    required this.label,
    required this.games,
    required this.assets,
  });
}

/// Pass [existing] to edit a shelf in place (label + games prefilled).
Future<ShelfResult?> showShelfEditorDialog(
  BuildContext context, {
  ShowcaseBlock? existing,
}) {
  return showHollowDialog<ShelfResult>(
    context: context,
    builder: (_) => _ShelfEditorDialog(existing: existing),
  );
}

class _ShelfEditorDialog extends StatefulWidget {
  final ShowcaseBlock? existing;

  const _ShelfEditorDialog({this.existing});

  @override
  State<_ShelfEditorDialog> createState() => _ShelfEditorDialogState();
}

class _ShelfEditorDialogState extends State<_ShelfEditorDialog> {
  late final TextEditingController _labelController;

  /// `{name, cover?, year?, details?}` maps — prefilled from an existing
  /// block; new picks append here and their bytes to [_newAssets].
  late final List<Map<String, dynamic>> _games;
  final List<showcase_api.ShowcaseAsset> _newAssets = [];

  /// In-flight background bakes; games land instantly (name+year) and each
  /// map is patched in place when its bake completes. Save awaits these.
  final Set<Future<BakedGame>> _pendingBakes = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _labelController =
        TextEditingController(text: widget.existing?.shelfLabel ?? '');
    _games = [...(widget.existing?.shelfGames ?? const [])];
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _addGame() async {
    final game = await showGamePickerDialog(context);
    if (game == null || !mounted) return;
    // Land instantly; the bake patches this map in place (the map keeps its
    // identity through reorders). Shelf entries carry the FULL card payload
    // — details, logos AND key art — so a shelf tap opens the exact same
    // card as a game block. The save-time 1.4MB bundle check is the budget
    // backstop for very art-heavy shelves.
    final map = <String, dynamic>{
      'name': game.name,
      if (game.year != null) 'year': game.year,
    };
    setState(() => _games.add(map));
    final bake = bakeGame(game);
    _pendingBakes.add(bake);
    bake.then((baked) {
      _pendingBakes.remove(bake);
      if (!mounted) return;
      setState(() {
        if (baked.cover != null) {
          map['cover'] = baked.cover!.hash;
          _newAssets.add(baked.cover!);
        }
        if (baked.art != null) {
          map['art'] = baked.art!.hash;
          _newAssets.add(baked.art!);
        }
        if (baked.detailsAsset != null) {
          map['details'] = baked.detailsAsset!.hash;
          _newAssets.add(baked.detailsAsset!);
          _newAssets.addAll(baked.logoAssets);
        }
      });
    });
  }

  Future<void> _save() async {
    if (_games.isEmpty || _saving) return;
    // Wait for in-flight bakes so covers/details ship with the shelf —
    // with the Save button spinning meanwhile (a fresh pick can still be
    // downloading its cover/key art when the user hits Save).
    if (_pendingBakes.isNotEmpty) {
      setState(() => _saving = true);
      await Future.wait(_pendingBakes.toList());
      if (!mounted) return;
    }
    Navigator.of(context).pop(ShelfResult(
      label: _labelController.text.trim(),
      games: _games,
      assets: _newAssets,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Game Shelf',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowTextField(
            controller: _labelController,
            hintText: 'Shelf label (e.g. "Backlog", optional)',
            maxLength: 40,
          ),
          const SizedBox(height: HollowSpacing.md),
          for (var i = 0; i < _games.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
              child: Row(
                children: [
                  Icon(LucideIcons.gamepad2,
                      size: 13, color: hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      (_games[i]['name'] as String?) ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  HollowPressable(
                    onTap: () => setState(() => _games.removeAt(i)),
                    semanticLabel: 'Remove game',
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.x,
                        size: 13, color: hollow.textSecondary),
                  ),
                ],
              ),
            ),
          HollowButton.ghost(
            onPressed:
                _games.length >= ShowcaseBoard.maxShelfGames ? null : _addGame,
            compact: true,
            icon: const Icon(LucideIcons.plus),
            child: Text(
                'Add Game (${_games.length}/${ShowcaseBoard.maxShelfGames})'),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _games.isEmpty || _saving ? null : _save,
          child: _saving ? _savingSpinner(hollow) : const Text('Save'),
        ),
      ],
    );
  }
}

// ── Small helpers ─────────────────────────────────────────────────────

/// One-field prompt; returns the trimmed text (possibly empty) or null on
/// cancel.
Future<String?> _promptText(
  BuildContext context, {
  required String title,
  required String hint,
  required int maxLength,
  String initial = '',
}) {
  final controller = TextEditingController(text: initial);
  return showHollowDialog<String>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: title,
      content: HollowTextField(
        controller: controller,
        hintText: hint,
        maxLength: maxLength,
        autofocus: true,
        onSubmitted: (_) =>
            Navigator.of(ctx).pop(controller.text.trim()),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(''),
          child: const Text('Skip'),
        ),
        HollowButton.filled(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

// ── Text block editor ─────────────────────────────────────────────────

/// Modal editor for a Text block. Returns the block, or null on cancel.
Future<ShowcaseBlock?> showTextBlockEditor(
  BuildContext context, {
  ShowcaseBlock? existing,
}) {
  return showHollowDialog<ShowcaseBlock>(
    context: context,
    builder: (_) => _TextBlockEditorDialog(existing: existing),
  );
}

class _TextBlockEditorDialog extends StatefulWidget {
  final ShowcaseBlock? existing;

  const _TextBlockEditorDialog({this.existing});

  @override
  State<_TextBlockEditorDialog> createState() =>
      _TextBlockEditorDialogState();
}

class _TextBlockEditorDialogState extends State<_TextBlockEditorDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;

  @override
  void initState() {
    super.initState();
    _titleController =
        TextEditingController(text: widget.existing?.textTitle ?? '');
    _bodyController =
        TextEditingController(text: widget.existing?.textBody ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _save() {
    final body = _bodyController.text.trim();
    if (body.isEmpty) return;
    Navigator.of(context).pop(ShowcaseBlock(
      type: ShowcaseBlockType.text,
      data: {
        if (_titleController.text.trim().isNotEmpty)
          'title': _titleController.text.trim(),
        'body': body,
      },
    ));
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: widget.existing == null ? 'Add Text Block' : 'Edit Text Block',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowTextField(
            controller: _titleController,
            hintText: 'Title (optional)',
            maxLength: ShowcaseBoard.maxTextTitleLength,
            autofocus: widget.existing == null,
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowTextField(
            controller: _bodyController,
            hintText: 'Write something…',
            maxLength: ShowcaseBoard.maxTextBodyLength,
            maxLines: 6,
            showCounter: true,
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Supports **bold**, *italic*, `code`, ||spoilers|| and links.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary.withValues(alpha: 0.7),
              fontSize: 10,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
