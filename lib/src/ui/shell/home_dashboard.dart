import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:url_launcher/url_launcher.dart';

/// Home dashboard — shown when no server or DM is selected in dock mode.
/// Three-column layout: Profile | Recent Conversations | Stats overview.
class HomeDashboard extends ConsumerWidget {
  const HomeDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    // Staggered reveal animations for each column.
    final leftReveal =
        StartupRevealScope.interval(context, 0.30, 0.55);
    final centerReveal =
        StartupRevealScope.interval(context, 0.35, 0.60);
    final rightReveal =
        StartupRevealScope.interval(context, 0.40, 0.65);

    Widget leftCol = SizedBox(
      width: 240,
      child: _ProfileColumn(hollow: hollow),
    );
    Widget centerCol = Expanded(
      child: _RecentConversationsColumn(hollow: hollow),
    );
    Widget rightCol = SizedBox(
      width: 260,
      child: _NetworkColumn(hollow: hollow),
    );

    // Apply fade + slide-up reveal to each column.
    if (leftReveal != null) {
      leftCol = SizedBox(
        width: 240,
        child: FadeTransition(
          opacity: leftReveal,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(leftReveal),
            child: _ProfileColumn(hollow: hollow),
          ),
        ),
      );
    }
    if (centerReveal != null) {
      centerCol = Expanded(
        child: FadeTransition(
          opacity: centerReveal,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(centerReveal),
            child: _RecentConversationsColumn(hollow: hollow),
          ),
        ),
      );
    }
    if (rightReveal != null) {
      rightCol = SizedBox(
        width: 260,
        child: FadeTransition(
          opacity: rightReveal,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(rightReveal),
            child: _NetworkColumn(hollow: hollow),
          ),
        ),
      );
    }

    return Container(
      color: hollow.background,
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            leftCol,

            // Divider
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg,
              ),
              child: Container(
                width: 1,
                height: double.infinity,
                color: hollow.border,
              ),
            ),

            centerCol,

            // Divider
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg,
              ),
              child: Container(
                width: 1,
                height: double.infinity,
                color: hollow.border,
              ),
            ),

            rightCol,
          ],
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
    final nodeState = ref.watch(nodeProvider);
    final profiles = ref.watch(profileProvider);
    final localPeerId = identity.peerId;

    final displayName = localPeerId != null
        ? displayNameFor(profiles, localPeerId)
        : 'Loading...';
    final profile = localPeerId != null ? profiles[localPeerId] : null;
    final statusText = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    final isOnline = nodeState.status == NodeStatus.connected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: HollowSpacing.lg),

        // Avatar
        if (localPeerId != null)
          HollowAvatar(peerId: localPeerId, size: 72, imageBytes: profiles[localPeerId]?.avatarBytes, animate: true)
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

        // Name
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

        // Online status
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(
              color: isOnline ? hollow.success : hollow.textSecondary,
              size: 8,
              pulse: isOnline,
            ),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              isOnline ? 'Online' : 'Offline',
              style: HollowTypography.caption.copyWith(
                color: isOnline ? hollow.success : hollow.textSecondary,
              ),
            ),
          ],
        ),

        // Twitch badge
        FutureBuilder<String?>(
          future: twitch_api.twitchGetUsername(),
          builder: (context, snap) {
            final username = snap.data;
            if (username == null || username.isEmpty) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: GestureDetector(
                onTap: () => launchUrl(
                  Uri.parse('https://twitch.tv/$username'),
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
                      Icon(SimpleIcons.twitch,
                          size: 11, color: const Color(0xFF9146FF)),
                      const SizedBox(width: 4),
                      Text(
                        username,
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
            );
          },
        ),

        // Custom status
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

        // Divider + About Me
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

        // Recovery phrase status
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm + 2,
            vertical: HollowSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.border),
          ),
          child: identity.mnemonic != null
              ? HollowPressable(
                  onTap: () => showMnemonicDialog(
                      context, identity.mnemonic!),
                  borderRadius:
                      BorderRadius.circular(hollow.radiusSm),
                  child: Row(
                    children: [
                      Icon(LucideIcons.shieldAlert, size: 14,
                          color: hollow.warning),
                      const SizedBox(width: HollowSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Recovery Phrase',
                              style:
                                  HollowTypography.caption.copyWith(
                                color: hollow.textPrimary,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              'Not backed up — tap to view',
                              style:
                                  HollowTypography.caption.copyWith(
                                color: hollow.warning,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                )
              : Row(
                  children: [
                    Icon(LucideIcons.shieldCheck, size: 14,
                        color: hollow.success),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Recovery Phrase',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            'Secured',
                            style: HollowTypography.caption.copyWith(
                              color: hollow.success,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),

        const Spacer(),

        // Peer ID (copyable, centered, bottom)
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

/// Center column — recent DM conversations.
class _RecentConversationsColumn extends ConsumerWidget {
  final HollowTheme hollow;
  const _RecentConversationsColumn({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(friendsProvider);
    final chatHistory = ref.watch(chatProvider);
    final profiles = ref.watch(profileProvider);
    final peers = ref.watch(peersProvider);
    final unreadState = ref.watch(unreadProvider);

    // Build list of friends with their last message, sorted by recency.
    final accepted = friends.values
        .where((f) => f.status == 'accepted')
        .toList();

    final conversations = <_ConversationInfo>[];
    for (final friend in accepted) {
      final msgs = chatHistory[friend.peerId];
      final lastMsg = msgs != null && msgs.isNotEmpty ? msgs.last : null;
      final timestamp = lastMsg?.timestamp ?? DateTime(2000);
      conversations.add(_ConversationInfo(
        peerId: friend.peerId,
        lastMessage: lastMsg,
        timestamp: timestamp,
        isOnline: peers.containsKey(friend.peerId),
        unreadCount: unreadState.dmUnreadCounts[friend.peerId] ?? 0,
      ));
    }

    // Sort by most recent first.
    conversations.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
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
              Text(
                'Recent Conversations',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
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
                final name = displayNameFor(profiles, conv.peerId);

                return Padding(
                  padding: const EdgeInsets.only(
                    bottom: HollowSpacing.xs,
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
                        // Avatar with status
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            HollowAvatar(
                                peerId: conv.peerId, size: 36, imageBytes: profiles[conv.peerId]?.avatarBytes),
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
                                  pulse: conv.isOnline,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: HollowSpacing.sm),

                        // Name + last message
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

                        // Time + unread badge (vertically centered)
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

/// Right column — stats overview.
/// Right column — live network & connection status.
class _NetworkColumn extends ConsumerWidget {
  final HollowTheme hollow;
  const _NetworkColumn({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nodeState = ref.watch(nodeProvider);
    final peers = ref.watch(peersProvider);
    final friends = ref.watch(friendsProvider);
    final profiles = ref.watch(profileProvider);
    final relayStats = ref.watch(relayStatsProvider);

    final isOnline = nodeState.status == NodeStatus.connected;

    // Friends connection status (granular via connectionStatusProvider).
    final connStatus = ref.watch(connectionStatusProvider);
    final accepted = friends.values
        .where((f) => f.status == 'accepted')
        .toList();
    final encryptedFriends = <String>[];
    final activeFriends = <PeerConnectionStatus>[];
    final offlineFriends = <String>[];
    for (final f in accepted) {
      final peer = peers[f.peerId];
      final cs = connStatus.peers[f.peerId];
      if (peer != null && peer.isEncrypted) {
        encryptedFriends.add(f.peerId);
      } else if (cs != null &&
          (cs.stage == PeerConnectionStage.connected ||
           cs.stage == PeerConnectionStage.keyExchange)) {
        activeFriends.add(cs);
      } else if (peer != null && !peer.isEncrypted) {
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
        // Header
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

        // Node status
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
                color: isOnline ? hollow.success : hollow.warning,
                size: 8,
                pulse: isOnline,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isOnline ? 'Connected' : _nodeLabel(nodeState.status),
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      '${peers.length} peer${peers.length == 1 ? '' : 's'} reachable',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: HollowSpacing.lg),

        // ── Friends Connections ──
        _SectionLabel(hollow: hollow, label: 'FRIENDS'),
        const SizedBox(height: HollowSpacing.sm),

        // Active connections — per-peer detail rows
        for (final cs in activeFriends)
          _ConnectionRow(
            hollow: hollow,
            peerId: cs.peerId,
            name: displayNameFor(profiles, cs.peerId),
            avatarBytes: profiles[cs.peerId]?.avatarBytes,
            status: cs.label,
            statusColor: cs.stage == PeerConnectionStage.failed
                ? hollow.error
                : hollow.accent,
            showSpinner: cs.stage != PeerConnectionStage.failed &&
                cs.stage != PeerConnectionStage.encrypted,
          ),

        // Summary counters
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

        // ── Relay Server ──
        _SectionLabel(hollow: hollow, label: 'RELAY SERVER'),
        const SizedBox(height: HollowSpacing.sm),

        _RelayStatsCard(hollow: hollow, stats: relayStats),

        const SizedBox(height: HollowSpacing.lg),

        Expanded(child: _NewsPanel(hollow: hollow)),

        const SizedBox(height: HollowSpacing.sm),

        // ── Online Users (bottom) ──
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
                child: _ShimmerDivider(hollow: hollow),
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

  String _nodeLabel(NodeStatus status) {
    return switch (status) {
      NodeStatus.connected => 'Connected',
      NodeStatus.starting => 'Starting...',
      NodeStatus.loading => 'Loading...',
      NodeStatus.error => 'Error',
    };
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

/// News panel — fetches developer posts from news.json, shows version + updates.
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
                      GestureDetector(
                        onTap: () => showUserSettingsDialog(
                          context,
                          ref,
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
                    ],
                    const Spacer(),
                    GestureDetector(
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
                            'Failed to fetch news — check your connection',
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

/// Relay server stats card — RAM + bandwidth progress bars + synced poll bar.
class _RelayStatsCard extends StatefulWidget {
  final HollowTheme hollow;
  final RelayStats stats;
  const _RelayStatsCard({required this.hollow, required this.stats});

  @override
  State<_RelayStatsCard> createState() => _RelayStatsCardState();
}

class _RelayStatsCardState extends State<_RelayStatsCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _lastFetchCount = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 7),
    )..forward();
  }

  @override
  void didUpdateWidget(_RelayStatsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset animation when a new fetch completes.
    if (widget.stats.fetchCount != _lastFetchCount) {
      _lastFetchCount = widget.stats.fetchCount;
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
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
          // RAM usage
          _StatBar(
            hollow: hollow,
            icon: LucideIcons.memoryStick,
            label: 'RAM',
            value: stats.memLabel,
            progress: stats.memUsagePercent,
          ),
          const SizedBox(height: HollowSpacing.sm),
          // Bandwidth usage
          _StatBar(
            hollow: hollow,
            icon: LucideIcons.activity,
            label: 'Bandwidth',
            value: stats.bandwidthLabel,
            progress: stats.bandwidthUsagePercent,
          ),
          const SizedBox(height: HollowSpacing.sm),
          // Poll cycle bar — synced to 5s fetch interval
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => SizedBox(
              height: 3,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: _controller.value,
                  backgroundColor: hollow.border,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    hollow.accent.withValues(alpha: 0.4),
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

/// Single stat row with label + animated progress bar + value.
class _StatBar extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String label;
  final String value;
  final double progress;

  const _StatBar({
    required this.hollow,
    required this.icon,
    required this.label,
    required this.value,
    required this.progress,
  });

  @override
  Widget build(BuildContext context) {
    // Color shifts from accent → warning → error as usage increases.
    final Color barColor;
    if (progress < 0.6) {
      barColor = hollow.accent;
    } else if (progress < 0.85) {
      barColor = hollow.warning;
    } else {
      barColor = hollow.error;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 12, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              label,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: HollowTypography.caption.copyWith(
                color: hollow.textPrimary,
                fontSize: 10,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 4,
            width: double.infinity,
            child: Stack(
              children: [
                Container(color: hollow.border),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
                  duration: HollowDurations.slow,
                  curve: Curves.easeOutCubic,
                  builder: (context, value, _) => FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: value,
                    child: Container(
                      decoration: BoxDecoration(
                        color: barColor,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 1px divider with a looping teal shimmer sweep (ASOT style).
/// Uses [SharedTickers.shimmer] instead of its own AnimationController.
class _ShimmerDivider extends StatelessWidget {
  final HollowTheme hollow;
  const _ShimmerDivider({required this.hollow});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SharedTickers.instance.shimmer,
      builder: (context, value, _) {
        final pos = value * 4.0 - 1.5;
        return Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(pos - 0.5, 0),
              end: Alignment(pos + 0.5, 0),
              colors: [
                hollow.border,
                hollow.accent.withValues(alpha: 0.6),
                hollow.border,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Row showing a friend currently in-progress (encrypting).
class _ConnectionRow extends StatelessWidget {
  final HollowTheme hollow;
  final String peerId;
  final String name;
  final String status;
  final Color statusColor;
  final bool showSpinner;
  final Uint8List? avatarBytes;

  const _ConnectionRow({
    required this.hollow,
    required this.peerId,
    required this.name,
    required this.status,
    required this.statusColor,
    this.showSpinner = false,
    this.avatarBytes,
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
            HollowAvatar(peerId: peerId, size: 20, imageBytes: avatarBytes),
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

/// Compact counter row (e.g., "✓ Encrypted  3").
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

