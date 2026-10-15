import 'dart:math' as math;

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';

/// Voice LEVELS, 0..1 per person, beside the speaking sets in
/// `speaking_provider.dart` and keyed the same way: remote voice channel
/// peers by DEVICE id, ourselves as a plain value. Separate providers so no
/// widget that draws a speaking cue rebuilds on every level tick; only the
/// overlay publisher and the look editor's preview read these.

/// dBFS that maps to level 0; 0 dBFS maps to 1 (plan 16.4).
const double kVoiceLevelFloorDb = -60.0;

/// The level poll's period with no OBS page open, as before the overlay.
const Duration kVoicePollNormal = Duration(milliseconds: 200);

/// The period while an OBS page streams, so its bounce follows the voice.
const Duration kVoicePollFast = Duration(milliseconds: 100);

/// `clamp((dBFS + 60) / 60, 0, 1)`.
double levelFromDb(double? db) {
  if (db == null || db.isNaN) return 0.0;
  return ((db - kVoiceLevelFloorDb) / -kVoiceLevelFloorDb)
      .clamp(0.0, 1.0)
      .toDouble();
}

/// A getStats `audioLevel` (linear 0..1) as a level: `20 * log10(audioLevel)`
/// then [levelFromDb]. Absent or silent reads 0.
double levelFromAudioLevel(num? audioLevel) {
  if (audioLevel == null || audioLevel <= 0) return 0.0;
  return levelFromDb(20.0 * math.log(audioLevel.toDouble()) / math.ln10);
}

/// Two decimals: finer steps are invisible on a page and only cost rebuilds.
double _quantize(double v) => (v.clamp(0.0, 1.0) * 100).roundToDouble() / 100;

/// How often the voice channel and DM call level polls run.
final voicePollIntervalProvider = Provider<Duration>((ref) =>
    ref.watch(overlayOpenStreamsProvider) > 0
        ? kVoicePollFast
        : kVoicePollNormal);

/// One level, ours: [vcLocalLevelProvider] and [listenLevelProvider].
class VoiceLevelNotifier extends Notifier<double> {
  @override
  double build() => 0.0;

  void set(double level) {
    final q = _quantize(level);
    if (q != state) state = q;
  }

  void reset() => set(0.0);
}

/// Remote voice channel peers' levels by routable DEVICE id. Peers at 0 are
/// left out, so a quiet room is an empty map.
class VoiceLevelsNotifier extends Notifier<Map<String, double>> {
  @override
  Map<String, double> build() => const {};

  void set(Map<String, double> levels) {
    final next = <String, double>{};
    levels.forEach((peer, level) {
      final q = _quantize(level);
      if (q > 0) next[peer] = q;
    });
    if (mapEquals(next, state)) return;
    state = next;
  }

  void reset() => set(const {});
}

/// Remote peers in the voice channel we are in.
final vcLevelsProvider =
    NotifierProvider<VoiceLevelsNotifier, Map<String, double>>(
        VoiceLevelsNotifier.new);

/// Us in the voice channel: the native capture meter, pre-chain, 0 while muted.
final vcLocalLevelProvider =
    NotifierProvider<VoiceLevelNotifier, double>(VoiceLevelNotifier.new);

/// A 1:1 call: us (capture meter) and the peer (inbound-rtp).
final callLevelProvider =
    NotifierProvider<CallLevelNotifier, ({double local, double remote})>(
        CallLevelNotifier.new);

class CallLevelNotifier extends Notifier<({double local, double remote})> {
  @override
  ({double local, double remote}) build() => (local: 0.0, remote: 0.0);

  void set({required double local, required double remote}) {
    final l = _quantize(local);
    final r = _quantize(remote);
    if (state.local == l && state.remote == r) return;
    state = (local: l, remote: r);
  }

  void reset() => set(local: 0.0, remote: 0.0);
}

/// Us while listening for the overlay outside a call: the raw capture's RMS.
final listenLevelProvider =
    NotifierProvider<VoiceLevelNotifier, double>(VoiceLevelNotifier.new);
