import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';

/// Small selection pill, accent-tinted when active. Padding and whether the
/// fill animates differ per call site.
class SelectorPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  final EdgeInsets padding;
  final bool animated;

  const SelectorPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    required this.padding,
    this.animated = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final decoration = BoxDecoration(
      color: active ? hollow.accent.withValues(alpha: 0.15) : hollow.surface,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      border: Border.all(
        color: active ? hollow.accent.withValues(alpha: 0.4) : hollow.border,
      ),
    );
    final text = Text(
      label,
      style: HollowTypography.caption.copyWith(
        color: active ? hollow.accent : hollow.textSecondary,
        fontSize: 11,
        fontWeight: active ? FontWeight.w600 : FontWeight.normal,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: HollowFocusRing(
        onActivate: onTap,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        child: GestureDetector(
          onTap: onTap,
          child: animated
              ? AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: padding,
                  decoration: decoration,
                  child: text,
                )
              : Container(
                  padding: padding,
                  decoration: decoration,
                  child: text,
                ),
        ),
      ),
    );
  }
}
