import 'package:flutter/material.dart';
import 'package:haven/src/rust/api/crdt.dart' as crdt_api;
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_button.dart';
import 'package:haven/src/ui/components/haven_dialog.dart';
import 'package:haven/src/ui/components/haven_text_field.dart';

/// Shows a dialog to create a new server.
void showCreateServerDialog(BuildContext context) {
  final nameController = TextEditingController();

  showHavenDialog(
    context: context,
    builder: (dialogContext) {
      return HavenDialog(
        title: 'Create a Server',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Give your server a name. You can change it later.',
              style: HavenTypography.body.copyWith(
                color: HavenTheme.of(dialogContext).textSecondary,
              ),
            ),
            const SizedBox(height: HavenSpacing.lg),
            HavenTextField(
              controller: nameController,
              hintText: 'My Awesome Server',
              autofocus: true,
              onSubmitted: (_) async {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.of(dialogContext).pop();
                await crdt_api.createServer(name: name);
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
              await crdt_api.createServer(name: name);
            },
            child: const Text('Create'),
          ),
        ],
      );
    },
  );
}
