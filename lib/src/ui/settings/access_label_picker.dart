import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Multi-select picker for ACCESS labels (a channel's Custom visibility /
/// posting gate). Returns the chosen label-id set — empty set = clear the
/// gate back to tier mode — or null on cancel.
Future<Set<String>?> showAccessLabelPicker({
  required BuildContext context,
  required String serverId,
  required String title,
  required Set<String> initial,
}) {
  return showHollowDialog<Set<String>>(
    context: context,
    builder: (_) => _AccessLabelPickerDialog(
      serverId: serverId,
      title: title,
      initial: initial,
    ),
  );
}

class _AccessLabelPickerDialog extends ConsumerStatefulWidget {
  final String serverId;
  final String title;
  final Set<String> initial;

  const _AccessLabelPickerDialog({
    required this.serverId,
    required this.title,
    required this.initial,
  });

  @override
  ConsumerState<_AccessLabelPickerDialog> createState() =>
      _AccessLabelPickerDialogState();
}

class _AccessLabelPickerDialogState
    extends ConsumerState<_AccessLabelPickerDialog> {
  late Set<String> _selected;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initial};
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final labelsAsync = ref.watch(serverLabelsProvider(widget.serverId));
    final accessLabels =
        (labelsAsync.valueOrNull ?? const []).where((l) => l.access).toList();

    return HollowDialog(
      title: widget.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Members holding ANY selected label get access. Admins and the '
            'Owner always have access.',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          if (labelsAsync.isLoading && accessLabels.isEmpty)
            const Center(child: CircularProgressIndicator())
          else if (accessLabels.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(HollowSpacing.lg),
              decoration: BoxDecoration(
                color: hollow.surface.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.shieldCheck,
                      size: 18, color: hollow.textSecondary),
                  const SizedBox(width: HollowSpacing.md),
                  Expanded(
                    child: Text(
                      'No access labels yet. Create one in the Labels tab and '
                      'mark it "Access".',
                      style: HollowTypography.bodySmall.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            )
          else
            // Same grouped-card language as the bulk-access sections so the
            // chips don't float loose on the dialog background.
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(HollowSpacing.lg),
              decoration: BoxDecoration(
                color: hollow.surface.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
              ),
              child: Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  for (final l in accessLabels)
                    LabelChip(
                      label: l,
                      selected: _selected.contains(l.labelId),
                      onTap: () => setState(() {
                        if (!_selected.remove(l.labelId)) {
                          _selected.add(l.labelId);
                        }
                      }),
                    ),
                ],
              ),
            ),
          if (_selected.isEmpty && widget.initial.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(LucideIcons.triangleAlert,
                    size: 14, color: hollow.warning),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(
                    'No labels selected. The channel returns to '
                    'tier-based access.',
                    style: HollowTypography.bodySmall.copyWith(
                      color: hollow.warning,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
