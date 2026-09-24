import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The small speaker on a server tile whose voice room you are in, so the
/// call's home is visible from anywhere. [ring] is the surface it sits on.
class VoiceHereBadge extends StatelessWidget {
  final Color ring;

  const VoiceHereBadge({super.key, required this.ring});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      label: 'Your voice room is here',
      child: Container(
        width: HollowSpacing.lg + HollowSpacing.xs,
        height: HollowSpacing.lg + HollowSpacing.xs,
        decoration: BoxDecoration(
          color: hollow.success,
          shape: BoxShape.circle,
          border: Border.all(color: ring, width: HollowSpacing.xxs),
        ),
        alignment: Alignment.center,
        // A badge glyph, as AwaitingSetupBadge's: 14 would fill the disc.
        child: Icon(LucideIcons.volume2, size: 10, color: hollow.textOnAccent),
      ),
    );
  }
}
