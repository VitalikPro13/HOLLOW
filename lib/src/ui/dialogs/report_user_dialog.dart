import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
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

/// How a report dialog ended.
enum ReportOutcome { reported, reportedAndBlocked }

/// Shows the "Report user" dialog for [masterId]; [aboutMessage] words it for
/// a message the person points at. Only [masterId] and the reason leave the
/// device, whatever was pointed at. The report is sent from inside the dialog,
/// so a failure shows there with the pick kept, and the same dialog then
/// offers to block. Reports are deduped server-side, so a repeat is safe.
Future<ReportOutcome?> showReportUserDialog(
  BuildContext context, {
  required String masterId,
  String? displayName,
  bool aboutMessage = false,
}) async {
  final outcome = await showHollowDialog<ReportOutcome>(
    context: context,
    builder: (_) => _ReportUserDialog(
      masterId: masterId,
      displayName: displayName,
      aboutMessage: aboutMessage,
    ),
  );
  if (outcome != null && context.mounted) {
    final name = displayName == null || displayName.isEmpty ? 'them' : displayName;
    HollowToast.show(
      context,
      outcome == ReportOutcome.reportedAndBlocked
          ? 'Report sent and $name blocked'
          : 'Report sent',
      type: HollowToastType.success,
    );
  }
  return outcome;
}

/// The Report action on someone else's message: the report names the author's
/// MASTER identity, never the message. Null for our own messages (any device
/// of ours) and for a sender with no id.
VoidCallback? reportMessageAction(
  BuildContext context, {
  required bool isMe,
  required String senderMaster,
  required String displayName,
}) {
  final self = ProviderScope.containerOf(context, listen: false)
      .read(savedMessagesPeerIdProvider);
  if (isMe || senderMaster.isEmpty || senderMaster == self) return null;
  return () => showReportUserDialog(context,
      masterId: senderMaster, displayName: displayName, aboutMessage: true);
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
    message: blockConsequences,
    confirmLabel: 'Block',
    destructive: true,
    onConfirm: () => container.read(blockedUsersProvider.notifier).block(masterId),
  );
  if (blocked && context.mounted) {
    HollowToast.show(context, 'Blocked $displayName',
        type: HollowToastType.success);
  }
}

/// What a block does, said the same way wherever someone is blocked.
const blockConsequences =
    "They can't send you friend requests or direct messages, or call you. "
    'Their messages are hidden, and so is your conversation with them. They '
    'are not told. Our relay adds one to an anonymous count against them and '
    'keeps no record that it was you.';

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
  final bool aboutMessage;
  const _ReportUserDialog({
    required this.masterId,
    this.displayName,
    this.aboutMessage = false,
  });

  @override
  State<_ReportUserDialog> createState() => _ReportUserDialogState();
}

class _ReportUserDialogState extends State<_ReportUserDialog>
    with HollowDialogAction {
  String? _selected;
  bool _offeringBlock = false;

  String? get _name {
    final name = widget.displayName;
    return name == null || name.isEmpty ? null : name;
  }

  Future<void> _send() async {
    final category = _selected;
    if (category == null) return;
    final sent = await runDialogAction(
      () => network_api.reportUser(target: widget.masterId, category: category),
      fallback: "Couldn't send the report. Try again.",
    );
    if (!sent || !mounted) return;
    final container = ProviderScope.containerOf(context, listen: false);
    if (container.read(blockedUsersProvider).contains(widget.masterId)) {
      Navigator.of(context).pop(ReportOutcome.reported);
      return;
    }
    setState(() {
      actionRunning = false;
      _offeringBlock = true;
    });
  }

  Future<void> _block() async {
    final container = ProviderScope.containerOf(context, listen: false);
    final blocked = await runDialogAction(
      () => container.read(blockedUsersProvider.notifier).block(widget.masterId),
      fallback: "Couldn't block them. Try again.",
    );
    if (blocked && mounted) {
      Navigator.of(context).pop(ReportOutcome.reportedAndBlocked);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _offeringBlock ? _blockStep() : _reportStep();
  }

  Widget _blockStep() {
    return HollowDialog(
      title: 'Report sent',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(_name != null
              ? 'Do you also want to block $_name?'
              : 'Do you also want to block this user?'),
          const SizedBox(height: HollowSpacing.md),
          const HollowDialogText(blockConsequences),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning
              ? null
              : () => Navigator.of(context).pop(ReportOutcome.reported),
          child: const Text('Not now'),
        ),
        HollowButton.danger(
          onPressed: _block,
          loading: actionRunning,
          child: const Text('Block'),
        ),
      ],
    );
  }

  Widget _reportStep() {
    final name = _name;
    final String question;
    if (widget.aboutMessage) {
      question = name != null
          ? 'Why are you reporting this message from $name?'
          : 'Why are you reporting this message?';
    } else {
      question = name != null
          ? 'Why are you reporting $name?'
          : 'Why are you reporting this user?';
    }
    return HollowDialog(
      title: widget.aboutMessage ? 'Report message' : 'Report user',
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(question),
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
          HollowDialogText(
            widget.aboutMessage
                ? 'Our relay gets only the reason and who sent the message. '
                    'The message itself never leaves this device. The relay '
                    'keeps a count per category, plus a one-way fingerprint '
                    "only it can check, so the same report isn't counted twice."
                : 'The relay sees your report arrive. It keeps a count per '
                    'category, plus a one-way fingerprint only it can check, '
                    "so the same report isn't counted twice.",
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
