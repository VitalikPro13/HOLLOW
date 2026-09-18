import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';

/// A key combination such as "Ctrl + Shift + M", one mono badge per key.
///
/// The Shortcuts page and the keybind capture field both render bindings, and
/// a binding has to look the same wherever the user meets it.
class HollowKeyCombo extends StatelessWidget {
  /// Keys joined by " + ", the format a binding's `display()` produces.
  final String display;

  const HollowKeyCombo(this.display, {super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final keys = display.split(' + ');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < keys.length; i++) ...[
          if (i > 0)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: HollowSpacing.xxs),
              child: Text(
                '+',
                style: HollowTypography.micro
                    .copyWith(color: hollow.textTertiary),
              ),
            ),
          HollowBadge(keys[i], kind: HollowBadgeKind.mono),
        ],
      ],
    );
  }
}
