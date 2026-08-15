import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/audio_route_provider.dart';
import 'package:hollow/src/core/services/audio_route.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Icon for an audio route, shared by the sheet and the in-call control row
/// so the button always shows where the audio is actually going.
IconData audioRouteIcon(AudioRouteKind? kind) {
  switch (kind) {
    case AudioRouteKind.earpiece:
      return LucideIcons.phone;
    case AudioRouteKind.wired:
      // headSET (with boom), not headPHONES — the deafen button next to this
      // one in every call control row already owns the plain headphones glyph.
      return LucideIcons.headset;
    case AudioRouteKind.bluetooth:
      return LucideIcons.bluetooth;
    case AudioRouteKind.usb:
      return LucideIcons.usb;
    case AudioRouteKind.carAudio:
      return LucideIcons.car;
    case AudioRouteKind.airplay:
      return LucideIcons.airplay;
    case AudioRouteKind.speaker:
    case null:
      return LucideIcons.speaker;
  }
}

/// Output/input picker for a live mobile call (HOLLOW_PLAN "change input/
/// output on mobile"). Picking a route sets BOTH ends on iOS — a headset's
/// mic travels with its speakers in an AVAudioSession route.
///
/// [onSelect] performs the switch through whichever call surface is live
/// (1:1 call or voice channel), so `isSpeakerOn` stays in step with the route.
Future<void> showMobileAudioRouteSheet(
  BuildContext context, {
  required Future<void> Function(AudioRoute route) onSelect,
}) {
  final hollow = HollowTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: hollow.surface,
    isScrollControlled: true,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (_) => _AudioRouteSheet(onSelect: onSelect),
  );
}

class _AudioRouteSheet extends ConsumerStatefulWidget {
  final Future<void> Function(AudioRoute route) onSelect;

  const _AudioRouteSheet({required this.onSelect});

  @override
  ConsumerState<_AudioRouteSheet> createState() => _AudioRouteSheetState();
}

class _AudioRouteSheetState extends ConsumerState<_AudioRouteSheet> {
  @override
  void initState() {
    super.initState();
    // Re-read on open: a headset may have been plugged in while the sheet was
    // closed, and the list must show what is attached RIGHT NOW.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(audioRouteProvider.notifier).refresh();
    });
  }

  Future<void> _pick(AudioRoute route) async {
    Navigator.pop(context);
    await widget.onSelect(route);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final routeState = ref.watch(audioRouteProvider);
    final routes = routeState.routes;

    return SafeArea(
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
            Row(
              children: [
                Icon(audioRouteIcon(routeState.activeKind),
                    size: 20, color: hollow.textPrimary),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  'Audio device',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.md),
            if (routes.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: HollowSpacing.lg, horizontal: HollowSpacing.xs),
                child: Text(
                  'Looking for audio devices…',
                  style: HollowTypography.body
                      .copyWith(color: hollow.textTertiary),
                ),
              )
            else
              for (final route in routes)
                _RouteRow(
                  route: route,
                  selected: route.kind == routeState.activeKind,
                  onTap: () => _pick(route),
                ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              'Your microphone follows the device you pick.',
              style:
                  HollowTypography.caption.copyWith(color: hollow.textTertiary),
            ),
            const SizedBox(height: HollowSpacing.lg),
          ],
        ),
      ),
    );
  }
}

class _RouteRow extends StatelessWidget {
  final AudioRoute route;
  final bool selected;
  final VoidCallback onTap;

  const _RouteRow({
    required this.route,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = selected ? hollow.accentText : hollow.textPrimary;
    return HollowPressable(
      onTap: onTap,
      semanticButton: false,
      semanticLabel: selected ? '${route.label}, in use' : route.label,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      // Selection reads as a tinted row, never a filled button — and the
      // background is a real colour, never Colors.transparent (lerping from
      // transparent goes via black).
      backgroundColor: selected
          ? hollow.accent.withValues(alpha: 0.12)
          : hollow.surface,
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md, vertical: HollowSpacing.md),
      child: Row(
        children: [
          Icon(audioRouteIcon(route.kind), size: 18, color: color),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Text(
              route.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.body.copyWith(color: color),
            ),
          ),
          if (selected)
            Icon(LucideIcons.check, size: 16, color: hollow.accentText),
        ],
      ),
    );
  }
}
