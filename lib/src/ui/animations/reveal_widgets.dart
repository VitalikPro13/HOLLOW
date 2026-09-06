import 'package:flutter/material.dart';

/// Reveals a child by animating a clip from one edge.
///
/// A null [animation] renders the child directly, at zero overhead. [axis] runs
/// top to bottom or left to right, reversed by [alignment].
class RevealClip extends StatelessWidget {
  final Animation<double>? animation;
  final Axis axis;
  final Alignment alignment;
  final Widget child;

  const RevealClip({
    super.key,
    required this.animation,
    this.axis = Axis.vertical,
    this.alignment = Alignment.topLeft,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (animation == null) return child;

    return AnimatedBuilder(
      animation: animation!,
      builder: (context, child) {
        return ClipRect(
          child: Align(
            alignment: alignment,
            heightFactor: axis == Axis.vertical ? animation!.value : null,
            widthFactor: axis == Axis.horizontal ? animation!.value : null,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

/// Reveals text character by character over the [animation] interval; a null
/// animation shows the whole text at once.
class TypewriterText extends StatelessWidget {
  final String text;
  final Animation<double>? animation;
  final TextStyle? style;
  final TextOverflow? overflow;
  final int? maxLines;

  const TypewriterText({
    super.key,
    required this.text,
    required this.animation,
    this.style,
    this.overflow,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    if (animation == null) {
      return Text(text, style: style, overflow: overflow, maxLines: maxLines);
    }

    return AnimatedBuilder(
      animation: animation!,
      builder: (context, _) {
        final charCount = (animation!.value * text.length).round();
        final visible = text.substring(0, charCount);
        return Text(
          visible,
          style: style,
          overflow: overflow,
          maxLines: maxLines,
        );
      },
    );
  }
}

/// A divider that "draws" itself from one side to the other; a null [animation]
/// renders it at full width.
class LineDrawDivider extends StatelessWidget {
  final Animation<double>? animation;
  final double height;
  final Color? color;
  final Alignment alignment;

  const LineDrawDivider({
    super.key,
    required this.animation,
    this.height = 1,
    this.color,
    this.alignment = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    final dividerColor = color ?? Theme.of(context).dividerColor;
    final divider = Container(height: height, color: dividerColor);

    if (animation == null) return divider;

    return AnimatedBuilder(
      animation: animation!,
      builder: (context, child) {
        return FractionallySizedBox(
          alignment: alignment,
          widthFactor: animation!.value,
          child: child,
        );
      },
      child: divider,
    );
  }
}

/// Wraps a list item with a fade and slide entrance, staggered by [index]; a
/// null [parentAnimation] renders the child directly.
class StaggeredListItem extends StatelessWidget {
  final Animation<double>? parentAnimation;
  final int index;
  final int totalItems;
  final Offset slideFrom;
  final Widget child;

  const StaggeredListItem({
    super.key,
    required this.parentAnimation,
    required this.index,
    required this.totalItems,
    this.slideFrom = const Offset(-0.3, 0),
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (parentAnimation == null) return child;

    final itemDuration = 0.4;
    final totalStagger = 1.0 - itemDuration;
    final step =
        totalItems > 1 ? totalStagger / (totalItems - 1) : 0.0;
    final begin = (index * step).clamp(0.0, 1.0 - itemDuration);
    final end = (begin + itemDuration).clamp(0.0, 1.0);

    final itemAnimation = CurvedAnimation(
      parent: parentAnimation!,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );

    return FadeTransition(
      opacity: itemAnimation,
      child: SlideTransition(
        position: Tween<Offset>(begin: slideFrom, end: Offset.zero)
            .animate(itemAnimation),
        child: child,
      ),
    );
  }
}
