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
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons/lucide_icons.dart';

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
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => MobileChatRoute(peerId: peerId),
      ),
    );
  }

  void _openChannelChat(String serverId, ChannelInfo channel) {
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
    final unread = ref.watch(unreadProvider);
    final hiddenDms = ref.watch(hiddenArchiveDmsProvider);
    final profiles = ref.watch(profileProvider);

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
      final serverUnread = unread.serverUnreadCount(server.serverId);
      items.add(_ConversationItem(
        type: _ItemType.server,
        id: server.serverId,
        name: server.name,
        unreadCount: serverUnread,
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

    Widget content;
    if (items.isEmpty) {
      content = Center(
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
      );
    } else {
      content = ListView.builder(
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
            onChannelTap: (channel) => _openChannelChat(item.id, channel),
          );
        }
      },
    );
    }

    return Stack(
      children: [
        content,
        Positioned(
          right: HollowSpacing.lg,
          bottom: HollowSpacing.lg,
          child: _ChatsFab(onAction: () => _showNewDialog(context)),
        ),
      ],
    );
  }

  void _showNewDialog(BuildContext context) {
    showHollowDialog(
      context: context,
      builder: (_) => const _NewConversationDialog(),
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
    final hasUnread =
        !isDmMuted && ref.watch(unreadProvider.select((s) => s.isDmUnread(peerId)));

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
          // Timestamp + unread dot
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (lastMessage != null)
                Text(
                  formatTime(lastMessage!.timestamp),
                  style: HollowTypography.caption.copyWith(
                    color: hasUnread ? hollow.accent : hollow.textSecondary,
                  ),
                ),
              if (hasUnread) ...[
                const SizedBox(height: 4),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: hollow.accent,
                    shape: BoxShape.circle,
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
  final void Function(ChannelInfo) onChannelTap;

  const _ServerRow({
    required this.serverId,
    required this.name,
    required this.unreadCount,
    required this.memberCount,
    required this.isExpanded,
    required this.onTap,
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
                    color: hollow.accent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    unreadCount > 99 ? '99+' : '$unreadCount',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textOnAccent,
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
    final unread = ref.watch(unreadProvider);
    final voiceState = ref.watch(voiceChannelProvider);

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
        for (final channel in channels)
          _ChannelRow(
            channel: channel,
            serverId: widget.serverId,
            hasUnread: unread.isChannelUnread(widget.serverId, channel.channelId),
            voiceParticipants: channel.channelType == ChannelType.voice
                ? (voiceState.participants[widget.serverId]
                        ?[channel.channelId]
                        ?.length ??
                    0)
                : 0,
            onTap: () => widget.onChannelTap(channel),
          ),
        const SizedBox(height: HollowSpacing.xs),
      ],
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final ChannelInfo channel;
  final String serverId;
  final bool hasUnread;
  final int voiceParticipants;
  final VoidCallback onTap;

  const _ChannelRow({
    required this.channel,
    required this.serverId,
    required this.hasUnread,
    required this.voiceParticipants,
    required this.onTap,
  });

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
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(left: HollowSpacing.sm),
              decoration: BoxDecoration(
                color: hollow.accent,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Floating action button
// ─────────────────────────────────────────────────

class _ChatsFab extends StatelessWidget {
  final VoidCallback onAction;

  const _ChatsFab({required this.onAction});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      onTap: onAction,
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: hollow.accent,
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          boxShadow: [
            BoxShadow(
              color: hollow.accent.withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(LucideIcons.plus, size: 24, color: hollow.textOnAccent),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// New conversation dialog (Create/Join Server, Add Friend)
// ─────────────────────────────────────────────────

class _NewConversationDialog extends ConsumerStatefulWidget {
  const _NewConversationDialog();

  @override
  ConsumerState<_NewConversationDialog> createState() =>
      _NewConversationDialogState();
}

class _NewConversationDialogState
    extends ConsumerState<_NewConversationDialog> {
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
