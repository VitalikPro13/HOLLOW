import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/download_manager_popup.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Download manager icon button with activity badge.
/// Shared between [UserBar] (classic layout, iconSize 16) and
/// [BottomBar] (dock layout, iconSize 18).
class DownloadIconButton extends ConsumerWidget {
  final double iconSize;

  const DownloadIconButton({super.key, required this.iconSize});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final activeCount = ref.watch(activeTransferCountProvider);

    return HollowTooltip(
      message: 'Downloads',
      child: HollowPressable(
        onTap: () {
          final box = context.findRenderObject() as RenderBox?;
          final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
          showDownloadManagerPopup(
            context: context,
            anchor: Offset(pos.dx, pos.dy - 8),
            anchorBottom: true,
          );
        },
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: const EdgeInsets.all(HollowSpacing.xs),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(
              LucideIcons.download,
              size: iconSize,
              color: hollow.textSecondary,
            ),
            if (activeCount > 0)
              Positioned(
                right: -3,
                top: -3,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: hollow.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
