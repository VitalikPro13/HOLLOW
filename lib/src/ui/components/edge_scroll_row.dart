import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../theme/hollow_theme.dart';
import 'hollow_pressable.dart';

/// Make a vertical mouse wheel pan a horizontal scroller.
///
/// The minimal half of what [EdgeScrollRow] does, for a scroller that must
/// stay exactly as it is otherwise. No layout change, no gesture
/// interception — only the wheel signal, and only while there is somewhere to
/// scroll, so a strip that fits keeps passing wheel events to the page behind
/// it.
Widget wheelToScroll({
  required ScrollController controller,
  required Widget child,
}) {
  return Listener(
    onPointerSignal: (signal) {
      if (signal is! PointerScrollEvent) return;
      if (!controller.hasClients) return;
      final pos = controller.position;
      if (pos.maxScrollExtent <= 0) return;
      final delta = signal.scrollDelta;
      final amount = delta.dx.abs() > delta.dy.abs() ? delta.dx : delta.dy;
      controller.jumpTo(
          (controller.offset + amount).clamp(0.0, pos.maxScrollExtent));
    },
    child: child,
  );
}

/// A horizontal strip that stays REACHABLE when it overflows.
///
/// The trap this exists for: a plain `SingleChildScrollView(scrollDirection:
/// Axis.horizontal)` scrolls fine by touch or trackpad, but on a desktop with
/// a plain wheel mouse there is no affordance and no gesture — the
/// overflowing items are simply unreachable. It showed up first as GIF
/// favourites lists you could create but not scroll to, and again as Server
/// Settings tabs once the panel got narrow.
///
/// So this adds, only while the content actually overflows:
///   * arrow buttons on whichever side has more to show,
///   * a vertical wheel that scrolls horizontally (the natural reflex),
///   * a fade at each overflowing edge, so it LOOKS scrollable.
///
/// Nothing appears when everything fits, which is the common case.
///
/// The arrows are SIBLINGS of the scroller, not an overlay on top of it.
/// Overlaid arrows cover the content underneath — fine for a chip you can
/// scroll back to, not fine for the dock's reorder drop zones, which sit
/// exactly at the two ends.
class EdgeScrollRow extends StatefulWidget {
  /// Eagerly-built children. Mutually exclusive with [builder].
  final List<Widget>? children;

  /// Builds the scrollable itself, given the controller to attach. Use this
  /// for a LAZY list — `EdgeScrollRow(children: …)` would materialize every
  /// child, which a long friends list must not do.
  final Widget Function(BuildContext context, ScrollController controller)?
      builder;

  /// How far one arrow press travels.
  final double step;

  /// Cross-axis height. Null lets the row size to its children.
  final double? height;

  final EdgeInsets padding;

  /// Purpose label for the arrows (they are icon-only controls).
  final String semanticLabel;

  /// Centre the content while it FITS, then scroll normally once it does
  /// not. For the dock's server strip, where a handful of icons centred
  /// under the cursor is the whole look.
  ///
  /// A bare `Center` around this widget cannot do it: the arrow slots make
  /// the internal Row take the full width, so the Center has nothing to
  /// centre. The centring therefore happens INSIDE the viewport — the
  /// content is given a minimum width of the viewport and centres itself in
  /// it, which collapses to a no-op the moment the content is wider.
  final bool center;

  const EdgeScrollRow({
    super.key,
    required List<Widget> this.children,
    this.step = 120,
    this.height,
    this.padding = EdgeInsets.zero,
    this.semanticLabel = 'items',
    this.center = false,
  }) : builder = null;

  const EdgeScrollRow.builder({
    super.key,
    required Widget Function(BuildContext, ScrollController) this.builder,
    this.step = 120,
    this.height,
    this.padding = EdgeInsets.zero,
    this.semanticLabel = 'items',
  })  : children = null,
        // Centring needs the viewport width, which only the children form
        // controls. A custom builder centres its own content if it wants to.
        center = false;

  @override
  State<EdgeScrollRow> createState() => _EdgeScrollRowState();
}

class _EdgeScrollRowState extends State<EdgeScrollRow> {
  final _controller = ScrollController();

  /// There is anything to scroll at all. Drives whether the arrow slots
  /// EXIST — deliberately separate from whether each arrow can move.
  ///
  /// This split is load-bearing. Sibling arrows take width from the
  /// scroller, so showing one shrinks the viewport and grows
  /// maxScrollExtent, which can re-trigger the other — a flip-flop. Once
  /// overflowing, BOTH slots stay occupied (the unusable direction just goes
  /// dim), so an arrow changing state never changes the layout. Entering and
  /// leaving overflow is then the only width change, and that is stable: the
  /// content has to shrink past `width - 40` to hide the arrows, and past
  /// `width` to bring them back.
  bool _overflowing = false;
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_sync);
    // Overflow is only knowable after layout.
    _syncSoon();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Re-check after the current frame. Scroll metrics arrive DURING layout,
  /// so setState has to wait for the frame to finish.
  void _syncSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _sync());
  }

  void _sync() {
    if (!mounted || !_controller.hasClients) return;
    final pos = _controller.position;
    final overflowing = pos.maxScrollExtent > 0;
    final left = overflowing && pos.pixels > 1;
    final right = overflowing && pos.pixels < pos.maxScrollExtent - 1;
    if (overflowing != _overflowing || left != _canLeft || right != _canRight) {
      setState(() {
        _overflowing = overflowing;
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _nudge(double delta) {
    if (!_controller.hasClients) return;
    final target = (_controller.offset + delta)
        .clamp(0.0, _controller.position.maxScrollExtent);
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  Widget _scrollView({BoxConstraints? fill}) => SingleChildScrollView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        padding: widget.padding,
        child: fill == null
            ? Row(mainAxisSize: MainAxisSize.min, children: widget.children!)
            : ConstrainedBox(
                constraints: fill,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  // With a minWidth of the viewport, the Row is at least
                  // viewport-wide and centre distributes the slack. Once the
                  // children exceed that there is no slack, so this quietly
                  // becomes an ordinary scrolling row.
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: widget.children!,
                ),
              ),
      );

  Widget _childrenScroller() {
    if (!widget.center) return _scrollView();
    return LayoutBuilder(
      builder: (context, constraints) => _scrollView(
        fill: constraints.maxWidth.isFinite
            // Minus the padding, which sits INSIDE the viewport — without
            // that subtraction the content would always overflow by exactly
            // the padding and the arrows would never switch off.
            ? BoxConstraints(
                minWidth:
                    (constraints.maxWidth - widget.padding.horizontal)
                        .clamp(0.0, double.infinity),
              )
            : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final scroller = widget.builder != null
        ? widget.builder!(context, _controller)
        : _childrenScroller();

    return SizedBox(
      height: widget.height,
      child: NotificationListener<ScrollMetricsNotification>(
        // THE resize hook. The controller listener above only fires when the
        // offset moves; this fires when the EXTENTS change — narrowing the
        // window, a larger-text setting, or the list growing. Without it a
        // strip that starts out fitting never grows arrows, which is exactly
        // how the Server Settings tabs stayed unreachable.
        onNotification: (_) {
          _syncSoon();
          return false;
        },
        child: Row(
          children: [
            if (_overflowing) _arrow(hollow, left: true, enabled: _canLeft),
            Expanded(
              child: Stack(
                children: [
                  wheelToScroll(controller: _controller, child: scroller),
                  // Fades are decoration only — never let them eat a tap.
                  if (_canLeft) _fade(hollow, left: true),
                  if (_canRight) _fade(hollow, left: false),
                ],
              ),
            ),
            if (_overflowing) _arrow(hollow, left: false, enabled: _canRight),
          ],
        ),
      ),
    );
  }

  /// Both arrows exist while overflowing; the one with nowhere to go goes
  /// dim and stops responding, which also reads as "you are at that end".
  Widget _arrow(HollowTheme hollow, {required bool left, required bool enabled}) {
    return HollowPressable(
      onTap: enabled ? () => _nudge(left ? -widget.step : widget.step) : null,
      semanticLabel: left
          ? 'Scroll ${widget.semanticLabel} left'
          : 'Scroll ${widget.semanticLabel} right',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: EdgeInsets.zero,
      child: SizedBox(
        width: 20,
        child: Icon(
          left ? Icons.chevron_left_rounded : Icons.chevron_right_rounded,
          size: 18,
          color: enabled ? hollow.textSecondary : hollow.textTertiary,
        ),
      ),
    );
  }

  Widget _fade(HollowTheme hollow, {required bool left}) {
    return Positioned(
      key: ValueKey(left ? 'edge-fade-left' : 'edge-fade-right'),
      left: left ? 0 : null,
      right: left ? null : 0,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: Container(
          width: 14,
          decoration: BoxDecoration(
            // Fade FROM the surface colour, never from Colors.transparent —
            // a transparent stop lerps through black and shows as a grey
            // smear.
            gradient: LinearGradient(
              colors: left
                  ? [hollow.surface, hollow.surface.withValues(alpha: 0)]
                  : [hollow.surface.withValues(alpha: 0), hollow.surface],
            ),
          ),
        ),
      ),
    );
  }
}

/// [wheelToScroll] plus the ScrollController it needs, so a stateless widget
/// can gain wheel panning without becoming stateful. Prefer
/// [EdgeScrollRow.builder] — this is for scrollers that cannot give up any
/// width to arrows.
class WheelScrollable extends StatefulWidget {
  final Widget Function(BuildContext context, ScrollController controller)
      builder;

  const WheelScrollable({super.key, required this.builder});

  @override
  State<WheelScrollable> createState() => _WheelScrollableState();
}

class _WheelScrollableState extends State<WheelScrollable> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => wheelToScroll(
        controller: _controller,
        child: widget.builder(context, _controller),
      );
}
