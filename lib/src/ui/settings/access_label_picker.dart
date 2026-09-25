import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';

/// Which gate the picker sets.
enum AccessLabelGate { see, post }

/// The picker's title, owned here so every surface asks the same question.
/// [target] names what the gate is on: "#general", "the channels in General".
String accessLabelPickerTitle(AccessLabelGate gate, String target) =>
    gate == AccessLabelGate.see
        ? 'Who can see $target'
        : 'Who can post in $target';

/// Multi-select picker for a channel's ACCESS labels. Returns the chosen
/// label-id set, where empty clears the gate back to tier mode, or null on
/// cancel.
Future<Set<String>?> showAccessLabelPicker({
  required BuildContext context,
  required String serverId,
  required Set<String> initial,
  AccessLabelGate gate = AccessLabelGate.see,
  String? target,
  @Deprecated('The title comes from gate and target') String? title,
}) {
  return showHollowDialog<Set<String>>(
    context: context,
    builder: (_) => _AccessLabelPickerDialog(
      serverId: serverId,
      // A caller not yet on gate/target keeps its own title until it moves.
      title: target == null && title != null
          ? title
          : accessLabelPickerTitle(gate, target ?? 'this channel'),
      gate: gate,
      initial: initial,
    ),
  );
}

class _AccessLabelPickerDialog extends ConsumerStatefulWidget {
  final String serverId;
  final String title;
  final AccessLabelGate gate;
  final Set<String> initial;

  const _AccessLabelPickerDialog({
    required this.serverId,
    required this.title,
    required this.gate,
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
    final labelsAsync = ref.watch(serverLabelsProvider(widget.serverId));
    final accessLabels =
        (labelsAsync.valueOrNull ?? const []).where((l) => l.access).toList();
    final see = widget.gate == AccessLabelGate.see;

    final Widget labels;
    if (labelsAsync.isLoading && accessLabels.isEmpty) {
      labels = const HollowSpinner.medium();
    } else if (labelsAsync.hasError && accessLabels.isEmpty) {
      labels = const HollowEmptyState(
        dense: true,
        title: "Couldn't load the labels",
        description: 'Close this and try again.',
      );
    } else if (accessLabels.isEmpty) {
      labels = const HollowEmptyState(
        dense: true,
        title: 'No access labels yet',
        description: 'Create one under Labels and mark it Access.',
      );
    } else {
      labels = Wrap(
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
      );
    }

    return HollowDialog(
      title: widget.title,
      width: 420,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(see
              ? 'Members with any of these labels can see it. Admins and the '
                  'owner always can.'
              : 'Members with any of these labels can post. Admins and the '
                  'owner always can.'),
          const SizedBox(height: HollowSpacing.lg),
          labels,
          if (_selected.isEmpty && widget.initial.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.lg),
            HollowDialogText(see
                ? 'With no label chosen, roles decide who can see it again.'
                : 'With no label chosen, roles decide who can post again.'),
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
