import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/nav_selection_mark.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileNavBar extends ConsumerWidget {
  final VoidCallback? onAdd;

  const MobileNavBar({super.key, this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final currentTab = ref.watch(mobileTabProvider);
    final pendingFriends = ref.watch(pendingFriendCountProvider);
    // The derived SUM, so this always-mounted bar rebuilds only when the total
    // changes rather than on every unread mutation.
    final totalUnread = ref.watch(unreadProvider.select((u) {
      int total = 0;
      for (final count in u.dmUnreadCounts.values) {
        total += count;
      }
      for (final count in u.channelUnreadCounts.values) {
        total += count;
      }
      return total;
    }));
    final totalMentions = ref.watch(unreadProvider.select((u) {
      int total = 0;
      for (final count in u.channelMentionCounts.values) {
        total += count;
      }
      return total;
    }));

    return Container(
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slotWidth = constraints.maxWidth / 5;
              // The centre slot is not a tab, so indexes past it shift by one.
              final slotIndex = currentTab < 2 ? currentTab : currentTab + 1;

              return Stack(
                children: [
                  // The active tab is marked by position as well as colour.
                  AnimatedPositioned(
                    duration: ReduceMotionController.instance.isReduced
                        ? Duration.zero
                        : HollowDurations.normal,
                    curve: HollowCurves.subtle,
                    left: slotIndex * slotWidth +
                        (slotWidth - _indicatorWidth) / 2,
                    top: 0,
                    child: const NavSelectionMark(width: _indicatorWidth),
                  ),
                  Row(
                    children: [
                      _NavTab(
                        icon: LucideIcons.messageCircle,
                        label: 'Chats',
                        isActive: currentTab == 0,
                        // A mention outranks plain unread, as on the dock.
                        badge: totalMentions > 0 ? totalMentions : totalUnread,
                        badgeMention: totalMentions > 0,
                        badgeNoun: totalMentions > 0 ? 'mention' : 'unread',
                        onTap: () =>
                            ref.read(mobileTabProvider.notifier).state = 0,
                      ),
                      _NavTab(
                        icon: LucideIcons.users,
                        label: 'Friends',
                        isActive: currentTab == 1,
                        badge: pendingFriends,
                        badgeNoun: 'friend request',
                        onTap: () =>
                            ref.read(mobileTabProvider.notifier).state = 1,
                      ),
                      _AddButton(onTap: onAdd),
                      _NavTab(
                        icon: LucideIcons.archive,
                        label: 'Archive',
                        isActive: currentTab == 2,
                        badge: 0,
                        badgeNoun: 'unread',
                        onTap: () =>
                            ref.read(mobileTabProvider.notifier).state = 2,
                      ),
                      _NavTab(
                        icon: LucideIcons.settings,
                        label: 'Settings',
                        isActive: currentTab == 3,
                        badge: 0,
                        badgeNoun: 'unread',
                        onTap: () =>
                            ref.read(mobileTabProvider.notifier).state = 3,
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  static const double _indicatorWidth = 32;
}


class _AddButton extends StatelessWidget {
  final VoidCallback? onTap;

  const _AddButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Expanded(
      child: Semantics(
        button: true,
        label: 'Add a server',
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
              ),
              child: ExcludeSemantics(
                child: Icon(LucideIcons.plus,
                    size: 20, color: hollow.textOnAccent),
              ),
            ),
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
  final bool badgeMention;

  /// What the [badge] count means, for the screen-reader label: the visible
  /// badge is only a number.
  final String badgeNoun;
  final VoidCallback onTap;

  const _NavTab({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.badge,
    required this.badgeNoun,
    required this.onTap,
    this.badgeMention = false,
  });

  /// Composes the screen-reader announcement: the tab, its count and noun, and
  /// the active state.
  String _semanticLabel() {
    final buf = StringBuffer(label);
    if (badge > 0) {
      final noun = badge == 1 ? badgeNoun : '${badgeNoun}s';
      buf.write(', $badge $noun');
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = isActive ? hollow.accentText : hollow.textSecondary;

    return Expanded(
      child: Semantics(
        button: true,
        selected: isActive,
        label: _semanticLabel(),
        // Excluded so the composed label above is announced, not a meaningless
        // "5, Chats" from the badge and label nodes.
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 24, color: color),
                if (badge > 0)
                  Positioned(
                    top: -6,
                    right: -10,
                    child: HollowCountBadge(
                      count: badge,
                      mention: badgeMention,
                      ring: hollow.surface,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            // A fixed-height control, so like the iOS and Android tab bars it
            // caps label scaling; content areas still honour the full OS scale.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Text(
                label,
                style: HollowTypography.caption.copyWith(color: color),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
          ),
        ),
      ),
    );
  }
}
