import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Home dashboard — shown when no server or DM is selected in dock mode.
/// Three-column layout: Profile | Recent Conversations | Stats overview.
class HomeDashboard extends ConsumerWidget {
  const HomeDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return Container(
      color: hollow.background,
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Left: Profile Card ──
            SizedBox(
              width: 240,
              child: _ProfileColumn(hollow: hollow),
            ),

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

            // ── Center: Recent Conversations ──
            Expanded(
              child: _RecentConversationsColumn(hollow: hollow),
            ),

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

            // ── Right: Network & Status ──
            SizedBox(
              width: 260,
              child: _NetworkColumn(hollow: hollow),
            ),
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
          HollowAvatar(peerId: localPeerId, size: 72)
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
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
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
                                  ),
                                  if (conv.lastMessage != null)
                                    Text(
                                      _formatTime(conv.timestamp),
                                      style: HollowTypography.caption
                                          .copyWith(
                                        color: hollow.textSecondary,
                                        fontSize: 10,
                                      ),
                                    ),
                                ],
                              ),
                              if (conv.lastMessage != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  conv.lastMessage!.text,
                                  style:
                                      HollowTypography.caption.copyWith(
                                    color: hollow.textSecondary,
                                    fontSize: 11,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ],
                          ),
                        ),

                        // Unread badge
                        if (conv.unreadCount > 0) ...[
                          const SizedBox(width: HollowSpacing.sm),
                          Container(
                            constraints:
                                const BoxConstraints(minWidth: 18),
                            height: 18,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 5),
                            decoration: BoxDecoration(
                              color: hollow.accent,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              conv.unreadCount > 99
                                  ? '99+'
                                  : '${conv.unreadCount}',
                              style: TextStyle(
                                color: hollow.textOnAccent,
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
    final servers = ref.watch(serverListProvider);
    final profiles = ref.watch(profileProvider);

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

    // Server sync statuses.
    final serverEntries = servers.values.toList();

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

        const SizedBox(height: HollowSpacing.sm),

        // Relay status
        _RelayStatusCard(hollow: hollow),

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

        // ── Server Sync ──
        _SectionLabel(hollow: hollow, label: 'SERVERS'),
        const SizedBox(height: HollowSpacing.sm),

        Expanded(
          child: serverEntries.isEmpty
              ? Text(
                  'No servers joined',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                )
              : ListView.builder(
                  itemCount: serverEntries.length,
                  padding: EdgeInsets.zero,
                  itemBuilder: (context, index) {
                    final server = serverEntries[index];
                    return _ServerSyncRow(
                      hollow: hollow,
                      serverId: server.serverId,
                      serverName: server.name,
                    );
                  },
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

/// Relay connection status card.
class _RelayStatusCard extends ConsumerWidget {
  final HollowTheme hollow;
  const _RelayStatusCard({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connStatus = ref.watch(connectionStatusProvider);
    final relayStatus = connStatus.relayStatus;

    final Color dotColor;
    final bool pulse;
    switch (relayStatus) {
      case RelayConnectionStatus.circuitReady:
        dotColor = hollow.success;
        pulse = false;
      case RelayConnectionStatus.connected:
      case RelayConnectionStatus.circuitRequested:
        dotColor = hollow.accent;
        pulse = true;
      case RelayConnectionStatus.connecting:
      case RelayConnectionStatus.reconnecting:
        dotColor = hollow.warning;
        pulse = true;
      case RelayConnectionStatus.disconnected:
        dotColor = hollow.textSecondary;
        pulse = false;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.sm + 2),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.radio, size: 14, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Relay',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                    fontSize: 12,
                  ),
                ),
                Text(
                  connStatus.relayLabel,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          StatusDot(color: dotColor, size: 8, pulse: pulse),
        ],
      ),
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

/// Per-server sync status row with server avatar + name + live status.
class _ServerSyncRow extends ConsumerWidget {
  final HollowTheme hollow;
  final String serverId;
  final String serverName;

  const _ServerSyncRow({
    required this.hollow,
    required this.serverId,
    required this.serverName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncStatus = ref.watch(serverSyncStatusProvider(serverId));
    final peers = ref.watch(peersProvider);
    final membersAsync = ref.watch(serverMembersProvider(serverId));
    final localPeerId = ref.watch(identityProvider).peerId;

    // Count online members for this server.
    final onlineCount = membersAsync.whenOrNull(
          data: (members) => members
              .where((m) =>
                  m.peerId != localPeerId &&
                  peers.containsKey(m.peerId))
              .length,
        ) ??
        0;

    final effectiveStatus = syncStatus == ServerSyncStatus.idle &&
            onlineCount == 0
        ? ServerSyncStatus.connecting
        : syncStatus;

    final Color statusColor;
    final String statusLabel;
    final bool showSpinner;

    switch (effectiveStatus) {
      case ServerSyncStatus.connecting:
        statusColor = hollow.textSecondary;
        // Check if we're actually trying to connect to members.
        final connStatus = ref.watch(connectionStatusProvider);
        final memberIds = membersAsync.whenOrNull(
              data: (members) => members
                  .where((m) => m.peerId != localPeerId)
                  .map((m) => m.peerId)
                  .toList(),
            ) ??
            [];
        final connectingCount = memberIds
            .where((id) {
              final cs = connStatus.peers[id];
              return cs != null &&
                  (cs.stage == PeerConnectionStage.connected ||
                   cs.stage == PeerConnectionStage.keyExchange);
            })
            .length;
        statusLabel = connectingCount > 0
            ? 'Connecting to $connectingCount member${connectingCount == 1 ? '' : 's'}...'
            : 'No members online';
        showSpinner = connectingCount > 0;
      case ServerSyncStatus.syncing:
        statusColor = hollow.accent;
        statusLabel = 'Syncing...';
        showSpinner = true;
      case ServerSyncStatus.synced:
      case ServerSyncStatus.idle:
        statusColor = hollow.success;
        statusLabel = 'Synced';
        showSpinner = false;
      case ServerSyncStatus.retrying:
        statusColor = hollow.warning;
        statusLabel = 'Retrying...';
        showSpinner = true;
      case ServerSyncStatus.failed:
        statusColor = hollow.error;
        statusLabel = 'Failed';
        showSpinner = false;
    }

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
            // Server avatar (colored square with initials)
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: _colorFromId(serverId),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                _initialsFromName(serverName),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Text(
                serverName,
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
            ] else ...[
              StatusDot(color: statusColor, size: 6),
              const SizedBox(width: 4),
            ],
            Text(
              statusLabel,
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

  Color _colorFromId(String id) {
    final hash = id.hashCode;
    final hue = (hash % 360).abs().toDouble();
    return HSLColor.fromAHSL(1.0, hue, 0.5, 0.45).toColor();
  }

  String _initialsFromName(String name) {
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    }
    return name.substring(0, name.length.clamp(0, 2)).toUpperCase();
  }
}
