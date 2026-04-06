import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shows a dialog to join or create a server.
void showCreateServerDialog(BuildContext context) {
  final joinController = TextEditingController();
  final nameController = TextEditingController();

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);

      return Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600, minWidth: 400),
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
                    // Close button row
                    Align(
                      alignment: Alignment.centerRight,
                      child: HollowPressable(
                        onTap: () => Navigator.of(dialogContext).pop(),
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(LucideIcons.x, size: 18, color: hollow.textSecondary),
                      ),
                    ),
                    Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left side — Join a server
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(LucideIcons.logIn, size: 18,
                                  color: hollow.accent),
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
                            hintText: 'hollow://join?server=... or ID',
                            autofocus: true,
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
                            onPressed: () => _handleJoin(
                                dialogContext, joinController),
                            expand: true,
                            child: const Text('Join'),
                          ),
                        ],
                      ),
                    ),

                    // Vertical divider
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: HollowSpacing.lg),
                      child: SizedBox(
                        height: 180,
                        child: VerticalDivider(
                          color: hollow.border,
                          width: 1,
                        ),
                      ),
                    ),

                    // Right side — Create a server
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(LucideIcons.plus, size: 18,
                                  color: hollow.accent),
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
                            onPressed: () => _handleCreate(
                                dialogContext, nameController),
                            expand: true,
                            child: const Text('Create'),
                          ),
                        ],
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
      );
    },
  );
}

void _handleJoin(BuildContext context, TextEditingController controller) {
  final input = controller.text.trim();
  if (input.isEmpty) return;

  // Parse invite link or raw server ID.
  String serverId;
  final uri = Uri.tryParse(input);
  if (uri != null &&
      uri.scheme == 'hollow' &&
      uri.queryParameters.containsKey('server')) {
    serverId = uri.queryParameters['server']!;
  } else {
    serverId = input;
  }

  final overlayContext = Navigator.of(context).context;
  Navigator.of(context).pop();
  crdt_api.joinServer(serverId: serverId);
  HollowToast.show(overlayContext, 'Joining server...',
      type: HollowToastType.info);
}

void _handleCreate(
    BuildContext context, TextEditingController controller) async {
  final name = controller.text.trim();
  if (name.isEmpty) return;
  Navigator.of(context).pop();
  await crdt_api.createServer(name: name);
}
