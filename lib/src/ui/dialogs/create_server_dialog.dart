import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';

/// Shows a dialog to join or create a server.
void showCreateServerDialog(BuildContext context) {
  final joinController = TextEditingController();
  final nameController = TextEditingController();

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);
      final isCompact = MediaQuery.sizeOf(dialogContext).width <
          HollowDialogSurface.compactBreakpoint;

      // Two separate regions, each with its own filled primary: the person
      // picks a region, never both, so neither button outranks the other.
      final joinSection = Consumer(builder: (context, joinRef, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowSectionHeader(
            'Join a Server',
            subtitle: 'Paste an invite link or server ID.',
          ),
          HollowTextField(
            controller: joinController,
            hintText: 'Invite link or server ID',
            autofocus: !isCompact,
            style: HollowTypography.mono.copyWith(color: hollow.textPrimary),
            onSubmitted: (_) {
              _handleJoin(dialogContext, joinRef, joinController);
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
          HollowButton.filled(
            onPressed: () => _handleJoin(dialogContext, joinRef, joinController),
            expand: true,
            child: const Text('Join'),
          ),
        ],
      ));

      final createSection = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowSectionHeader(
            'Create a Server',
            subtitle: 'Start your own server. You can invite others later.',
          ),
          HollowTextField(
            controller: nameController,
            hintText: 'My Awesome Server',
            onSubmitted: (_) {
              _handleCreate(dialogContext, nameController);
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
          HollowButton.filled(
            onPressed: () => _handleCreate(dialogContext, nameController),
            expand: true,
            child: const Text('Create'),
          ),
        ],
      );

      // Stacked on a phone, two columns on desktop.
      final body = isCompact
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                joinSection,
                const Padding(
                  padding:
                      EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                  child: HollowDivider(),
                ),
                createSection,
              ],
            )
          : IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: joinSection),
                  const Padding(
                    padding:
                        EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
                    child: HollowVerticalDivider(),
                  ),
                  Expanded(child: createSection),
                ],
              ),
            );

      return HollowDialog(
        title: 'Add a server',
        showClose: true,
        width: 600,
        content: body,
      );
    },
  );
}

Future<void> _handleJoin(BuildContext context, WidgetRef ref,
    TextEditingController controller) async {
  final input = controller.text.trim();
  if (input.isEmpty) return;

  // Accepts a hollow:// link, a web /join# link or a raw server id.
  final invite = inviteFromInput(input, HollowLinkType.serverInvite);
  final serverId = invite.id;

  if (!await ensureRelayForInviteId(context, ref,
      type: HollowLinkType.serverInvite, id: serverId, relay: invite.relay)) {
    return;
  }
  if (!context.mounted) return;
  Navigator.of(context).pop();
  // Fire-and-forget FFI: an un-awaited Future's rejection hits the zone crash
  // handler (feedback_ffi_fire_and_forget_catcherror).
  crdt_api.joinServer(serverId: serverId, nsfwConfirmed: false)
      .catchError((_) {});
  // The dialog is popped, so its contexts may have no Overlay above them and
  // Overlay.of on a dead one crashes. Ride the root navigator's overlay
  // instead (feedback_toast_from_nonwidget_overlaystate).
  final overlay = hollowNavigatorKey.currentState?.overlay;
  final overlayContext = overlay?.context;
  if (overlay != null && overlayContext != null && overlayContext.mounted) {
    HollowToast.show(overlayContext, 'Joining server...',
        type: HollowToastType.info, overlayState: overlay);
  }
}

void _handleCreate(
    BuildContext context, TextEditingController controller) async {
  final name = controller.text.trim();
  if (name.isEmpty) return;
  Navigator.of(context).pop();
  await crdt_api.createServer(name: name);
}
