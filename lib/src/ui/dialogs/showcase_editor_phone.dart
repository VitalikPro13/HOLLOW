import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/profile_identity_column.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_blocks.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_draft.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_search.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The editor on a phone: a pushed page listing the boards in the order
/// viewers see them stacked, each block with its actions behind More.
class ShowcaseEditorPhonePage extends ConsumerStatefulWidget {
  const ShowcaseEditorPhonePage({super.key});

  @override
  ConsumerState<ShowcaseEditorPhonePage> createState() =>
      _ShowcaseEditorPhonePageState();
}

class _ShowcaseEditorPhonePageState
    extends ConsumerState<ShowcaseEditorPhonePage> {
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

  Future<PickedGame?> _search(BuildContext _) => showGameSearchSheet(context);

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

  void _openAddSheet(ShowcaseSide side) {
    showHollowSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetTitle('Add block'),
            for (final type in kShowcaseAddable)
              _SheetRow(
                icon: showcaseBlockIcon(type),
                label: showcaseBlockLabel(type),
                hint: showcaseBlockHint(type),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  addShowcaseBlock(context, _draft, side, type, _search);
                },
              ),
            const HollowDivider(),
            _SheetRow(
              icon: LucideIcons.galleryHorizontal,
              label: kWideArtworkLabel,
              hint: _draft.board.hasWide
                  ? 'You have one already. A showcase holds one.'
                  : 'One picture that spans both boards',
              onTap: _draft.board.hasWide || _draft.processingWide
                  ? null
                  : () {
                      Navigator.of(sheetContext).pop();
                      addShowcaseWide(context, _draft);
                    },
            ),
          ],
        ),
      ),
    );
  }

  void _openBlockSheet(ShowcaseBlock block) {
    final side = _draft.sideOf(block);
    final wide = identical(_draft.board.wide, block);
    final other = side == ShowcaseSide.left ? 'right' : 'left';
    void act(BuildContext sheet, VoidCallback run) {
      Navigator.of(sheet).pop();
      run();
    }

    showHollowSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SheetTitle(
              wide
                  ? kWideArtworkLabel
                  : (ShowcaseBlockView.headerOf(block).isEmpty
                        ? showcaseBlockLabel(block.type)
                        : ShowcaseBlockView.headerOf(block)),
            ),
            if (block.type == ShowcaseBlockType.nowPlaying ||
                block.type == ShowcaseBlockType.favoriteGame)
              _SheetRow(
                label: 'Change game',
                onTap: () => act(sheet, () => _changeGame(block)),
              ),
            if (block.type != ShowcaseBlockType.nowPlaying)
              _SheetRow(
                label: switch (block.type) {
                  ShowcaseBlockType.favoriteGame => 'Edit why this game',
                  ShowcaseBlockType.gameShelf => 'Edit shelf',
                  ShowcaseBlockType.artwork => 'Edit caption',
                  _ => 'Edit text',
                },
                onTap: () => act(sheet, () => _draft.beginEdit(block)),
              ),
            if (wide)
              _SheetRow(
                label: _draft.board.wideAtTop
                    ? 'Move below the boards'
                    : 'Move above the boards',
                onTap: () => act(
                  sheet,
                  () => _draft.setWideAtTop(!_draft.board.wideAtTop),
                ),
              )
            else ...[
              _SheetRow(
                label: 'Move up',
                onTap: _draft.canMoveBy(block, -1)
                    ? () => act(sheet, () => _draft.moveBy(block, -1))
                    : null,
              ),
              _SheetRow(
                label: 'Move down',
                onTap: _draft.canMoveBy(block, 1)
                    ? () => act(sheet, () => _draft.moveBy(block, 1))
                    : null,
              ),
              _SheetRow(
                label: 'Move to the $other board',
                hint: _draft.canMoveAcross(block) ? null : 'That board is full',
                onTap: _draft.canMoveAcross(block)
                    ? () => act(sheet, () => _draft.moveAcross(block))
                    : null,
              ),
            ],
            const HollowDivider(),
            _SheetRow(
              label: 'Remove',
              danger: true,
              onTap: () => act(sheet, () => _draft.remove(block)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _changeGame(ShowcaseBlock block) async {
    final game = await showGameSearchSheet(context);
    if (game == null) return;
    final placed = gameBlockFor(block.type, game, blurb: block.gameBlurb);
    _draft.replace(block, placed.block, keepBakes: false);
    _draft.trackBake(placed.block, placed.bake);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final board = _draft.board;
    final hasWide = board.hasWide || _draft.processingWide;
    final over = _draft.overSizeLimit;
    final error = over
        ? 'Your showcase is over its size limit. Shorten a text block to save.'
        : _draft.saveError;
    return PopScope(
      canPop: _leaving || !_draft.dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_draft.saving) _askToLeave();
      },
      child: Scaffold(
        backgroundColor: hollow.background,
        body: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.xs,
                  vertical: HollowSpacing.xs,
                ),
                child: Row(
                  children: [
                    HollowIconButton(
                      icon: LucideIcons.arrowLeft,
                      label: 'Back',
                      size: 44,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    Expanded(
                      child: Text(
                        'Edit showcase',
                        style: HollowTypography.subheading.copyWith(
                          color: hollow.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const HollowDivider(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(HollowSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hasWide && board.wideAtTop) ...[
                        _wideSection(),
                        const _SectionBreak(),
                      ],
                      _boardSection(ShowcaseSide.left),
                      const _SectionBreak(),
                      _boardSection(ShowcaseSide.right),
                      if (hasWide && !board.wideAtTop) ...[
                        const _SectionBreak(),
                        _wideSection(),
                      ],
                    ],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: hollow.background,
                  border: Border(top: BorderSide(color: hollow.border)),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    HollowSpacing.lg,
                    HollowSpacing.md,
                    HollowSpacing.lg,
                    HollowSpacing.lg,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null) ...[
                        Text(
                          error,
                          style: HollowTypography.bodySmall.copyWith(
                            color: hollow.error,
                          ),
                        ),
                        const SizedBox(height: HollowSpacing.sm),
                      ],
                      HollowButton.filled(
                        touch: true,
                        expand: true,
                        loading: _draft.saving,
                        onPressed: over ? null : _save,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading(String name, String? count) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              style: HollowTypography.label.copyWith(color: hollow.textPrimary),
            ),
          ),
          if (count != null)
            Text(
              count,
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }

  Widget _boardSection(ShowcaseSide side) {
    final hollow = HollowTheme.of(context);
    final blocks = _draft.side(side);
    final processing = _draft.processingSide == side;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          side == ShowcaseSide.left ? 'Left board' : 'Right board',
          '${blocks.length} of ${ShowcaseBoard.maxBlocksPerSide}',
        ),
        if (blocks.isEmpty && !processing)
          const HollowEmptyState(
            dense: true,
            title: 'Nothing on this side yet',
            description:
                'A side with nothing on it stays hidden on your profile',
          ),
        for (final block in blocks) ...[
          _block(block),
          const SizedBox(height: HollowSpacing.xl),
        ],
        if (processing) ...[
          const ShowcaseProcessingBlock(),
          const SizedBox(height: HollowSpacing.xl),
        ],
        if (_draft.isFull(side))
          Text(
            'A side holds ${ShowcaseBoard.maxBlocksPerSide} blocks. Remove one '
            'to add another.',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textTertiary,
            ),
          )
        else
          ShowcaseOnTextEdge(
            child: HollowButton.ghost(
              touch: true,
              icon: const Icon(LucideIcons.plus),
              onPressed: processing ? null : () => _openAddSheet(side),
              child: const Text('Add block'),
            ),
          ),
      ],
    );
  }

  Widget _wideSection() {
    final wide = _draft.board.wide;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading('Across both boards', null),
        if (wide == null)
          const ShowcaseProcessingBlock()
        else
          _block(wide, isWide: true),
      ],
    );
  }

  Widget _block(ShowcaseBlock block, {bool isWide = false}) {
    if (identical(_draft.editing, block)) {
      final key = ValueKey('edit-${_draft.idOf(block)}');
      return switch (block.type) {
        ShowcaseBlockType.text => ShowcaseTextEditor(
          key: key,
          draft: _draft,
          touch: true,
        ),
        ShowcaseBlockType.artwork => ShowcaseCaptionEditor(
          key: key,
          draft: _draft,
          wide: isWide,
          touch: true,
        ),
        ShowcaseBlockType.favoriteGame => ShowcaseBlurbEditor(
          key: key,
          draft: _draft,
          search: _search,
          touch: true,
        ),
        ShowcaseBlockType.gameShelf => ShowcaseShelfEditor(
          key: key,
          draft: _draft,
          search: _search,
          touch: true,
        ),
        _ => const SizedBox.shrink(),
      };
    }
    final label = ShowcaseBlockView.headerOf(block).isEmpty
        ? showcaseBlockLabel(block.type)
        : ShowcaseBlockView.headerOf(block);
    final view = isWide
        ? ShowcaseWideArtwork(block: block, assets: _draft.assets)
        : ShowcaseBlockView(
            block: block,
            assets: _draft.assets,
            ownerPeerId: _draft.peerId,
          );
    final onArt = block.type == ShowcaseBlockType.artwork;
    return Stack(
      key: ValueKey(_draft.idOf(block)),
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _openBlockSheet(block),
          // A game here opens its actions, not its card.
          child: IgnorePointer(child: view),
        ),
        Positioned(
          top: onArt ? HollowSpacing.sm : -HollowSpacing.md,
          right: onArt ? HollowSpacing.sm : -HollowSpacing.md,
          child: onArt
              ? MediaScrimIconButton(
                  icon: LucideIcons.ellipsis,
                  label: '$label options',
                  size: 44,
                  onPressed: () => _openBlockSheet(block),
                )
              : HollowIconButton(
                  icon: LucideIcons.ellipsis,
                  label: '$label options',
                  size: 44,
                  onPressed: () => _openBlockSheet(block),
                ),
        ),
      ],
    );
  }
}

class _SectionBreak extends StatelessWidget {
  const _SectionBreak();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: HollowSpacing.xl),
    child: HollowDivider(),
  );
}

class _SheetTitle extends StatelessWidget {
  final String text;

  const _SheetTitle(this.text);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.lg,
        HollowSpacing.xs,
        HollowSpacing.lg,
        HollowSpacing.sm,
      ),
      child: Text(
        text,
        style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
      ),
    );
  }
}

/// One row of a phone action sheet; null [onTap] shows it unavailable.
class _SheetRow extends StatelessWidget {
  final IconData? icon;
  final String label;
  final String? hint;
  final bool danger;
  final VoidCallback? onTap;

  const _SheetRow({
    required this.label,
    required this.onTap,
    this.icon,
    this.hint,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final enabled = onTap != null;
    final color = !enabled
        ? hollow.textTertiary
        : (danger ? hollow.error : hollow.textPrimary);
    return HollowPressable(
      onTap: onTap,
      disabled: !enabled,
      semanticLabel: label,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 20,
                color: enabled ? hollow.textSecondary : color,
              ),
              const SizedBox(width: HollowSpacing.lg),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: HollowTypography.bodyTouch.copyWith(color: color),
                  ),
                  if (hint != null)
                    Text(
                      hint!,
                      style: HollowTypography.bodySmall.copyWith(
                        color: hollow.textTertiary,
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
}
