import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:haven/src/core/models/channel_info.dart';
import 'package:haven/src/core/models/chat_message.dart';
import 'package:haven/src/core/models/node_status.dart';
import 'package:haven/src/core/models/peer_info.dart';
import 'package:haven/src/core/models/server_info.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:haven/src/ui/components/haven_toast.dart';
import 'package:haven/src/ui/shell/user_bar.dart';
import 'package:haven/src/ui/sidebar/empty_peer_list.dart';
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
  final String? activeRoom;
  final TextEditingController roomController;
  final Future<void> Function(String) onJoinRoom;
  final VoidCallback onCreateInvite;

  // -- Server mode props --
  final ServerInfo? selectedServer;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;

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
    required this.activeRoom,
    required this.roomController,
    required this.onJoinRoom,
    required this.onCreateInvite,
    this.selectedServer,
    this.channels = const {},
    this.selectedChannelId,
    this.onChannelSelected = _noop,
    this.onCreateChannel = _noopVoid,
    this.width = 240,
  });

  static void _noop(String _) {}
  static void _noopVoid() {}

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    return Container(
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
          // Header — changes based on mode
          _buildHeader(haven),

          // Content — server channels or home/DM view
          if (selectedServer != null)
            ..._buildServerView(context, haven)
          else
            ..._buildHomeView(context, haven),

          // User bar at bottom
          const UserBar(),
        ],
      ),
    );
  }

  Widget _buildHeader(HavenTheme haven) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: haven.border),
        ),
      ),
      alignment: Alignment.centerLeft,
      child: Text(
        selectedServer?.name ?? 'Direct Messages',
        style: HavenTypography.subheading.copyWith(
          color: haven.textPrimary,
          fontWeight: FontWeight.w600,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  // ---------- Server mode ----------

  List<Widget> _buildServerView(BuildContext context, HavenTheme haven) {
    final channelList = channels.values.toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    return [
      // "TEXT CHANNELS" section header with "+" button
      Padding(
        padding: const EdgeInsets.fromLTRB(
          HavenSpacing.lg,
          HavenSpacing.sm,
          HavenSpacing.sm,
          HavenSpacing.sm,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'TEXT CHANNELS',
                style: HavenTypography.caption.copyWith(
                  color: haven.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            HavenPressable(
              onTap: onCreateChannel,
              borderRadius: BorderRadius.circular(haven.radiusSm),
              padding: const EdgeInsets.all(HavenSpacing.xs),
              child: Icon(LucideIcons.plus,
                  size: 14, color: haven.textSecondary),
            ),
          ],
        ),
      ),

      Divider(height: 1, color: haven.border),

      // Channel list
      Expanded(
        child: channelList.isEmpty
            ? Center(
                child: Text(
                  'No channels',
                  style: HavenTypography.bodySmall
                      .copyWith(color: haven.textSecondary),
                ),
              )
            : ListView.builder(
                itemCount: channelList.length,
                padding: const EdgeInsets.symmetric(
                    vertical: HavenSpacing.xs),
                itemBuilder: (context, index) {
                  final channel = channelList[index];
                  final isSelected =
                      channel.channelId == selectedChannelId;
                  return _ChannelTile(
                    channel: channel,
                    isSelected: isSelected,
                    onTap: () =>
                        onChannelSelected(channel.channelId),
                  );
                },
              ),
      ),
    ];
  }

  // ---------- Home / DM mode ----------

  List<Widget> _buildHomeView(BuildContext context, HavenTheme haven) {
    return [
      // Room controls
      _buildRoomSection(context, haven),

      Divider(height: 1, color: haven.border),

      // Peer count label
      Padding(
        padding: const EdgeInsets.fromLTRB(
          HavenSpacing.lg,
          HavenSpacing.sm,
          HavenSpacing.lg,
          HavenSpacing.sm,
        ),
        child: Text(
          'ONLINE — ${peers.length}',
          style: HavenTypography.caption.copyWith(
            color: haven.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      ),

      Divider(height: 1, color: haven.border),

      // Peer list
      Expanded(
        child: peers.isEmpty
            ? EmptyPeerList(nodeStatus: nodeStatus)
            : ListView.builder(
                itemCount: peers.length,
                padding: const EdgeInsets.symmetric(
                    vertical: HavenSpacing.xs),
                itemBuilder: (context, index) {
                  final peerId = peers.keys.elementAt(index);
                  final peer = peers[peerId];
                  final isSelected = peerId == selectedPeerId;
                  final last = lastMessage(peerId);

                  return PeerCard(
                    peerId: peerId,
                    isSelected: isSelected,
                    isEncrypted: peer?.isEncrypted ?? false,
                    lastMessage: last,
                    formatTime: formatTime,
                    onTap: () => onPeerSelected(peerId),
                  );
                },
              ),
      ),
    ];
  }

  Widget _buildRoomSection(BuildContext context, HavenTheme haven) {
    if (activeRoom != null) {
      return Padding(
        padding: const EdgeInsets.all(HavenSpacing.sm + 2),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: HavenSpacing.sm + 2,
            vertical: HavenSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: haven.accentMuted,
            borderRadius: BorderRadius.circular(haven.radiusMd),
            border: Border.all(
              color: haven.accent.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.cloud, size: 16, color: haven.accent),
              const SizedBox(width: HavenSpacing.sm),
              Expanded(
                child: Text(
                  'Room: $activeRoom',
                  style: HavenTypography.bodySmall.copyWith(
                    color: haven.accent,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HavenPressable(
                onTap: () {
                  final link = 'haven://join?room=$activeRoom';
                  Clipboard.setData(ClipboardData(text: link));
                  HavenToast.show(
                    context,
                    'Invite link copied',
                    type: HavenToastType.success,
                  );
                },
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(LucideIcons.copy,
                    size: 14, color: haven.accent),
              ),
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(HavenSpacing.sm + 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: HavenTextField(
                  controller: roomController,
                  hintText: 'Room code or invite...',
                  isDense: true,
                  style: HavenTypography.bodySmall.copyWith(
                    color: haven.textPrimary,
                  ),
                  onSubmitted: (v) => onJoinRoom(v.trim()),
                ),
              ),
              const SizedBox(width: HavenSpacing.xs + 2),
              HavenButton.filled(
                onPressed: () =>
                    onJoinRoom(roomController.text.trim()),
                compact: true,
                child: const Text('Join'),
              ),
            ],
          ),
          const SizedBox(height: HavenSpacing.sm - 2),
          HavenButton.outline(
            onPressed: onCreateInvite,
            expand: true,
            icon: Icon(LucideIcons.link, size: 14),
            child: const Text('Create Invite'),
          ),
        ],
      ),
    );
  }
}

/// A single channel tile in the channel list.
class _ChannelTile extends StatelessWidget {
  final ChannelInfo channel;
  final bool isSelected;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.channel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.sm,
        vertical: HavenSpacing.xxs,
      ),
      child: HavenPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(haven.radiusMd),
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
            color: isSelected
                ? haven.textPrimary
                : haven.textSecondary,
            fontWeight:
                isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.hash,
                size: 18,
                color: isSelected
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
            ],
          ),
        ),
      ),
    );
  }
}
