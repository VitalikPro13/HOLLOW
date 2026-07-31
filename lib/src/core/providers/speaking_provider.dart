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

/// Voice-channel speaking REMOTE peers (routable peer ids currently speaking).
///
/// Our own speaking state is NOT in here — it lives in
/// [vcLocalSpeakingProvider], exactly like the `local` half of
/// [callSpeakingProvider]. It used to be a member of this set under our own
/// peer id, and the self indicator never lit: the set is keyed by the
/// ROUTABLE device id while several call sites test it with the MASTER id
/// (`identityOf`), so the membership test silently missed. A bool for "us"
/// has no id to get wrong.
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
/// [vcSpeakingProvider] so the self cue never depends on matching a peer id
/// against a set — see the note there.
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
