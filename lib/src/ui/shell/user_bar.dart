import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/room_budget_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
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
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Bottom bar in the channel sidebar showing the local user's identity and status.
/// Mirrors Discord's bottom-left user panel.
class UserBar extends ConsumerWidget {
  const UserBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final identity = ref.watch(identityProvider);
    final selectedServerId = ref.watch(selectedServerProvider);

    final localPeerId = identity.peerId;
    final localProfile = localPeerId != null
        ? ref.watch(profileProvider.select((p) => p[localPeerId]))
        : null;
    final myDisplayName = localPeerId != null
        ? displayNameForPeer(localProfile, localPeerId)
        : '---';

    // Derive status: mirror channel pane when a server is selected.
    String statusText;
    Color statusColor;
    bool statusPulse;

    final amInvisible =
        ref.watch(invisibleModeProvider);

    if (amInvisible) {
      statusText = 'Invisible';
      statusColor = hollow.textSecondary;
      statusPulse = false;
    } else if (selectedServerId != null) {
      final syncStatus =
          ref.watch(serverSyncStatusProvider(selectedServerId));
      // Multi-device: count members online via ANY of their devices.
      final onlineIdentities = ref.watch(onlineIdentitiesProvider);
      final membersAsync =
          ref.watch(serverMembersProvider(selectedServerId));
      final onlineCount = membersAsync.when(
        data: (members) => members
            .where((m) =>
                m.peerId != localPeerId &&
                onlineIdentities.contains(m.peerId))
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
          statusColor = hollow.accentText;
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
      // No server selected — show the REAL relay connection state (node started
      // + relay WS connected), not just "the local node booted".
      final overall = ref.watch(overallConnectionProvider);
      statusText = overall == OverallConnection.connected ? 'Online' : overall.label;
      statusColor = switch (overall) {
        OverallConnection.connected => hollow.success,
        OverallConnection.offline || OverallConnection.error => hollow.warning,
        _ => hollow.textSecondary,
      };
      statusPulse = overall.isOnline;
    }

    final roomBudget = ref.watch(roomBudgetProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (roomBudget.usage > 0.5)
          _RoomBudgetBar(budget: roomBudget),
        Container(
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
            HollowAvatar(peerId: localPeerId, size: 32)
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
                    final pos = overlayAnchorOf(context);
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
                // a11y Phase 3: this user panel is fixed-height chrome (52px);
                // cap its label scale (like a tab bar) so the two lines stay in
                // the bar at high OS text size. Content areas honor full 2.0×.
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
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
                          // Non-pulsing states (sync failed/offline) read as a
                          // hollow ring — the adjacent status word labels it.
                          filled: statusPulse,
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
          ),

          // Downloads
          const DownloadIconButton(iconSize: 16),

          // Settings
          HollowTooltip(
            message: 'Settings',
            child: HollowPressable(
              semanticLabel: 'Settings',
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
                semanticLabel: 'Recovery phrase',
                onTap: () =>
                    showMnemonicDialog(context, identity.mnemonic!),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.keyRound, size: 16, color: hollow.textSecondary),
              ),
            ),
        ],
      ),
    ),
      ],
    );
  }
}

class _RoomBudgetBar extends StatelessWidget {
  final RoomBudget budget;
  const _RoomBudgetBar({required this.budget});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = budget.isAtLimit
        ? hollow.error
        : budget.isNearLimit
            ? hollow.warning
            : hollow.accent;

    return HollowTooltip(
      message: '${budget.joined} / ${budget.limit} connections used',
      child: Container(
        height: 3,
        decoration: BoxDecoration(
          color: hollow.border,
        ),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: budget.usage.clamp(0.0, 1.0),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              color: color,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
