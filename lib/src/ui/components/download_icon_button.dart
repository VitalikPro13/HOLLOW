import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/download_manager_popup.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The download manager's button, with a count of transfers in flight, shared
/// by [UserBar] and the dock.
class DownloadIconButton extends ConsumerWidget {
  /// The button's square, as [HollowIconButton.size].
  final double size;

  const DownloadIconButton({super.key, this.size = 32});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final activeCount = ref.watch(activeTransferCountProvider);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        HollowIconButton(
          icon: LucideIcons.download,
          label: 'Downloads',
          size: size,
          onPressed: () {
            final pos = overlayAnchorOf(context);
            showDownloadManagerPopup(
              context: context,
              anchor: Offset(pos.dx, pos.dy - HollowSpacing.sm),
              anchorBottom: true,
            );
          },
        ),
        if (activeCount > 0)
          Positioned(
            right: -HollowSpacing.xs,
            top: -HollowSpacing.xxs,
            child: IgnorePointer(
              child: HollowCountBadge(
                count: activeCount,
                ring: hollow.opaqueSurface,
              ),
            ),
          ),
      ],
    );
  }
}
