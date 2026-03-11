import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/node_status.dart';
import 'package:haven/src/core/providers/identity_provider.dart';
import 'package:haven/src/core/providers/node_provider.dart';
import 'package:haven/src/core/providers/peers_provider.dart';
import 'package:haven/src/core/providers/profile_provider.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_avatar.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/components/haven_tooltip.dart';
import 'package:haven/src/ui/components/profile_card_popup.dart';
import 'package:haven/src/ui/components/status_dot.dart';
import 'package:haven/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:haven/src/ui/dialogs/user_settings_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Bottom bar in the channel sidebar showing the local user's identity and status.
/// Mirrors Discord's bottom-left user panel.
class UserBar extends ConsumerWidget {
  const UserBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final haven = HavenTheme.of(context);
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
          statusColor = haven.textSecondary;
          statusPulse = true;
        case ServerSyncStatus.syncing:
          statusText = 'Syncing...';
          statusColor = haven.accent;
          statusPulse = true;
        case ServerSyncStatus.synced:
        case ServerSyncStatus.idle:
          statusText = 'Online';
          statusColor = haven.success;
          statusPulse = true;
        case ServerSyncStatus.retrying:
          statusText = 'Retrying...';
          statusColor = haven.warning;
          statusPulse = true;
        case ServerSyncStatus.failed:
          statusText = 'Sync failed';
          statusColor = haven.error;
          statusPulse = false;
      }
    } else {
      // No server selected — fall back to node-level status.
      statusText = _statusText(nodeState.status);
      statusColor = _statusColor(haven, nodeState.status);
      statusPulse = nodeState.status == NodeStatus.connected;
    }

    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.sm + 2),
      decoration: BoxDecoration(
        color: haven.background,
        border: Border(
          top: BorderSide(color: haven.border),
        ),
      ),
      child: Row(
        children: [
          // Avatar
          if (localPeerId != null)
            HavenAvatar(peerId: localPeerId, size: 32)
          else
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: haven.elevated,
                borderRadius: BorderRadius.circular(haven.radiusMd),
              ),
            ),

          const SizedBox(width: HavenSpacing.sm),

          // Peer ID + status
          Expanded(
            child: HavenTooltip(
              message: localPeerId ?? 'Loading...',
              child: HavenPressable(
                borderRadius: BorderRadius.circular(haven.radiusSm),
                onTap: () {
                  if (localPeerId != null) {
                    final box = context.findRenderObject() as RenderBox?;
                    final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
                    // Show card above the user bar, left-aligned with the bar
                    showProfileCardPopup(
                      context: context,
                      ref: ref,
                      peerId: localPeerId,
                      anchor: Offset(
                        pos.dx,
                        pos.dy - 310, // well above the bar
                      ),
                    );
                  }
                },
                padding: const EdgeInsets.symmetric(
                  vertical: HavenSpacing.xs,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      myDisplayName,
                      style: HavenTypography.body.copyWith(
                        color: haven.textPrimary,
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
                        const SizedBox(width: HavenSpacing.xs),
                        Text(
                          statusText,
                          style: HavenTypography.caption.copyWith(
                            color: haven.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Settings
          HavenTooltip(
            message: 'Settings',
            child: HavenPressable(
              onTap: () => showUserSettingsDialog(context, ref),
              borderRadius: BorderRadius.circular(haven.radiusSm),
              padding: const EdgeInsets.all(HavenSpacing.xs),
              child: Icon(
                LucideIcons.settings,
                size: 16,
                color: haven.textSecondary,
              ),
            ),
          ),

          // Recovery key button
          if (identity.mnemonic != null)
            HavenTooltip(
              message: 'Recovery phrase',
              child: HavenPressable(
                onTap: () =>
                    showMnemonicDialog(context, identity.mnemonic!),
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(LucideIcons.keyRound, size: 16, color: haven.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  Color _statusColor(HavenTheme haven, NodeStatus status) {
    return switch (status) {
      NodeStatus.connected => haven.success,
      NodeStatus.starting => haven.warning,
      NodeStatus.loading => haven.textSecondary,
      NodeStatus.error => haven.error,
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
