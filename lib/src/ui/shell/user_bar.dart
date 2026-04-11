import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/download_icon_button.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Bottom bar in the channel sidebar showing the local user's identity and status.
/// Mirrors Discord's bottom-left user panel.
class UserBar extends ConsumerWidget {
  const UserBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final identity = ref.watch(identityProvider);
    final nodeState = ref.watch(nodeProvider);
    final selectedServerId = ref.watch(selectedServerProvider);

    final localPeerId = identity.peerId;
    final profiles = ref.watch(profileProvider);
    final myDisplayName = localPeerId != null
        ? displayNameFor(profiles, localPeerId)
        : '---';

    // Derive status: mirror channel pane when a server is selected.
    String statusText;
    Color statusColor;
    bool statusPulse;

    if (selectedServerId != null) {
      final syncStatus =
          ref.watch(serverSyncStatusProvider(selectedServerId));
      final connectedPeers = ref.watch(peersProvider);
      final membersAsync =
          ref.watch(serverMembersProvider(selectedServerId));
      final onlineCount = membersAsync.when(
        data: (members) => members
            .where((m) =>
                m.peerId != localPeerId &&
                connectedPeers.containsKey(m.peerId))
            .length,
        loading: () => 0,
        error: (_, _) => 0,
      );

      final effectiveStatus = syncStatus == ServerSyncStatus.idle &&
              onlineCount == 0
          ? ServerSyncStatus.connecting
          : syncStatus;

      switch (effectiveStatus) {
        case ServerSyncStatus.connecting:
          statusText = 'Connecting...';
          statusColor = hollow.textSecondary;
          statusPulse = true;
        case ServerSyncStatus.syncing:
          statusText = 'Syncing...';
          statusColor = hollow.accent;
          statusPulse = true;
        case ServerSyncStatus.synced:
        case ServerSyncStatus.idle:
          statusText = 'Online';
          statusColor = hollow.success;
          statusPulse = true;
        case ServerSyncStatus.retrying:
          statusText = 'Retrying...';
          statusColor = hollow.warning;
          statusPulse = true;
        case ServerSyncStatus.failed:
          statusText = 'Sync failed';
          statusColor = hollow.error;
          statusPulse = false;
      }
    } else {
      // No server selected — fall back to node-level status.
      statusText = _statusText(nodeState.status);
      statusColor = _statusColor(hollow, nodeState.status);
      statusPulse = nodeState.status == NodeStatus.connected;
    }

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm + 2),
      decoration: BoxDecoration(
        color: hollow.opaqueBackground,
        border: Border(
          top: BorderSide(color: hollow.border),
        ),
      ),
      child: Row(
        children: [
          // Avatar
          if (localPeerId != null)
            HollowAvatar(peerId: localPeerId, size: 32, imageBytes: profiles[localPeerId]?.avatarBytes)
          else
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
              ),
            ),

          const SizedBox(width: HollowSpacing.sm),

          // Peer ID + status
          Expanded(
            child: HollowTooltip(
              message: localPeerId ?? 'Loading...',
              child: HollowPressable(
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                onTap: () {
                  if (localPeerId != null) {
                    final box = context.findRenderObject() as RenderBox?;
                    final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
                    // Show card with bottom edge just above the user bar
                    showProfileCardPopup(
                      context: context,
                      ref: ref,
                      peerId: localPeerId,
                      anchor: Offset(
                        pos.dx,
                        pos.dy - 8,
                      ),
                      anchorBottom: true,
                    );
                  }
                },
                padding: const EdgeInsets.symmetric(
                  vertical: HollowSpacing.xs,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      myDisplayName,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        StatusDot(
                          color: statusColor,
                          size: 7,
                          pulse: statusPulse,
                        ),
                        const SizedBox(width: HollowSpacing.xs),
                        Text(
                          statusText,
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Downloads
          const DownloadIconButton(iconSize: 16),

          // Settings
          HollowTooltip(
            message: 'Settings',
            child: HollowPressable(
              onTap: () => showUserSettingsDialog(context, ref),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(
                LucideIcons.settings,
                size: 16,
                color: hollow.textSecondary,
              ),
            ),
          ),

          // Recovery key button
          if (identity.mnemonic != null)
            HollowTooltip(
              message: 'Recovery phrase',
              child: HollowPressable(
                onTap: () =>
                    showMnemonicDialog(context, identity.mnemonic!),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.keyRound, size: 16, color: hollow.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Color _statusColor(HollowTheme hollow, NodeStatus status) {
    return switch (status) {
      NodeStatus.connected => hollow.success,
      NodeStatus.starting => hollow.warning,
      NodeStatus.loading => hollow.textSecondary,
      NodeStatus.error => hollow.error,
    };
  }

  String _statusText(NodeStatus status) {
    return switch (status) {
      NodeStatus.connected => 'Online',
      NodeStatus.starting => 'Connecting...',
      NodeStatus.loading => 'Loading...',
      NodeStatus.error => 'Error',
    };
  }
}
