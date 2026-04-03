import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shows a dialog to create a new channel in a server.
void showCreateChannelDialog(BuildContext context, String serverId) {
  final nameController = TextEditingController();
  var isVoice = false;

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          Future<void> submit() async {
            final name = nameController.text.trim();
            if (name.isEmpty) return;
            Navigator.of(dialogContext).pop();
            await crdt_api.createChannel(
              serverId: serverId,
              name: name,
              category: null,
              channelType: isVoice ? 'voice' : 'text',
            );
          }

          final hollow = HollowTheme.of(dialogContext);

          return HollowDialog(
            title: 'Create Channel',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Choose a type and name for your new channel.',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
                const SizedBox(height: HollowSpacing.lg),
                // Channel type selector
                Row(
                  children: [
                    Expanded(
                      child: _TypeOption(
                        icon: LucideIcons.hash,
                        label: 'Text',
                        isSelected: !isVoice,
                        onTap: () => setState(() => isVoice = false),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: _TypeOption(
                        icon: LucideIcons.volume2,
                        label: 'Voice',
                        isSelected: isVoice,
                        onTap: () => setState(() => isVoice = true),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: HollowSpacing.lg),
                HollowTextField(
                  controller: nameController,
                  hintText: isVoice ? 'General' : 'general',
                  autofocus: true,
                  prefixIcon: Icon(
                      isVoice ? LucideIcons.volume2 : LucideIcons.hash),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              HollowButton.ghost(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              HollowButton.filled(
                onPressed: submit,
                child: const Text('Create'),
              ),
            ],
          );
        },
      );
    },
  );
}

class _TypeOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _TypeOption({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: HollowDurations.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected ? hollow.accentMuted : hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(
            color: isSelected ? hollow.accent : hollow.border,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18,
                color: isSelected ? hollow.accent : hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              label,
              style: HollowTypography.body.copyWith(
                color: isSelected ? hollow.accent : hollow.textSecondary,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
