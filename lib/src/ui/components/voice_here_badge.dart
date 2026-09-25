import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The small green mark on whatever holds your call, so the call's home is
/// visible from anywhere: a speaker on the server tile whose voice room you
/// are in, a handset on the friend you are calling. [ring] is the surface it
/// sits on.
class VoiceHereBadge extends StatelessWidget {
  final Color ring;
  final IconData icon;
  final String semanticLabel;

  const VoiceHereBadge({
    super.key,
    required this.ring,
    this.icon = LucideIcons.volume2,
    this.semanticLabel = 'Your voice room is here',
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      label: semanticLabel,
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
        child: Icon(icon, size: 10, color: hollow.textOnAccent),
      ),
    );
  }
}
