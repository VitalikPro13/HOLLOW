import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Quality label chip for a watched share tile. While [renderer] is
/// delivering frames it shows what WE actually receive (e.g. "824p60" on a
/// clamped stream — media forwarding step 1), live-updating when the sharer
/// re-encodes (Source-quality toggle); before any frame arrives it falls
/// back to the sharer's source label (e.g. "1080p60"). The fps suffix rides
/// over from the source label — the frame rate isn't per-viewer clamped.
/// Pass a null [renderer] (e.g. our own outgoing share) to always show the
/// source label.
class ShareQualityChip extends StatelessWidget {
  const ShareQualityChip({super.key, this.renderer, this.sourceLabel});

  final RTCVideoRenderer? renderer;
  final String? sourceLabel;

  /// "824p60" from received 1465x824 + source label "1080p60". Uses the
  /// SHORT edge (the "p" convention), which also makes rotation irrelevant.
  static String receivedLabel(int w, int h, String? sourceLabel) {
    if (w <= 0 || h <= 0) return sourceLabel ?? '';
    final p = w < h ? w : h;
    final fps = sourceLabel == null
        ? null
        : RegExp(r'p(\d+)$').firstMatch(sourceLabel)?.group(1);
    return fps == null ? '${p}p' : '${p}p$fps';
  }

  @override
  Widget build(BuildContext context) {
    final r = renderer;
    if (r == null) {
      final label = sourceLabel;
      return (label == null || label.isEmpty)
          ? const SizedBox.shrink()
          : _chip(context, label);
    }
    return ValueListenableBuilder<RTCVideoValue>(
      valueListenable: r,
      builder: (context, v, _) {
        final label =
            receivedLabel(v.width.toInt(), v.height.toInt(), sourceLabel);
        return label.isEmpty ? const SizedBox.shrink() : _chip(context, label);
      },
    );
  }

  Widget _chip(BuildContext context, String label) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
      ),
      child: Text(
        label,
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Viewer-side "Source quality" toggle for a watched screen share (media
/// forwarding step 1). OFF by default: the sharer clamps our stream to our
/// display resolution; ON requests the share's full source quality for OUR
/// connection only (per-viewer encoders — nobody else pays for it). The
/// opt-in is per watch session, never persisted.
///
/// Styled like the quality-label chip it sits beside (surface pill on top of
/// video); active state = accent text/border, never a filled button.
class ShareSourceQualityChip extends StatelessWidget {
  const ShareSourceQualityChip({
    super.key,
    required this.active,
    required this.onChanged,
  });

  final bool active;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final fg = active ? hollow.accentText : hollow.textSecondary;
    return HollowTooltip(
      message: active
          ? 'Receiving source quality — click to match your display again'
          : 'Receive source quality (uses more bandwidth)',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: hollow.surface.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: active ? hollow.accentText : hollow.border),
        ),
        child: HollowPressable(
          semanticLabel: 'Source quality',
          onTap: () => onChanged(!active),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.maximize2, size: 12, color: fg),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'Source',
                style: HollowTypography.caption.copyWith(
                  color: fg,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
