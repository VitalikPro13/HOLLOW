import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/lost_call_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The glyph for a link in trouble, as `LinkHealthChip` draws it.
IconData linkTroubleIcon(LinkHealth health) =>
    health == LinkHealth.unstable ? LucideIcons.wifiLow : LucideIcons.wifiOff;

/// A lost link is an error, one still trying a warning.
HollowBadgeKind linkTroubleBadgeKind(LinkHealth health) =>
    health == LinkHealth.lost ? HollowBadgeKind.error : HollowBadgeKind.warning;

Color linkTroubleColor(HollowTheme hollow, LinkHealth health) =>
    health == LinkHealth.lost ? hollow.error : hollow.warning;

/// The DM call with [peerMaster] that its link ended, while nothing else is on
/// the line: its surfaces keep saying "Connection lost" for a few seconds.
LostCall? lostDmCallWith(WidgetRef ref, String peerMaster) {
  final lost = ref.watch(lostCallProvider);
  if (lost == null || lost.peerMaster != peerMaster) return null;
  final idle =
      ref.watch(callProvider.select((c) => c.status)) == CallStatus.idle;
  return idle ? lost : null;
}

/// "Connection lost", for the surfaces a lost call lingers on.
HollowBadge lostCallMark() => HollowBadge('Connection lost',
    kind: linkTroubleBadgeKind(LinkHealth.lost),
    icon: linkTroubleIcon(LinkHealth.lost));

/// The seconds left before a lost call's surface goes. Visual only: the
/// surface already says what happened.
class LostCallCountdown extends StatelessWidget {
  final LostCall lost;
  const LostCallCountdown({super.key, required this.lost});

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: HollowBadge('${lost.secondsLeft} s',
            key: const ValueKey('lost-call-countdown')),
      );
}
