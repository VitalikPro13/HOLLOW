import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/nav_selection_mark.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Servers tab's badge: channel mentions across the listed servers (red),
/// else their unread posts. A muted server counts nothing, as on the dock, and
/// a server the phone hides (age gate) never counts.
final mobileServersBadgeProvider = Provider<({int count, bool mention})>((ref) {
  final servers = ref.watch(serverListProvider);
  final unread = ref.watch(unreadProvider);
  final notif = ref.watch(notificationSettingsProvider);
  final hidden = ref.watch(ageGateProvider.select((g) => g.hidden));
  var mentions = 0;
  var posts = 0;
  for (final id in servers.keys) {
    if (notif.isServerMuted(id) || hidden.contains(id)) continue;
    mentions += unread.serverMentionCount(id);
    posts += unread.serverUnreadCount(id);
  }
  return mentions > 0
      ? (count: mentions, mention: true)
      : (count: posts, mention: false);
});

class MobileNavBar extends ConsumerWidget {
  final VoidCallback? onAdd;

  const MobileNavBar({super.key, this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentTab = ref.watch(mobileTabProvider);
    final pendingFriends = ref.watch(pendingFriendCountProvider);
    // Mention rows live in Chats but count on Servers, where the channel is.
    final dmUnread = ref.watch(dmUnreadBadgeProvider);
    final servers = ref.watch(mobileServersBadgeProvider);
    final hollow = HollowTheme.of(context);

    void select(MobileTab tab) =>
        ref.read(mobileTabProvider.notifier).state = tab;

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

              return Stack(
                children: [
                  // The active tab is marked by position as well as colour.
                  AnimatedPositioned(
                    duration: ReduceMotionController.instance.isReduced
                        ? Duration.zero
                        : HollowDurations.normal,
                    curve: HollowCurves.subtle,
                    left: currentTab.slot * slotWidth +
                        (slotWidth - _indicatorWidth) / 2,
                    top: 0,
                    child: const NavSelectionMark(width: _indicatorWidth),
                  ),
                  Row(
                    children: [
                      _NavTab(
                        icon: LucideIcons.messageCircle,
                        label: 'Chats',
                        isActive: currentTab == MobileTab.chats,
                        badge: dmUnread,
                        badgeNoun: 'unread',
                        onTap: () => select(MobileTab.chats),
                      ),
                      _NavTab(
                        icon: LucideIcons.layoutGrid,
                        label: 'Servers',
                        isActive: currentTab == MobileTab.servers,
                        // A mention outranks plain unread, as on the dock.
                        badge: servers.count,
                        badgeMention: servers.mention,
                        badgeNoun: servers.mention ? 'mention' : 'unread',
                        onTap: () => select(MobileTab.servers),
                      ),
                      _AddButton(onTap: onAdd),
                      _NavTab(
                        icon: LucideIcons.users,
                        label: 'Friends',
                        isActive: currentTab == MobileTab.friends,
                        badge: pendingFriends,
                        badgeNoun: 'friend request',
                        onTap: () => select(MobileTab.friends),
                      ),
                      _NavTab(
                        icon: LucideIcons.settings,
                        label: 'Settings',
                        isActive: currentTab == MobileTab.settings,
                        badge: 0,
                        badgeNoun: 'unread',
                        onTap: () => select(MobileTab.settings),
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
            const SizedBox(height: HollowSpacing.xxs),
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
