import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';

/// The shield beside a person's name in a chat header, shown once their safety
/// number was confirmed out of band. The shape carries it, not the colour.
class VerifiedMark extends StatelessWidget {
  const VerifiedMark({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowTooltip(
      message: 'Verified contact',
      child: Semantics(
        label: 'Verified contact',
        child: Icon(LucideIcons.shieldCheck, size: 16, color: hollow.success),
      ),
    );
  }
}
