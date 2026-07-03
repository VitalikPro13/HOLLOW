import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Rapidly-flipping VAD state, deliberately OUTSIDE `CallState` /
/// `VoiceChannelState`: a speaking flip used to `copyWith` the whole call
/// state object and rebuild every `callProvider`/`voiceChannelProvider`
/// watcher (the shell, both panes, video subtrees) 1-4x per second per
/// talker. Widgets that render the speaking cue watch these providers with
/// `.select(...)` for just the bit they draw; everything else never
/// rebuilds on VAD.

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

/// Voice-channel speaking peers (peer ids currently speaking).
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
