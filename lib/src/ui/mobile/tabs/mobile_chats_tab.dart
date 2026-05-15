import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/hidden_archive_dm_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/ui/animations/ambient_background.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_server_settings_route.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/services.dart';

class MobileChatsTab extends ConsumerStatefulWidget {
  const MobileChatsTab({super.key});

  @override
  ConsumerState<MobileChatsTab> createState() => _MobileChatsTabState();
}

class _MobileChatsTabState extends ConsumerState<MobileChatsTab> {
  final _expandedServers = <String>{};

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day}';
  }

  void _openDmChat(String peerId) {
    ref.read(selectedPeerProvider.notifier).state = peerId;
    ref.read(selectedServerProvider.notifier).state = null;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => MobileChatRoute(peerId: peerId),
      ),
    );
  }

  void _showServerSheet(BuildContext context, String serverId, String serverName) {
    final hollow = HollowTheme.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusLg)),
      ),
      builder: (_) => SafeArea(
        child: _ServerContextSheet(
          serverId: serverId,
          serverName: serverName,
          onNavigateSettings: () {
            Navigator.pop(context);
            Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute(
                builder: (_) => MobileServerSettingsRoute(serverId: serverId),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openChannelChat(String serverId, ChannelInfo channel) {
    ref.read(selectedServerProvider.notifier).state = serverId;
    ref.read(selectedChannelProvider.notifier).state = channel.channelId;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => MobileChatRoute(
          serverId: serverId,
          channelId: channel.channelId,
          channelName: channel.name,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final friends = ref.watch(friendsProvider);
    final peers = ref.watch(peersProvider);
    final lastMessages = ref.watch(lastDmMessageProvider);
    final servers = ref.watch(serverListProvider);
    final hiddenDms = ref.watch(hiddenArchiveDmsProvider);
    final profiles = ref.watch(profileProvider);
    final unread = ref.watch(unreadProvider);

    // Build unified list items
    final items = <_ConversationItem>[];

    // DM conversations (accepted friends, not hidden)
    for (final friend in friends.values) {
      if (friend.status != 'accepted') continue;
      if (hiddenDms.contains(friend.peerId)) continue;
      final last = lastMessages[friend.peerId];
      items.add(_ConversationItem(
        type: _ItemType.dm,
        id: friend.peerId,
        name: displayNameFor(profiles, friend.peerId),
        lastMessage: last,
        unreadCount: unread.dmUnreadCount(friend.peerId),
        isOnline: peers.containsKey(friend.peerId),
        timestamp: last?.timestamp,
      ));
    }

    // Servers
    for (final server in servers.values) {
      items.add(_ConversationItem(
        type: _ItemType.server,
        id: server.serverId,
        name: server.name,
        unreadCount: unread.serverUnreadCount(server.serverId),
        isOnline: false,
        memberCount: server.memberCount,
      ));
    }

    // Sort: items with unread first, then by timestamp (DMs) or name (servers)
    items.sort((a, b) {
      final aHasUnread = a.unreadCount > 0 ? 0 : 1;
      final bHasUnread = b.unreadCount > 0 ? 0 : 1;
      if (aHasUnread != bHasUnread) return aHasUnread.compareTo(bHasUnread);

      // Both have or lack unreads — sort DMs by timestamp, servers by name
      final aTime = a.timestamp ?? DateTime(2000);
      final bTime = b.timestamp ?? DateTime(2000);
      if (aTime != bTime) return bTime.compareTo(aTime); // newest first
      return a.name.compareTo(b.name);
    });

    Widget body;
    if (items.isEmpty) {
      body = Expanded(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                LucideIcons.messageCircle,
                size: 48,
                color: hollow.textSecondary.withValues(alpha: 0.4),
              ),
              const SizedBox(height: HollowSpacing.lg),
              Text(
                'No conversations yet',
                style: HollowTypography.heading.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
              const SizedBox(height: HollowSpacing.sm),
              Text(
                'Add a friend or join a server to start chatting',
                style: HollowTypography.bodySmall,
              ),
            ],
          ),
        ),
      );
    } else {
      body = Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            if (item.type == _ItemType.dm) {
              return _DmRow(
                peerId: item.id,
                name: item.name,
                lastMessage: item.lastMessage,
                isOnline: item.isOnline,
                formatTime: _formatTime,
                onTap: () => _openDmChat(item.id),
              );
            } else {
              return _ServerRow(
                serverId: item.id,
                name: item.name,
                unreadCount: item.unreadCount,
                memberCount: item.memberCount,
                isExpanded: _expandedServers.contains(item.id),
                onTap: () {
                  setState(() {
                    if (_expandedServers.contains(item.id)) {
                      _expandedServers.remove(item.id);
                    } else {
                      _expandedServers.add(item.id);
                    }
                  });
                },
                onLongPress: () => _showServerSheet(context, item.id, item.name),
                onChannelTap: (channel) => _openChannelChat(item.id, channel),
              );
            }
          },
        ),
      );
    }

    return AmbientBackground(
      color1: hollow.accent,
      color2: hollow.accent,
      opacity: 0.12,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.md,
            ),
            child: Row(
              children: [
                Text(
                  'Hollow',
                  style: HollowTypography.heading.copyWith(
                    color: hollow.accent,
                    fontWeight: FontWeight.w700,
                    fontSize: 24,
                  ),
                ),
                const SizedBox(width: HollowSpacing.md),
                Expanded(child: _HeaderShimmerLine(hollow: hollow)),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}

class _HeaderShimmerLine extends StatelessWidget {
  final HollowTheme hollow;
  const _HeaderShimmerLine({required this.hollow});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: SharedTickers.instance.ambient,
        builder: (context, value, _) {
          // 45s cycle, we use a sub-range for a ~10s ping-pong sweep
          final sub = (value * 4.5) % 1.0;
          final pingPong = sub < 0.5 ? sub * 2.0 : 2.0 - sub * 2.0;
          final curved = Curves.easeInOut.transform(pingPong);
          final t = -0.2 + curved * 1.4;
          const glowWidth = 0.15;
          return Container(
            height: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  hollow.border,
                  hollow.accent.withValues(alpha: 0.5),
                  hollow.border,
                ],
                stops: [
                  (t - glowWidth).clamp(0.0, 1.0),
                  t.clamp(0.0, 1.0),
                  (t + glowWidth).clamp(0.0, 1.0),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: hollow.accent.withValues(alpha: 0.15),
                  blurRadius: 3,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

enum _ItemType { dm, server }

class _ConversationItem {
  final _ItemType type;
  final String id;
  final String name;
  final ChatMessage? lastMessage;
  final int unreadCount;
  final bool isOnline;
  final DateTime? timestamp;
  final int memberCount;

  const _ConversationItem({
    required this.type,
    required this.id,
    required this.name,
    this.lastMessage,
    this.unreadCount = 0,
    this.isOnline = false,
    this.timestamp,
    this.memberCount = 0,
  });
}

// ─────────────────────────────────────────────────
// DM conversation row
// ─────────────────────────────────────────────────

class _DmRow extends ConsumerWidget {
  final String peerId;
  final String name;
  final ChatMessage? lastMessage;
  final bool isOnline;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;

  const _DmRow({
    required this.peerId,
    required this.name,
    required this.lastMessage,
    required this.isOnline,
    required this.formatTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final isDmMuted = !ref.watch(
        notificationSettingsProvider.select((s) => s.isDmEnabled(peerId)));
    final dmUnreadCount = isDmMuted
        ? 0
        : ref.watch(unreadProvider.select((s) => s.dmUnreadCount(peerId)));
    final hasUnread = dmUnreadCount > 0;

    return HollowPressable(
      onTap: onTap,
      subtle: true,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          // Avatar + status dot
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              children: [
                HollowAvatar(peerId: peerId, size: 44),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    decoration: BoxDecoration(
                      color: hollow.background,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(1.5),
                    child: StatusDot(
                      color: isOnline ? hollow.success : hollow.textSecondary,
                      size: 10,
                      pulse: isOnline,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          // Name + last message
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: HollowTypography.body.copyWith(
                    fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                    color: hollow.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (lastMessage != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    lastMessage!.isMe
                        ? 'You: ${lastMessage!.text}'
                        : lastMessage!.text,
                    style: HollowTypography.bodySmall.copyWith(
                      color: hollow.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          // Timestamp + unread badge
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (lastMessage != null)
                Text(
                  formatTime(lastMessage!.timestamp),
                  style: HollowTypography.caption.copyWith(
                    color: hasUnread ? hollow.error : hollow.textSecondary,
                  ),
                ),
              if (hasUnread) ...[
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: hollow.error,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    dmUnreadCount > 99 ? '99+' : '$dmUnreadCount',
                    style: HollowTypography.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Server row with accordion channel expansion
// ─────────────────────────────────────────────────

class _ServerRow extends ConsumerWidget {
  final String serverId;
  final String name;
  final int unreadCount;
  final int memberCount;
  final bool isExpanded;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final void Function(ChannelInfo) onChannelTap;

  const _ServerRow({
    required this.serverId,
    required this.name,
    required this.unreadCount,
    required this.memberCount,
    required this.isExpanded,
    required this.onTap,
    required this.onLongPress,
    required this.onChannelTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final serverAvatar = ref.watch(serverAvatarProvider)[serverId];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Server header row
        HollowPressable(
          onTap: onTap,
          onLongPress: onLongPress,
          subtle: true,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.md,
          ),
          child: Row(
            children: [
              // Server icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                ),
                clipBehavior: Clip.antiAlias,
                child: serverAvatar != null
                    ? Image.memory(serverAvatar, fit: BoxFit.cover)
                    : Center(
                        child: Text(
                          name.isNotEmpty ? name[0].toUpperCase() : '?',
                          style: HollowTypography.heading.copyWith(
                            color: hollow.accent,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: HollowSpacing.md),
              // Server name + member count
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: HollowTypography.body.copyWith(
                        fontWeight:
                            unreadCount > 0 ? FontWeight.w600 : FontWeight.w400,
                        color: hollow.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$memberCount members',
                      style: HollowTypography.bodySmall.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              // Unread badge + expand chevron
              if (unreadCount > 0) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.error,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : '$unreadCount',
                    style: HollowTypography.caption.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
              ],
              AnimatedRotation(
                turns: isExpanded ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: Icon(
                  LucideIcons.chevronDown,
                  size: 18,
                  color: hollow.textSecondary,
                ),
              ),
            ],
          ),
        ),
        // Expanded channel list
        AnimatedCrossFade(
          firstChild: const SizedBox.shrink(),
          secondChild: _ChannelList(
            serverId: serverId,
            onChannelTap: onChannelTap,
          ),
          crossFadeState:
              isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Channel list inside expanded server (loads on demand)
// ─────────────────────────────────────────────────

class _ChannelList extends ConsumerStatefulWidget {
  final String serverId;
  final void Function(ChannelInfo) onChannelTap;

  const _ChannelList({
    required this.serverId,
    required this.onChannelTap,
  });

  @override
  ConsumerState<_ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends ConsumerState<_ChannelList> {
  List<ChannelInfo>? _channels;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    final channelMap =
        await ChannelListNotifier.fetchChannels(widget.serverId);
    if (!mounted) return;
    final list = channelMap.values.toList();
    list.sort((a, b) {
      final aType = a.channelType == ChannelType.voice ? 1 : 0;
      final bType = b.channelType == ChannelType.voice ? 1 : 0;
      if (aType != bType) return aType.compareTo(bType);
      return a.name.compareTo(b.name);
    });
    setState(() {
      _channels = list;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final voiceState = ref.watch(voiceChannelProvider);
    final unread = ref.watch(unreadProvider);

    // Re-fetch channels when server/channel state changes (CRDT sync, channel added/removed).
    ref.listen(serverListProvider.select((s) => s[widget.serverId]),
        (prev, next) {
      if (prev != next) _loadChannels();
    });
    ref.listen(channelListProvider, (prev, next) {
      if (prev != next) _loadChannels();
    });

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.only(
          left: 44 + HollowSpacing.lg + HollowSpacing.md,
          bottom: HollowSpacing.sm,
          top: HollowSpacing.xs,
        ),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: hollow.textSecondary,
          ),
        ),
      );
    }

    final channels = _channels ?? [];
    if (channels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(
          left: 44 + HollowSpacing.lg + HollowSpacing.md,
          bottom: HollowSpacing.sm,
        ),
        child: Text(
          'No channels',
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textSecondary,
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < channels.length; i++)
          _TreeChannelRow(
            channel: channels[i],
            serverId: widget.serverId,
            unreadCount: unread.channelUnreadCount(widget.serverId, channels[i].channelId),
            voiceParticipants: channels[i].channelType == ChannelType.voice
                ? (voiceState.participants[widget.serverId]
                        ?[channels[i].channelId]
                        ?.length ??
                    0)
                : 0,
            isLast: i == channels.length - 1,
            onTap: () => widget.onChannelTap(channels[i]),
          ),
        const SizedBox(height: HollowSpacing.xs),
      ],
    );
  }
}

class _TreeChannelRow extends StatelessWidget {
  final ChannelInfo channel;
  final String serverId;
  final int unreadCount;
  final int voiceParticipants;
  final bool isLast;
  final VoidCallback onTap;

  const _TreeChannelRow({
    required this.channel,
    required this.serverId,
    required this.unreadCount,
    required this.voiceParticipants,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final lineColor = hollow.textSecondary.withValues(alpha: 0.7);
    // Tree connector aligned under the server avatar center (44/2 + lg padding)
    const double treeLeft = HollowSpacing.lg + 22;

    return Stack(
      children: [
        // Tree lines
        Positioned(
          left: treeLeft,
          top: 0,
          bottom: isLast ? null : 0,
          child: SizedBox(
            width: 1,
            height: isLast ? null : double.infinity,
            child: ColoredBox(color: lineColor),
          ),
        ),
        // Branch connector
        Positioned(
          left: treeLeft,
          top: 18,
          child: SizedBox(
            width: 12,
            height: 1,
            child: ColoredBox(color: lineColor),
          ),
        ),
        // Vertical line segment for last item (only goes to the branch)
        if (isLast)
          Positioned(
            left: treeLeft,
            top: 0,
            child: SizedBox(
              width: 1,
              height: 19,
              child: ColoredBox(color: lineColor),
            ),
          ),
        // Actual channel row
        _ChannelRow(
          channel: channel,
          serverId: serverId,
          unreadCount: unreadCount,
          voiceParticipants: voiceParticipants,
          onTap: onTap,
        ),
      ],
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final ChannelInfo channel;
  final String serverId;
  final int unreadCount;
  final int voiceParticipants;
  final VoidCallback onTap;

  const _ChannelRow({
    required this.channel,
    required this.serverId,
    required this.unreadCount,
    required this.voiceParticipants,
    required this.onTap,
  });

  bool get hasUnread => unreadCount > 0;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final isVoice = channel.channelType == ChannelType.voice;

    return HollowPressable(
      onTap: onTap,
      subtle: true,
      padding: EdgeInsets.only(
        left: 44 + HollowSpacing.lg + HollowSpacing.md,
        right: HollowSpacing.lg,
        top: HollowSpacing.sm,
        bottom: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            isVoice ? LucideIcons.volume2 : LucideIcons.hash,
            size: 16,
            color: hasUnread ? hollow.textPrimary : hollow.textSecondary,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              channel.name,
              style: HollowTypography.body.copyWith(
                fontSize: 13,
                fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                color: hasUnread ? hollow.textPrimary : hollow.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isVoice && voiceParticipants > 0) ...[
            const SizedBox(width: HollowSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.xs,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: hollow.success.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.users, size: 10, color: hollow.success),
                  const SizedBox(width: 2),
                  Text(
                    '$voiceParticipants',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.success,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (hasUnread && !isVoice)
            Container(
              margin: const EdgeInsets.only(left: HollowSpacing.sm),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: hollow.error,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                unreadCount > 99 ? '99+' : '$unreadCount',
                style: HollowTypography.caption.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// New conversation dialog (Create/Join Server, Add Friend)
// ─────────────────────────────────────────────────

void showNewConversationDialog(BuildContext context) {
  showHollowDialog(
    context: context,
    builder: (_) => const NewConversationDialog(),
  );
}

class NewConversationDialog extends ConsumerStatefulWidget {
  const NewConversationDialog({super.key});

  @override
  ConsumerState<NewConversationDialog> createState() =>
      _NewConversationDialogState();
}

class _NewConversationDialogState
    extends ConsumerState<NewConversationDialog> {
  final _joinController = TextEditingController();
  final _createController = TextEditingController();
  final _friendController = TextEditingController();

  @override
  void dispose() {
    _joinController.dispose();
    _createController.dispose();
    _friendController.dispose();
    super.dispose();
  }

  void _handleJoin() {
    final input = _joinController.text.trim();
    if (input.isEmpty) return;

    String serverId;
    final uri = Uri.tryParse(input);
    if (uri != null &&
        uri.scheme == 'hollow' &&
        uri.queryParameters.containsKey('server')) {
      serverId = uri.queryParameters['server']!;
    } else {
      serverId = input;
    }

    Navigator.of(context).pop();
    crdt_api.joinServer(serverId: serverId);
    HollowToast.show(context, 'Joining server...',
        type: HollowToastType.info);
  }

  Future<void> _handleCreate() async {
    final name = _createController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop();
    await crdt_api.createServer(name: name);
    if (mounted) {
      HollowToast.show(context, 'Server created',
          type: HollowToastType.success);
    }
  }

  Future<void> _handleAddFriend() async {
    final peerId = _friendController.text.trim();
    if (peerId.isEmpty) return;
    Navigator.of(context).pop();
    try {
      await ref.read(friendsProvider.notifier).sendRequest(peerId);
      if (mounted) {
        HollowToast.show(context, 'Friend request sent',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to send request',
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 400),
            padding: const EdgeInsets.all(HollowSpacing.xl),
            decoration: BoxDecoration(
              color: hollow.elevated.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(hollow.radiusLg),
              border: Border.all(
                color: hollow.accent.withValues(alpha: 0.15),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                ),
              ],
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'New',
                          style: HollowTypography.heading
                              .copyWith(color: hollow.textPrimary),
                        ),
                      ),
                      HollowPressable(
                        onTap: () => Navigator.of(context).pop(),
                        borderRadius:
                            BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(LucideIcons.x,
                            size: 18, color: hollow.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.xl),

                  // Join Server
                  _SectionLabel(
                    icon: LucideIcons.logIn,
                    label: 'Join a Server',
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  _InputRow(
                    controller: _joinController,
                    hint: 'Invite link or server ID',
                    mono: true,
                    buttonLabel: 'Join',
                    onSubmit: _handleJoin,
                  ),

                  const SizedBox(height: HollowSpacing.xl),

                  // Create Server
                  _SectionLabel(
                    icon: LucideIcons.plusCircle,
                    label: 'Create a Server',
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  _InputRow(
                    controller: _createController,
                    hint: 'Server name',
                    mono: false,
                    buttonLabel: 'Create',
                    onSubmit: _handleCreate,
                  ),

                  const SizedBox(height: HollowSpacing.xl),

                  // Add Friend
                  _SectionLabel(
                    icon: LucideIcons.userPlus,
                    label: 'Add a Friend',
                  ),
                  const SizedBox(height: HollowSpacing.sm),
                  _InputRow(
                    controller: _friendController,
                    hint: 'Paste peer ID',
                    mono: true,
                    buttonLabel: 'Send',
                    onSubmit: _handleAddFriend,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SectionLabel({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Icon(icon, size: 16, color: hollow.accent),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          label,
          style: HollowTypography.label.copyWith(color: hollow.textPrimary),
        ),
      ],
    );
  }
}

class _InputRow extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool mono;
  final String buttonLabel;
  final VoidCallback onSubmit;

  const _InputRow({
    required this.controller,
    required this.hint,
    required this.mono,
    required this.buttonLabel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final textStyle = mono
        ? HollowTypography.mono
            .copyWith(color: hollow.textPrimary, fontSize: 12)
        : HollowTypography.body.copyWith(color: hollow.textPrimary);
    final hintStyle = mono
        ? HollowTypography.mono
            .copyWith(color: hollow.textSecondary, fontSize: 12)
        : HollowTypography.body.copyWith(color: hollow.textSecondary);

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: textStyle,
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: hintStyle,
              filled: true,
              fillColor: hollow.surface,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
                vertical: HollowSpacing.md,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                borderSide: BorderSide(color: hollow.accent),
              ),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.filled(
          onPressed: onSubmit,
          compact: true,
          child: Text(buttonLabel),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Server long-press context sheet
// ─────────────────────────────────────────────────

class _ServerContextSheet extends ConsumerWidget {
  final String serverId;
  final String serverName;
  final VoidCallback onNavigateSettings;

  const _ServerContextSheet({
    required this.serverId,
    required this.serverName,
    required this.onNavigateSettings,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final role = ref.watch(myRoleProvider(serverId)).valueOrNull ?? 'member';
    final isOwner = role == 'owner';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: hollow.textSecondary.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          // Server name header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            child: Text(
              serverName,
              style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          // Actions
          _SheetAction(
            icon: LucideIcons.settings,
            label: 'Server Settings',
            onTap: onNavigateSettings,
          ),
          _SheetAction(
            icon: LucideIcons.userPlus,
            label: 'Invite',
            onTap: () {
              Navigator.pop(context);
              final link = 'hollow://join?server=$serverId';
              showInviteDialog(context, link, serverId);
            },
          ),
          _SheetAction(
            icon: LucideIcons.copy,
            label: 'Copy Server ID',
            onTap: () {
              Clipboard.setData(ClipboardData(text: serverId));
              Navigator.pop(context);
              HollowToast.show(context, 'Server ID copied',
                  type: HollowToastType.success);
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
          Divider(color: hollow.border, height: 1, indent: HollowSpacing.lg, endIndent: HollowSpacing.lg),
          const SizedBox(height: HollowSpacing.sm),
          _SheetAction(
            icon: isOwner ? LucideIcons.trash2 : LucideIcons.logOut,
            label: isOwner ? 'Delete Server' : 'Leave Server',
            danger: true,
            onTap: () {
              Navigator.pop(context);
              _confirmLeaveOrDelete(context, ref, serverId, serverName, isOwner);
            },
          ),
        ],
      ),
    );
  }

  static void _confirmLeaveOrDelete(
    BuildContext context,
    WidgetRef ref,
    String serverId,
    String serverName,
    bool isOwner,
  ) {
    showHollowDialog(
      context: context,
      builder: (_) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx) {
              final hollow = HollowTheme.of(ctx);
              return Container(
                constraints: const BoxConstraints(maxWidth: 360),
                padding: const EdgeInsets.all(HollowSpacing.xl),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(color: hollow.border),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isOwner ? 'Delete Server' : 'Leave Server',
                      style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Text(
                      isOwner
                          ? 'Are you sure you want to delete "$serverName"? This cannot be undone.'
                          : 'Are you sure you want to leave "$serverName"?',
                      textAlign: TextAlign.center,
                      style: HollowTypography.body.copyWith(color: hollow.textSecondary),
                    ),
                    const SizedBox(height: HollowSpacing.xl),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.danger(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              if (isOwner) {
                                await crdt_api.deleteServer(serverId: serverId);
                              } else {
                                await crdt_api.leaveServer(serverId: serverId);
                              }
                              ref.read(selectedServerProvider.notifier).state = null;
                              ref.read(selectedChannelProvider.notifier).state = null;
                              ref.read(channelListProvider.notifier).clear();
                              if (context.mounted) {
                                HollowToast.show(
                                  context,
                                  isOwner ? 'Server deleted' : 'Left server',
                                  type: HollowToastType.success,
                                );
                              }
                            },
                            child: Text(isOwner ? 'Delete' : 'Leave'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = danger ? hollow.error : hollow.textPrimary;
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: HollowSpacing.md),
          Text(
            label,
            style: HollowTypography.body.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
