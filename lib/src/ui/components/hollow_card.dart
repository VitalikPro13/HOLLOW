import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// A repeatable, self-contained unit (a listing, a device, a news item),
/// set apart by a background step alone: no hairline, no shadow.
class HollowCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final Color? color;

  const HollowCard({
    super.key,
    required this.child,
    this.padding,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      padding: padding ?? const EdgeInsets.all(HollowSpacing.lg),
      decoration: BoxDecoration(
        color: color ?? hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: child,
    );
  }
}
