import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/stat_bar.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:url_launcher/url_launcher.dart';

/// Total visible DM message count, the number two synced devices compare.
///
/// DMs fully converge across a person's devices, so both should report the
/// same value. Channel messages are excluded: they are lazy-paged per device
/// and would diverge even when fully synced.
final _dmMessageCountProvider = FutureProvider.autoDispose<int>((ref) async {
  // The last-message map is the cheapest proxy for "the DM table changed".
  ref.watch(lastDmMessageProvider);
  try {
    return await storage_api.countAllDmMessages();
  } catch (_) {
    return 0;
  }
});

/// Home dashboard, shown when no server or DM is selected in dock mode.
class HomeDashboard extends ConsumerWidget {
  const HomeDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    final leftReveal =
        StartupRevealScope.interval(context, 0.30, 0.55);
    final centerReveal =
        StartupRevealScope.interval(context, 0.35, 0.60);
    final rightReveal =
        StartupRevealScope.interval(context, 0.40, 0.65);

    Widget revealed(Widget child, Animation<double>? reveal) {
      if (reveal == null) return child;
      return FadeTransition(
        opacity: reveal,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.08),
            end: Offset.zero,
          ).animate(reveal),
          child: child,
        ),
      );
    }

    final leftContent =
        revealed(_ProfileColumn(hollow: hollow), leftReveal);
    final centerCol = Expanded(
      child: revealed(
          _RecentConversationsColumn(hollow: hollow), centerReveal),
    );
    final rightContent =
        revealed(_NetworkColumn(hollow: hollow), rightReveal);
    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          child: Container(
            width: 1,
            height: double.infinity,
            color: hollow.border,
          ),
        );

    return Container(
      color: hollow.background,
      // Outside the padding on purpose: `dashboardColumnWidths` subtracts the
      // padding and dividers itself, so it needs the full width.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final widths = dashboardColumnWidths(constraints.maxWidth);
          return Padding(
            padding: const EdgeInsets.all(HollowSpacing.xl),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ScrollableColumn(width: widths.left, child: leftContent),
                divider(),
                centerCol,
                if (widths.right case final rightWidth?) ...[
                  divider(),
                  _ScrollableColumn(
                      width: rightWidth, child: rightContent),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Height band for the news panel. The minimum reads a post heading plus the
/// start of its body; the maximum bounds what the panel contributes to the
/// column's intrinsic height (see its use site).
const double _kNewsPanelMin = 140;
const double _kNewsPanelMax = 280;

/// Natural widths of the two fixed columns, and the width the centre list
/// needs before they start giving ground.
const double _kLeftColumnWidth = 240;
const double _kRightColumnWidth = 260;
const double _kCentreColumnMin = 200;

/// How far the side columns may shrink before the layout gives up a column
/// instead. Squeezing harder makes the relay bars, stats rows and conversation
/// header overflow on their own, fitting the columns at the cost of contents.
const double _kSideColumnMinFactor = 0.85;

/// Below this the dashboard drops to two columns, so the conversation list
/// keeps something to live in.
const double _kThreeColumnMin = 720;

/// The dashboard layout for a given width.
///
/// The interface zoom shrinks the viewport horizontally too, so the fixed
/// columns stop fitting at high zoom. They give ground together to stay
/// balanced, and below [_kThreeColumnMin] the Network column drops out rather
/// than every card inside it breaking.
({double left, double? right}) dashboardColumnWidths(double available) {
  // Outer padding either side, plus two dividers with their own padding.
  const divider = HollowSpacing.lg * 2 + 1;
  const chrome = HollowSpacing.xl * 2 + divider * 2;
  if (!available.isFinite) {
    return (left: _kLeftColumnWidth, right: _kRightColumnWidth);
  }
  if (available < _kThreeColumnMin) {
    final free = available - HollowSpacing.xl * 2 - divider;
    return (left: _kLeftColumnWidth.clamp(0.0, free - _kCentreColumnMin), right: null);
  }
  final free = available - chrome;
  const natural = _kLeftColumnWidth + _kRightColumnWidth;
  if (free - natural >= _kCentreColumnMin) {
    return (left: _kLeftColumnWidth, right: _kRightColumnWidth);
  }
  final factor =
      ((free - _kCentreColumnMin) / natural).clamp(_kSideColumnMinFactor, 1.0);
  return (
    left: _kLeftColumnWidth * factor,
    right: _kRightColumnWidth * factor,
  );
}

/// Our own verified Twitch login, read exactly as a viewer reads it.
///
/// Deliberately NOT `twitchGetUsername()`, which answers from our own OAuth
/// token: a connected account is not a verified one, and the purple chip means
/// verified everywhere else.
String? _myVerifiedTwitch(WidgetRef ref, String? peerId) =>
    peerId == null ? null : ref.watch(twitchLoginProvider(peerId));

/// A fixed-width dashboard column that scrolls once it outgrows the viewport.
///
/// A plain [Column] here is clipped by the shell's `ClipRect` with nothing to
/// say more is below, which only shows up once the interface zoom shrinks the
/// logical viewport. The scrollbar keeps the DEFAULT fade behaviour, since
/// `thumbVisibility: true` reads as a stuck UI element rather than a hint.
class _ScrollableColumn extends StatefulWidget {
  final double width;
  final Widget child;

  const _ScrollableColumn({required this.width, required this.child});

  @override
  State<_ScrollableColumn> createState() => _ScrollableColumnState();
}

class _ScrollableColumnState extends State<_ScrollableColumn> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      child: LayoutBuilder(
        // No explicit Scrollbar: HollowScrollBehavior already gives every
        // desktop vertical scrollable a gutter-reserved one (issue #54), and a
        // manual wrapper paints a second thumb on top of it.
        builder: (context, constraints) => SingleChildScrollView(
          controller: _controller,
          // minHeight + IntrinsicHeight, not a bare scroll view: the network
          // column ends in a flexible news panel, and flex inside an unbounded
          // scroll view is a hard error. This keeps the column as it is
          // whenever it fits and falls back to its intrinsic height when not.
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(child: widget.child),
          ),
        ),
      ),
    );
  }
}

/// Left column — user profile card.
class _ProfileColumn extends ConsumerWidget {
  final HollowTheme hollow;
  const _ProfileColumn({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider);
    final localPeerId = identity.peerId;
    final localProfile = localPeerId != null
        ? ref.watch(profileProvider.select((p) => p[localPeerId]))
        : null;

    final displayName = localPeerId != null
        ? displayNameForPeer(localProfile, localPeerId)
        : 'Loading...';
    final profile = localProfile;
    final statusText = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    // "Online" means actually reachable (relay connected), not merely that the
    // local node started, which would show Online with no internet.
    final isOnline = ref.watch(overallConnectionProvider).isOnline;
    final amInvisible =
        ref.watch(invisibleModeProvider);
    final verifiedTwitch = _myVerifiedTwitch(ref, localPeerId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: HollowSpacing.lg),

        if (localPeerId != null)
          HollowAvatar(peerId: localPeerId, size: 72, animate: true)
        else
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusLg),
            ),
          ),

        const SizedBox(height: HollowSpacing.md),

        Text(
          displayName,
          style: HollowTypography.heading.copyWith(
            color: hollow.textPrimary,
            fontSize: 18,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),

        const SizedBox(height: HollowSpacing.xs),

        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(
              color: amInvisible
                  ? hollow.textSecondary
                  : (isOnline ? hollow.success : hollow.textSecondary),
              size: 8,
              filled: !amInvisible && isOnline,
            ),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              amInvisible
                  ? 'Invisible'
                  : (isOnline ? 'Online' : 'Offline'),
              style: HollowTypography.caption.copyWith(
                color: amInvisible
                    ? hollow.textSecondary
                    : (isOnline ? hollow.success : hollow.textSecondary),
              ),
            ),
          ],
        ),

        if (verifiedTwitch != null && verifiedTwitch.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.sm),
            child: HollowFocusRing(
              enabled: true,
              onActivate: () => launchUrl(
                Uri.parse('https://twitch.tv/$verifiedTwitch'),
                mode: LaunchMode.externalApplication,
              ),
              borderRadius: BorderRadius.circular(6),
              child: GestureDetector(
                onTap: () => launchUrl(
                  Uri.parse('https://twitch.tv/$verifiedTwitch'),
                  mode: LaunchMode.externalApplication,
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.sm, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF9146FF).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(BrandIcons.twitch,
                          size: 11, color: Color(0xFF9146FF)),
                      const SizedBox(width: 4),
                      Text(
                        verifiedTwitch,
                        style: HollowTypography.caption.copyWith(
                          color: const Color(0xFF9146FF),
                          fontWeight: FontWeight.w600,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        if (statusText.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            statusText,
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontStyle: FontStyle.italic,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],

        if (aboutMe.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: HollowSpacing.md,
              horizontal: HollowSpacing.lg,
            ),
            child: Divider(height: 1, color: hollow.border),
          ),
          Text(
            '\u201C$aboutMe\u201D',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontStyle: FontStyle.italic,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: HollowSpacing.md,
              horizontal: HollowSpacing.lg,
            ),
            child: Divider(height: 1, color: hollow.border),
          ),
        ] else
          const SizedBox(height: HollowSpacing.lg),

        const HomeStatusCard(),

        const SizedBox(height: HollowSpacing.md),

        _SyncStatsCard(hollow: hollow),

        const Spacer(),

        if (localPeerId != null)
          HollowPressable(
            onTap: () {
              Clipboard.setData(ClipboardData(text: localPeerId));
              HollowToast.show(
                context,
                'Peer ID copied',
                type: HollowToastType.success,
                duration: const Duration(seconds: 1),
              );
            },
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            hoverColor: hollow.elevated,
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm,
              vertical: HollowSpacing.xs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.copy, size: 10,
                    color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.xs),
                Text(
                  localPeerId.length > 16
                      ? '${localPeerId.substring(0, 8)}...${localPeerId.substring(localPeerId.length - 6)}'
                      : localPeerId,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Counts that fully converge across a person's devices, so two devices can be
/// compared at a glance. Local-only: the numbers themselves are the sync truth.
///
/// Deliberately omits channel messages, which are lazy-paged per device and
/// would differ even when fully synced, reading falsely as "out of sync".
class _SyncStatsCard extends ConsumerWidget {
  final HollowTheme hollow;
  const _SyncStatsCard({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final servers = ref.watch(serverListProvider);
    final devices = ref.watch(myDevicesProvider);
    final dmCount = ref.watch(_dmMessageCountProvider);

    // Master-collapsed and deduped, so a friend stranded under a device id is
    // not counted twice.
    final friendCount = ref.watch(sortedFriendsProvider).length;
    final serverCount = servers.length;
    final devicesOnline = devices.where((d) => d.online).length;
    final deviceCount = devices.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.sm + 2),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.chartColumn, size: 13,
                  color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'YOUR STATS',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),

          _StatRow(
            hollow: hollow,
            icon: LucideIcons.users,
            label: 'Friends',
            value: '$friendCount',
          ),
          const SizedBox(height: HollowSpacing.xs + 2),
          _StatRow(
            hollow: hollow,
            icon: LucideIcons.server,
            label: 'Servers',
            value: '$serverCount',
          ),
          const SizedBox(height: HollowSpacing.xs + 2),
          _StatRow(
            hollow: hollow,
            icon: LucideIcons.messageSquare,
            label: 'DM messages',
            value: dmCount.maybeWhen(
              data: (n) => '$n',
              orElse: () => '…',
            ),
          ),

          // Shown even on a single-device install, as a hint that linking
          // exists; the online/total form is the sync indicator once there are
          // siblings.
          const SizedBox(height: HollowSpacing.xs + 2),
          _StatRow(
            hollow: hollow,
            icon: LucideIcons.smartphone,
            label: 'Devices',
            value: deviceCount > 1
                ? '$devicesOnline / $deviceCount online'
                : '1',
            // Green only when every sibling is online, so the colour answers
            // "are we converging right now?".
            valueColor: deviceCount > 1
                ? (devicesOnline == deviceCount
                    ? hollow.success
                    : hollow.warning)
                : hollow.textPrimary,
          ),
        ],
      ),
    );
  }
}

/// Single label/value row inside the stats card.
class _StatRow extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatRow({
    required this.hollow,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 12, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          label,
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 11,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: HollowTypography.body.copyWith(
            color: valueColor ?? hollow.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// Center column — recent DM conversations.
class _RecentConversationsColumn extends ConsumerWidget {
  final HollowTheme hollow;
  const _RecentConversationsColumn({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lastMessages = ref.watch(lastDmMessageProvider);
    final online = ref.watch(onlineIdentitiesProvider);
    final dmUnreads = ref.watch(unreadProvider.select((s) => s.dmUnreadCounts));

    // The shared provider collapses a friend's stored id to their master and
    // dedupes, so a friend stranded under a DEVICE id does not appear as a
    // phantom duplicate conversation.
    final accepted = ref.watch(sortedFriendsProvider);

    final conversations = <_ConversationInfo>[];
    for (final friend in accepted) {
      final lastMsg = lastMessages[friend.peerId];
      final timestamp = lastMsg?.timestamp ?? DateTime(2000);
      conversations.add(_ConversationInfo(
        peerId: friend.peerId,
        lastMessage: lastMsg,
        timestamp: timestamp,
        isOnline: online.contains(friend.peerId),
        unreadCount: dmUnreads[friend.peerId] ?? 0,
      ));
    }

    conversations.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: HollowSpacing.lg,
            bottom: HollowSpacing.md,
          ),
          child: Row(
            children: [
              Icon(LucideIcons.messageCircle, size: 18,
                  color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              // This column is the Expanded one, so the zoom squeezes it
              // first and a bare Text here overflows.
              Flexible(
                child: Text(
                  'Recent Conversations',
                  style: HollowTypography.subheading.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        if (conversations.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.messageCircle, size: 40,
                      color: hollow.textSecondary.withValues(alpha: 0.2)),
                  const SizedBox(height: HollowSpacing.md),
                  Text(
                    'No conversations yet',
                    style: HollowTypography.body
                        .copyWith(color: hollow.textSecondary),
                  ),
                  const SizedBox(height: HollowSpacing.xs),
                  Text(
                    'Add a friend to start chatting',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary),
                  ),
                ],
              ),
            ),
          )
        else
          Expanded(
            child: ListView.builder(
              itemCount: conversations.length,
              padding: EdgeInsets.zero,
              itemBuilder: (context, index) {
                final conv = conversations[index];
                final name = displayNameForPeer(
                    ref.watch(profileProvider.select((p) => p[conv.peerId])),
                    conv.peerId);

                return Padding(
                  padding: const EdgeInsets.only(
                    bottom: HollowSpacing.xs,
                  ),
                  // The same conversation menu the sidebar DM tile carries
                  // (issue #61).
                  child: ContextMenuTarget(
                    semanticLabel: 'Conversation actions',
                    onOpen: (anchor) => showUserContextMenu(
                      context: context,
                      ref: ref,
                      peerId: conv.peerId,
                      surface: UserMenuSurface.dmTile,
                      anchor: anchor,
                    ),
                    child: HollowPressable(
                    onTap: () {
                      ref.read(selectedPeerProvider.notifier).state =
                          conv.peerId;
                      ref.read(selectedServerProvider.notifier).state =
                          null;
                      ref.read(channelListProvider.notifier).clear();
                      ref.read(selectedChannelProvider.notifier).state =
                          null;
                      ref.read(unreadProvider.notifier)
                          .markDmSeen(conv.peerId, null);
                    },
                    borderRadius:
                        BorderRadius.circular(hollow.radiusMd),
                    hoverColor: hollow.elevated,
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.md,
                      vertical: HollowSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            HollowAvatar(
                                peerId: conv.peerId, size: 36),
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: hollow.background,
                                  shape: BoxShape.circle,
                                ),
                                alignment: Alignment.center,
                                child: StatusDot(
                                  color: conv.isOnline
                                      ? hollow.success
                                      : hollow.textSecondary,
                                  size: 8,
                                  filled: conv.isOnline,
                                  semanticLabel:
                                      conv.isOnline ? 'Online' : 'Offline',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: HollowSpacing.sm),

                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                name,
                                style: HollowTypography.body
                                    .copyWith(
                                  color: hollow.textPrimary,
                                  fontWeight: conv.unreadCount > 0
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (conv.lastMessage != null) ...[
                                const SizedBox(height: 2),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      if (conv.lastMessage!.isMe)
                                        TextSpan(
                                          text: 'You: ',
                                          style: HollowTypography.caption
                                              .copyWith(
                                            color: hollow.textSecondary,
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      TextSpan(
                                        text: conv.lastMessage!.text,
                                        style: HollowTypography.caption
                                            .copyWith(
                                          color: hollow.textSecondary,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),

                        if (conv.lastMessage != null) ...[
                          const SizedBox(width: HollowSpacing.sm),
                          Text(
                            _formatTime(conv.timestamp),
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                        ],
                        if (conv.unreadCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            constraints:
                                const BoxConstraints(minWidth: 18),
                            height: 18,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5),
                            decoration: BoxDecoration(
                              color: hollow.error,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              conv.unreadCount > 99
                                  ? '99+'
                                  : '${conv.unreadCount}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year &&
        dt.month == now.month &&
        dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    final yesterday = now.subtract(const Duration(days: 1));
    if (dt.year == yesterday.year &&
        dt.month == yesterday.month &&
        dt.day == yesterday.day) {
      return 'Yesterday';
    }
    return '${dt.month}/${dt.day}';
  }
}

class _ConversationInfo {
  final String peerId;
  final ChatMessage? lastMessage;
  final DateTime timestamp;
  final bool isOnline;
  final int unreadCount;

  const _ConversationInfo({
    required this.peerId,
    required this.lastMessage,
    required this.timestamp,
    required this.isOnline,
    required this.unreadCount,
  });
}

/// Right column — live network & connection status.
class _NetworkColumn extends ConsumerWidget {
  final HollowTheme hollow;
  const _NetworkColumn({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peers = ref.watch(peersProvider);
    // A friend can be online via a device whose peer_id differs from their
    // master, so the master key will not be in `peers`.
    final online = ref.watch(onlineIdentitiesProvider);
    final relayStats = ref.watch(relayStatsProvider);

    // Real connection state (local node and relay WS), not "node started".
    final overall = ref.watch(overallConnectionProvider);

    final connStatus = ref.watch(connectionStatusProvider);
    // Master-collapsed, so the `links.identityOf(device) == f.peerId` scans
    // below match; a friend stranded under a device id would never match its
    // own devices and would stick in a fake "connecting" state.
    final accepted = ref.watch(sortedFriendsProvider);
    // `peers` and `connStatus` are keyed by the DEVICE peer_id the relay
    // reports while a friend is their MASTER id, so each friend resolves by
    // scanning ANY of their devices. Looking the master up directly leaves a
    // multi-device friend stuck in a fake "connecting" state while the DM works.
    final links = ref.watch(deviceLinkProvider);
    final encryptedFriends = <String>[];
    final activeFriends = <PeerConnectionStatus>[];
    final offlineFriends = <String>[];
    for (final f in accepted) {
      final hasEncrypted = peers.entries.any((e) =>
          links.identityOf(e.key) == f.peerId && e.value.isEncrypted);
      // The most-advanced status across this friend's devices.
      PeerConnectionStatus? bestCs;
      for (final e in connStatus.peers.entries) {
        if (links.identityOf(e.key) != f.peerId) continue;
        final stage = e.value.stage;
        if (stage == PeerConnectionStage.connected ||
            stage == PeerConnectionStage.keyExchange) {
          bestCs = e.value;
          if (stage == PeerConnectionStage.connected) break;
        }
      }
      if (hasEncrypted) {
        encryptedFriends.add(f.peerId);
      } else if (bestCs != null) {
        activeFriends.add(bestCs);
      } else if (online.contains(f.peerId)) {
        // Online via a device whose status is not surfaced yet, so connecting
        // rather than offline.
        activeFriends.add(PeerConnectionStatus(
          peerId: f.peerId,
          stage: PeerConnectionStage.keyExchange,
          lastUpdated: DateTime.now(),
        ));
      } else {
        offlineFriends.add(f.peerId);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: HollowSpacing.lg,
            bottom: HollowSpacing.md,
          ),
          child: Row(
            children: [
              Icon(LucideIcons.activity, size: 18,
                  color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Network',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),

        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(HollowSpacing.sm + 2),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.border),
          ),
          child: Row(
            children: [
              StatusDot(
                color: overall.isOnline
                    ? hollow.success
                    : (overall == OverallConnection.offline ||
                            overall == OverallConnection.error
                        ? hollow.warning
                        : hollow.textSecondary),
                size: 8,
                // Adjacent overall.label text names the state; ring = not online.
                filled: overall.isOnline,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      overall.label,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                    Builder(builder: (context) {
                      // Reachable FRIENDS, not raw relay device peers: a
                      // just-removed friend lingers in `peers` while still in a
                      // shared room, so counting sockets shows a phantom peer.
                      final reachable =
                          accepted.where((f) => online.contains(f.peerId)).length;
                      return Text(
                        '$reachable friend${reachable == 1 ? '' : 's'} reachable',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 10,
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: HollowSpacing.lg),

        _SectionLabel(hollow: hollow, label: 'FRIENDS'),
        const SizedBox(height: HollowSpacing.sm),

        for (final cs in activeFriends)
          _ConnectionRow(
            hollow: hollow,
            peerId: cs.peerId,
            name: displayNameForPeer(
                ref.watch(profileProvider.select((p) => p[cs.peerId])),
                cs.peerId),
            status: cs.label,
            statusColor: cs.stage == PeerConnectionStage.failed
                ? hollow.error
                : hollow.accent,
            showSpinner: cs.stage != PeerConnectionStage.failed &&
                cs.stage != PeerConnectionStage.encrypted,
          ),

        if (encryptedFriends.isNotEmpty)
          _CounterRow(
            hollow: hollow,
            icon: LucideIcons.shieldCheck,
            label: 'Encrypted',
            count: encryptedFriends.length,
            color: hollow.success,
          ),
        if (offlineFriends.isNotEmpty)
          _CounterRow(
            hollow: hollow,
            icon: LucideIcons.wifiOff,
            label: 'Offline',
            count: offlineFriends.length,
            color: hollow.textSecondary,
          ),

        if (accepted.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: HollowSpacing.sm,
            ),
            child: Text(
              'No friends added',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
          ),

        const SizedBox(height: HollowSpacing.lg),

        _SectionLabel(hollow: hollow, label: 'RELAY SERVER'),
        const SizedBox(height: HollowSpacing.sm),

        _RelayStatsCard(hollow: hollow, stats: relayStats),

        const SizedBox(height: HollowSpacing.lg),

        // Flexible plus a bounded box, not a bare `Expanded`: under the
        // column's outer scroll view the max caps what this contributes to the
        // INTRINSIC height, or the un-scrolled posts inflate the column past
        // the viewport and the outer bar takes over the scrolling. The min
        // stops the panel being squeezed to nothing on a short column.
        Flexible(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: _kNewsPanelMin,
              maxHeight: _kNewsPanelMax,
            ),
            child: _NewsPanel(hollow: hollow),
          ),
        ),

        const SizedBox(height: HollowSpacing.sm),

        Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
          child: Row(
            children: [
              Icon(LucideIcons.users, size: 13, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'Online',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: ShimmerDividerLine(hollow: hollow),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                '${relayStats.onlineUsers}',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Section label (e.g., "FRIENDS", "SERVERS").
class _SectionLabel extends StatelessWidget {
  final HollowTheme hollow;
  final String label;
  const _SectionLabel({required this.hollow, required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: HollowTypography.caption.copyWith(
        color: hollow.textSecondary,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        fontSize: 10,
      ),
    );
  }
}

/// News panel: developer posts from news.json, plus version and updates.
class _NewsPanel extends ConsumerWidget {
  final HollowTheme hollow;
  const _NewsPanel({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final news = ref.watch(newsProvider);
    final updateState = ref.watch(updaterProvider);
    final hasUpdate = ref.watch(hasUpdateProvider);

    if (news.posts.isEmpty) return const SizedBox.shrink();

    final posts = news.posts.take(2).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(hollow: hollow, label: 'NEWS'),
        const SizedBox(height: HollowSpacing.sm),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(HollowSpacing.sm + 2),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (int i = 0; i < posts.length; i++) ...[
                          _NewsPostEntry(hollow: hollow, post: posts[i]),
                          if (i < posts.length - 1) ...[
                            const SizedBox(height: HollowSpacing.sm),
                            Container(
                              height: 1,
                              color: hollow.border.withValues(alpha: 0.2),
                            ),
                            const SizedBox(height: HollowSpacing.sm),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: HollowSpacing.sm),
                Container(
                  height: 1,
                  color: hollow.border.withValues(alpha: 0.3),
                ),
                const SizedBox(height: HollowSpacing.sm),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text(
                          'Installed',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 9,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: HollowSpacing.xs + 2,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: hollow.textSecondary.withValues(alpha: 0.1),
                            borderRadius:
                                BorderRadius.circular(hollow.radiusSm),
                            border: Border.all(
                              color:
                                  hollow.textSecondary.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Text(
                            'v${updateState.currentVersion}',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (hasUpdate && updateState.manifest != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(
                          left: HollowSpacing.xs,
                          right: HollowSpacing.xs,
                          top: 13,
                        ),
                        child: Icon(
                          LucideIcons.arrowRight,
                          size: 12,
                          color: hollow.accent,
                        ),
                      ),
                      HollowFocusRing(
                        enabled: true,
                        onActivate: () => showUserSettingsDialog(
                          context,
                          openUpdatesTab: true,
                        ),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        child: GestureDetector(
                        onTap: () => showUserSettingsDialog(
                          context,
                          openUpdatesTab: true,
                        ),
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                'Latest',
                                style: HollowTypography.caption.copyWith(
                                  color: hollow.accent,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: HollowSpacing.xs + 2,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color:
                                      hollow.accent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(
                                      hollow.radiusSm),
                                  border: Border.all(
                                    color:
                                        hollow.accent.withValues(alpha: 0.4),
                                  ),
                                ),
                                child: Text(
                                  'v${updateState.manifest!.latest}',
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.accent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      ),
                    ],
                    const Spacer(),
                    HollowFocusRing(
                      enabled: true,
                      onActivate: () async {
                        final results = await Future.wait([
                          ref.read(newsProvider.notifier).refresh(),
                          ref
                              .read(updaterProvider.notifier)
                              .checkForUpdates()
                              .then((_) => true)
                              .catchError((_) => false),
                        ]);
                        if (context.mounted && results[0] == false) {
                          HollowToast.show(
                            context,
                            'Failed to fetch news. Check your connection',
                            type: HollowToastType.error,
                          );
                        }
                      },
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      child: GestureDetector(
                      onTap: () async {
                        final results = await Future.wait([
                          ref.read(newsProvider.notifier).refresh(),
                          ref
                              .read(updaterProvider.notifier)
                              .checkForUpdates()
                              .then((_) => true)
                              .catchError((_) => false),
                        ]);
                        if (context.mounted && results[0] == false) {
                          HollowToast.show(
                            context,
                            'Failed to fetch news. Check your connection',
                            type: HollowToastType.error,
                          );
                        }
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: Icon(
                          LucideIcons.refreshCw,
                          size: 12,
                          color: hollow.textSecondary,
                        ),
                      ),
                    ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NewsPostEntry extends StatelessWidget {
  final HollowTheme hollow;
  final NewsPost post;
  const _NewsPostEntry({required this.hollow, required this.post});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          post.title,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          post.date,
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 10,
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        MarkdownBody(
          data: post.body,
          shrinkWrap: true,
          selectable: true,
          onTapLink: (text, href, title) {
            if (href != null) {
              launchUrl(Uri.parse(href),
                  mode: LaunchMode.externalApplication);
            }
          },
          styleSheet: MarkdownStyleSheet(
            p: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontSize: 11,
              height: 1.5,
            ),
            h2: HollowTypography.heading.copyWith(
              color: hollow.textPrimary,
              fontSize: 13,
            ),
            h3: HollowTypography.heading.copyWith(
              color: hollow.textPrimary,
              fontSize: 12,
            ),
            listBullet: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
            ),
            strong: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
            a: HollowTypography.body.copyWith(
              color: hollow.accent,
              fontSize: 11,
              decoration: TextDecoration.underline,
              decorationColor: hollow.accent,
            ),
            blockSpacing: 8,
            horizontalRuleDecoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: hollow.border.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Relay server stats card: RAM and bandwidth bars, plus the poll-cycle bar.
class _RelayStatsCard extends ConsumerStatefulWidget {
  final HollowTheme hollow;
  final RelayStats stats;
  const _RelayStatsCard({required this.hollow, required this.stats});

  @override
  ConsumerState<_RelayStatsCard> createState() => _RelayStatsCardState();
}

class _RelayStatsCardState extends ConsumerState<_RelayStatsCard> {
  /// Progress of the decorative poll-cycle sweep, 0..1.
  ///
  /// A [Timer] and a [ValueNotifier], never an [AnimationController]: one
  /// restarted as often as its own duration never stops its Ticker, and a
  /// running Ticker asks the engine for a frame at every vsync for as long as
  /// Home is open (feedback_ticker_is_a_frame_request). It advances one step
  /// per second, which also reads as the countdown to the next poll that it is.
  final ValueNotifier<double> _sweep = ValueNotifier<double>(0);
  final Stopwatch _since = Stopwatch();
  Timer? _timer;
  int _lastFetchCount = 0;

  /// Matched to the 7s stats poll in `relay_stats_provider.dart`. Keep the two
  /// in step if either moves.
  static const _sweepStep = Duration(seconds: 1);
  static const _sweepSteps = 7;

  @override
  void initState() {
    super.initState();
    _restartSweep();
  }

  void _restartSweep() {
    _timer?.cancel();
    // Reduce motion holds it full rather than sweeping.
    if (ReduceMotionController.instance.isReduced) {
      _sweep.value = 1.0;
      return;
    }
    _sweep.value = 0;
    _since
      ..reset()
      ..start();
    _timer = Timer.periodic(_sweepStep, (t) {
      final step = (_since.elapsedMilliseconds / _sweepStep.inMilliseconds)
          .floor()
          .clamp(0, _sweepSteps);
      _sweep.value = step / _sweepSteps;
      // Stop asking for frames until the next fetch restarts the sweep.
      if (step >= _sweepSteps) {
        t.cancel();
        _timer = null;
        _since.stop();
      }
    });
  }

  @override
  void didUpdateWidget(_RelayStatsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.stats.fetchCount != _lastFetchCount) {
      _lastFetchCount = widget.stats.fetchCount;
      _restartSweep();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;
    final stats = widget.stats;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.sm + 2),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatBar(
            hollow: hollow,
            icon: LucideIcons.memoryStick,
            label: 'RAM',
            value: stats.memLabel,
            progress: stats.memUsagePercent,
          ),
          const SizedBox(height: HollowSpacing.sm),
          StatBar(
            hollow: hollow,
            icon: LucideIcons.activity,
            label: 'Bandwidth',
            value: stats.bandwidthLabel,
            progress: stats.bandwidthUsagePercent,
          ),
          const SizedBox(height: HollowSpacing.sm),
          RepaintBoundary(
            child: ValueListenableBuilder<double>(
            valueListenable: _sweep,
            builder: (context, sweep, _) => SizedBox(
              height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: sweep,
                  backgroundColor: hollow.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    hollow.accent.withValues(alpha: 0.4),
                  ),
                ),
              ),
            ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Row for a friend whose session is still being established.
class _ConnectionRow extends StatelessWidget {
  final HollowTheme hollow;
  final String peerId;
  final String name;
  final String status;
  final Color statusColor;
  final bool showSpinner;

  const _ConnectionRow({
    required this.hollow,
    required this.peerId,
    required this.name,
    required this.status,
    required this.statusColor,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: hollow.border),
        ),
        child: Row(
          children: [
            HollowAvatar(peerId: peerId, size: 20),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Text(
                name,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 11,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (showSpinner) ...[
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: statusColor,
                ),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              status,
              style: HollowTypography.caption.copyWith(
                color: statusColor,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact counter row, e.g. "Encrypted 3".
class _CounterRow extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String label;
  final int count;
  final Color color;

  const _CounterRow({
    required this.hollow,
    required this.icon,
    required this.label,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: color,
              fontSize: 11,
            ),
          ),
          const Spacer(),
          Text(
            '$count',
            style: HollowTypography.body.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

