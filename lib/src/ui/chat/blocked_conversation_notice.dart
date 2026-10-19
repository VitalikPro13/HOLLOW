import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Stands in for a DM with someone we blocked, messages and composer both, so
/// their content leaves the screen the moment the block lands. Unblocking
/// brings the stored history back.
class BlockedConversationNotice extends StatelessWidget {
  final String masterId;
  final String displayName;

  /// Touch-size action on a phone.
  final bool touch;

  const BlockedConversationNotice({
    super.key,
    required this.masterId,
    required this.displayName,
    this.touch = false,
  });

  @override
  Widget build(BuildContext context) {
    return HollowEmptyState(
      glyph: LucideIcons.ban,
      title: 'You blocked $displayName',
      description:
          'Their messages are hidden. Unblock them to see this conversation again.',
      action: HollowButton.outline(
        touch: touch,
        onPressed: () => unblockUser(context, masterId: masterId),
        child: const Text('Unblock'),
      ),
    );
  }
}
