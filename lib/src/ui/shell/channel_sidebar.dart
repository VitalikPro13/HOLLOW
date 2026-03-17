import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/channel_info.dart';
import 'package:haven/src/core/models/chat_message.dart';
import 'package:haven/src/core/models/node_status.dart';
import 'package:haven/src/core/models/peer_info.dart';
import 'package:haven/src/core/models/server_info.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';
import 'package:haven/src/ui/animations/reveal_widgets.dart';
import 'package:haven/src/ui/animations/selection_shimmer.dart';
import 'package:haven/src/ui/dialogs/storage_dashboard_dialog.dart';
import 'package:haven/src/ui/animations/startup_reveal.dart';
import 'package:haven/src/core/providers/friends_provider.dart';
import 'package:haven/src/core/providers/notification_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/unread_provider.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/dialogs/invite_dialog.dart';
import 'package:haven/src/ui/shell/user_bar.dart';
import 'package:haven/src/ui/sidebar/peer_card.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Channel / DM sidebar (240px). Supports two modes:
///
/// **Home mode** (`selectedServer == null`): room controls + peer list.
/// **Server mode** (`selectedServer != null`): server name header + channel list.
class ChannelSidebar extends StatelessWidget {
  // -- Home mode props --
  final Map<String, PeerInfo> peers;
  final Map<String, List<ChatMessage>> chatHistory;
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

  const ChannelSidebar({
    super.key,
    required this.peers,
    required this.chatHistory,
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
  });

  static void _noop(String _) {}
  static void _noopVoid() {}

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final sidebarReveal =
        StartupRevealScope.interval(context, 0.12, 0.30);
    final userBarReveal =
        StartupRevealScope.interval(context, 0.50, 0.60);

    Widget userBar = const UserBar();
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

    Widget sidebar = Container(
      width: width,
      decoration: BoxDecoration(
        color: haven.surface,
        border: Border(
          right: BorderSide(color: haven.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header — crossfade between server name and "Direct Messages"
          AnimatedSwitcher(
            duration: HavenDurations.fast,
            child: _buildHeader(context, haven),
          ),

          // Content — crossfade between server channels and home/DM view
          Expanded(
            child: AnimatedSwitcher(
              duration: HavenDurations.normal,
              switchInCurve: HavenCurves.enter,
              switchOutCurve: HavenCurves.exit,
              child: selectedServer != null
                  ? _ServerContent(
                      key: ValueKey('server-${selectedServer!.serverId}'),
                      haven: haven,
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
                      haven: haven,
                      peers: peers,
                      selectedPeerId: selectedPeerId,
                      nodeStatus: nodeStatus,
                      onPeerSelected: onPeerSelected,
                      lastMessage: lastMessage,
                      formatTime: formatTime,
                    ),
            ),
          ),

          // User bar at bottom
          userBar,
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

  Widget _buildHeader(BuildContext context, HavenTheme haven) {
    final label = selectedServer?.name ?? 'Direct Messages';
    final headerTextReveal =
        StartupRevealScope.interval(context, 0.25, 0.40);

    return Container(
      key: ValueKey('header-$label'),
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: haven.border),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TypewriterText(
              text: label,
              animation: headerTextReveal,
              style: HavenTypography.subheading.copyWith(
                color: haven.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (selectedServer != null) ...[
            HavenTooltip(
              message: 'Invite people',
              child: HavenPressable(
                onTap: () {
                  final link =
                      'haven://join?server=${selectedServer!.serverId}';
                  showInviteDialog(
                      context, link, selectedServer!.serverId);
                },
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(
                  LucideIcons.userPlus,
                  size: 16,
                  color: haven.textSecondary,
                ),
              ),
            ),
            HavenTooltip(
              message: 'Storage',
              child: HavenPressable(
                onTap: () => showStorageDashboardDialog(
                    context, selectedServer!.serverId),
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(
                  LucideIcons.hardDrive,
                  size: 16,
                  color: haven.textSecondary,
                ),
              ),
            ),
            HavenTooltip(
              message: 'Server settings',
              child: HavenPressable(
                onTap: onOpenSettings,
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(
                  LucideIcons.settings,
                  size: 16,
                  color: haven.textSecondary,
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
  final HavenTheme haven;
  final String serverId;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final bool canManageChannels;
  final String channelLayoutJson;

  const _ServerContent({
    super.key,
    required this.haven,
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
            haven: w.haven,
            name: currentCategory,
            onToggle: () => setState(() {}),
          ));
        } else if (item['type'] == 'separator') {
          currentCategory = null;
          // Add a small visual divider in the sidebar.
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HavenSpacing.lg,
              vertical: HavenSpacing.sm,
            ),
            child: Divider(height: 1, color: w.haven.border),
          ));
        } else if (item['type'] == 'channel') {
          final channelId = item['channel_id'] as String;
          final channel = w.channels[channelId];
          if (channel != null) {
            placedChannels.add(channelId);
            final collapsed = currentCategory != null &&
                (_categoryCollapsedState[currentCategory] ?? false);
            widgets.add(_AnimatedChannelTile(
              key: ValueKey('ach-$channelId'),
              visible: !collapsed,
              child: _ChannelTile(
                channel: channel,
                serverId: w.serverId,
                isSelected: channel.channelId == w.selectedChannelId,
                onTap: () => w.onChannelSelected(channel.channelId),
              ),
            ));
          }
        }
      }
    } catch (_) {}

    // Only show unplaced channels if no layout has been saved yet
    // (empty layout = no admin organization). Once a layout exists,
    // new channels only appear after the admin saves the layout.
    final hasLayout = placedChannels.isNotEmpty;
    if (!hasLayout) {
      final unplaced = w.channels.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      for (final channel in unplaced) {
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
              HavenSpacing.lg, HavenSpacing.sm, HavenSpacing.sm, HavenSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'TEXT CHANNELS',
                    style: HavenTypography.caption.copyWith(
                      color: w.haven.textSecondary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                if (w.canManageChannels)
                  HavenPressable(
                    onTap: w.onCreateChannel,
                    borderRadius: BorderRadius.circular(w.haven.radiusSm),
                    padding: const EdgeInsets.all(HavenSpacing.xs),
                    child: Icon(LucideIcons.plus,
                        size: 14, color: w.haven.textSecondary),
                  ),
              ],
            ),
          ),
        if (!hasCategories) Divider(height: 1, color: w.haven.border),
        Expanded(
          child: items.isEmpty
              ? Center(
                  child: Text('No channels',
                      style: HavenTypography.bodySmall
                          .copyWith(color: w.haven.textSecondary)),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: HavenSpacing.xs),
                  children: items,
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
      duration: const Duration(milliseconds: 150),
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
  final HavenTheme haven;
  final String name;
  final VoidCallback? onToggle;

  const _CategoryHeader({
    required this.haven,
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
        HavenSpacing.sm + 2,
        HavenSpacing.md,
        HavenSpacing.sm,
        HavenSpacing.xs,
      ),
      child: HavenPressable(
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
              duration: const Duration(milliseconds: 150),
              child: Icon(LucideIcons.chevronDown,
                  size: 10, color: widget.haven.textSecondary),
            ),
            const SizedBox(width: HavenSpacing.xs),
            Expanded(
              child: Text(
                widget.name.toUpperCase(),
                style: HavenTypography.caption.copyWith(
                  color: widget.haven.textSecondary,
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
  final HavenTheme haven;
  final Map<String, PeerInfo> peers;
  final String? selectedPeerId;
  final NodeStatus nodeStatus;
  final ValueChanged<String> onPeerSelected;
  final ChatMessage? Function(String) lastMessage;
  final String Function(DateTime) formatTime;

  const _HomeContent({
    super.key,
    required this.haven,
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
    final dividerTextStyle = HavenTypography.caption.copyWith(
      color: haven.textSecondary,
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
          padding: const EdgeInsets.all(HavenSpacing.sm + 2),
          child: HavenButton.outline(
            onPressed: () => _showAddFriendDialog(innerContext, ref),
            expand: true,
            icon: Icon(LucideIcons.userPlus, size: 14),
            child: const Text('Add Friend'),
          ),
        ),

        Divider(height: 1, color: haven.border),

        // Pending requests section
        if (hasPending) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HavenSpacing.sm + 2,
              vertical: HavenSpacing.sm,
            ),
            child: Row(
              children: [
                Text('PENDING', style: dividerTextStyle),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(child: Divider(height: 1, color: haven.border)),
                const SizedBox(width: HavenSpacing.sm),
                Text('${pendingIncoming.length + pendingOutgoing.length}',
                    style: dividerTextStyle),
              ],
            ),
          ),
          for (final req in pendingIncoming)
            _PendingRequestTile(
              haven: haven,
              peerId: req.peerId,
              direction: 'incoming',
              onAccept: () =>
                  ref.read(friendsProvider.notifier).acceptRequest(req.peerId),
              onReject: () =>
                  ref.read(friendsProvider.notifier).rejectRequest(req.peerId),
            ),
          for (final req in pendingOutgoing)
            _PendingRequestTile(
              haven: haven,
              peerId: req.peerId,
              direction: 'outgoing',
            ),
          Divider(height: 1, color: haven.border),
        ],

        // Friends section header
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.sm + 2,
            vertical: HavenSpacing.sm,
          ),
          child: Row(
            children: [
              Text('FRIENDS', style: dividerTextStyle),
              const SizedBox(width: HavenSpacing.sm),
              Expanded(child: Divider(height: 1, color: haven.border)),
              const SizedBox(width: HavenSpacing.sm),
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
                          color: haven.textSecondary.withValues(alpha: 0.3)),
                      const SizedBox(height: HavenSpacing.md),
                      Text('No friends yet',
                          style: HavenTypography.body
                              .copyWith(color: haven.textSecondary)),
                      const SizedBox(height: HavenSpacing.xs),
                      Text('Add a friend by their peer ID',
                          style: HavenTypography.caption
                              .copyWith(color: haven.textSecondary)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: accepted.length,
                  padding: const EdgeInsets.symmetric(
                      vertical: HavenSpacing.xs),
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
    showHavenDialog(
      context: context,
      builder: (ctx) => HavenDialog(
        title: 'Add Friend',
        content: HavenTextField(
          controller: controller,
          hintText: 'Paste peer ID...',
          autofocus: true,
          style: HavenTypography.mono.copyWith(
            color: haven.textPrimary,
            fontSize: 12,
          ),
          onSubmitted: (_) {
            final peerId = controller.text.trim();
            if (peerId.isNotEmpty) {
              ref.read(friendsProvider.notifier).sendRequest(peerId);
              Navigator.pop(ctx);
              HavenToast.show(
                context,
                'Friend request sent',
                type: HavenToastType.success,
              );
            }
          },
        ),
        actions: [
          HavenButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HavenButton.filled(
            onPressed: () {
              final peerId = controller.text.trim();
              if (peerId.isNotEmpty) {
                ref.read(friendsProvider.notifier).sendRequest(peerId);
                Navigator.pop(ctx);
                HavenToast.show(
                  context,
                  'Friend request sent',
                  type: HavenToastType.success,
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
  final HavenTheme haven;
  final String peerId;
  final String direction;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  const _PendingRequestTile({
    required this.haven,
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
        horizontal: HavenSpacing.sm,
        vertical: HavenSpacing.xxs,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HavenSpacing.sm + 2,
          vertical: HavenSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: haven.elevated,
          borderRadius: BorderRadius.circular(haven.radiusMd),
        ),
        child: Row(
          children: [
            HavenAvatar(peerId: peerId, size: 28),
            const SizedBox(width: HavenSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: HavenTypography.body.copyWith(
                      color: haven.textPrimary,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    direction == 'incoming'
                        ? 'Wants to be friends'
                        : 'Request sent',
                    style: HavenTypography.caption.copyWith(
                      color: haven.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            if (direction == 'incoming') ...[
              HavenPressable(
                onTap: onAccept,
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(LucideIcons.check, size: 16, color: haven.success),
              ),
              HavenPressable(
                onTap: onReject,
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(LucideIcons.x, size: 16, color: haven.error),
              ),
            ] else
              Icon(LucideIcons.clock, size: 14, color: haven.textSecondary),
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
    final haven = HavenTheme.of(context);
    final radius = BorderRadius.circular(haven.radiusMd);
    final isMuted = ref.watch(notificationSettingsProvider.notifier)
        .isChannelMuted(serverId, channel.channelId);
    final hasUnread = !isSelected &&
        !isMuted &&
        ref.watch(unreadProvider.notifier).isChannelUnread(
            serverId, channel.channelId);

    Widget tile = HavenPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: radius,
      backgroundColor:
          isSelected ? haven.accentMuted : Colors.transparent,
      hoverColor: haven.elevated,
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm + 2,
        vertical: HavenSpacing.sm,
      ),
      child: AnimatedDefaultTextStyle(
        duration: HavenDurations.fast,
        curve: HavenCurves.subtle,
        style: HavenTypography.body.copyWith(
          color: isSelected || hasUnread
              ? haven.textPrimary
              : haven.textSecondary,
          fontWeight:
              isSelected || hasUnread ? FontWeight.w600 : FontWeight.w400,
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.hash,
              size: 18,
              color: isSelected || hasUnread
                  ? haven.textPrimary
                  : haven.textSecondary,
            ),
            const SizedBox(width: HavenSpacing.sm),
            Expanded(
              child: Text(
                channel.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Unread dot
            if (hasUnread)
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: haven.accent,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );

    if (isSelected) {
      tile = SelectionShimmer(
        highlightColor: haven.accent.withValues(alpha: 0.12),
        borderRadius: radius,
        child: tile,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm,
        vertical: HavenSpacing.xxs,
      ),
      child: tile,
    );
  }
}
