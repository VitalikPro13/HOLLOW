import 'package:flutter/material.dart';
import 'package:haven/src/rust/api/crdt.dart' as crdt_api;
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Shows a dialog to create a new channel in a server.
void showCreateChannelDialog(BuildContext context, String serverId) {
  final nameController = TextEditingController();

  showHavenDialog(
    context: context,
    builder: (dialogContext) {
      return HavenDialog(
        title: 'Create Channel',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Choose a name for your new channel.',
              style: HavenTypography.body.copyWith(
                color: HavenTheme.of(dialogContext).textSecondary,
              ),
            ),
            const SizedBox(height: HavenSpacing.lg),
            HavenTextField(
              controller: nameController,
              hintText: 'general',
              autofocus: true,
              prefixIcon: const Icon(LucideIcons.hash),
              onSubmitted: (_) async {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.of(dialogContext).pop();
                await crdt_api.createChannel(
                  serverId: serverId,
                  name: name,
                  category: null,
                );
              },
            ),
          ],
        ),
        actions: [
          HavenButton.ghost(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          HavenButton.filled(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) return;
              Navigator.of(dialogContext).pop();
              await crdt_api.createChannel(
                serverId: serverId,
                name: name,
                category: null,
              );
            },
            child: const Text('Create'),
          ),
        ],
      );
    },
  );
}
