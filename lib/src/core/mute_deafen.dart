import 'package:flutter/foundation.dart';

/// The mic and the speakers as one model (#154, as Discord does it), for DM
/// calls and voice rooms alike: deafen mutes the mic too, unmuting while
/// deafened undeafens as well, and undeafening gives the mic back as it was
/// before the deafen. Deafened always means muted, so the transmit gate, the
/// buttons and what the others are told never disagree.
@immutable
class MuteDeafen {
  final bool muted;
  final bool deafened;

  /// The mic before the deafen, given back when it ends; unread otherwise.
  final bool mutedBeforeDeafen;

  const MuteDeafen({
    this.muted = false,
    this.deafened = false,
    this.mutedBeforeDeafen = false,
  });

  /// The mute button: while deafened it is an unmute that also undeafens.
  MuteDeafen tapMute() =>
      deafened ? const MuteDeafen() : MuteDeafen(muted: !muted);

  /// The deafen button.
  MuteDeafen tapDeafen() => deafened
      ? MuteDeafen(muted: mutedBeforeDeafen)
      : MuteDeafen(muted: true, deafened: true, mutedBeforeDeafen: muted);

  @override
  bool operator ==(Object other) =>
      other is MuteDeafen &&
      other.muted == muted &&
      other.deafened == deafened &&
      (!deafened || other.mutedBeforeDeafen == mutedBeforeDeafen);

  @override
  int get hashCode => Object.hash(muted, deafened, deafened && mutedBeforeDeafen);

  @override
  String toString() =>
      'MuteDeafen(muted=$muted, deafened=$deafened, before=$mutedBeforeDeafen)';
}
