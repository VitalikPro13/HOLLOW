import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/services/share_audio_level.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Volume button for the screen-share control bars, opening the share-audio
/// panel as a desktop popover or a mobile sheet.
///
/// Controls RECEIVED share audio only: the raw data-channel stream, which
/// bypasses the per-peer voice volume.
class ShareVolumeButton extends ConsumerWidget {
  const ShareVolumeButton({
    super.key,
    this.iconSize = 16,
    this.padding = const EdgeInsets.all(HollowSpacing.xs),
  });

  final double iconSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    return HollowTooltip(
      message: 'Share volume',
      child: HollowPressable(
        semanticLabel: 'Share volume',
        onTap: () => _open(context),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: padding,
        child: Icon(
          LucideIcons.volume2,
          size: iconSize,
          color: hollow.textSecondary,
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS) {
      showShareVolumeSheet(context);
    } else {
      _showPopover(context);
    }
  }

  void _showPopover(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final overlay = Overlay.of(context);
    final box = context.findRenderObject() as RenderBox?;
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (box == null || overlayBox == null) return;
    final origin =
        box.localToGlobal(Offset.zero, ancestor: overlayBox);
    final screen = overlayBox.size;
    const panelW = 260.0;
    // Opens ABOVE the button, because the share control bars sit at the bottom
    // of the tile.
    final left = (origin.dx + box.size.width / 2 - panelW / 2)
        .clamp(8.0, screen.width - panelW - 8.0);
    final bottom = screen.height - origin.dy + HollowSpacing.sm;

    OverlayEntry? entry;
    var removed = false;
    void remove() {
      if (removed) return;
      removed = true;
      entry?.remove();
      entry = null;
    }

    entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: remove,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: left,
              bottom: bottom,
              width: panelW,
              child: Material(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                elevation: 4,
                child: const Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.sm,
                  ),
                  child: ShareVolumePanel(),
                ),
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(entry!);
  }
}

/// Mobile bottom sheet hosting the share-audio panel.
Future<void> showShareVolumeSheet(BuildContext context) {
  final hollow = HollowTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: hollow.surface,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (_) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: HollowSpacing.sm),
                child: Container(
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: hollow.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: HollowSpacing.lg),
            const ShareVolumePanel(),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    ),
  );
}

/// The share-audio controls, shared by the desktop popover and the mobile
/// sheet. The slider runs 0-200%, where 100% is the calibrated -6 dB default
/// and 200% the source's own loudness.
class ShareVolumePanel extends ConsumerStatefulWidget {
  const ShareVolumePanel({super.key});

  @override
  ConsumerState<ShareVolumePanel> createState() => _ShareVolumePanelState();
}

class _ShareVolumePanelState extends ConsumerState<ShareVolumePanel> {
  /// The slider pushes the bus live per tick but persists only on drag end.
  double? _dragVolume;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final volume = _dragVolume ??
        (ref.watch(shareAudioVolumeProvider).valueOrNull ??
            kShareAudioVolumeDefault);
    final duck = ref.watch(shareAudioDuckProvider).valueOrNull ?? true;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Share audio',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Row(
          children: [
            Icon(LucideIcons.volume1, size: 14, color: hollow.textSecondary),
            Expanded(
              child: SizedBox(
                height: 28,
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: hollow.accent,
                    inactiveTrackColor: hollow.border,
                    thumbColor: hollow.accent,
                    overlayColor: hollow.accent.withValues(alpha: 0.08),
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 5),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                  ),
                  child: Slider(
                    value: volume,
                    min: 0.0,
                    max: 200.0,
                    onChanged: (v) {
                      setState(() => _dragVolume = v);
                      ShareAudioLevel.setVolumePercent(v);
                    },
                    onChangeEnd: (v) {
                      setState(() => _dragVolume = null);
                      ref
                          .read(shareAudioVolumeProvider.notifier)
                          .setVolume(v);
                    },
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 34,
              child: Text(
                '${volume.round()}%',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 10,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: [
            Expanded(
              child: Text(
                'Quieter when people talk',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
            HollowToggle(
              value: duck,
              onChanged: (v) {
                ShareAudioLevel.setDuckEnabled(v);
                ref.read(shareAudioDuckProvider.notifier).setEnabled(v);
              },
            ),
          ],
        ),
      ],
    );
  }
}
