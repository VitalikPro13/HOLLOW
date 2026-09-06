import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows a dialog to join or create a server.
void showCreateServerDialog(BuildContext context) {
  final joinController = TextEditingController();
  final nameController = TextEditingController();

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);
      final screenWidth = MediaQuery.sizeOf(dialogContext).width;
      final isCompact = screenWidth < 600;
      final minWidth = isCompact
          ? (screenWidth - HollowSpacing.xl * 2).clamp(0.0, 600.0)
          : 400.0;

      final joinSection = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.logIn, size: 18, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Join a Server',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Paste an invite link or server ID.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: joinController,
            hintText: 'Invite link or server ID',
            autofocus: !isCompact,
            style: HollowTypography.mono.copyWith(
              color: hollow.textPrimary,
              fontSize: 12,
            ),
            onSubmitted: (_) {
              _handleJoin(dialogContext, joinController);
            },
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowButton.filled(
            onPressed: () => _handleJoin(dialogContext, joinController),
            expand: true,
            child: const Text('Join'),
          ),
        ],
      );

      final createSection = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.plus, size: 18, color: hollow.accent),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'Create a Server',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Start your own server. You can invite others later.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          HollowTextField(
            controller: nameController,
            hintText: 'My Awesome Server',
            onSubmitted: (_) {
              _handleCreate(dialogContext, nameController);
            },
          ),
          const SizedBox(height: HollowSpacing.md),
          HollowButton.outline(
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
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                  child: Divider(color: hollow.border, height: 1),
                ),
                createSection,
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: joinSection),
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
                  child: SizedBox(
                    height: 180,
                    child: VerticalDivider(color: hollow.border, width: 1),
                  ),
                ),
                Expanded(child: createSection),
              ],
            );

      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 600, minWidth: minWidth),
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.all(HollowSpacing.lg),
                decoration: BoxDecoration(
                  color: hollow.elevated.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(
                    color: hollow.accent.withValues(alpha: 0.15),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 24,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: HollowPressable(
                        onTap: () => Navigator.of(dialogContext).pop(),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        semanticLabel: 'Close',
                        child: Icon(LucideIcons.x,
                            size: 18, color: hollow.textSecondary),
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(child: body),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

void _handleJoin(BuildContext context, TextEditingController controller) {
  final input = controller.text.trim();
  if (input.isEmpty) return;

  // Accepts a hollow:// link, a web /join# link or a raw server id.
  final serverId = inviteIdFromInput(input, HollowLinkType.serverInvite);

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
