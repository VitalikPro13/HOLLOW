import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Report categories the relay accepts. The wire strings are exact: the relay
/// silently ignores anything else.
const _reportCategories = <(String, String)>[
  ('spam', 'Spam'),
  ('harassment', 'Harassment'),
  ('illegal_content', 'Illegal content'),
  ('impersonation', 'Impersonation'),
];

/// Shows the "Report user" dialog for [masterId]. The report is sent from
/// inside the dialog, so a failure shows there with the pick kept. Reports are
/// deduped server-side, so a repeat submission is safe.
Future<void> showReportUserDialog(
  BuildContext context, {
  required String masterId,
  String? displayName,
}) async {
  final sent = await showHollowDialog<bool>(
    context: context,
    builder: (_) =>
        _ReportUserDialog(masterId: masterId, displayName: displayName),
  );
  if (sent == true && context.mounted) {
    HollowToast.show(context, 'Report sent', type: HollowToastType.success);
  }
}

/// Confirm-then-block flow for [masterId]; resolve a device id at the call
/// site. Reads providers through [context]'s container, so it stays safe when
/// the launching widget was dismissed first.
Future<void> confirmAndBlockUser(
  BuildContext context, {
  required String masterId,
  required String displayName,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final blocked = await showHollowConfirm(
    context: context,
    title: 'Block $displayName?',
    message: "They won't be able to send you friend requests, direct messages, "
        'or call you, and their messages in shared channels are hidden. '
        'They are not notified.',
    confirmLabel: 'Block',
    destructive: true,
    onConfirm: () => container.read(blockedUsersProvider.notifier).block(masterId),
  );
  if (blocked && context.mounted) {
    HollowToast.show(context, 'Blocked $displayName',
        type: HollowToastType.success);
  }
}

/// Unblocks [masterId], with no confirmation.
Future<void> unblockUser(BuildContext context, {required String masterId}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await container.read(blockedUsersProvider.notifier).unblock(masterId);
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't unblock them. Try again.",
          type: HollowToastType.error);
    }
  }
}

class _ReportUserDialog extends StatefulWidget {
  final String masterId;
  final String? displayName;
  const _ReportUserDialog({required this.masterId, this.displayName});

  @override
  State<_ReportUserDialog> createState() => _ReportUserDialogState();
}

class _ReportUserDialogState extends State<_ReportUserDialog>
    with HollowDialogAction {
  String? _selected;

  Future<void> _send() async {
    final category = _selected;
    if (category == null) return;
    final sent = await runDialogAction(
      () => network_api.reportUser(target: widget.masterId, category: category),
      fallback: "Couldn't send the report. Try again.",
    );
    if (sent && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: 'Report user',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(
            widget.displayName != null && widget.displayName!.isNotEmpty
                ? 'Why are you reporting ${widget.displayName}?'
                : 'Why are you reporting this user?',
          ),
          const SizedBox(height: HollowSpacing.md),
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              for (final (value, label) in _reportCategories)
                HollowChip(
                  label: label,
                  selected: _selected == value,
                  onTap: actionRunning
                      ? null
                      : () => setState(() => _selected = value),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          const HollowDialogText(
            'The relay sees your report arrive. It keeps a count per '
            'category, plus a one-way fingerprint only it can check, so the '
            "same report isn't counted twice.",
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _selected == null ? null : _send,
          loading: actionRunning,
          child: const Text('Report'),
        ),
      ],
    );
  }
}
