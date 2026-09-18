import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

/// What a badge is saying. The kind picks the colour; it never picks a shape,
/// a size or a radius, because those are the same for every badge.
enum HollowBadgeKind { neutral, accent, success, warning, error, mono }

/// A static statement of fact: a kind, a count, a status, a role.
///
/// **A badge is never clickable.** If it responds to a tap it is a
/// [HollowChip]. That is the whole distinction, and it is why the 46 local
/// chip, pill, tag and badge classes collapse into these two.
///
/// [HollowBadgeKind.mono] is the console voice, for the short ids and hashes
/// the protocol produces.
class HollowBadge extends StatelessWidget {
  final String label;
  final HollowBadgeKind kind;

  /// Only when it carries meaning the word does not. Rendered at 14.
  final IconData? icon;

  const HollowBadge(
    this.label, {
    super.key,
    this.kind = HollowBadgeKind.neutral,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final foreground = _foreground(hollow);
    final style = (kind == HollowBadgeKind.mono
            ? HollowTypography.monoSmall
            : HollowTypography.micro)
        .copyWith(
      color: foreground,
      // A badge is usually a count, and a count changes in place.
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.xs,
        vertical: HollowSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: _fill(hollow, foreground),
        borderRadius: BorderRadius.circular(hollow.radiusXs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: _iconSize, color: foreground),
            const SizedBox(width: HollowSpacing.xs),
          ],
          Text(label, style: style),
        ],
      ),
    );
  }

  Color _foreground(HollowTheme hollow) => switch (kind) {
        HollowBadgeKind.neutral => hollow.textSecondary,
        HollowBadgeKind.mono => hollow.textSecondary,
        HollowBadgeKind.accent => hollow.accentText,
        HollowBadgeKind.success => hollow.success,
        HollowBadgeKind.warning => hollow.warning,
        HollowBadgeKind.error => hollow.error,
      };

  /// Neutral sits on the raised surface; a semantic kind sits on a wash of its
  /// own colour, so the badge still reads without relying on colour alone.
  Color _fill(HollowTheme hollow, Color foreground) => switch (kind) {
        HollowBadgeKind.neutral || HollowBadgeKind.mono => hollow.elevated,
        _ => foreground.withValues(alpha: _wash),
      };
}

const double _iconSize = 14;
const double _wash = 0.14;
