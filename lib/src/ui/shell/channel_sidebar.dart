import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/peer_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/reveal_widgets.dart';
import 'package:hollow/src/ui/animations/selection_shimmer.dart';
import 'package:hollow/src/ui/dialogs/storage_dashboard_dialog.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';
import 'package:hollow/src/ui/shell/voice_channel_panel.dart';
import 'package:hollow/src/ui/sidebar/peer_card.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Channel / DM sidebar (240px). Supports two modes:
///
/// **Home mode** (`selectedServer == null`): room controls + peer list.
/// **Server mode** (`selectedServer != null`): server name header + channel list.
class ChannelSidebar extends StatelessWidget {
  // -- Home mode props --
  final Map<String, PeerInfo> peers;
  final Map<String, ChatMessage> lastMessages;
  final String? selectedPeerId;
  final NodeStatus nodeStatus;
  final ValueChanged<String> onPeerSelected;
  final ChatMessage? Function(String) lastMessage;
  final String Function(DateTime) formatTime;

  // -- Server mode props --
  final ServerInfo? selectedServer;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final VoidCallback onOpenSettings;
  final bool canManageChannels;
  final String channelLayoutJson;

  /// Fixed width for desktop/tablet. Pass null on mobile to fill available space.
  final double? width;

  /// When true, sidebar hides entirely when no server selected (Dock layout).
  final bool dockMode;

  /// Whether to show the UserBar at the bottom. False in Dock layout.
  final bool showUserBar;

  const ChannelSidebar({
    super.key,
    required this.peers,
    required this.lastMessages,
    required this.selectedPeerId,
    required this.nodeStatus,
    required this.onPeerSelected,
    required this.lastMessage,
    required this.formatTime,
    this.selectedServer,
    this.channels = const {},
    this.selectedChannelId,
    this.onChannelSelected = _noop,
    this.onCreateChannel = _noopVoid,
    this.onOpenSettings = _noopVoid,
    this.canManageChannels = false,
    this.channelLayoutJson = '[]',
    this.width = 240,
    this.dockMode = false,
    this.showUserBar = true,
  });

  static void _noop(String _) {}
  static void _noopVoid() {}

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // In dock mode, hide sidebar entirely when no server is selected.
    if (dockMode && selectedServer == null) {
      return const SizedBox.shrink();
    }

    final sidebarReveal =
        StartupRevealScope.interval(context, 0.12, 0.30);
    final userBarReveal =
        StartupRevealScope.interval(context, 0.50, 0.60);

    Widget? userBar;
    if (showUserBar) {
      userBar = const UserBar();
      if (userBarReveal != null) {
        userBar = FadeTransition(
          opacity: userBarReveal,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.5),
              end: Offset.zero,
            ).animate(userBarReveal),
            child: userBar,
          ),
        );
      }
    }

    Widget sidebar = Container(
      width: width,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          right: BorderSide(color: hollow.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — crossfade between server name and "Direct Messages"
          AnimatedSwitcher(
            duration: HollowDurations.fast,
            child: _buildHeader(context, hollow),
          ),

          // Content — crossfade between server channels and home/DM view
          Expanded(
            child: AnimatedSwitcher(
              duration: HollowDurations.normal,
              switchInCurve: HollowCurves.enter,
              switchOutCurve: HollowCurves.exit,
              child: selectedServer != null
                  ? _ServerContent(
                      key: ValueKey('server-${selectedServer!.serverId}'),
                      hollow: hollow,
                      serverId: selectedServer!.serverId,
                      channels: channels,
                      selectedChannelId: selectedChannelId,
                      onChannelSelected: onChannelSelected,
                      onCreateChannel: onCreateChannel,
                      canManageChannels: canManageChannels,
                      channelLayoutJson: channelLayoutJson,
                    )
                  : _HomeContent(
                      key: const ValueKey('home'),
                      hollow: hollow,
                      peers: peers,
                      selectedPeerId: selectedPeerId,
                      nodeStatus: nodeStatus,
                      onPeerSelected: onPeerSelected,
                      lastMessage: lastMessage,
                      formatTime: formatTime,
                    ),
            ),
          ),

          // Voice channel controls (visible when in a voice channel)
          const VoiceChannelPanel(),

          // User bar at bottom (hidden in dock mode)
          ?userBar,
        ],
      ),
    );

    return RevealClip(
      animation: sidebarReveal,
      axis: Axis.horizontal,
      alignment: Alignment.centerLeft,
      child: sidebar,
    );
  }

  Widget _buildHeader(BuildContext context, HollowTheme hollow) {
    final label = selectedServer?.name ?? 'Direct Messages';
    final headerTextReveal =
        StartupRevealScope.interval(context, 0.25, 0.40);

    return Container(
      key: ValueKey('header-$label'),
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: hollow.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TypewriterText(
              text: label,
              animation: headerTextReveal,
              style: HollowTypography.subheading.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (selectedServer != null) ...[
            HollowTooltip(
              message: 'Invite people',
              child: HollowPressable(
                onTap: () {
                  final link =
                      'hollow://join?server=${selectedServer!.serverId}';
                  showInviteDialog(
                      context, link, selectedServer!.serverId);
                },
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.userPlus,
                  size: 16,
                  color: hollow.textSecondary,
                ),
              ),
            ),
            HollowTooltip(
              message: 'Storage',
              child: HollowPressable(
                onTap: () => showStorageDashboardDialog(
                    context, selectedServer!.serverId),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.hardDrive,
                  size: 16,
                  color: hollow.textSecondary,
                ),
              ),
            ),
            HollowTooltip(
              message: 'Server settings',
              child: HollowPressable(
                onTap: onOpenSettings,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.settings,
                  size: 16,
                  color: hollow.textSecondary,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Server mode content — channel list with create button.
class _ServerContent extends StatefulWidget {
  final HollowTheme hollow;
  final String serverId;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final bool canManageChannels;
  final String channelLayoutJson;

  const _ServerContent({
    super.key,
    required this.hollow,
    required this.serverId,
    required this.channels,
    required this.selectedChannelId,
    required this.onChannelSelected,
    required this.onCreateChannel,
    this.canManageChannels = false,
    this.channelLayoutJson = '[]',
  });

  @override
  State<_ServerContent> createState() => _ServerContentState();
}

class _ServerContentState extends State<_ServerContent> {
  List<Widget> _buildLayoutItems() {
    final w = widget;
    final widgets = <Widget>[];
    final placedChannels = <String>{};

    try {
      final List<dynamic> layout = jsonDecode(w.channelLayoutJson);
      String? currentCategory;
      for (final item in layout) {
        if (item['type'] == 'category') {
          currentCategory = item['name'] as String;
          widgets.add(_CategoryHeader(
            hollow: w.hollow,
            name: currentCategory,
            onToggle: () => setState(() {}),
          ));
        } else if (item['type'] == 'separator') {
          currentCategory = null;
          // Add a small visual divider in the sidebar.
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
            child: Divider(height: 1, color: w.hollow.border),
          ));
        } else if (item['type'] == 'channel') {
          final channelId = item['channel_id'] as String;
          final channel = w.channels[channelId];
          if (channel != null) {
            placedChannels.add(channelId);
            final collapsed = currentCategory != null &&
                (_categoryCollapsedState[currentCategory] ?? false);
            final Widget tile;
            if (channel.channelType == ChannelType.voice) {
              tile = _VoiceChannelTile(
                channel: channel,
                serverId: w.serverId,
                onChannelSelected: w.onChannelSelected,
              );
            } else {
              tile = _ChannelTile(
                channel: channel,
                serverId: w.serverId,
                isSelected: channel.channelId == w.selectedChannelId,
                onTap: () => w.onChannelSelected(channel.channelId),
              );
            }
            widgets.add(_AnimatedChannelTile(
              key: ValueKey('ach-$channelId'),
              visible: !collapsed,
              child: tile,
            ));
          }
        }
      }
    } catch (_) {}

    // Always show channels not yet placed in the layout.
    // This ensures newly created channels appear immediately.
    final unplaced = w.channels.values
        .where((ch) => !placedChannels.contains(ch.channelId))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final channel in unplaced) {
      if (channel.channelType == ChannelType.voice) {
        widgets.add(_VoiceChannelTile(
          channel: channel,
          serverId: w.serverId,
          onChannelSelected: w.onChannelSelected,
        ));
      } else {
        widgets.add(_ChannelTile(
          channel: channel,
          serverId: w.serverId,
          isSelected: channel.channelId == w.selectedChannelId,
          onTap: () => w.onChannelSelected(channel.channelId),
        ));
      }
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final items = _buildLayoutItems();
    final hasCategories = items.any((i) => i is _CategoryHeader);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!hasCategories)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.sm, HollowSpacing.sm, HollowSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'TEXT CHANNELS',
                    style: HollowTypography.caption.copyWith(
                      color: w.hollow.textSecondary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                if (w.canManageChannels)
                  HollowPressable(
                    onTap: w.onCreateChannel,
                    borderRadius: BorderRadius.circular(w.hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.plus,
                        size: 14, color: w.hollow.textSecondary),
                  ),
              ],
            ),
          ),
        if (!hasCategories) Divider(height: 1, color: w.hollow.border),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('No channels',
                      style: HollowTypography.bodySmall
                          .copyWith(color: w.hollow.textSecondary)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                  itemCount: items.length,
                  itemBuilder: (_, i) => items[i],
                ),
        ),
      ],
    );
  }
}

/// Animates a channel tile in/out when its category is collapsed/expanded.
class _AnimatedChannelTile extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _AnimatedChannelTile({
    super.key,
    required this.visible,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: HollowDurations.fast,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: visible ? null : 0,
        child: visible
            ? child
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// Tracks collapsed state of categories in the sidebar (persists across rebuilds).
final Map<String, bool> _categoryCollapsedState = {};

/// Category header in the sidebar — collapsible folder label.
class _CategoryHeader extends StatefulWidget {
  final HollowTheme hollow;
  final String name;
  final VoidCallback? onToggle;

  const _CategoryHeader({
    required this.hollow,
    required this.name,
    this.onToggle,
  });

  @override
  State<_CategoryHeader> createState() => _CategoryHeaderState();
}

class _CategoryHeaderState extends State<_CategoryHeader> {
  bool get _collapsed => _categoryCollapsedState[widget.name] ?? false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.sm + 2,
        HollowSpacing.md,
        HollowSpacing.sm,
        HollowSpacing.xs,
      ),
      child: HollowPressable(
        subtle: true,
        onTap: () {
          setState(() =>
              _categoryCollapsedState[widget.name] = !_collapsed);
          widget.onToggle?.call();
        },
        child: Row(
          children: [
            AnimatedRotation(
              turns: _collapsed ? -0.25 : 0,
              duration: HollowDurations.fast,
              child: Icon(LucideIcons.chevronDown,
                  size: 10, color: widget.hollow.textSecondary),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Text(
                widget.name.toUpperCase(),
                style: HollowTypography.caption.copyWith(
                  color: widget.hollow.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home / DM mode content — friends list.
class _HomeContent extends ConsumerWidget {
  final HollowTheme hollow;
  final Map<String, PeerInfo> peers;
  final String? selectedPeerId;
  final NodeStatus nodeStatus;
  final ValueChanged<String> onPeerSelected;
  final ChatMessage? Function(String) lastMessage;
  final String Function(DateTime) formatTime;

  const _HomeContent({
    super.key,
    required this.hollow,
    required this.peers,
    required this.selectedPeerId,
    required this.nodeStatus,
    required this.onPeerSelected,
    required this.lastMessage,
    required this.formatTime,
  });

  @override
  Widget build(BuildContext innerContext, WidgetRef ref) {
    final friends = ref.watch(friendsProvider);
    final dividerTextStyle = HollowTypography.caption.copyWith(
      color: hollow.textSecondary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      fontSize: 11,
    );

    // Split friends into accepted and pending.
    final accepted = friends.values
        .where((f) => f.status == 'accepted')
        .toList();
    final pendingIncoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList();
    final pendingOutgoing = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'outgoing')
        .toList();

    // Sort accepted: online first, then by peer ID.
    accepted.sort((a, b) {
      final aOnline = peers.containsKey(a.peerId) ? 0 : 1;
      final bOnline = peers.containsKey(b.peerId) ? 0 : 1;
      if (aOnline != bOnline) return aOnline.compareTo(bOnline);
      return a.peerId.compareTo(b.peerId);
    });

    final hasPending = pendingIncoming.isNotEmpty || pendingOutgoing.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Add friend button
        Padding(
          padding: const EdgeInsets.all(HollowSpacing.sm + 2),
          child: HollowButton.outline(
            onPressed: () => _showAddFriendDialog(innerContext, ref),
            expand: true,
            icon: Icon(LucideIcons.userPlus, size: 14),
            child: const Text('Add Friend'),
          ),
        ),

        Divider(height: 1, color: hollow.border),

        // Pending requests section
        if (hasPending) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm + 2,
              vertical: HollowSpacing.sm,
            ),
            child: Row(
              children: [
                Text('PENDING', style: dividerTextStyle),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(child: Divider(height: 1, color: hollow.border)),
                const SizedBox(width: HollowSpacing.sm),
                Text('${pendingIncoming.length + pendingOutgoing.length}',
                    style: dividerTextStyle),
              ],
            ),
          ),
          for (final req in pendingIncoming)
            _PendingRequestTile(
              hollow: hollow,
              peerId: req.peerId,
              direction: 'incoming',
              onAccept: () =>
                  ref.read(friendsProvider.notifier).acceptRequest(req.peerId),
              onReject: () =>
                  ref.read(friendsProvider.notifier).rejectRequest(req.peerId),
            ),
          for (final req in pendingOutgoing)
            _PendingRequestTile(
              hollow: hollow,
              peerId: req.peerId,
              direction: 'outgoing',
            ),
          Divider(height: 1, color: hollow.border),
        ],

        // Friends section header
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm + 2,
            vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Text('FRIENDS', style: dividerTextStyle),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(child: Divider(height: 1, color: hollow.border)),
              const SizedBox(width: HollowSpacing.sm),
              Text('${accepted.length}', style: dividerTextStyle),
            ],
          ),
        ),

        // Friends list
        Expanded(
          child: accepted.isEmpty && !hasPending
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.users, size: 48,
                          color: hollow.textSecondary.withValues(alpha: 0.3)),
                      const SizedBox(height: HollowSpacing.md),
                      Text('No friends yet',
                          style: HollowTypography.body
                              .copyWith(color: hollow.textSecondary)),
                      const SizedBox(height: HollowSpacing.xs),
                      Text('Add a friend by their peer ID',
                          style: HollowTypography.caption
                              .copyWith(color: hollow.textSecondary)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: accepted.length,
                  padding: const EdgeInsets.symmetric(
                      vertical: HollowSpacing.xs),
                  itemBuilder: (context, index) {
                    final friend = accepted[index];
                    final isOnline = peers.containsKey(friend.peerId);
                    final peer = peers[friend.peerId];
                    final isSelected = friend.peerId == selectedPeerId;
                    final last = lastMessage(friend.peerId);

                    return PeerCard(
                      peerId: friend.peerId,
                      isSelected: isSelected,
                      isEncrypted: peer?.isEncrypted ?? false,
                      isOnline: isOnline,
                      lastMessage: last,
                      formatTime: formatTime,
                      onTap: () => onPeerSelected(friend.peerId),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showAddFriendDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showHollowDialog(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Add Friend',
        content: HollowTextField(
          controller: controller,
          hintText: 'Paste peer ID...',
          autofocus: true,
          style: HollowTypography.mono.copyWith(
            color: hollow.textPrimary,
            fontSize: 12,
          ),
          onSubmitted: (_) {
            final peerId = controller.text.trim();
            if (peerId.isNotEmpty) {
              ref.read(friendsProvider.notifier).sendRequest(peerId);
              Navigator.pop(ctx);
              HollowToast.show(
                context,
                'Friend request sent',
                type: HollowToastType.success,
              );
            }
          },
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () {
              final peerId = controller.text.trim();
              if (peerId.isNotEmpty) {
                ref.read(friendsProvider.notifier).sendRequest(peerId);
                Navigator.pop(ctx);
                HollowToast.show(
                  context,
                  'Friend request sent',
                  type: HollowToastType.success,
                );
              }
            },
            child: const Text('Send Request'),
          ),
        ],
      ),
    );
  }
}

/// Pending friend request tile with accept/reject buttons.
class _PendingRequestTile extends ConsumerWidget {
  final HollowTheme hollow;
  final String peerId;
  final String direction;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  const _PendingRequestTile({
    required this.hollow,
    required this.peerId,
    required this.direction,
    this.onAccept,
    this.onReject,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profileProvider);
    final name = displayNameFor(profiles, peerId);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm + 2,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
        ),
        child: Row(
          children: [
            HollowAvatar(peerId: peerId, size: 28),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    direction == 'incoming'
                        ? 'Wants to be friends'
                        : 'Request sent',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            if (direction == 'incoming') ...[
              HollowPressable(
                onTap: onAccept,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.check, size: 16, color: hollow.success),
              ),
              HollowPressable(
                onTap: onReject,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.x, size: 16, color: hollow.error),
              ),
            ] else
              Icon(LucideIcons.clock, size: 14, color: hollow.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// A single channel tile in the channel list.
class _ChannelTile extends ConsumerWidget {
  final ChannelInfo channel;
  final String serverId;
  final bool isSelected;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.channel,
    required this.serverId,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusMd);
    final isMuted = ref.watch(notificationSettingsProvider.notifier)
        .isChannelMuted(serverId, channel.channelId);
    final hasUnread = !isSelected &&
        !isMuted &&
        ref.watch(unreadProvider.notifier).isChannelUnread(
            serverId, channel.channelId);
    final mentionCount = isSelected ? 0 :
        ref.watch(unreadProvider.notifier).channelMentionCount(
            serverId, channel.channelId);

    Widget tile = HollowPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: radius,
      backgroundColor:
          isSelected ? hollow.accentMuted : Colors.transparent,
      hoverColor: hollow.elevated,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      child: AnimatedDefaultTextStyle(
        duration: HollowDurations.fast,
        curve: HollowCurves.subtle,
        style: HollowTypography.body.copyWith(
          color: isSelected || hasUnread
              ? hollow.textPrimary
              : hollow.textSecondary,
          fontWeight:
              isSelected || hasUnread ? FontWeight.w600 : FontWeight.w400,
        ),
        child: Row(
          children: [
            Icon(
              channel.channelType == ChannelType.voice
                  ? LucideIcons.volume2
                  : LucideIcons.hash,
              size: 18,
              color: isSelected || hasUnread
                  ? hollow.textPrimary
                  : hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                channel.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (mentionCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: hollow.error,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '@$mentionCount',
                  style: HollowTypography.caption.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10),
                ),
              )
            else if (hasUnread)
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: hollow.accent,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );

    if (isSelected) {
      tile = SelectionShimmer(
        highlightColor: hollow.accent.withValues(alpha: 0.12),
        borderRadius: radius,
        child: tile,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: tile,
    );
  }
}

/// Voice channel tile — shows speaker icon, channel name, and participant list.
/// Clicking joins the voice channel instead of selecting it for text.
/// Tracks leaving peers to animate them out before removal.
class _VoiceChannelTile extends ConsumerStatefulWidget {
  final ChannelInfo channel;
  final String serverId;
  final ValueChanged<String> onChannelSelected;

  const _VoiceChannelTile({
    required this.channel,
    required this.serverId,
    required this.onChannelSelected,
  });

  @override
  ConsumerState<_VoiceChannelTile> createState() => _VoiceChannelTileState();
}

class _VoiceChannelTileState extends ConsumerState<_VoiceChannelTile> {
  /// Peers currently animating out (kept in tree until animation finishes).
  final Set<String> _leavingPeers = {};

  /// Previous frame's participant set for diffing.
  Set<String> _prevParticipants = {};

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final isConnected = vcState.currentServerId == widget.serverId &&
        vcState.currentChannelId == widget.channel.channelId;
    final participants =
        vcState.getParticipants(widget.serverId, widget.channel.channelId);

    // Detect who just left.
    final departed = _prevParticipants.difference(participants);
    for (final peerId in departed) {
      if (!_leavingPeers.contains(peerId)) {
        _leavingPeers.add(peerId);
      }
    }
    _prevParticipants = Set.of(participants);

    // Visible = current participants + still-animating leavers.
    final visible = [...participants, ..._leavingPeers];

    final radius = BorderRadius.circular(hollow.radiusMd);

    Widget channelRow = HollowPressable(
      onTap: () {
        if (isConnected) {
          // Already in this channel — select it for the main pane.
          widget.onChannelSelected(widget.channel.channelId);
          return;
        }
        ref.read(voiceChannelProvider.notifier)
            .joinChannel(widget.serverId, widget.channel.channelId);
      },
      subtle: true,
      borderRadius: radius,
      backgroundColor: isConnected ? hollow.accentMuted : Colors.transparent,
      hoverColor: hollow.elevated,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.volume2,
            size: 18,
            color: isConnected ? hollow.accent : hollow.textSecondary,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              widget.channel.name,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.body.copyWith(
                color: isConnected
                    ? hollow.textPrimary
                    : hollow.textSecondary,
                fontWeight: isConnected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );

    if (isConnected) {
      channelRow = SelectionShimmer(
        highlightColor: hollow.accent.withValues(alpha: 0.12),
        borderRadius: radius,
        vertical: true,
        child: channelRow,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          channelRow,
          AnimatedSize(
            duration: HollowDurations.normal,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(
                  left: HollowSpacing.sm + 2 + 18 + HollowSpacing.sm),
              child: Column(
                children: visible
                    .map((peerId) => _AnimatedParticipantRow(
                          key: ValueKey('vp-$peerId'),
                          leaving: _leavingPeers.contains(peerId),
                          onLeaveComplete: () {
                            if (mounted) {
                              setState(() => _leavingPeers.remove(peerId));
                            }
                          },
                          child: _VoiceParticipantRow(
                            peerId: peerId,
                            serverId: widget.serverId,
                            channelId: widget.channel.channelId,
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Animates a participant row in/out with a simple fade.
class _AnimatedParticipantRow extends StatefulWidget {
  final Widget child;
  final bool leaving;
  final VoidCallback? onLeaveComplete;

  const _AnimatedParticipantRow({
    super.key,
    required this.child,
    this.leaving = false,
    this.onLeaveComplete,
  });

  @override
  State<_AnimatedParticipantRow> createState() =>
      _AnimatedParticipantRowState();
}

class _AnimatedParticipantRowState extends State<_AnimatedParticipantRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 180),
    );
    if (widget.leaving) {
      _controller.value = 1.0;
      _controller.reverse().then((_) => widget.onLeaveComplete?.call());
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_AnimatedParticipantRow old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      _controller.reverse().then((_) => widget.onLeaveComplete?.call());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: widget.child,
    );
  }
}

/// A single participant row in a voice channel tile.
class _VoiceParticipantRow extends ConsumerWidget {
  final String peerId;
  final String serverId;
  final String channelId;

  const _VoiceParticipantRow({
    required this.peerId,
    required this.serverId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profileProvider);
    final name = displayNameFor(profiles, peerId);
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';

    final bool isMuted;
    final bool isDeafened;
    if (peerId == localPeerId) {
      isMuted = vcState.isMuted;
      isDeafened = vcState.isDeafened;
    } else {
      final peerState = vcState.getPeerAudioState(peerId);
      isMuted = peerState.isMuted;
      isDeafened = peerState.isDeafened;
    }

    final speaking = vcState.isSpeaking(peerId);
    final isRemote = peerId != localPeerId;
    final isScreenSharing = peerId == localPeerId
        ? vcState.isScreenSharing
        : (vcState.peerScreenSharing[peerId] ?? false);
    final isCameraOn = peerId == localPeerId
        ? vcState.isCameraOn
        : (vcState.peerCameraOn[peerId] ?? false);

    return GestureDetector(
      onSecondaryTapUp: isRemote
          ? (details) =>
              _showVolumePopup(context, ref, details.globalPosition)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            HollowAvatar(
                peerId: peerId,
                size: 18),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Text(
                name,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Speaking indicator — teal dot, fades in/out.
            _SpeakingDot(visible: speaking),
            // Screen sharing indicator — green monitor icon.
            if (isScreenSharing)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(LucideIcons.monitor,
                    size: 12, color: Colors.green),
              ),
            // Camera indicator — accent video icon.
            if (isCameraOn)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(LucideIcons.video,
                    size: 12, color: hollow.accent),
              ),
            if (isMuted)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child:
                    Icon(LucideIcons.micOff, size: 12, color: hollow.error),
              ),
            if (isDeafened)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Icon(LucideIcons.headphones,
                    size: 12, color: hollow.error),
              ),
          ],
        ),
      ),
    );
  }

  void _showVolumePopup(
      BuildContext context, WidgetRef ref, Offset position) {
    final hollow = HollowTheme.of(context);
    final overlay = Overlay.of(context);
    final vcState = ref.read(voiceChannelProvider);
    var volume = vcState.getPeerVolume(peerId);
    OverlayEntry? entry;

    void remove() {
      entry?.remove();
      entry = null;
    }

    entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            // Tap-away barrier.
            Positioned.fill(
              child: GestureDetector(
                onTap: remove,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: position.dx,
              top: position.dy,
              child: Material(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                elevation: 4,
                child: StatefulBuilder(
                  builder: (ctx, setPopupState) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.volume2,
                              size: 12, color: hollow.textSecondary),
                          SizedBox(
                            width: 110,
                            height: 24,
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: hollow.accent,
                                inactiveTrackColor: hollow.border,
                                thumbColor: hollow.accent,
                                overlayColor:
                                    hollow.accent.withValues(alpha: 0.08),
                                trackHeight: 2,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 4),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 8),
                              ),
                              child: Slider(
                                value: volume,
                                min: 0.0,
                                max: 2.0,
                                onChanged: (v) {
                                  setPopupState(() => volume = v);
                                  ref
                                      .read(voiceChannelProvider.notifier)
                                      .setPeerVolume(peerId, v);
                                },
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              '${(volume * 100).round()}%',
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                                fontSize: 10,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(entry!);
  }
}

/// Teal dot that fades in when [visible] and fades out when not.
/// No pulsing — steady while shown.
class _SpeakingDot extends StatelessWidget {
  final bool visible;
  const _SpeakingDot({required this.visible});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1.0 : 0.0,
      duration: HollowDurations.fast,
      child: Padding(
        padding: const EdgeInsets.only(left: 2),
        child: Container(
          width: 7,
          height: 7,
          decoration: const BoxDecoration(
            color: Colors.teal,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
