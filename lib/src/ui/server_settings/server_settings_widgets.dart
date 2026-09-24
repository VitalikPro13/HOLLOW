import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A chip naming the current choice that opens the others as a menu, at a
/// row's trailing edge.
class SettingsMenuPicker<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;

  /// Null disables the chip.
  final ValueChanged<T>? onChanged;

  /// Names the choice for a screen reader ("Followed for at least").
  final String semanticLabel;

  const SettingsMenuPicker({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.semanticLabel,
  });

  @override
  Widget build(BuildContext context) {
    final current =
        options.where((o) => o.$1 == value).firstOrNull?.$2 ?? options.first.$2;
    return Builder(
      builder: (chipContext) => HollowChip(
        label: current,
        trailingIcon: LucideIcons.chevronDown,
        semanticLabel: '$semanticLabel, $current',
        onTap: onChanged == null
            ? null
            : () => showHollowMenu(
                  context: chipContext,
                  alignEnd: true,
                  anchor: overlayAnchorOf(chipContext,
                      localOffset: Offset(chipContext.size?.width ?? 0,
                          (chipContext.size?.height ?? 0) + HollowSpacing.xs)),
                  builder: (_, _) => [
                    for (final (v, label) in options)
                      HollowMenuItem(
                        label: label,
                        isChecked: v == value,
                        onTap: () => onChanged!(v),
                      ),
                  ],
                ),
      ),
    );
  }
}
