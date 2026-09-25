import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// The preset lengths every "for how long" choice offers; null is "until I
/// remove it".
const kHollowDurationPresets = <Duration?>[
  Duration(minutes: 10),
  Duration(minutes: 15),
  Duration(hours: 1),
  Duration(hours: 24),
  Duration(days: 7),
  null,
];

/// A length as the picker and its toasts say it: "10 minutes", "1 hour",
/// "7 days", and "until I remove it" for null (lower case, for a sentence).
String hollowDurationLabel(Duration? duration) {
  if (duration == null) return 'until I remove it';
  String unit(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
  if (duration.inDays >= 2 && duration.inHours % 24 == 0) {
    return unit(duration.inDays, 'day');
  }
  if (duration.inHours >= 1 && duration.inMinutes % 60 == 0) {
    return unit(duration.inHours, 'hour');
  }
  return unit(duration.inMinutes, 'minute');
}

/// "For how long" as one [HollowChip] row: pick a preset, and the dialog's
/// ONE filled confirm acts on it. [value] null is "Until I remove it", which
/// is a choice like any other, never drawn in red.
class HollowDurationPicker extends StatelessWidget {
  final Duration? value;
  final ValueChanged<Duration?>? onChanged;
  final List<Duration?> presets;

  const HollowDurationPicker({
    super.key,
    required this.value,
    required this.onChanged,
    this.presets = kHollowDurationPresets,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.sm,
      children: [
        for (final preset in presets)
          Semantics(
            selected: preset == value,
            inMutuallyExclusiveGroup: true,
            child: HollowChip(
              label: _chipLabel(preset),
              selected: preset == value,
              onTap: onChanged == null ? null : () => onChanged!(preset),
            ),
          ),
      ],
    );
  }

  static String _chipLabel(Duration? preset) =>
      preset == null ? 'Until I remove it' : hollowDurationLabel(preset);
}

/// Asks "for how long", then runs [onConfirm] with the choice inside the
/// dialog: the confirm loads while it runs, a throw shows the reason above the
/// actions. Resolves true once [onConfirm] finished, false on Cancel.
Future<bool> showHollowDurationDialog({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  required Future<void> Function(Duration? duration) onConfirm,
  Duration? initial = const Duration(hours: 1),
  List<Duration?> presets = kHollowDurationPresets,
}) async {
  final done = await showHollowDialog<bool>(
    context: context,
    builder: (_) => _DurationDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      onConfirm: onConfirm,
      initial: initial,
      presets: presets,
    ),
  );
  return done ?? false;
}

class _DurationDialog extends StatefulWidget {
  final String title;
  final String message;
  final String confirmLabel;
  final Future<void> Function(Duration? duration) onConfirm;
  final Duration? initial;
  final List<Duration?> presets;

  const _DurationDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.onConfirm,
    required this.initial,
    required this.presets,
  });

  @override
  State<_DurationDialog> createState() => _DurationDialogState();
}

class _DurationDialogState extends State<_DurationDialog>
    with HollowDialogAction {
  late Duration? _value = widget.initial;

  Future<void> _confirm() async {
    if (await runDialogAction(() => widget.onConfirm(_value)) && mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return HollowDialog(
      title: widget.title,
      width: 420,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText(widget.message),
          const SizedBox(height: HollowSpacing.lg),
          HollowDurationPicker(
            value: _value,
            presets: widget.presets,
            // Ignored while running rather than disabled, so the row does not
            // fade under the spinner.
            onChanged: (d) {
              if (actionRunning) return;
              setState(() {
                _value = d;
                actionError = null;
              });
            },
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed:
              actionRunning ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _confirm,
          loading: actionRunning,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
