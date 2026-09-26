import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/profile_identity_column.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/dialogs/profile_dialog.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_blocks.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_draft.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_phone.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_search.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

export 'package:hollow/src/ui/dialogs/showcase_editor_draft.dart'
    show BakedGame, PickedGame, bakeGame;

/// Opens the showcase editor for the LOCAL user: the profile dialog in edit
/// mode on desktop, a pushed page on a phone.
void showShowcaseEditorDialog(BuildContext context, WidgetRef ref) {
  final phone =
      Platform.isAndroid ||
      Platform.isIOS ||
      MediaQuery.sizeOf(context).width < 600;
  if (phone) {
    Navigator.of(context).push(
      hollowMobileRoute<void>(builder: (_) => const ShowcaseEditorPhonePage()),
    );
    return;
  }
  showHollowDialog<void>(
    context: context,
    builder: (_) => const ShowcaseEditorDialog(),
  );
}

/// A fresh draft of the local user's board, its pictures loading.
ShowcaseDraft openShowcaseDraft(WidgetRef ref) {
  final peerId = ref.read(identityProvider).peerId ?? '';
  final profile = ref.read(profileProvider)[peerId];
  return ShowcaseDraft(
    peerId: peerId,
    initial: ShowcaseBoard.decode(profile?.showcaseBoard),
  )..loadAssets();
}

/// The block kinds offered by Add block, in menu order.
const kShowcaseAddable = [
  ShowcaseBlockType.nowPlaying,
  ShowcaseBlockType.favoriteGame,
  ShowcaseBlockType.gameShelf,
  ShowcaseBlockType.artwork,
  ShowcaseBlockType.text,
];

String showcaseBlockLabel(ShowcaseBlockType type) => switch (type) {
  ShowcaseBlockType.nowPlaying => 'Now playing',
  ShowcaseBlockType.favoriteGame => 'Favourite game',
  ShowcaseBlockType.gameShelf => 'Game shelf',
  ShowcaseBlockType.artwork => 'Artwork',
  ShowcaseBlockType.text => 'Text',
  ShowcaseBlockType.unknown => '',
};

String showcaseBlockHint(ShowcaseBlockType type) => switch (type) {
  ShowcaseBlockType.nowPlaying => 'The game you are playing right now',
  ShowcaseBlockType.favoriteGame => 'One game, and why it stays with you',
  ShowcaseBlockType.gameShelf => 'Up to 8 games, like a backlog',
  ShowcaseBlockType.artwork => 'An image or GIF, with a caption',
  ShowcaseBlockType.text => 'A few lines, with bold, links and spoilers',
  ShowcaseBlockType.unknown => '',
};

IconData showcaseBlockIcon(ShowcaseBlockType type) => switch (type) {
  ShowcaseBlockType.nowPlaying => LucideIcons.gamepad2,
  ShowcaseBlockType.favoriteGame => LucideIcons.heart,
  ShowcaseBlockType.gameShelf => LucideIcons.libraryBig,
  ShowcaseBlockType.artwork => LucideIcons.image,
  ShowcaseBlockType.text => LucideIcons.type,
  ShowcaseBlockType.unknown => LucideIcons.box,
};

const kWideArtworkLabel = 'Wide artwork (across both boards)';

/// The label on a block's Edit control.
String showcaseEditLabel(ShowcaseBlock block) => switch (block.type) {
  ShowcaseBlockType.nowPlaying => 'Change game',
  ShowcaseBlockType.favoriteGame => 'Edit favourite game',
  ShowcaseBlockType.gameShelf => 'Edit shelf',
  ShowcaseBlockType.artwork => 'Edit caption',
  _ => 'Edit text',
};

/// Adds a block of [type] to [side]; games ask [search] first, artwork opens
/// the file picker. Desktop and phone both add through here.
Future<void> addShowcaseBlock(
  BuildContext context,
  ShowcaseDraft draft,
  ShowcaseSide side,
  ShowcaseBlockType type,
  ShowcaseGameSearch search,
) async {
  switch (type) {
    case ShowcaseBlockType.nowPlaying:
    case ShowcaseBlockType.favoriteGame:
      final game = await search(context);
      if (game == null) return;
      final placed = gameBlockFor(type, game);
      draft.add(
        side,
        placed.block,
        edit: type == ShowcaseBlockType.favoriteGame,
      );
      // The game is the block; a line under it is optional.
      draft.editingIsNew = false;
      draft.trackBake(placed.block, placed.bake);
    case ShowcaseBlockType.gameShelf:
      draft.add(
        side,
        const ShowcaseBlock(type: ShowcaseBlockType.gameShelf),
        edit: true,
      );
    case ShowcaseBlockType.text:
      draft.add(
        side,
        const ShowcaseBlock(type: ShowcaseBlockType.text),
        edit: true,
      );
    case ShowcaseBlockType.artwork:
      final block = await _pickArtwork(context, draft, side);
      if (block == null) return;
      draft.add(side, block, edit: true);
      draft.editingIsNew = false;
    case ShowcaseBlockType.unknown:
      break;
  }
}

/// Adds the one artwork that spans both boards.
Future<void> addShowcaseWide(BuildContext context, ShowcaseDraft draft) async {
  final block = await _pickArtwork(context, draft, null);
  if (block == null) return;
  draft.setWide(block, edit: true);
  draft.editingIsNew = false;
}

Future<ShowcaseBlock?> _pickArtwork(
  BuildContext context,
  ShowcaseDraft draft,
  ShowcaseSide? side,
) async {
  try {
    return await draft.pickArtwork(forSide: side);
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(
        context,
        friendlyError(e, fallback: 'That picture could not be used.'),
        type: HollowToastType.error,
      );
    }
    return null;
  }
}

/// Opens [block] for editing in place; Now playing has nothing to edit but
/// the game, so it goes straight to search.
Future<void> editShowcaseBlock(
  BuildContext anchor,
  ShowcaseDraft draft,
  ShowcaseBlock block,
  ShowcaseGameSearch search,
) async {
  if (block.type != ShowcaseBlockType.nowPlaying) {
    draft.beginEdit(block);
    return;
  }
  final game = await search(anchor);
  if (game == null) return;
  final placed = gameBlockFor(block.type, game);
  draft.replace(block, placed.block, keepBakes: false);
  draft.trackBake(placed.block, placed.bake);
}

/// Asks before throwing away changes. True when the editor may close.
Future<bool> confirmDiscardShowcase(BuildContext context) => showHollowConfirm(
  context: context,
  title: 'Discard your changes?',
  message: 'Your showcase stays as it was.',
  confirmLabel: 'Discard',
  destructive: true,
);

/// The editor on desktop: the profile dialog in edit mode. Your identity
/// column stays as context, both boards are always open, blocks look exactly
/// as viewers see them, and the only thing ever layered on top is a menu or
/// game search.
class ShowcaseEditorDialog extends ConsumerStatefulWidget {
  const ShowcaseEditorDialog({super.key});

  @override
  ConsumerState<ShowcaseEditorDialog> createState() =>
      _ShowcaseEditorDialogState();
}

class _ShowcaseEditorDialogState extends ConsumerState<ShowcaseEditorDialog> {
  late final ShowcaseDraft _draft = openShowcaseDraft(ref)
    ..addListener(_changed);
  bool _leaving = false;

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _draft
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  Future<void> _save() async {
    try {
      await _draft.save(ref.read(profileProvider.notifier));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _draft.saveError = friendlyError(
          e,
          fallback: 'Your showcase could not be saved. Try again.',
        ),
      );
      return;
    }
    if (!mounted) return;
    _leaving = true;
    Navigator.of(context).pop();
    HollowToast.show(context, 'Showcase saved', type: HollowToastType.success);
  }

  Future<void> _askToLeave() async {
    if (!await confirmDiscardShowcase(context) || !mounted) return;
    _leaving = true;
    Navigator.of(context).pop();
  }

  Future<PickedGame?> _search(BuildContext anchor, {bool alignEnd = false}) {
    final box = anchor.findRenderObject() as RenderBox?;
    final height = box?.size.height ?? 0;
    return showGameSearchPopover(
      anchor,
      anchor: overlayAnchorOf(
        anchor,
        localOffset: Offset(
          alignEnd ? math.max(box?.size.width ?? 0, kShowcaseColumnWidth) : 0,
          height + HollowSpacing.xs,
        ),
      ),
      alignEnd: alignEnd,
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final available = size.width - HollowSpacing.xl * 2;
    final twoColumns =
        kProfileColumnWidth + 1 + showcasePaneWidth(2) <= available;
    final withIdentity =
        kProfileColumnWidth + 1 + showcasePaneWidth(1) <= available;
    final paneWidth = showcasePaneWidth(twoColumns ? 2 : 1);
    final width = (withIdentity ? kProfileColumnWidth + 1 : 0) + paneWidth;
    final height = math.min(820.0, size.height - HollowSpacing.xl * 2);

    return PopScope(
      canPop: _leaving || !_draft.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_draft.saving) _askToLeave();
      },
      child: HollowDialogSurface(
        width: width,
        maxWidth: width,
        maxHeight: height,
        padded: false,
        child: SizedBox(
          height: height,
          child: Column(
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (withIdentity) ...[
                      SizedBox(
                        width: kProfileColumnWidth,
                        // No scrollbar: its gutter would pull the banner off
                        // the dialog's edge.
                        child: ScrollConfiguration(
                          behavior: ScrollConfiguration.of(
                            context,
                          ).copyWith(scrollbars: false),
                          child: SingleChildScrollView(
                            child: ProfileIdentityColumn(
                              peerId: _draft.peerId,
                              density: ProfileCardDensity.full,
                              width: kProfileColumnWidth,
                              dismissHost: () {},
                              showActions: false,
                            ),
                          ),
                        ),
                      ),
                      const HollowVerticalDivider(),
                    ],
                    SizedBox(
                      width: paneWidth,
                      child: _EditorPane(
                        draft: _draft,
                        columns: twoColumns ? 2 : 1,
                        search: _search,
                      ),
                    ),
                  ],
                ),
              ),
              const HollowDivider(),
              _Footer(
                draft: _draft,
                onCancel: () => Navigator.of(context).maybePop(),
                onSave: _save,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

typedef _AnchoredSearch =
    Future<PickedGame?> Function(BuildContext anchor, {bool alignEnd});

class _EditorPane extends StatelessWidget {
  final ShowcaseDraft draft;
  final int columns;
  final _AnchoredSearch search;

  const _EditorPane({
    required this.draft,
    required this.columns,
    required this.search,
  });

  @override
  Widget build(BuildContext context) {
    final board = draft.board;
    final gutter = scrollGutterOf(context);
    final Widget boards = columns == 2
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: kShowcaseColumnWidth,
                child: _BoardColumn(
                  draft: draft,
                  side: ShowcaseSide.left,
                  search: search,
                ),
              ),
              const SizedBox(width: kShowcaseGap),
              SizedBox(
                width: kShowcaseColumnWidth,
                child: _BoardColumn(
                  draft: draft,
                  side: ShowcaseSide.right,
                  search: search,
                  trailing: true,
                ),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BoardColumn(
                draft: draft,
                side: ShowcaseSide.left,
                search: search,
              ),
              const SizedBox(height: kShowcaseGap),
              _BoardColumn(
                draft: draft,
                side: ShowcaseSide.right,
                search: search,
              ),
            ],
          );
    final hasWide = board.hasWide || draft.processingWide;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        kShowcasePanePadding,
        kShowcasePanePadding,
        kShowcasePanePadding - gutter,
        kShowcasePanePadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hasWide && board.wideAtTop) ...[
            _WideSlot(draft: draft, columns: columns),
            const SizedBox(height: kShowcaseGap),
          ],
          boards,
          if (hasWide && !board.wideAtTop) ...[
            const SizedBox(height: kShowcaseGap),
            _WideSlot(draft: draft, columns: columns),
          ],
        ],
      ),
    );
  }
}

/// One board while editing: its name and count, its blocks in order (drag
/// the handle to reorder), and Add block at its foot.
class _BoardColumn extends StatelessWidget {
  final ShowcaseDraft draft;
  final ShowcaseSide side;
  final _AnchoredSearch search;

  /// The right-hand column: its popovers hang from its trailing edge.
  final bool trailing;

  const _BoardColumn({
    required this.draft,
    required this.side,
    required this.search,
    this.trailing = false,
  });

  String get _name => side == ShowcaseSide.left ? 'Left board' : 'Right board';

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final blocks = draft.side(side);
    final processing = draft.processingSide == side;
    Future<PickedGame?> find(BuildContext anchor) =>
        search(anchor, alignEnd: trailing);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _name,
                style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
            Text(
              '${blocks.length} of ${ShowcaseBoard.maxBlocksPerSide}',
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.lg),
        if (blocks.isEmpty && !processing)
          const HollowEmptyState(
            dense: true,
            title: 'Nothing on this side yet',
            description:
                'A side with nothing on it stays hidden on your profile',
          ),
        // The blocks sit on the column's edge; their hover and edit frames
        // bleed past it.
        HollowBleed(
          horizontal: HollowSpacing.sm,
          child: ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: blocks.length,
            proxyDecorator: (child, _, _) => _DragLift(child: child),
            onReorderItem: (from, to) => draft.reorder(side, from, to),
            itemBuilder: (context, i) {
              final block = blocks[i];
              return Padding(
                key: ValueKey(draft.idOf(block)),
                padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
                child: _blockFor(context, block, i, find),
              );
            },
          ),
        ),
        if (processing) ...[
          const ShowcaseProcessingBlock(),
          const SizedBox(height: HollowSpacing.lg),
        ],
        if (draft.isFull(side))
          Text(
            'A side holds ${ShowcaseBoard.maxBlocksPerSide} blocks. Remove one '
            'to add another.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
            ),
          )
        else
          ShowcaseOnTextEdge(
            child: Builder(
              builder: (anchor) => HollowButton.ghost(
                icon: const Icon(LucideIcons.plus),
                onPressed: processing
                    ? null
                    : () => _openAddMenu(context, anchor, find),
                child: const Text('Add block'),
              ),
            ),
          ),
      ],
    );
  }

  Widget _blockFor(
    BuildContext context,
    ShowcaseBlock block,
    int index,
    ShowcaseGameSearch find,
  ) {
    if (identical(draft.editing, block)) {
      final key = ValueKey('edit-${draft.idOf(block)}');
      return switch (block.type) {
        ShowcaseBlockType.text => ShowcaseTextEditor(key: key, draft: draft),
        ShowcaseBlockType.artwork => ShowcaseCaptionEditor(
          key: key,
          draft: draft,
        ),
        ShowcaseBlockType.favoriteGame => ShowcaseBlurbEditor(
          key: key,
          draft: draft,
          search: find,
        ),
        ShowcaseBlockType.gameShelf => ShowcaseShelfEditor(
          key: key,
          draft: draft,
          search: find,
        ),
        _ => const SizedBox.shrink(),
      };
    }
    return Builder(
      builder: (blockContext) => EditableShowcaseBlock(
        view: ShowcaseBlockView(
          block: block,
          assets: draft.assets,
          ownerPeerId: draft.peerId,
        ),
        editLabel: showcaseEditLabel(block),
        onEdit: () => editShowcaseBlock(blockContext, draft, block, find),
        onRemove: () => draft.remove(block),
        handle: ReorderableDragStartListener(
          index: index,
          child: Builder(
            builder: (handleContext) => HollowIconButton(
              icon: LucideIcons.gripVertical,
              label: 'Move',
              onPressed: () => _openMoveMenu(handleContext, block),
            ),
          ),
        ),
      ),
    );
  }

  void _openMoveMenu(BuildContext anchor, ShowcaseBlock block) {
    final other = side == ShowcaseSide.left ? 'right' : 'left';
    showHollowMenu(
      context: anchor,
      anchor: overlayAnchorOf(anchor, localOffset: const Offset(0, 36)),
      builder: (_, _) => [
        HollowMenuItem(
          icon: LucideIcons.arrowUp,
          label: 'Move up',
          enabled: draft.canMoveBy(block, -1),
          onTap: () => draft.moveBy(block, -1),
        ),
        HollowMenuItem(
          icon: LucideIcons.arrowDown,
          label: 'Move down',
          enabled: draft.canMoveBy(block, 1),
          onTap: () => draft.moveBy(block, 1),
        ),
        HollowMenuItem(
          icon: side == ShowcaseSide.left
              ? LucideIcons.arrowRight
              : LucideIcons.arrowLeft,
          label: 'Move to the $other board',
          trailing: draft.canMoveAcross(block) ? null : 'Full',
          enabled: draft.canMoveAcross(block),
          onTap: () => draft.moveAcross(block),
        ),
      ],
    );
  }

  void _openAddMenu(
    BuildContext context,
    BuildContext anchor,
    ShowcaseGameSearch find,
  ) {
    final box = anchor.findRenderObject() as RenderBox?;
    showHollowMenu(
      context: anchor,
      anchor: overlayAnchorOf(
        anchor,
        localOffset: Offset(0, (box?.size.height ?? 0) + HollowSpacing.xs),
      ),
      builder: (_, _) => [
        for (final type in kShowcaseAddable)
          HollowMenuItem(
            icon: showcaseBlockIcon(type),
            label: showcaseBlockLabel(type),
            onTap: () => addShowcaseBlock(anchor, draft, side, type, find),
          ),
        const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.galleryHorizontal,
          label: kWideArtworkLabel,
          trailing: draft.board.hasWide ? 'You have one' : null,
          enabled: !draft.board.hasWide && !draft.processingWide,
          onTap: () => addShowcaseWide(anchor, draft),
        ),
      ],
    );
  }
}

/// The artwork across both boards, where viewers will see it.
class _WideSlot extends StatelessWidget {
  final ShowcaseDraft draft;
  final int columns;

  const _WideSlot({required this.draft, required this.columns});

  @override
  Widget build(BuildContext context) {
    final wide = draft.board.wide;
    final Widget child;
    if (wide == null) {
      child = const ShowcaseProcessingBlock(height: 240);
    } else if (identical(draft.editing, wide)) {
      child = ShowcaseCaptionEditor(
        key: ValueKey('edit-${draft.idOf(wide)}'),
        draft: draft,
        wide: true,
      );
    } else {
      final top = draft.board.wideAtTop;
      child = EditableShowcaseBlock(
        view: ShowcaseWideArtwork(block: wide, assets: draft.assets),
        editLabel: 'Edit caption',
        onEdit: () => draft.beginEdit(wide),
        onRemove: () => draft.remove(wide),
        leadingTools: [
          HollowChip(
            label: 'Top',
            selected: top,
            onTap: () => draft.setWideAtTop(true),
          ),
          HollowChip(
            label: 'Bottom',
            selected: !top,
            onTap: () => draft.setWideAtTop(false),
          ),
        ],
      );
    }
    // The wide piece spans exactly the columns under it, however wide the
    // scroll view is.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: columns == 2 ? kShowcaseWideWidth : kShowcaseColumnWidth,
        child: HollowBleed(horizontal: HollowSpacing.sm, child: child),
      ),
    );
  }
}

/// The dragged block, lifted.
class _DragLift extends StatelessWidget {
  final Widget child;

  const _DragLift({required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return DefaultTextStyle(
      style: HollowTypography.body.copyWith(color: hollow.textPrimary),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hollow.hover,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          boxShadow: HollowShadows.float,
        ),
        child: child,
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final ShowcaseDraft draft;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  const _Footer({
    required this.draft,
    required this.onCancel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final over = draft.overSizeLimit;
    final error = over
        ? 'Your showcase is over its size limit. Shorten a text block to save.'
        : draft.saveError;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.xl,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          if (error != null) ...[
            Icon(LucideIcons.circleAlert, size: 16, color: hollow.error),
            const SizedBox(width: HollowSpacing.sm),
          ],
          Expanded(
            child: Text(
              error ?? 'People see your showcase when you save',
              style: HollowTypography.bodySmall.copyWith(
                color: error != null ? hollow.error : hollow.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: HollowSpacing.lg),
          HollowButton.ghost(
            onPressed: draft.saving ? null : onCancel,
            child: const Text('Cancel'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            onPressed: over ? null : onSave,
            loading: draft.saving,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
