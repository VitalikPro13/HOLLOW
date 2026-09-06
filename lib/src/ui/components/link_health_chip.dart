import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The "your connection is having a moment" flair.
///
/// Shown on call surfaces whenever the link is anything but healthy, so a
/// held-open call reads as the network rather than as the app misbehaving.
///
/// Deliberately static: a pulsing indicator would request a frame every vsync
/// on a machine that is already struggling
/// (`feedback_ticker_is_a_frame_request`).
class LinkHealthChip extends StatelessWidget {
  const LinkHealthChip({
    super.key,
    required this.snapshot,
    this.compact = false,
  });

  final LinkHealthSnapshot snapshot;

  /// Icon only, for surfaces with no room for a label. The label still reaches
  /// screen readers and the tooltip.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (!snapshot.hasFlair) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final label = snapshot.label;
    if (label == null) return const SizedBox.shrink();

    final (color, icon) = switch (snapshot.health) {
      LinkHealth.lost => (hollow.error, LucideIcons.wifiOff),
      LinkHealth.reconnecting => (hollow.warning, LucideIcons.wifiOff),
      LinkHealth.unstable => (hollow.warning, LucideIcons.wifiLow),
      LinkHealth.healthy => (hollow.textTertiary, LucideIcons.video),
    };

    final detail = snapshot.detail;
    // One string for the tooltip and assistive tech, so a screen reader gets
    // the explanation and not just the headline.
    final full = detail == null ? label : '$label. $detail';

    return HollowTooltip(
      message: full,
      child: Semantics(
        liveRegion: true,
        label: full,
        excludeSemantics: true,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? HollowSpacing.xs : HollowSpacing.sm,
            vertical: HollowSpacing.xxs,
          ),
          decoration: BoxDecoration(
            // withValues, never a lerp from transparent, which goes via black.
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              if (!compact) ...[
                const SizedBox(width: HollowSpacing.xs),
                Text(
                  label,
                  style: HollowTypography.caption.copyWith(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A full-width banner for large call surfaces, where there is room to say
/// what is happening and what is being done about it.
class LinkHealthBanner extends StatelessWidget {
  const LinkHealthBanner({super.key, required this.snapshot});

  final LinkHealthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    if (!snapshot.hasFlair) return const SizedBox.shrink();
    final label = snapshot.label;
    if (label == null) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final color = switch (snapshot.health) {
      LinkHealth.lost => hollow.error,
      LinkHealth.reconnecting || LinkHealth.unstable => hollow.warning,
      LinkHealth.healthy => hollow.textTertiary,
    };
    final detail = snapshot.detail;

    return Semantics(
      liveRegion: true,
      label: detail == null ? label : '$label. $detail',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              snapshot.health == LinkHealth.unstable
                  ? LucideIcons.wifiLow
                  : LucideIcons.wifiOff,
              size: 14,
              color: color,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: HollowTypography.caption.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textTertiary,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Full-bleed status strip for the top of a call panel. Spanning the panel with
/// a bottom border attaches it to the conversation the way a header does; a
/// floating card in the middle reads as a stray widget.
class LinkHealthHeader extends StatelessWidget {
  const LinkHealthHeader({super.key, required this.snapshot});

  final LinkHealthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    if (!snapshot.hasFlair) return const SizedBox.shrink();
    final label = snapshot.label;
    if (label == null) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final color = switch (snapshot.health) {
      LinkHealth.lost => hollow.error,
      LinkHealth.reconnecting || LinkHealth.unstable => hollow.warning,
      LinkHealth.healthy => hollow.textTertiary,
    };
    final detail = snapshot.detail;

    return Semantics(
      liveRegion: true,
      label: detail == null ? label : '$label. $detail',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          border: Border(
            bottom: BorderSide(color: color.withValues(alpha: 0.28)),
          ),
        ),
        child: Row(
          children: [
            Icon(
              snapshot.health == LinkHealth.unstable
                  ? LucideIcons.wifiLow
                  : LucideIcons.wifiOff,
              size: 14,
              color: color,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(width: HollowSpacing.sm),
              // Flexible, not Expanded: on a narrow panel the detail gives way
              // rather than forcing the row to overflow.
              Flexible(
                child: Text(
                  detail,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
