import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_draft.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Finds a game from wherever [anchor] sits: a popover on desktop, a sheet on
/// a phone.
typedef ShowcaseGameSearch = Future<PickedGame?> Function(BuildContext anchor);

/// A field's label with a quiet note or count on the trailing edge.
class ShowcaseFieldLabel extends StatelessWidget {
  final String label;
  final String? trailing;

  const ShowcaseFieldLabel(this.label, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: HollowTypography.label.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ),
          if (trailing != null)
            Text(
              trailing!,
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}

/// Puts a ghost button's label on the text edge of the column above it, so
/// the button's own padding and hover reach out past the edge instead.
class ShowcaseOnTextEdge extends StatelessWidget {
  final bool compact;
  final Widget child;

  const ShowcaseOnTextEdge({
    super.key,
    required this.child,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Transform.translate(
      offset: Offset(-(compact ? HollowSpacing.md : HollowSpacing.lg), 0),
      child: child,
    ),
  );
}

/// Catches Escape inside an in-place editor so it cancels the edit instead of
/// reaching the dialog, where it would ask to discard the whole showcase.
class _EscapeCancels extends StatelessWidget {
  final VoidCallback onCancel;
  final Widget child;

  const _EscapeCancels({required this.onCancel, required this.child});

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) {
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        onCancel();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
    child: child,
  );
}

/// A block on the desktop editor: exactly what viewers see, with a floating
/// toolbar on hover or keyboard focus. A click on the block edits it.
class EditableShowcaseBlock extends StatefulWidget {
  final Widget view;
  final String editLabel;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  /// The drag handle, already wrapped for the list it moves in; null where a
  /// block cannot move (the wide artwork).
  final Widget? handle;

  /// Controls shown before the icons (the wide artwork's Top / Bottom).
  final List<Widget> leadingTools;

  const EditableShowcaseBlock({
    super.key,
    required this.view,
    required this.editLabel,
    required this.onEdit,
    required this.onRemove,
    this.handle,
    this.leadingTools = const [],
  });

  @override
  State<EditableShowcaseBlock> createState() => _EditableShowcaseBlockState();
}

class _EditableShowcaseBlockState extends State<EditableShowcaseBlock> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final active = _hovered || _focused;
    return FocusScope(
      canRequestFocus: true,
      onFocusChange: (f) => setState(() => _focused = f),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onEdit,
              child: AnimatedContainer(
                duration: HollowDurations.fast,
                padding: const EdgeInsets.all(HollowSpacing.sm),
                decoration: BoxDecoration(
                  color: active ? hollow.hover : null,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                ),
                // The block's own taps (a game opening its card) belong to
                // viewers; here a click edits.
                child: IgnorePointer(child: widget.view),
              ),
            ),
            Positioned(
              top: HollowSpacing.xs,
              right: HollowSpacing.xs,
              // Hidden until hover or focus, but always there for a screen
              // reader and for Tab.
              child: AnimatedOpacity(
                opacity: active ? 1 : 0,
                duration: HollowDurations.fast,
                alwaysIncludeSemantics: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hollow.overlay,
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    border: Border.all(color: hollow.border),
                    boxShadow: HollowShadows.float,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(HollowSpacing.xxs),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final t in widget.leadingTools) ...[
                          t,
                          const SizedBox(width: HollowSpacing.xs),
                        ],
                        if (widget.handle != null) widget.handle!,
                        HollowIconButton(
                          icon: LucideIcons.pencil,
                          label: widget.editLabel,
                          onPressed: widget.onEdit,
                        ),
                        HollowIconButton(
                          icon: LucideIcons.trash2,
                          label: 'Remove block',
                          onPressed: widget.onRemove,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frame around a block being edited in place: the hover fill, held.
class ShowcaseEditFrame extends StatelessWidget {
  final Widget child;
  final bool touch;

  const ShowcaseEditFrame({super.key, required this.child, this.touch = false});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    if (touch) return child;
    return Container(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.hover,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: child,
    );
  }
}

/// Ghost Cancel and a compact outline Done, for the editors that take more
/// than one field.
class _EditorActions extends StatelessWidget {
  final VoidCallback onCancel;
  final VoidCallback? onDone;
  final bool touch;

  const _EditorActions({
    required this.onCancel,
    required this.onDone,
    required this.touch,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: HollowSpacing.md),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        HollowButton.ghost(
          compact: !touch,
          touch: touch,
          onPressed: onCancel,
          child: const Text('Cancel'),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.outline(
          compact: !touch,
          touch: touch,
          onPressed: onDone,
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// A text block's title and body, edited where the block sits. Every
/// keystroke lands in the draft; Cancel puts the block back as it was.
class ShowcaseTextEditor extends StatefulWidget {
  final ShowcaseDraft draft;
  final bool touch;

  const ShowcaseTextEditor({
    super.key,
    required this.draft,
    this.touch = false,
  });

  @override
  State<ShowcaseTextEditor> createState() => _ShowcaseTextEditorState();
}

class _ShowcaseTextEditorState extends State<ShowcaseTextEditor> {
  late final ShowcaseBlock _original = widget.draft.editing!;
  late final _title = TextEditingController(text: _original.textTitle);
  late final _body = TextEditingController(text: _original.textBody);

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  void _write() {
    final current = widget.draft.editing;
    if (current == null) return;
    final title = _title.text.trim();
    final body = _body.text.trim();
    widget.draft.replace(
      current,
      ShowcaseBlock(
        type: ShowcaseBlockType.text,
        data: {
          if (title.isNotEmpty) 'title': title,
          if (body.isNotEmpty) 'body': body,
        },
      ),
    );
    setState(() {});
  }

  void _cancel() {
    final current = widget.draft.editing;
    if (current != null && !widget.draft.editingIsNew) {
      widget.draft.replace(current, _original);
    }
    widget.draft.endEdit(committed: false);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = widget.touch;
    return _EscapeCancels(
      onCancel: _cancel,
      child: ShowcaseEditFrame(
        touch: touch,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ShowcaseFieldLabel(
              'Title',
              trailing:
                  '${_title.text.length}/${ShowcaseBoard.maxTextTitleLength}',
            ),
            HollowTextField(
              controller: _title,
              hintText: 'Currently',
              autofocus: _original.textTitle.isEmpty,
              maxLength: ShowcaseBoard.maxTextTitleLength,
              showCounter: false,
              onChanged: (_) => _write(),
            ),
            const SizedBox(height: HollowSpacing.md),
            ShowcaseFieldLabel(
              'Text',
              trailing:
                  '${_body.text.length}/${ShowcaseBoard.maxTextBodyLength}',
            ),
            HollowTextField(
              controller: _body,
              hintText: 'A few lines about you',
              maxLength: ShowcaseBoard.maxTextBodyLength,
              showCounter: false,
              minLines: 4,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              onChanged: (_) => _write(),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              '**bold**, *italic*, `code`, ||spoilers|| and links work here',
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
              ),
            ),
            _EditorActions(
              touch: touch,
              onCancel: _cancel,
              onDone: _body.text.trim().isEmpty
                  ? null
                  : () => widget.draft.endEdit(committed: true),
            ),
          ],
        ),
      ),
    );
  }
}

/// An artwork's caption, edited under its picture. Enter keeps the new one,
/// Escape keeps the old one, and leaving the field keeps what is typed.
class ShowcaseCaptionEditor extends StatefulWidget {
  final ShowcaseDraft draft;
  final bool wide;
  final bool touch;

  const ShowcaseCaptionEditor({
    super.key,
    required this.draft,
    this.wide = false,
    this.touch = false,
  });

  @override
  State<ShowcaseCaptionEditor> createState() => _ShowcaseCaptionEditorState();
}

class _ShowcaseCaptionEditorState extends State<ShowcaseCaptionEditor> {
  late final ShowcaseBlock _original = widget.draft.editing!;
  late final _caption = TextEditingController(text: _original.artworkCaption);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && widget.draft.editing != null) _done();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _caption.dispose();
    super.dispose();
  }

  void _write(String text) {
    final current = widget.draft.editing;
    if (current == null) return;
    final caption = text.trim();
    widget.draft.replace(
      current,
      ShowcaseBlock(
        type: ShowcaseBlockType.artwork,
        data: {
          'image': current.artworkHash,
          if (caption.isNotEmpty) 'caption': caption,
        },
      ),
    );
  }

  void _done() => widget.draft.endEdit(committed: true);

  void _cancel() {
    final current = widget.draft.editing;
    if (current != null) widget.draft.replace(current, _original);
    widget.draft.endEdit(committed: true);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final picture = ShowcaseBlock(
      type: ShowcaseBlockType.artwork,
      data: {'image': _original.artworkHash},
    );
    return _EscapeCancels(
      onCancel: _cancel,
      child: ShowcaseEditFrame(
        touch: widget.touch,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ShowcaseArtwork(
              block: picture,
              assets: widget.draft.assets,
              placeholderHeight: widget.wide ? 240 : 160,
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowTextField(
              controller: _caption,
              focusNode: _focus,
              hintText: 'Add a caption',
              autofocus: true,
              maxLength: kShowcaseCaptionLength,
              showCounter: false,
              onChanged: _write,
              onSubmitted: (_) => _done(),
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              widget.touch
                  ? 'Optional'
                  : 'Enter saves it, Escape keeps the old caption',
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A favourite game's "Why this game?" line under the game itself.
class ShowcaseBlurbEditor extends StatefulWidget {
  final ShowcaseDraft draft;
  final ShowcaseGameSearch search;
  final bool touch;

  const ShowcaseBlurbEditor({
    super.key,
    required this.draft,
    required this.search,
    this.touch = false,
  });

  @override
  State<ShowcaseBlurbEditor> createState() => _ShowcaseBlurbEditorState();
}

class _ShowcaseBlurbEditorState extends State<ShowcaseBlurbEditor> {
  late final ShowcaseBlock _original = widget.draft.editing!;
  late final _blurb = TextEditingController(text: _original.gameBlurb);
  final _focus = FocusNode();
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && !_searching && widget.draft.editing != null) {
        widget.draft.endEdit(committed: true);
      }
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    _blurb.dispose();
    super.dispose();
  }

  void _write(String text) {
    final current = widget.draft.editing;
    if (current == null) return;
    final blurb = text.trim();
    final data = {...current.data};
    if (blurb.isEmpty) {
      data.remove('blurb');
    } else {
      data['blurb'] = blurb;
    }
    widget.draft.replace(
      current,
      ShowcaseBlock(type: current.type, data: data),
    );
    setState(() {});
  }

  void _cancel() {
    final current = widget.draft.editing;
    if (current != null) {
      _blurb.text = _original.gameBlurb;
      _write(_original.gameBlurb);
    }
    widget.draft.endEdit(committed: true);
  }

  Future<void> _changeGame(BuildContext anchor) async {
    _searching = true;
    final game = await widget.search(anchor);
    _searching = false;
    final current = widget.draft.editing;
    if (game == null || current == null || !mounted) {
      _focus.requestFocus();
      return;
    }
    final placed = gameBlockFor(current.type, game, blurb: _blurb.text.trim());
    widget.draft.replace(current, placed.block, keepBakes: false);
    widget.draft.trackBake(placed.block, placed.bake);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final current = widget.draft.editing ?? _original;
    final shown = ShowcaseBlock(
      type: current.type,
      data: {...current.data}..remove('blurb'),
    );
    return _EscapeCancels(
      onCancel: _cancel,
      child: ShowcaseEditFrame(
        touch: widget.touch,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              child: ShowcaseBlockView(
                block: shown,
                assets: widget.draft.assets,
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            ShowcaseFieldLabel(
              'Why this game?',
              trailing:
                  'Optional · ${_blurb.text.length}/${ShowcaseBoard.maxBlurbLength}',
            ),
            HollowTextField(
              controller: _blurb,
              focusNode: _focus,
              hintText: 'What makes it stay with you',
              autofocus: true,
              maxLength: ShowcaseBoard.maxBlurbLength,
              showCounter: false,
              onChanged: _write,
              onSubmitted: (_) => widget.draft.endEdit(committed: true),
            ),
            const SizedBox(height: HollowSpacing.xs),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Shows under the game on your profile',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textTertiary,
                    ),
                  ),
                ),
                Builder(
                  builder: (anchor) => HollowButton.ghost(
                    compact: !widget.touch,
                    touch: widget.touch,
                    onPressed: () => _changeGame(anchor),
                    child: const Text('Change game'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// A game shelf's name and games, edited in place. Games added here start
/// downloading their covers at once.
class ShowcaseShelfEditor extends StatefulWidget {
  final ShowcaseDraft draft;
  final ShowcaseGameSearch search;
  final bool touch;

  const ShowcaseShelfEditor({
    super.key,
    required this.draft,
    required this.search,
    this.touch = false,
  });

  @override
  State<ShowcaseShelfEditor> createState() => _ShowcaseShelfEditorState();
}

class _ShowcaseShelfEditorState extends State<ShowcaseShelfEditor> {
  late final ShowcaseBlock _original = widget.draft.editing!;
  late final _label = TextEditingController(text: _original.shelfLabel);

  /// The shelf's entries as maps the background bakes patch in place.
  late final List<Map<String, dynamic>> _games = [
    for (final g in _original.shelfGames) Map<String, dynamic>.of(g),
  ];

  @override
  void initState() {
    super.initState();
    widget.draft.addListener(_onDraft);
  }

  @override
  void dispose() {
    widget.draft.removeListener(_onDraft);
    _label.dispose();
    super.dispose();
  }

  /// A bake landing patches a map this editor holds; show its cover.
  void _onDraft() {
    if (mounted) setState(() {});
  }

  void _write() {
    final current = widget.draft.editing;
    if (current == null) return;
    final label = _label.text.trim();
    widget.draft.replace(
      current,
      ShowcaseBlock(
        type: ShowcaseBlockType.gameShelf,
        data: {if (label.isNotEmpty) 'label': label, 'games': _games},
      ),
    );
  }

  Future<void> _addGame(BuildContext anchor) async {
    final game = await widget.search(anchor);
    if (game == null || !mounted) return;
    final entry = <String, dynamic>{
      'name': game.name,
      if (game.year != null) 'year': game.year,
    };
    _games.add(entry);
    widget.draft.trackShelfBake(entry, bakeGame(game));
    _write();
  }

  void _removeGame(int i) {
    _games.removeAt(i);
    _write();
  }

  void _cancel() {
    final current = widget.draft.editing;
    if (current != null && !widget.draft.editingIsNew) {
      widget.draft.replace(current, _original);
    }
    widget.draft.endEdit(committed: false);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = widget.touch;
    final full = _games.length >= ShowcaseBoard.maxShelfGames;
    return _EscapeCancels(
      onCancel: _cancel,
      child: ShowcaseEditFrame(
        touch: touch,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const ShowcaseFieldLabel('Shelf name', trailing: 'Optional'),
            HollowTextField(
              controller: _label,
              hintText: 'Backlog',
              autofocus: _games.isNotEmpty,
              maxLength: kShowcaseShelfLabelLength,
              showCounter: false,
              onChanged: (_) => _write(),
            ),
            const SizedBox(height: HollowSpacing.md),
            ShowcaseFieldLabel(
              'Games',
              trailing: '${_games.length} of ${ShowcaseBoard.maxShelfGames}',
            ),
            for (var i = 0; i < _games.length; i++)
              _ShelfGameRow(
                game: _games[i],
                cover:
                    widget.draft.assets[(_games[i]['cover'] as String?) ?? ''],
                touch: touch,
                onRemove: () => _removeGame(i),
              ),
            if (full)
              Text(
                'A shelf holds ${ShowcaseBoard.maxShelfGames} games.',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                ),
              )
            else
              ShowcaseOnTextEdge(
                compact: !touch,
                child: Builder(
                  builder: (anchor) => HollowButton.ghost(
                    compact: !touch,
                    touch: touch,
                    icon: const Icon(LucideIcons.plus),
                    onPressed: () => _addGame(anchor),
                    child: const Text('Add a game'),
                  ),
                ),
              ),
            _EditorActions(
              touch: touch,
              onCancel: _cancel,
              onDone: _games.isEmpty
                  ? null
                  : () => widget.draft.endEdit(committed: true),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShelfGameRow extends StatelessWidget {
  final Map<String, dynamic> game;
  final Uint8List? cover;
  final bool touch;
  final VoidCallback onRemove;

  const _ShelfGameRow({
    required this.game,
    required this.cover,
    required this.touch,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final name = (game['name'] as String?) ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Row(
        children: [
          ShowcaseCover(bytes: cover, width: 32),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  (touch ? HollowTypography.bodyTouch : HollowTypography.body)
                      .copyWith(color: hollow.textPrimary),
            ),
          ),
          HollowIconButton(
            icon: LucideIcons.x,
            label: 'Remove $name',
            size: touch ? 44 : 32,
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}

/// Where a new block lands while its picture is being processed.
class ShowcaseProcessingBlock extends StatelessWidget {
  final double height;

  const ShowcaseProcessingBlock({super.key, this.height = 160});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      alignment: Alignment.center,
      child: Semantics(
        label: 'Preparing the picture',
        child: const HollowSpinner.medium(),
      ),
    );
  }
}
