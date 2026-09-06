import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// The draggable seam between two shell panes (issue #54).
///
/// It occupies its own strip in the row rather than floating over the panel's
/// edge, which already belongs to the scrollbar gutter: a handle on top of it
/// would swallow the thumb and make the list undraggable.
///
/// It paints as an EXTENSION OF THE PANEL and owns the divider, because
/// painting nothing at rest left a 6px hole that the chat's opaque header and
/// composer bars stopped short of, reading as dark notches at the chat's
/// corners. The panel beside a seam must therefore NOT draw its own edge border
/// (`ChannelSidebar.edgeBorder`, `MemberPanel.edgeBorder`); a panel with no
/// seam keeps drawing one.
///
/// Arrow keys move it in [_kKeyStep] steps and Home resets, because a splitter
/// that only answers to a drag is a control blind and motor-impaired users do
/// not have.
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

  /// Movement since the drag started, in LOCAL logical pixels. Accumulated from
  /// `delta` rather than `localPosition` because the seam moves with the panel
  /// it sizes, and `delta` already arrives out of window space (so the interface
  /// zoom stays honest).
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
                    // The panel's own fill, so the strip reads as more panel
                    // instead of a hole punched between the two.
                    color: hollow.surface,
                    // ...and the divider, on the CHAT side of the strip. A
                    // DecoratedBox does not inset its child, so the drag target
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
                    // The accent sits ON the divider it replaces; centred in
                    // the strip the two read as a double rule.
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
