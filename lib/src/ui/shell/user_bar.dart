import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/room_budget_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/connection_visual.dart';
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

    // MY connection state — the same source of truth the Dock bar uses, so the
    // indicator reads identically in both layouts. It is never derived from
    // whether OTHER people happen to be online: sitting alone in your own
    // server is still "Online".
    final amInvisible = ref.watch(invisibleModeProvider);
    final overall = ref.watch(overallConnectionProvider);
    var visual = connectionVisual(hollow, overall, invisible: amInvisible);

    // Connected + a server open: the sync pipeline for THAT server is the more
    // specific thing to report (it only ever refines "Online", never contradicts
    // it — a stalled sync can't mean "not connected").
    if (!amInvisible && overall.isOnline && selectedServerId != null) {
      final syncStatus = ref.watch(serverSyncStatusProvider(selectedServerId));
      visual = switch (syncStatus) {
        ServerSyncStatus.syncing => ConnectionVisual(
            label: 'Syncing...',
            color: hollow.accentText,
            pulse: true,
            filled: false,
          ),
        ServerSyncStatus.retrying => ConnectionVisual(
            label: 'Retrying...',
            color: hollow.warning,
            pulse: true,
            filled: false,
          ),
        ServerSyncStatus.failed => ConnectionVisual(
            label: 'Sync failed',
            color: hollow.error,
            pulse: false,
            filled: false,
          ),
        ServerSyncStatus.idle ||
        ServerSyncStatus.synced ||
        ServerSyncStatus.connecting =>
          visual,
      };
    }

    final statusText = visual.label;
    final statusColor = visual.color;
    final statusPulse = visual.pulse;
    final statusFilled = visual.filled;

    final roomBudget = ref.watch(roomBudgetProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (roomBudget.usage > 0.5)
          _RoomBudgetBar(budget: roomBudget),
        Container(
      // min-height, not a fixed 52: the a11y Phase 3 pattern for chrome bars.
      // Even with the label scale capped at 1.3 below, name + status stacked
      // in a hard 52px box overflowed by 2px at any OS text size >= 1.3 —
      // which desktop passes through unclamped.
      constraints: const BoxConstraints(minHeight: 52),
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
                    // Card's bottom edge just above the user bar; re-read on
                    // resize so it stays there (issue #54).
                    showProfileCardPopup(
                      context: context,
                      ref: ref,
                      peerId: localPeerId,
                      anchorOf: () {
                        final pos = overlayAnchorOf(context);
                        return Offset(pos.dx, pos.dy - 8);
                      },
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
                          // Shape cue: only a settled "Online" is a solid disc.
                          // Everything else is a hollow ring — the adjacent
                          // status word labels it.
                          filled: statusFilled,
                          semanticLabel: statusText,
                        ),
                        const SizedBox(width: HollowSpacing.xs),
                        // Flexible + ellipsis: a bare Text here overflowed
                        // the 240px sidebar by 36px once the OS text size
                        // grew a long status ("Connecting…", "Reconnecting…")
                        // past the room left beside the avatar and the three
                        // trailing icons.
                        Flexible(
                          child: Text(
                            statusText,
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
              onTap: () => showUserSettingsDialog(context),
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
