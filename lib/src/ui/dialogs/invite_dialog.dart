import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_copy_field.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// Shows the invite link for the server [serverId]. The link already carries
/// the id, so the id itself is not shown.
void showInviteDialog(BuildContext context, String link, String serverId) {
  showHollowDialog(
    context: context,
    builder: (_) => Consumer(builder: (context, ref, _) {
      final name = ref.watch(serverListProvider)[serverId]?.name ?? '';
      return HollowDialog(
        title: 'Invite link',
        showClose: true,
        width: 420,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HollowDialogText(name.isEmpty
                ? 'Anyone with this link can join your server.'
                : 'Anyone with this link can join $name.'),
            const SizedBox(height: HollowSpacing.lg),
            HollowCopyField(value: link, name: 'invite link', wrap: false),
          ],
        ),
      );
    }),
  );
}
