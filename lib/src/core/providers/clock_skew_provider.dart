import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How loudly the app should mention a device clock that is off.
enum ClockSkewLevel { none, warn, urgent }

/// Past this the warning shows: relays older than 0.12.1 refuse a login this far off.
const int clockWarnAboveSecs = 60;

/// Once shown, the warning stays until the offset is back under this, so a
/// reading that wobbles around the threshold does not make it flicker.
const int clockWarnClearsBelowSecs = 55;

/// Past this, peers start refusing what we send: they judge our sealed frames,
/// key exchanges, server changes and friend replies within five minutes of their
/// own clock, and this leaves a minute for theirs being off too.
const int clockUrgentAboveSecs = 240;

/// The relay's measure of our clock (relay minus ours, seconds) and what to show.
class ClockSkew {
  /// Positive: our clock is behind. Null until a relay that tells time answered.
  final int? offsetSecs;
  final ClockSkewLevel level;

  /// The level the person dismissed; a louder one shows again.
  final ClockSkewLevel dismissed;

  const ClockSkew({
    this.offsetSecs,
    this.level = ClockSkewLevel.none,
    this.dismissed = ClockSkewLevel.none,
  });

  bool get visible =>
      level != ClockSkewLevel.none && level.index > dismissed.index;
}

/// The level for an offset, given the one showing now.
ClockSkewLevel clockSkewLevelFor(int offsetSecs, ClockSkewLevel current) {
  final off = offsetSecs.abs();
  if (off > clockUrgentAboveSecs) return ClockSkewLevel.urgent;
  if (off > clockWarnAboveSecs) return ClockSkewLevel.warn;
  if (current != ClockSkewLevel.none && off >= clockWarnClearsBelowSecs) {
    return ClockSkewLevel.warn;
  }
  return ClockSkewLevel.none;
}

class ClockSkewNotifier extends Notifier<ClockSkew> {
  @override
  ClockSkew build() => const ClockSkew();

  /// A new measure from the node (`NetworkEvent.relayClockOffset`); null when the
  /// relay stopped telling its time, which leaves nothing to warn about.
  void onOffset(int? offsetSecs) {
    if (offsetSecs == null) {
      state = const ClockSkew();
      return;
    }
    final level = clockSkewLevelFor(offsetSecs, state.level);
    // A fixed clock forgets the dismissal, so a later drift is shown again.
    final dismissed =
        level == ClockSkewLevel.none ? ClockSkewLevel.none : state.dismissed;
    state = ClockSkew(offsetSecs: offsetSecs, level: level, dismissed: dismissed);
  }

  /// Hides the banner until the clock gets worse or is fixed and drifts again.
  void dismiss() {
    state = ClockSkew(
      offsetSecs: state.offsetSecs,
      level: state.level,
      dismissed: state.level,
    );
  }
}

final clockSkewProvider =
    NotifierProvider<ClockSkewNotifier, ClockSkew>(ClockSkewNotifier.new);

/// "82 seconds", "3 minutes", "5 hours", "2 days": how far off, in plain words.
String clockSkewAmount(int offsetSecs) {
  final s = offsetSecs.abs();
  String unit(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
  if (s < 120) return unit(s, 'second');
  final minutes = (s / 60).round();
  if (minutes < 120) return unit(minutes, 'minute');
  final hours = (s / 3600).round();
  if (hours < 48) return unit(hours, 'hour');
  return unit((s / 86400).round(), 'day');
}
