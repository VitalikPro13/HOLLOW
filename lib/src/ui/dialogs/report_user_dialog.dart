import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Report categories the relay accepts. The wire strings are exact — the
/// relay silently ignores anything else.
const _reportCategories = <(String, String)>[
  ('spam', 'Spam'),
  ('harassment', 'Harassment'),
  ('illegal_content', 'Illegal content'),
  ('impersonation', 'Impersonation'),
];

/// Show the "Report user" dialog for [masterId], then file the report.
///
/// The dialog only picks a category (pops with the wire string); the FFI call
/// + toast run here against [context], which outlives the dialog. Reports are
/// deduped server-side (one per reporter per target per category), so repeat
/// submissions are safe.
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

/// Confirm-then-block flow for [masterId] (pass the MASTER id — resolve
/// device ids at the call site). Reads providers through the container of
/// [context] so it stays safe even when the launching widget (hover popup /
/// profile dialog) was dismissed first.
Future<void> confirmAndBlockUser(
  BuildContext context, {
  required String masterId,
  required String displayName,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Block $displayName?',
      content: Text(
        'They won\'t be able to send you friend requests, direct messages, '
        'or call you, and their messages in shared channels are hidden. '
        'They are not notified.',
        style: HollowTypography.body
            .copyWith(color: HollowTheme.of(ctx).textSecondary),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Block'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
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

/// Unblock [masterId] — no confirmation needed.
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
          Text(
            widget.displayName != null && widget.displayName!.isNotEmpty
                ? 'Why are you reporting ${widget.displayName}?'
                : 'Why are you reporting this user?',
            style: HollowTypography.body
                .copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          for (final (value, label) in _reportCategories)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
              child: _ReasonRow(
                label: label,
                selected: _selected == value,
                onTap: () => setState(() => _selected = value),
              ),
            ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Reports are anonymous: the relay only keeps a per-category '
            'counter, never who reported whom.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
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

/// A selectable reason row — selection state is a tinted chip-style border,
/// never a filled button.
class _ReasonRow extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReasonRow({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      selected: selected,
      child: HollowPressable(
        onTap: onTap,
        subtle: true,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        backgroundColor: null,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected ? hollow.accent.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(
              color: selected ? hollow.accent : hollow.border,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected ? LucideIcons.circleCheck : LucideIcons.circle,
                size: 16,
                color: selected ? hollow.accentText : hollow.textSecondary,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  label,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
