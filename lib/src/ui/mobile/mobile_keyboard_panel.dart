import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// The space under a phone composer: the software keyboard's inset, or the
/// home indicator's strip when there is no keyboard. Painted in the composer's
/// own colour, so the bar runs to the bottom edge of the screen instead of
/// floating over a band of the canvas.
///
/// The host Scaffold sets `resizeToAvoidBottomInset: false` and its SafeArea
/// `bottom: false`; this widget accounts for both.
class MobileKeyboardSpacer extends StatelessWidget {
  const MobileKeyboardSpacer({super.key});

  @override
  Widget build(BuildContext context) {
    // The padding already drops to zero while a keyboard covers the strip.
    final height = MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.paddingOf(context).bottom;
    return ColoredBox(
      color: HollowTheme.of(context).surface,
      child: SizedBox(width: double.infinity, height: height),
    );
  }
}
