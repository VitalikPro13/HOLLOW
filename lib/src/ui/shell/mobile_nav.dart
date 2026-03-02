import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Which tab is active on mobile.
/// 0 = Home (server/channel list), 1 = Chat, 2 = Members, 3 = Settings.
final mobileTabProvider = StateProvider<int>((ref) => 0);

/// Bottom navigation bar for mobile layout.
class MobileNav extends ConsumerWidget {
  const MobileNav({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
    final currentTab = ref.watch(mobileTabProvider);

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: haven.surface,
        border: Border(
          top: BorderSide(color: haven.border),
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
    final haven = HavenTheme.of(context);

    return Expanded(
      child: HavenPressable(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isActive ? activeIcon : icon,
              size: 22,
              color: isActive ? haven.accent : haven.textSecondary,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: HavenTypography.caption.copyWith(
                color: isActive ? haven.accent : haven.textSecondary,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
