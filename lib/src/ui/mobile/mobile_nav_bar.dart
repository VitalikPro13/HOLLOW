import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:lucide_icons/lucide_icons.dart';

class MobileNavBar extends ConsumerWidget {
  final VoidCallback? onAdd;

  const MobileNavBar({super.key, this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final currentTab = ref.watch(mobileTabProvider);
    final pendingFriends = ref.watch(pendingFriendCountProvider);
    final unread = ref.watch(unreadProvider);

    int totalUnread = 0;
    for (final count in unread.dmUnreadCounts.values) {
      totalUnread += count;
    }
    for (final count in unread.channelUnreadCounts.values) {
      totalUnread += count;
    }

    return Container(
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              _NavTab(
                icon: LucideIcons.messageCircle,
                label: 'Chats',
                isActive: currentTab == 0,
                badge: totalUnread,
                onTap: () =>
                    ref.read(mobileTabProvider.notifier).state = 0,
              ),
              _NavTab(
                icon: LucideIcons.users,
                label: 'Friends',
                isActive: currentTab == 1,
                badge: pendingFriends,
                onTap: () =>
                    ref.read(mobileTabProvider.notifier).state = 1,
              ),
              _AddButton(onTap: onAdd),
              _NavTab(
                icon: LucideIcons.archive,
                label: 'Archive',
                isActive: currentTab == 2,
                badge: 0,
                onTap: () =>
                    ref.read(mobileTabProvider.notifier).state = 2,
              ),
              _NavTab(
                icon: LucideIcons.settings,
                label: 'Settings',
                isActive: currentTab == 3,
                badge: 0,
                onTap: () =>
                    ref.read(mobileTabProvider.notifier).state = 3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  final VoidCallback? onTap;

  const _AddButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: hollow.accent,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              boxShadow: [
                BoxShadow(
                  color: hollow.accent.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(LucideIcons.plus, size: 20, color: hollow.textOnAccent),
          ),
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final int badge;
  final VoidCallback onTap;

  const _NavTab({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.badge,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = isActive ? hollow.accent : hollow.textSecondary;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 22, color: color),
                if (badge > 0)
                  Positioned(
                    top: -6,
                    right: -10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.xs,
                        vertical: 1,
                      ),
                      constraints: const BoxConstraints(minWidth: 16),
                      decoration: BoxDecoration(
                        color: hollow.error,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        textAlign: TextAlign.center,
                        style: HollowTypography.caption.copyWith(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: color,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
