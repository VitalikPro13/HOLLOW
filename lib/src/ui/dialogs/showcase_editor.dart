import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
    final encoded = _board.encode();
    if (encoded.length > ShowcaseBoard.maxEncodedLength) {
      HollowToast.show(
        context,
        'Showcase is too large — shorten a text block',
        type: HollowToastType.error,
      );
      return;
    }
    // The board is the source of truth: ship exactly the assets it
    // references (pruning anything orphaned by removed blocks).
    final referenced = _board.referencedAssetHashes();
    final assets = [
      for (final e in _assets.entries)
        if (referenced.contains(e.key))
          showcase_api.ShowcaseAsset(hash: e.key, bytes: e.value),
    ];
    final totalBytes =
        assets.fold<int>(0, (sum, a) => sum + a.bytes.length);
    if (totalBytes > 1_400_000) {
      HollowToast.show(
        context,
        'Showcase images too large — remove an artwork or game',
        type: HollowToastType.error,
      );
      return;
    }
    final peerId = ref.read(identityProvider).peerId ?? '';
    final navigator = Navigator.of(context);
    await ref
        .read(profileProvider.notifier)
        .updateShowcaseBoard(peerId, encoded, assets: assets);
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

  /// The full add-block flow for one side: picker → type-specific editor.
  Future<void> _addBlockTo({required bool left}) async {
    final type = await _showBlockPicker(context);
    if (type == null || !mounted) return;

    ShowcaseBlock? block;
    switch (type) {
      case ShowcaseBlockType.text:
        block = await showTextBlockEditor(context);

      case ShowcaseBlockType.nowPlaying:
      case ShowcaseBlockType.favoriteGame:
        final game = await showGamePickerDialog(context);
        if (game == null || !mounted) break;
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
        if (game.asset != null) _stashAsset(game.asset!);
        block = ShowcaseBlock(type: type, data: {
          'name': game.name,
          if (game.asset != null) 'cover': game.asset!.hash,
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
    switch (block.type) {
      case ShowcaseBlockType.text:
        edited = await showTextBlockEditor(context, existing: block);

      case ShowcaseBlockType.nowPlaying:
        final game = await showGamePickerDialog(context);
        if (game == null) break;
        if (game.asset != null) _stashAsset(game.asset!);
        edited = ShowcaseBlock(type: block.type, data: {
          'name': game.name,
          if (game.asset != null) 'cover': game.asset!.hash,
          if (game.year != null) 'year': game.year,
        });

      case ShowcaseBlockType.favoriteGame:
        final game = await showGamePickerDialog(context);
        if (game == null || !mounted) break;
        final blurb = (await _promptText(
              context,
              title: 'Why this game?',
              hint: 'A short personal blurb (optional)',
              maxLength: 200,
              initial: block.gameBlurb,
            )) ??
            block.gameBlurb;
        if (game.asset != null) _stashAsset(game.asset!);
        edited = ShowcaseBlock(type: block.type, data: {
          'name': game.name,
          if (game.asset != null) 'cover': game.asset!.hash,
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
          child: const Text('Save'),
        ),
      ],
    );
  }
}

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

class PickedGame {
  final String name;
  final int? year;
  final showcase_api.ShowcaseAsset? asset;

  const PickedGame({required this.name, this.year, this.asset});
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
  bool _fetching = false;
  String? _error;

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
      setState(() { _results = const []; _error = null; });
      return;
    }
    setState(() { _searching = true; _error = null; });
    try {
      final results = await showcase_api.showcaseGameSearch(query: q);
      if (!mounted) return;
      setState(() { _results = results; _searching = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _error = 'Search unavailable — check your connection';
      });
    }
  }

  Future<void> _pick(showcase_api.GameSearchResult game) async {
    if (_fetching) return;
    final year = game.year;
    if (game.coverUrl == null) {
      Navigator.of(context)
          .pop(PickedGame(name: game.name, year: year));
      return;
    }
    setState(() => _fetching = true);
    try {
      final asset =
          await showcase_api.showcaseFetchCover(url: game.coverUrl!);
      if (!mounted) return;
      Navigator.of(context)
          .pop(PickedGame(name: game.name, year: year, asset: asset));
    } catch (_) {
      if (!mounted) return;
      // Cover fetch failed — still usable without art.
      Navigator.of(context)
          .pop(PickedGame(name: game.name, year: year));
    }
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
          if (_searching || _fetching)
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
              child: Text(
                _error!,
                style: HollowTypography.caption.copyWith(
                  color: hollow.error,
                  fontSize: 11,
                ),
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

  /// `{name, cover?}` maps — prefilled from an existing block; new picks
  /// append here and their bytes to [_newAssets].
  late final List<Map<String, dynamic>> _games;
  final List<showcase_api.ShowcaseAsset> _newAssets = [];

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
    if (game.asset != null) _newAssets.add(game.asset!);
    setState(() => _games.add({
          'name': game.name,
          if (game.asset != null) 'cover': game.asset!.hash,
        }));
  }

  void _save() {
    if (_games.isEmpty) return;
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
          onPressed: _games.isEmpty ? null : _save,
          child: const Text('Save'),
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
