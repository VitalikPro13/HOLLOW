import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Which tab is active on mobile.
/// 0 = Home (server/channel list), 1 = Chat, 2 = Members, 3 = Settings.
final mobileTabProvider = StateProvider<int>((ref) => 0);

/// Bottom navigation bar for mobile layout.
class MobileNav extends ConsumerWidget {
  const MobileNav({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final currentTab = ref.watch(mobileTabProvider);

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          top: BorderSide(color: hollow.border),
        ),
      ),
      child: Row(
        children: [
          _NavTab(
            icon: LucideIcons.home,
            activeIcon: LucideIcons.home,
            label: 'Home',
            isActive: currentTab == 0,
            onTap: () => ref.read(mobileTabProvider.notifier).state = 0,
          ),
          _NavTab(
            icon: LucideIcons.messageCircle,
            activeIcon: LucideIcons.messageCircle,
            label: 'Chat',
            isActive: currentTab == 1,
            onTap: () => ref.read(mobileTabProvider.notifier).state = 1,
          ),
          _NavTab(
            icon: LucideIcons.users,
            activeIcon: LucideIcons.users,
            label: 'Members',
            isActive: currentTab == 2,
            onTap: () => ref.read(mobileTabProvider.notifier).state = 2,
          ),
          _NavTab(
            icon: LucideIcons.settings,
            activeIcon: LucideIcons.settings,
            label: 'Settings',
            isActive: currentTab == 3,
            onTap: () => ref.read(mobileTabProvider.notifier).state = 3,
          ),
        ],
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _NavTab({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Expanded(
      child: HollowPressable(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              size: 22,
              color: isActive ? hollow.accent : hollow.textSecondary,
            ),
            const SizedBox(height: 2),
            // a11y Phase 3: bottom-nav labels cap their scale (like iOS/Android
            // tab bars) so the fixed-height bar stays intact; content areas
            // still honor the full 2.0× OS scale.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Text(
                label,
                style: HollowTypography.caption.copyWith(
                  color: isActive ? hollow.accent : hollow.textSecondary,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
