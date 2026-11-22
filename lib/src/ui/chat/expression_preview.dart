import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, HardwareKeyboard, KeyDownEvent, KeyEvent, KeyEventCallback, LogicalKeyboardKey;
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/gif_picker.dart' show GifMenuItem, GifMenuRow, showGifMenu;
import 'package:hollow/src/ui/chat/message_text_parser.dart' show isTouchForm;
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/ime_keys.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/components/popup_animator.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Longest side of a sticker or GIF in the preview.
const double kExpressionPreviewMedia = 200;

/// An emoji or emote in the preview.
const double kExpressionPreviewGlyph = 112;

/// Tests flip between the phone and desktop behaviour; null = this platform.
@visibleForTesting
bool? debugExpressionPreviewTouch;

bool get _touch => debugExpressionPreviewTouch ?? isTouchForm;

/// Width of the preview card.
const double _kCardWidth = kExpressionPreviewMedia + 2 * HollowSpacing.lg;

/// What one picker cell shows when it is previewed (#159).
class ExpressionPreviewData {
  /// The magnified sticker, GIF, emote or emoji, at most
  /// [kExpressionPreviewMedia] on its longest side. Built in the preview's own
  /// context, so it reads the cell's bytes as they are now.
  final WidgetBuilder media;

  /// The name under it ("Sticker" when it has none).
  final String label;

  const ExpressionPreviewData({required this.media, required this.label});
}

/// The picker panel a preview centres over. A held preview slides from cell to
/// cell inside it, so similar stickers can be told apart without letting go.
class ExpressionPreviewArea extends StatefulWidget {
  final Widget child;

  const ExpressionPreviewArea({super.key, required this.child});

  @override
  State<ExpressionPreviewArea> createState() => _ExpressionPreviewAreaState();
}

class _ExpressionPreviewAreaState extends State<ExpressionPreviewArea> {
  final Set<_ExpressionPreviewTargetState> _targets = {};

  /// The cell under [globalPosition] (window space), if any.
  _ExpressionPreviewTargetState? _targetAt(Offset globalPosition) {
    for (final t in _targets) {
      final box = t.context.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) continue;
      final local = box.globalToLocal(globalPosition);
      if ((Offset.zero & box.size).contains(local)) return t;
    }
    return null;
  }

  @override
  void dispose() {
    _ExpressionPreview.hideOwnedBy(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// A picker cell that previews on hold (#159).
///
/// Desktop: hold the left button for a magnified preview, let go and it closes;
/// right-click offers "Preview" beside the cell's own actions. Touch: a long
/// press shows the preview while the finger is down, sliding to other cells,
/// and on release it stays with "Send" and the cell's actions under it. A
/// released hold never sends: the long press wins the gesture arena, so the
/// cell's own tap is cancelled.
class ExpressionPreviewTarget extends StatefulWidget {
  final ExpressionPreviewData data;

  /// What a tap on the cell does, offered as "Send" under a kept preview.
  /// Null while the cell cannot send (a pick already running).
  final VoidCallback? onSend;

  /// Label of the "Send" action: an emoji goes into the message first.
  final String sendLabel;

  /// The cell's own actions; [globalPosition] anchors any submenu.
  final List<GifMenuItem> Function(Offset globalPosition)? actions;

  final Widget child;

  const ExpressionPreviewTarget({
    super.key,
    required this.data,
    required this.onSend,
    required this.child,
    this.sendLabel = 'Send',
    this.actions,
  });

  @override
  State<ExpressionPreviewTarget> createState() =>
      _ExpressionPreviewTargetState();
}

class _ExpressionPreviewTargetState extends State<ExpressionPreviewTarget> {
  _ExpressionPreviewAreaState? _area;

  /// The cell a held preview currently shows (this one, or one slid onto).
  _ExpressionPreviewTargetState? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final area = context.findAncestorStateOfType<_ExpressionPreviewAreaState>();
    if (!identical(area, _area)) {
      _area?._targets.remove(this);
      _area = area?.._targets.add(this);
    }
  }

  @override
  void didUpdateWidget(ExpressionPreviewTarget old) {
    super.didUpdateWidget(old);
    // Bytes that landed after the preview opened show in it, a frame later:
    // the entry cannot be marked dirty while this cell is being built.
    if (_ExpressionPreview.showing) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _ExpressionPreview.refresh());
    }
  }

  @override
  void dispose() {
    _area?._targets.remove(this);
    _ExpressionPreview.hideOwnedBy(this);
    super.dispose();
  }

  Object get _owner => _area ?? this;

  void _peek() {
    if (_touch) HapticFeedback.selectionClick();
    _shown = this;
    _ExpressionPreview.show(
      context: context,
      owner: _owner,
      area: _area,
      data: () => (_shown ?? this).widget.data,
      kept: false,
    );
  }

  void _slide(Offset globalPosition) {
    final under = _area?._targetAt(globalPosition);
    if (under == null || identical(under, _shown)) return;
    _shown = under;
    if (_touch) HapticFeedback.selectionClick();
    _ExpressionPreview.refresh();
  }

  void _release() {
    final shown = _shown ?? this;
    _shown = null;
    if (!_touch) {
      _ExpressionPreview.hide();
      return;
    }
    // A phone has no right-click, so the cell's actions live under the
    // preview it kept.
    shown._keep(_ExpressionPreview.lastCentre ?? Offset.zero);
  }

  /// Opens the preview to stay, with "Send" and the cell's actions under it.
  void _keep(Offset anchor) {
    if (!mounted) return;
    final send = widget.onSend;
    final items = [
      if (send != null)
        GifMenuItem(
            icon: LucideIcons.send, label: widget.sendLabel, onTap: send),
      ...?widget.actions?.call(anchor),
    ];
    _ExpressionPreview.show(
      context: context,
      owner: _owner,
      area: _area,
      data: () => widget.data,
      kept: true,
      items: items,
    );
  }

  void _menu(Offset globalPosition) {
    showGifMenu(
      context,
      globalPosition,
      header: widget.data.label,
      items: [
        GifMenuItem(
          icon: LucideIcons.eye,
          label: 'Preview',
          onTap: () => _keep(globalPosition),
        ),
        ...?widget.actions?.call(globalPosition),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (d) => _menu(d.globalPosition),
      onLongPressStart: (_) => _peek(),
      onLongPressMoveUpdate: (d) => _slide(d.globalPosition),
      onLongPressEnd: (_) => _release(),
      onLongPressCancel: () {
        if (_shown != null) _release();
      },
      child: widget.child,
    );
  }
}

/// The one preview on screen: an [OverlayEntry] above the picker, which is
/// itself a raw entry above every route.
abstract final class _ExpressionPreview {
  static OverlayEntry? _entry;
  static PopupAnimationController? _anim;
  static Object? _owner;

  /// Centre of the card last shown, for anchoring a kept preview's submenus.
  static Offset? lastCentre;

  static void show({
    required BuildContext context,
    required Object owner,
    required _ExpressionPreviewAreaState? area,
    required ExpressionPreviewData Function() data,
    required bool kept,
    List<GifMenuItem> items = const [],
  }) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) return;
    // Centred over the picker panel, or the cell when there is none.
    final anchorBox = (area?.context ?? context).findRenderObject() as RenderBox?;
    if (anchorBox == null || !anchorBox.hasSize) return;
    final anchor = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox) &
        anchorBox.size;
    lastCentre = anchorBox.localToGlobal(anchorBox.size.center(Offset.zero));

    // Replacing a preview with a kept one keeps it on screen: no exit, no
    // entrance in between.
    final again = _entry != null;
    _removeNow();
    final anim = PopupAnimationController();
    late final OverlayEntry entry;
    void dismiss() {
      if (!identical(_entry, entry)) return;
      hide();
    }

    entry = OverlayEntry(
      builder: (ctx) => anim.wrapEntry(_PreviewLayer(
        anchor: anchor,
        bounds: Offset.zero & overlayBox.size,
        data: data(),
        kept: kept,
        items: items,
        animate: !again,
        anim: anim,
        onDismiss: dismiss,
      )),
    );
    _entry = entry;
    _anim = anim;
    _owner = owner;
    overlay.insert(entry);
    if (kept) {
      OverlayHosts.register(entry, dismiss);
      // The entry sits outside every route's focus scope, so Escape is
      // caught before focus decides where keys go.
      bool onKey(KeyEvent event) {
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.escape ||
            keyBelongsToFocusedIme(event)) {
          return false;
        }
        dismiss();
        return true;
      }

      HardwareKeyboard.instance.addHandler(onKey);
      _keyHandler = onKey;
    }
  }

  static KeyEventCallback? _keyHandler;

  static void _dropKeys() {
    final handler = _keyHandler;
    if (handler != null) HardwareKeyboard.instance.removeHandler(handler);
    _keyHandler = null;
  }

  static bool get showing => _entry != null;

  static void refresh() => _entry?.markNeedsBuild();

  static void hide() {
    final entry = _entry;
    final anim = _anim;
    if (entry == null) return;
    _entry = null;
    _anim = null;
    _owner = null;
    _dropKeys();
    OverlayHosts.unregister(entry);
    void remove() {
      entry.remove();
      entry.dispose();
    }

    if (anim == null) {
      remove();
    } else {
      anim.dismiss(remove);
    }
  }

  static void hideOwnedBy(Object owner) {
    if (identical(_owner, owner)) _removeNow();
  }

  static void _removeNow() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    _anim = null;
    _owner = null;
    _dropKeys();
    OverlayHosts.unregister(entry);
    entry.remove();
    entry.dispose();
  }
}

/// The card, and for a kept preview the barrier that closes it.
class _PreviewLayer extends StatelessWidget {
  final Rect anchor;
  final Rect bounds;
  final ExpressionPreviewData data;
  final bool kept;
  final List<GifMenuItem> items;
  final bool animate;
  final PopupAnimationController anim;
  final VoidCallback onDismiss;

  const _PreviewLayer({
    required this.anchor,
    required this.bounds,
    required this.data,
    required this.kept,
    required this.items,
    required this.animate,
    required this.anim,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final card = _PreviewCard(
      data: data,
      items: kept ? items : const [],
      onAction: (item) {
        onDismiss();
        item.onTap();
      },
    );
    final placed = CustomSingleChildLayout(
      delegate: _CentreOver(anchor, bounds),
      child: animate
          ? PopupAnimator(controller: anim, child: card)
          : card,
    );
    if (!kept) {
      // A peek is only a picture: the held pointer stays with the cell.
      return IgnorePointer(child: placed);
    }
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            onSecondaryTap: onDismiss,
          ),
        ),
        Positioned.fill(child: placed),
      ],
    );
  }
}

/// Centres the card over [anchor], kept inside [bounds].
class _CentreOver extends SingleChildLayoutDelegate {
  final Rect anchor;
  final Rect bounds;

  const _CentreOver(this.anchor, this.bounds);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(constraints.biggest).deflate(
          const EdgeInsets.all(HollowSpacing.sm));

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final inset = bounds.deflate(HollowSpacing.sm);
    final left = (anchor.center.dx - childSize.width / 2)
        .clamp(inset.left, (inset.right - childSize.width).clamp(inset.left, double.infinity));
    final top = (anchor.center.dy - childSize.height / 2)
        .clamp(inset.top, (inset.bottom - childSize.height).clamp(inset.top, double.infinity));
    return Offset(left.toDouble(), top.toDouble());
  }

  @override
  bool shouldRelayout(_CentreOver old) =>
      old.anchor != anchor || old.bounds != bounds;
}

class _PreviewCard extends StatelessWidget {
  final ExpressionPreviewData data;
  final List<GifMenuItem> items;
  final ValueChanged<GifMenuItem> onAction;

  const _PreviewCard({
    required this.data,
    required this.items,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // The entry sits outside every Material, so the text style is set here.
    return DefaultTextStyle(
      style: HollowTypography.body.copyWith(color: hollow.textPrimary),
      child: Semantics(
      container: true,
      label: 'Preview of ${data.label}',
      child: Container(
        width: _kCardWidth,
        decoration: BoxDecoration(
          color: hollow.overlay,
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          border: Border.all(color: hollow.border),
          boxShadow: HollowShadows.float,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
                    HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.sm),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints.loose(const Size.square(
                        kExpressionPreviewMedia)),
                    child: Builder(builder: data.media),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                    left: HollowSpacing.lg,
                    right: HollowSpacing.lg,
                    bottom: HollowSpacing.md),
                child: Text(
                  data.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
              ),
              if (items.isNotEmpty) ...[
                const HollowDivider(),
                Padding(
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in items)
                        GifMenuRow(
                          item: item,
                          touch: _touch,
                          onTap: () => onAction(item),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    );
  }
}
