import 'package:flutter/widgets.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// "You are here" on a navigation bar: a short accent bar on the bar's edge
/// facing the content, above (or below) the one active item.
///
/// The phone's tab bar and the desktop dock share it, and each bar shows
/// exactly one.
class NavSelectionMark extends StatelessWidget {
  final double width;

  const NavSelectionMark({super.key, this.width = kNavSelectionMarkWidth});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      width: width,
      height: HollowSpacing.xxs,
      decoration: BoxDecoration(
        color: hollow.accent,
        borderRadius: BorderRadius.circular(hollow.radiusXs),
      ),
    );
  }
}

const double kNavSelectionMarkWidth = 20;
