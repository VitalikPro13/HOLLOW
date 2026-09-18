import 'package:flutter/material.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The slow-mode intervals offered in channel settings, in seconds.
const kSlowModeOptions = [0, 5, 10, 30, 60, 300, 900, 3600];

/// Label names are free-form user content, so an access chip stops growing
/// here and ellipsizes.
const double _maxChipWidth = 120;

/// Who can see or post in a channel, as a chip that opens its choices.
/// Desktop channel settings and the mobile route share it, so the two cannot
/// drift apart.
class ChannelAccessPicker extends StatelessWidget {
  final IconData icon;

  /// `everyone`, `moderator` or `admin`. Ignored while [gateLabels] is set.
  final String value;
  final List<String> gateLabels;
  final List<crdt_api.LabelFfi> allLabels;
  final Future<void> Function(String) onChanged;
  final VoidCallback onCustomPressed;

  /// Spoken instead of the short visible value ("Mod+").
  final String semanticLabel;

  const ChannelAccessPicker({
    super.key,
    required this.icon,
    required this.value,
    required this.onChanged,
    required this.onCustomPressed,
    required this.semanticLabel,
    this.gateLabels = const [],
    this.allLabels = const [],
  });

  bool get _gated => gateLabels.isNotEmpty;

  String get _label {
    if (_gated) {
      if (gateLabels.length == 1) {
        final match =
            allLabels.where((l) => l.labelId == gateLabels.first).firstOrNull;
        return match?.name ?? '1 label';
      }
      return '${gateLabels.length} labels';
    }
    return switch (value) {
      'moderator' => 'Mod+',
      'admin' => 'Admin+',
      _ => 'All',
    };
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _maxChipWidth),
      child: Builder(
        builder: (chipContext) => HollowChip(
          icon: _gated ? LucideIcons.shieldCheck : icon,
          label: _label,
          trailingIcon: LucideIcons.chevronDown,
          semanticLabel: '$semanticLabel, $_label',
          onTap: () => showHollowMenu(
            context: chipContext,
            anchor: _below(chipContext),
            builder: (_, _) => [
              _item('everyone', 'Everyone'),
              _item('moderator', 'Mod+'),
              _item('admin', 'Admin+'),
              HollowMenuItem(
                label: 'Custom…',
                isChecked: _gated,
                onTap: onCustomPressed,
              ),
            ],
          ),
        ),
      ),
    );
  }

  HollowMenuItem _item(String val, String label) => HollowMenuItem(
        label: label,
        isChecked: !_gated && val == value,
        onTap: () => onChanged(val),
      );
}

/// The minimum delay between one member's messages, as a chip that opens the
/// intervals.
class SlowModePicker extends StatelessWidget {
  final int seconds;
  final Future<void> Function(int) onChanged;

  const SlowModePicker({
    super.key,
    required this.seconds,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final label = seconds > 0
        ? 'Slow ${slowModeDurationLabel(seconds)}'
        : 'Slow mode';
    return Builder(
      builder: (chipContext) => HollowChip(
        icon: LucideIcons.timer,
        label: label,
        trailingIcon: LucideIcons.chevronDown,
        semanticLabel: seconds > 0
            ? 'Slow mode, ${slowModeDurationLabel(seconds)}'
            : 'Slow mode, off',
        onTap: () => showHollowMenu(
          context: chipContext,
          anchor: _below(chipContext),
          builder: (_, _) => [
            for (final s in kSlowModeOptions)
              HollowMenuItem(
                label: slowModeDurationLabel(s),
                isChecked: s == seconds,
                onTap: () => onChanged(s),
              ),
          ],
        ),
      ),
    );
  }
}

Offset _below(BuildContext context) => overlayAnchorOf(
      context,
      localOffset: Offset(0, (context.size?.height ?? 0) + HollowSpacing.xs),
    );
