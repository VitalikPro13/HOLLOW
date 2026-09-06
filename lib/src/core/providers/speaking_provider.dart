import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Rapidly-flipping VAD state, deliberately OUTSIDE `CallState` /
/// `VoiceChannelState`: a speaking flip used to `copyWith` the whole state and
/// rebuild every watcher 1-4x per second per talker. Widgets that draw the cue
/// `.select(...)` just the bit they need.

/// 1:1 call speaking state (local mic, remote peer).
final callSpeakingProvider =
    NotifierProvider<CallSpeakingNotifier, ({bool local, bool remote})>(
        CallSpeakingNotifier.new);

class CallSpeakingNotifier extends Notifier<({bool local, bool remote})> {
  @override
  ({bool local, bool remote}) build() => (local: false, remote: false);

  void set({required bool local, required bool remote}) {
    if (state.local == local && state.remote == remote) return;
    state = (local: local, remote: remote);
  }

  void reset() => set(local: false, remote: false);
}

/// Voice-channel speaking REMOTE peers (routable peer ids currently speaking).
///
/// Our own speaking state is NOT here; it lives in [vcLocalSpeakingProvider].
/// As a set member it never lit: the set is keyed by the ROUTABLE device id
/// while call sites test it with the MASTER id. A bool has no id to get wrong.
final vcSpeakingProvider =
    NotifierProvider<VcSpeakingNotifier, Set<String>>(VcSpeakingNotifier.new);

class VcSpeakingNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void set(Set<String> speaking) {
    if (setEquals(state, speaking)) return;
    state = speaking;
  }

  void reset() => set(const {});
}

/// Are WE talking in the voice channel we're connected to? Separate from
/// [vcSpeakingProvider] so the self cue never matches a peer id against a set.
final vcLocalSpeakingProvider =
    NotifierProvider<VcLocalSpeakingNotifier, bool>(
        VcLocalSpeakingNotifier.new);

class VcLocalSpeakingNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool speaking) {
    if (state == speaking) return;
    state = speaking;
  }

  void reset() => set(false);
}
