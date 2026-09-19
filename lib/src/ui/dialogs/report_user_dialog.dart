import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
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

/// Shows the "Report user" dialog for [masterId], then files the report.
///
/// The dialog only picks a category; the FFI call and toast run against
/// [context], which outlives it. Reports are deduped server-side, so a repeat
/// submission is safe.
Future<void> showReportUserDialog(
  BuildContext context, {
  required String masterId,
  String? displayName,
}) async {
  final category = await showHollowDialog<String>(
    context: context,
    builder: (_) => _ReportUserDialog(displayName: displayName),
  );
  if (category == null || !context.mounted) return;
  try {
    await network_api.reportUser(target: masterId, category: category);
    if (context.mounted) {
      HollowToast.show(context, 'Report submitted',
          type: HollowToastType.success);
    }
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't send report",
          type: HollowToastType.error);
    }
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
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Block $displayName?',
    message: "They won't be able to send you friend requests, direct messages, "
        'or call you, and their messages in shared channels are hidden. '
        'They are not notified.',
    confirmLabel: 'Block',
    destructive: true,
  );
  if (!confirmed || !context.mounted) return;
  try {
    await container.read(blockedUsersProvider.notifier).block(masterId);
    if (context.mounted) {
      HollowToast.show(context, 'User blocked', type: HollowToastType.success);
    }
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, 'Failed to block', type: HollowToastType.error);
    }
  }
}

/// Unblocks [masterId], with no confirmation.
Future<void> unblockUser(BuildContext context, {required String masterId}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await container.read(blockedUsersProvider.notifier).unblock(masterId);
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, 'Failed to unblock',
          type: HollowToastType.error);
    }
  }
}

class _ReportUserDialog extends StatefulWidget {
  final String? displayName;
  const _ReportUserDialog({this.displayName});

  @override
  State<_ReportUserDialog> createState() => _ReportUserDialogState();
}

class _ReportUserDialogState extends State<_ReportUserDialog> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Report user',
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
                  onTap: () => setState(() => _selected = value),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          Text(
            'Reports are anonymous: the relay only keeps a per-category '
            'counter, never who reported whom.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _selected == null
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: const Text('Report'),
        ),
      ],
    );
  }
}
