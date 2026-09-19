import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows a dialog to create a new channel in a server.
///
/// [onCreated] receives the NEW channel's id, so a caller can place it in the
/// layout rather than letting it land unsorted at the bottom.
void showCreateChannelDialog(
  BuildContext context,
  String serverId, {
  void Function(String channelId)? onCreated,
}) {
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
            final channelId = await crdt_api.createChannel(
              serverId: serverId,
              name: name,
              category: null,
              channelType: isVoice ? 'voice' : 'text',
            );
            onCreated?.call(channelId);
          }

          return HollowDialog(
            title: 'Create channel',
            width: 420,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const HollowDialogText(
                  'Choose a type and name for your new channel.',
                ),
                const SizedBox(height: HollowSpacing.lg),
                Row(
                  children: [
                    Expanded(
                      child: HollowChip(
                        expand: true,
                        icon: LucideIcons.hash,
                        label: 'Text',
                        selected: !isVoice,
                        onTap: () => setState(() => isVoice = false),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: HollowChip(
                        expand: true,
                        icon: LucideIcons.volume2,
                        label: 'Voice',
                        selected: isVoice,
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
