import 'package:flutter/material.dart';

/// The app-wide [ScrollBehavior] (issue #54).
///
/// Flutter's desktop default paints the thumb ON TOP of the last pixels of the
/// scrollable, covering anything flush at the right edge. Here the scrollbar
/// keeps the full width of the [Scrollable]'s box and the viewport inside it is
/// inset by [kScrollGutter] instead, so content and thumb never share a pixel.
/// Vertical and desktop only, like [MaterialScrollBehavior]; a
/// `copyWith(scrollbars: false)` above this still opts out entirely.
class HollowScrollBehavior extends MaterialScrollBehavior {
  const HollowScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (axisDirectionToAxis(details.direction) != Axis.vertical) return child;
    switch (getPlatform(context)) {
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return Scrollbar(
          controller: details.controller,
          child: Padding(
            padding: const EdgeInsets.only(right: kScrollGutter),
            child: child,
          ),
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return child;
    }
  }
}

/// Width reserved for the scrollbar on desktop vertical scrollables: the 6px
/// thumb plus a hair either side.
const double kScrollGutter = 10.0;
