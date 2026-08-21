import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// The draggable seam between two shell panes (issue #54: "being able to
/// resize the left panel").
///
/// It occupies its own narrow strip in the row rather than floating over the
/// panel's edge, because that edge already belongs to the panel's scrollbar
/// gutter — a handle on top of it would swallow the last few pixels of the
/// thumb and make the list undraggable.
///
/// **It paints as an EXTENSION OF THE PANEL, and it owns the divider.** Its
/// first version painted nothing at rest, which left a 6px hole between the
/// panel and the chat. Across the message area that was invisible (both sides
/// are `hollow.background`), but the chat's header bar and composer bar are
/// opaque `hollow.surface` and stopped 6px short of the divider at both ends
/// — measured on a real build: at the header's y the seam read 13,15,20 and
/// the chat read 20,22,28. Four dark notches at the corners of the chat, and
/// exactly the "gaps on the sides" the resizable panels were blamed for.
/// Filling the strip with the panel's own surface makes the panel simply 6px
/// wider and puts the divider back against the chat where it was.
///
/// Because the seam owns the divider now, the panel beside it must NOT draw
/// its own edge border — that is what `ChannelSidebar.edgeBorder` /
/// `MemberPanel.edgeBorder` are for. A panel with no seam (the split view's
/// right sidebar) keeps drawing its own.
///
/// Mouse: drag to resize, double-click to go back to the default width.
/// Keyboard: focusable, left/right arrows move it in [_kKeyStep] steps and
/// Home resets — a splitter that only answers to a drag is a control blind and
/// motor-impaired users simply do not have.
class PanelResizeHandle extends StatefulWidget {
  /// Current width of the panel this seam sizes.
  final double width;

  /// Called with the new width on every drag frame. The provider clamps.
  final ValueChanged<double> onResize;

  /// Double-click / Home. Null disables both.
  final VoidCallback? onReset;

  /// True when the panel is to the RIGHT of the seam (the member panel), so
  /// dragging left makes it bigger.
  final bool panelOnRight;

  /// Names the panel for screen readers: "Resize the member list".
  final String label;

  const PanelResizeHandle({
    super.key,
    required this.width,
    required this.onResize,
    required this.label,
    this.onReset,
    this.panelOnRight = false,
  });

  @override
  State<PanelResizeHandle> createState() => _PanelResizeHandleState();
}

/// Hit width of the seam. Wider than the hairline it paints, because a 1px
/// drag target is a game of pixel darts.
const double kPanelSeamWidth = 6.0;
const double _kKeyStep = 16.0;

class _PanelResizeHandleState extends State<PanelResizeHandle> {
  bool _hovering = false;
  bool _dragging = false;
  double _startWidth = 0;

  /// Movement since the drag started, in LOCAL logical pixels. Accumulated
  /// from `delta` rather than measured from `localPosition`: the seam moves
  /// with the panel it is sizing, so a position measured against the seam
  /// itself would fight the resize it just caused. `delta` arrives already
  /// converted out of window space, which also keeps this honest under the
  /// interface zoom.
  double _dragged = 0;

  void _nudge(double delta) =>
      widget.onResize(widget.width + (widget.panelOnRight ? -delta : delta));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _nudge(-_kKeyStep);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _nudge(_kKeyStep);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        widget.onReset?.call();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final active = _hovering || _dragging;
    return Focus(
      onKeyEvent: _onKey,
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Semantics(
            label: widget.label,
            value: '${widget.width.round()} pixels',
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              onEnter: (_) => setState(() => _hovering = true),
              onExit: (_) => setState(() => _hovering = false),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: widget.onReset,
                onHorizontalDragStart: (_) => setState(() {
                  _dragging = true;
                  _startWidth = widget.width;
                  _dragged = 0;
                }),
                onHorizontalDragUpdate: (d) {
                  _dragged += widget.panelOnRight ? -d.delta.dx : d.delta.dx;
                  widget.onResize(_startWidth + _dragged);
                },
                onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                onHorizontalDragCancel: () =>
                    setState(() => _dragging = false),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    // The panel's own fill, so the strip reads as 6px more
                    // panel instead of a hole punched between the two.
                    color: hollow.surface,
                    // ...and the divider, on the CHAT side of the strip. A
                    // DecoratedBox does not inset its child the way Container
                    // does, so this paints over the edge and the drag target
                    // keeps its full width.
                    border: Border(
                      left: widget.panelOnRight
                          ? BorderSide(color: hollow.border)
                          : BorderSide.none,
                      right: widget.panelOnRight
                          ? BorderSide.none
                          : BorderSide(color: hollow.border),
                    ),
                  ),
                  child: SizedBox(
                    width: kPanelSeamWidth,
                    height: double.infinity,
                    // The accent sits ON the divider it replaces. Centred in
                    // the strip it lit up 2.5px away from the panel's border
                    // and the two read as a double rule — the same bug the
                    // own-message accent bar had against the chat scrollbar.
                    child: Align(
                      alignment: widget.panelOnRight
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: AnimatedContainer(
                        duration: HollowDurations.fast,
                        width: active || focused ? 2 : 0,
                        decoration: BoxDecoration(
                          color: hollow.accent.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
