import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';

/// The icon-only button: headers, panel strips, toolbars.
///
/// [label] is both the tooltip and what a screen reader says. [selected] is a
/// toggle that is on (a panel shown), drawn as a grey fill, never the accent:
/// the accent marks the one primary action, not which panel is open. Siblings
/// sit [HollowSpacing.xs] apart, since each carries its own hover fill.
class HollowIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  /// The square the button fills. The icon inside is 20 at 32 and up, 16
  /// below.
  final double size;

  /// Tints the glyph, for the rare button whose icon IS the state (a muted
  /// microphone in red). Null keeps it grey.
  final Color? color;

  /// A short number after the icon (pinned messages), in the console voice.
  final String? count;

  /// Replaces [label] as the tooltip only, for a tooltip that explains a mode
  /// (push to talk) while the name stays the action.
  final String? tooltip;

  /// A state fill that is not a selection: a call's muted mic reads as an
  /// error wash. Wins over [selected]'s grey.
  final Color? fill;

  const HollowIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.size = 32,
    this.color,
    this.count,
    this.tooltip,
    this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowTooltip(
      message: tooltip ?? label,
      child: HollowPressable(
        onTap: onPressed,
        disabled: onPressed == null,
        semanticLabel: label,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        backgroundColor: fill ?? (selected ? hollow.hover : null),
        child: _content(hollow),
      ),
    );
  }

  Widget _content(HollowTheme hollow) {
    final tint =
        color ?? (selected ? hollow.textPrimary : hollow.textSecondary);
    final glyph = Icon(icon, size: size >= 32 ? 20 : 16, color: tint);
    final count = this.count;
    if (count == null) return SizedBox.square(dimension: size, child: glyph);
    return SizedBox(
      height: size,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            glyph,
            const SizedBox(width: HollowSpacing.xs),
            Text(count,
                style: HollowTypography.monoSmall.copyWith(color: tint)),
          ],
        ),
      ),
    );
  }
}
