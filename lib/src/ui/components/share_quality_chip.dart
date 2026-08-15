import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

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
