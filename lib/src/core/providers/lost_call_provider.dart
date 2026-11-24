import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'call_provider.dart';

/// How long a DM call the link ended stays on screen saying so.
const int kLostCallLingerSeconds = 5;

/// A DM call that ended because its link gave out (#154): its call row and the
/// phone's call screen stay up for [kLostCallLingerSeconds] saying "Connection
/// lost", then go. A hang-up, decline or cancel never lingers.
///
/// Outside CallState for the reason link health is (`link_health_provider`):
/// the call itself is over and idle, and no `CallStatus` guard may see it.
@immutable
class LostCall {
  final String callId;

  /// The peer's MASTER, as the call surfaces compare it.
  final String peerMaster;
  final int secondsLeft;

  const LostCall({
    required this.callId,
    required this.peerMaster,
    this.secondsLeft = kLostCallLingerSeconds,
  });

  @override
  bool operator ==(Object other) =>
      other is LostCall &&
      other.callId == callId &&
      other.peerMaster == peerMaster &&
      other.secondsLeft == secondsLeft;

  @override
  int get hashCode => Object.hash(callId, peerMaster, secondsLeft);
}

final lostCallProvider =
    NotifierProvider<LostCallNotifier, LostCall?>(LostCallNotifier.new);

class LostCallNotifier extends Notifier<LostCall?> {
  Timer? _tick;

  @override
  LostCall? build() {
    ref.onDispose(() => _tick?.cancel());
    // Any new call replaces it at once.
    ref.listen(callProvider.select((c) => c.callId), (_, next) {
      if (next != null && next != state?.callId) clear();
    });
    return null;
  }

  void show({required String callId, required String peerMaster}) {
    _tick?.cancel();
    state = LostCall(callId: callId, peerMaster: peerMaster);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = state;
      if (now == null || now.secondsLeft <= 1) {
        clear();
        return;
      }
      state = LostCall(
          callId: now.callId,
          peerMaster: now.peerMaster,
          secondsLeft: now.secondsLeft - 1);
    });
  }

  void clear() {
    _tick?.cancel();
    _tick = null;
    if (state != null) state = null;
  }
}
