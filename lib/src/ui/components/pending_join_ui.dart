/// Everything a parked server join looks like, on every surface.
///
/// A parked join has no name, no icon and no channels, so the tile cannot
/// explain itself and this menu has to. It opens on LEFT click as well as
/// right click, because a tile that does nothing when clicked reads as broken.
///
/// Desktop uses [showPendingJoinMenu] and mobile [showPendingJoinSheet], both
/// built from the SAME action helpers, so the two cannot drift apart.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/pending_join_info.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/services/pending_join_ffi.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';

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

/// A 10px clock in a ring the colour of the surface behind it, so it reads as a
/// badge rather than as part of the icon. A BADGE, not a spinner: the wait is
/// for another human to open the app, which can be tomorrow.
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
          border: Border.all(color: hollow.surface, width: 2),
        ),
        alignment: Alignment.center,
        child: Icon(LucideIcons.clock, size: 10, color: hollow.textSecondary),
      ),
    );
  }
}

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
          onTap: () => copyPendingJoinInvite(context, ref, serverId),
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

/// The same actions as [showPendingJoinMenu], in the mobile idiom.
void showPendingJoinSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
}) {
  showHollowSheet<void>(
    context: context,
    // The callbacks close over the OPENING surface's context and ref, because
    // the sheet is gone by the time an action runs and a toast anchored to its
    // context would never appear.
    builder: (sheetContext) => SafeArea(
      child: _PendingJoinSheet(
        serverId: serverId,
        onRetry: () {
          Navigator.pop(sheetContext);
          retryPendingJoinAction(context, ref, serverId);
        },
        onCopy: () {
          Navigator.pop(sheetContext);
          copyPendingJoinInvite(context, ref, serverId);
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

    Widget row(IconData icon, String label, VoidCallback onTap) =>
        HollowListRow(
          touch: true,
          title: label,
          leading: Icon(icon, size: 20, color: hollow.textSecondary),
          onTap: onTap,
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HollowSheetTitle(pendingJoinTitle(rejected: rejected)),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, 0, HollowSpacing.lg, HollowSpacing.sm),
          child: Text(
            pendingJoinExplanation(rejected: rejected, reason: reason),
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        ),
        if (rejected) row(LucideIcons.rotateCcw, 'Request again', onRetry),
        row(LucideIcons.link, 'Copy invite link', onCopy),
        row(LucideIcons.trash2, rejected ? 'Remove' : 'Discard request',
            onDiscard),
        const SizedBox(height: HollowSpacing.sm),
      ],
    );
  }
}

/// The invite is all we have of this server, so copying it is how the user
/// asks somebody who IS a member to come online.
void copyPendingJoinInvite(
    BuildContext context, WidgetRef ref, String serverId) {
  Clipboard.setData(ClipboardData(
      text: webServerInviteLink(serverId,
          relay: ref.read(relayDomainProvider))));
  HollowToast.show(context, 'Invite link copied',
      type: HollowToastType.success);
}

/// Drops the request. Awaited and toasted either way, or a silent failure
/// leaves a tile the user believes they removed.
Future<void> discardPendingJoinAction(
  BuildContext context,
  WidgetRef ref,
  String serverId,
) async {
  try {
    await discardPendingJoin(serverId);
    // Rust also emits `PendingJoinUpdated{discarded}`, so this is idempotent
    // and only saves the tile a round trip.
    ref.read(pendingJoinsProvider.notifier).remove(serverId);
    if (!context.mounted) return;
    HollowToast.show(context, 'Join request discarded',
        type: HollowToastType.info);
  } catch (e) {
    if (!context.mounted) return;
    HollowToast.show(context,
        friendlyError(e, fallback: "Couldn't discard the request. Try again."),
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
    HollowToast.show(context,
        friendlyError(e, fallback: "Couldn't send the request. Try again."),
        type: HollowToastType.error);
  }
}
