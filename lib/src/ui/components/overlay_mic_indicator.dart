import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/overlay_mic_provider.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// "Mic on for overlay" in the user bar and the dock while listening for the
/// stream overlay outside a call, so an open mic is never hidden inside a
/// Settings page. A tap stops it. Takes no space otherwise.
class OverlayMicIndicator extends ConsumerWidget {
  /// Space around the chip when it shows, so the bar's gap goes with it.
  final EdgeInsetsGeometry padding;

  const OverlayMicIndicator({super.key, this.padding = EdgeInsets.zero});

  static const String label = 'Mic on for overlay';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listening =
        ref.watch(overlayMicProvider.select((s) => s.listening));
    if (!listening) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: HollowTooltip(
        message: 'Stop listening',
        child: HollowChip(
          label: label,
          icon: LucideIcons.mic,
          trailingIcon: LucideIcons.x,
          selected: true,
          semanticLabel: '$label. Stop listening',
          onTap: () => ref
              .read(overlayMicProvider.notifier)
              .turnOff()
              .catchError((Object e) {
            if (!context.mounted) return;
            HollowToast.show(
                context,
                friendlyError(e,
                    fallback: "Couldn't turn the mic off. Try again."),
                type: HollowToastType.error);
          }),
        ),
      ),
    );
  }
}
