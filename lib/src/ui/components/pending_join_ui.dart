/// Everything a parked server join looks like, on every surface.
///
/// A parked join has no name, no icon and no channels: an invite link carries
/// an id and nothing else, and nobody has answered yet. So the tile cannot
/// explain itself the way a server icon does, and this menu has to. It opens
/// on LEFT click as well as right click, because a tile that does nothing when
/// you click it reads as broken.
///
/// Desktop gets [showPendingJoinMenu] (the shared `showHollowMenu` surface),
/// mobile gets [showPendingJoinSheet] (the bottom-sheet idiom used by the
/// server and DM rows). Both are built from the SAME action helpers below, so
/// a row that exists on one and not the other cannot happen.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/services/pending_join_ffi.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What the tile, the row and the menu all call the two states.
String pendingJoinTitle({required bool rejected}) =>
    rejected ? 'Join request declined' : 'Join request pending';

/// The sentence under that title.
String pendingJoinSubtitle({required bool rejected, required String reason}) =>
    rejected
        ? pendingJoinReasonText(reason)
        : 'You will be added when a member comes online';

/// The longer form, for the menu header where there is room for it.
String pendingJoinExplanation(
        {required bool rejected, required String reason}) =>
    rejected
        ? pendingJoinReasonText(reason)
        : 'You will be added as soon as a member of this server comes online.';

/// What the flair on an admitted-but-not-yet-set-up server says.
const String kAwaitingSetupTooltip = 'Waiting for a member to finish setup';

/// The flair itself: a 10px clock in a ring the colour of the surface behind
/// it, so it reads as a badge rather than as part of the icon.
///
/// It is a BADGE, not a spinner. The wait is for another human to open the
/// app, which can be tomorrow.
class AwaitingSetupBadge extends StatelessWidget {
  final double size;

  const AwaitingSetupBadge({super.key, this.size = 16});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      label: kAwaitingSetupTooltip,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: hollow.elevated,
          shape: BoxShape.circle,
          border: Border.all(color: hollow.background, width: 2),
        ),
        alignment: Alignment.center,
        child: Icon(LucideIcons.clock, size: 10, color: hollow.textSecondary),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Desktop menu
// ---------------------------------------------------------------------------

/// Opens the parked-join menu at [anchor] (already in OVERLAY space).
void showPendingJoinMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
  required Offset anchor,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    // `menuRef` deliberately not named `ref`: it dies with the menu, and every
    // row below runs after the menu closes.
    builder: (menuContext, menuRef) {
      final info = menuRef.watch(pendingJoinsProvider)[serverId];
      final rejected = info?.isRejected ?? false;
      final reason = info?.reason ?? '';

      return <HollowMenuEntry>[
        HollowMenuNote(
          pendingJoinExplanation(rejected: rejected, reason: reason),
        ),
        const HollowMenuDivider(),
        if (rejected)
          HollowMenuItem(
            icon: LucideIcons.rotateCcw,
            label: 'Request again',
            onTap: () => retryPendingJoinAction(context, ref, serverId),
          ),
        HollowMenuItem(
          icon: LucideIcons.link,
          label: 'Copy invite link',
          onTap: () => copyPendingJoinInvite(context, serverId),
        ),
        HollowMenuItem(
          icon: LucideIcons.trash2,
          label: rejected ? 'Remove' : 'Discard request',
          isDanger: true,
          onTap: () => discardPendingJoinAction(context, ref, serverId),
        ),
      ];
    },
  );
}

// ---------------------------------------------------------------------------
// Mobile sheet
// ---------------------------------------------------------------------------

/// The same actions as [showPendingJoinMenu], in the mobile idiom.
void showPendingJoinSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
}) {
  final hollow = HollowTheme.of(context);
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: hollow.surface,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(hollow.radiusLg)),
    ),
    // The callbacks close over the OPENING surface's context and ref: the
    // sheet is gone by the time an action runs, so a toast anchored to the
    // sheet's own context would never appear. (Nothing takes a `WidgetRef` as
    // a constructor parameter here either.)
    builder: (sheetContext) => SafeArea(
      child: _PendingJoinSheet(
        serverId: serverId,
        onRetry: () {
          Navigator.pop(sheetContext);
          retryPendingJoinAction(context, ref, serverId);
        },
        onCopy: () {
          Navigator.pop(sheetContext);
          copyPendingJoinInvite(context, serverId);
        },
        onDiscard: () {
          Navigator.pop(sheetContext);
          discardPendingJoinAction(context, ref, serverId);
        },
      ),
    ),
  );
}

class _PendingJoinSheet extends ConsumerWidget {
  final String serverId;
  final VoidCallback onRetry;
  final VoidCallback onCopy;
  final VoidCallback onDiscard;

  const _PendingJoinSheet({
    required this.serverId,
    required this.onRetry,
    required this.onCopy,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final info = ref.watch(pendingJoinsProvider)[serverId];
    final rejected = info?.isRejected ?? false;
    final reason = info?.reason ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: hollow.textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pendingJoinTitle(rejected: rejected),
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  pendingJoinExplanation(rejected: rejected, reason: reason),
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          if (rejected)
            _SheetRow(
              icon: LucideIcons.rotateCcw,
              label: 'Request again',
              onTap: onRetry,
            ),
          _SheetRow(
            icon: LucideIcons.link,
            label: 'Copy invite link',
            onTap: onCopy,
          ),
          _SheetRow(
            icon: LucideIcons.trash2,
            label: rejected ? 'Remove' : 'Discard request',
            danger: true,
            onTap: onDiscard,
          ),
        ],
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _SheetRow({
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
          Text(label, style: HollowTypography.body.copyWith(color: color)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

/// The invite is all we have of this server, so copying it is how the user
/// asks somebody who IS a member to come online.
void copyPendingJoinInvite(BuildContext context, String serverId) {
  Clipboard.setData(ClipboardData(text: webServerInviteLink(serverId)));
  HollowToast.show(context, 'Invite link copied',
      type: HollowToastType.success);
}

/// Drops the request. Awaited and toasted either way: a discard that silently
/// failed would leave a tile the user believes they removed.
Future<void> discardPendingJoinAction(
  BuildContext context,
  WidgetRef ref,
  String serverId,
) async {
  try {
    await discardPendingJoin(serverId);
    // Rust also emits `PendingJoinUpdated{discarded}`; removing here as well is
    // idempotent and keeps the tile from lingering for a round trip.
    ref.read(pendingJoinsProvider.notifier).remove(serverId);
    if (!context.mounted) return;
    HollowToast.show(context, 'Join request discarded',
        type: HollowToastType.info);
  } catch (e) {
    if (!context.mounted) return;
    HollowToast.show(context, 'Could not discard the request: $e',
        type: HollowToastType.error);
  }
}

/// Asks again after a rejection.
Future<void> retryPendingJoinAction(
  BuildContext context,
  WidgetRef ref,
  String serverId,
) async {
  try {
    await retryPendingJoin(serverId);
    ref.read(pendingJoinsProvider.notifier).markRequestedAgain(serverId);
    if (!context.mounted) return;
    HollowToast.show(context, 'Join request sent again',
        type: HollowToastType.info);
  } catch (e) {
    if (!context.mounted) return;
    HollowToast.show(context, 'Could not send the request: $e',
        type: HollowToastType.error);
  }
}
