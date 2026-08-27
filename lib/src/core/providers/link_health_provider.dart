import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/link_resilience.dart';

/// What the UI is allowed to say about a live media link.
///
/// ## Why this is not on CallState
///
/// The same reason speaking state is not (see `callSpeakingProvider`): a
/// `copyWith` on CallState rebuilds every watcher, which includes the shell,
/// the call panes and the video subtrees. Link health changes far less often
/// than VAD does, but it changes precisely when the machine is least able to
/// absorb a full rebuild, which is the worst possible moment to ask for one.
///
/// Keeping it separate also keeps `CallStatus` alone. A link in trouble is not
/// a new call status: the call is still `active`, which is the entire point of
/// the hold-open ladder. Adding a `reconnecting` status would have meant
/// auditing 46 `status == CallStatus.active` guards, and every one that was
/// missed would be a feature that silently switches itself off the moment the
/// network wobbles.
@immutable
class LinkHealthSnapshot {
  final LinkHealth health;

  /// The outbound camera has been stepped down the quality ladder.
  final bool videoDegraded;

  /// The outbound camera has been given up entirely to protect the audio.
  final bool videoPaused;

  // NOTE: deliberately no "time left in the grace window" field. It would
  // change every second while lapsing, so every watcher of this provider would
  // rebuild once a second on the machine that is, by hypothesis, already
  // struggling — and nothing renders a countdown. `LinkResilience.remainingGrace`
  // is still there for the day something wants to show one; it just must not
  // ride the snapshot that drives rebuilds.

  const LinkHealthSnapshot({
    this.health = LinkHealth.healthy,
    this.videoDegraded = false,
    this.videoPaused = false,
  });

  /// Whether there is anything worth putting on screen. A healthy link with an
  /// untouched camera says nothing, which is the overwhelmingly common case
  /// and the one that must cost nothing.
  bool get hasFlair => health != LinkHealth.healthy || videoDegraded;

  /// Primary line for the flair. Sentence case, no em dashes: this is UI text.
  String? get label => switch (health) {
        LinkHealth.reconnecting => 'Reconnecting',
        LinkHealth.lost => 'Connection lost',
        LinkHealth.unstable => 'Unstable connection',
        LinkHealth.healthy => videoDegraded ? 'Limited bandwidth' : null,
      };

  /// Secondary line explaining what was given up and why, so a soft picture
  /// reads as a deliberate trade rather than as the app breaking.
  String? get detail {
    if (health == LinkHealth.reconnecting) {
      return 'Holding the call open while the connection recovers';
    }
    if (videoPaused) return 'Video paused to keep voice clear';
    if (videoDegraded) return 'Video quality reduced to keep voice clear';
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is LinkHealthSnapshot &&
      other.health == health &&
      other.videoDegraded == videoDegraded &&
      other.videoPaused == videoPaused;

  @override
  int get hashCode => Object.hash(health, videoDegraded, videoPaused);
}

/// Health of the DM call's media link.
final callLinkHealthProvider =
    NotifierProvider<CallLinkHealthNotifier, LinkHealthSnapshot>(
        CallLinkHealthNotifier.new);

class CallLinkHealthNotifier extends Notifier<LinkHealthSnapshot> {
  @override
  LinkHealthSnapshot build() => const LinkHealthSnapshot();

  void set(LinkHealthSnapshot snapshot) {
    // Guarded assignment: the sampler runs on a timer and most samples say
    // exactly what the last one did. Writing an equal value would rebuild the
    // call surfaces once a second for no reason at all.
    if (state != snapshot) state = snapshot;
  }

  void clear() => set(const LinkHealthSnapshot());
}

/// Health of each peer's leg in a server voice channel, keyed by the DEVICE id
/// the mesh connects to.
///
/// Per peer rather than aggregated: in a mesh, one member on hotel Wi-Fi is a
/// problem with that member, and telling the whole channel their connection is
/// unstable would be both wrong and alarming. The UI reads the entry for the
/// tile it is drawing.
final vcLinkHealthProvider =
    NotifierProvider<VcLinkHealthNotifier, Map<String, LinkHealthSnapshot>>(
        VcLinkHealthNotifier.new);

class VcLinkHealthNotifier extends Notifier<Map<String, LinkHealthSnapshot>> {
  @override
  Map<String, LinkHealthSnapshot> build() => const {};

  void setFor(String peerId, LinkHealthSnapshot snapshot) {
    final existing = state[peerId];
    if (existing == snapshot) return;
    if (!snapshot.hasFlair) {
      // Drop healthy peers rather than storing a no-op snapshot for each, so
      // a quiet channel holds an empty map.
      if (existing == null) return;
      state = {...state}..remove(peerId);
      return;
    }
    state = {...state, peerId: snapshot};
  }

  void remove(String peerId) {
    if (!state.containsKey(peerId)) return;
    state = {...state}..remove(peerId);
  }

  void clear() {
    if (state.isNotEmpty) state = const {};
  }
}
