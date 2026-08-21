import 'package:flutter/material.dart';

/// The app-wide [ScrollBehavior] (issue #54).
///
/// Flutter's desktop default paints the scrollbar ON TOP of the last few
/// pixels of the scrollable — so a list whose rows end flush at their right
/// edge (a checkbox column, a text field, a trailing chevron) gets covered by
/// the thumb the moment the list is long enough to scroll. That is the whole
/// of "some scrollbars on the app cover other elements instead of being on the
/// side".
///
/// The fix is a reserved gutter, the way a native scrollbar has always worked:
/// the scrollbar keeps the full width of the [Scrollable]'s box, and the
/// VIEWPORT inside it is inset by [kScrollGutter] so content and thumb can
/// never share a pixel. Nothing at the call site changes — every vertical
/// scrollable on desktop gets the gutter, including ones written before this
/// existed.
///
/// Only vertical + desktop, exactly like [MaterialScrollBehavior]: touch
/// platforms draw no scrollbar, so reserving space there would be a hole in
/// the layout for nothing.
///
/// Opting out still works the usual way — `ScrollConfiguration.of(context)
/// .copyWith(scrollbars: false)` wraps this behavior and skips
/// [buildScrollbar] entirely (that is how the chat panes fly their own rail).
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
          // The gutter lives INSIDE the scrollbar and OUTSIDE the viewport:
          // the Scrollbar keeps the full box (so the thumb sits at the true
          // right edge), the scrollable loses [kScrollGutter] of width.
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

/// Width reserved for the scrollbar on desktop vertical scrollables.
/// 6px thumb (see `hollow_theme_data.dart`) plus a hair of breathing room on
/// each side.
const double kScrollGutter = 10.0;
