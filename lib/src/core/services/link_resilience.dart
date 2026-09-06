/// Hold-open policy for a real-time media link that loses its transport.
///
/// `RTCPeerConnectionStateDisconnected` is not a hangup: it is ICE consent
/// going unanswered for a couple of seconds, the signature of a Wi-Fi
/// stutter or a handover, and it clears itself most of the time. Treating it
/// as terminal hung calls up on BOTH machines over a three-second hiccup, so
/// a merely `disconnected` link is never restarted and only a `failed` one
/// earns an ICE restart. Both sides are eligible to start that, because the
/// polite peer may be exactly the machine whose network died.
///
/// Pure and lane-agnostic: no timers, no peer connection, no Riverpod state.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// How a real-time media link is doing, in the terms the UI shows.
enum LinkHealth {
  healthy,

  /// Media is still flowing over a degraded path. Nothing is broken.
  unstable,

  /// ICE stopped answering; the link is held open and the call has NOT ended.
  reconnecting,

  /// Grace expired or the connection closed. The only health that ends a call.
  lost,
}

/// What [LinkResilience] wants the caller to do at this moment.
enum LinkAction {
  none,

  /// The transport came back. Clear the flair and resume normal operation.
  recovered,

  /// Restart ICE, then send this lane's offer; the caller owns its glare rules.
  restartIce,

  /// The budget is spent. Tear this link down for real.
  giveUp,
}

/// Timings for the hold-open ladder. The defaults are the DM-call values: a
/// call survives a router reboot or a handover unnoticed, while a genuinely
/// dead peer resolves inside a minute.
class LinkResilienceConfig {
  /// Total time a link may sit in [LinkHealth.reconnecting], measured from
  /// the first lapse so a flapping link cannot extend its own reprieve.
  final Duration graceWindow;

  /// How long a link must sit in `failed` before the first ICE restart. A
  /// merely `disconnected` link is never restarted at any age: in the field a
  /// restart has never been what recovered a link, while rebuilding the
  /// transport under SFrame wedged the cryptors in `DecryptionFailed`.
  final Duration restartAfter;

  /// Spacing between ICE restarts. Deliberately NO cap on the count: an
  /// attempt is cheap and only useful when signalling can deliver it, so the
  /// controls are this cadence, [graceWindow] and
  /// [LinkResilience.setSignalingReady].
  final Duration restartCooldown;

  /// Extra delay before the impolite side (higher peer id) initiates, so the
  /// two ends rarely restart into each other.
  final Duration impoliteOffset;

  /// The window once something OUTSIDE the media path agrees the peer is gone
  /// ([LinkResilience.notePeerPresenceLost]). Short, because the long window
  /// exists to out-wait a network that might come back.
  final Duration corroboratedGrace;

  /// Hard ceiling on a single lapse. [graceWindow] is a budget of time we
  /// could actually USE, so this backstops a link with no signalling at all.
  final Duration absoluteCeiling;

  const LinkResilienceConfig({
    this.graceWindow = const Duration(seconds: 45),
    this.restartAfter = const Duration(seconds: 8),
    this.restartCooldown = const Duration(seconds: 5),
    this.impoliteOffset = const Duration(seconds: 3),
    this.corroboratedGrace = const Duration(seconds: 10),
    this.absoluteCeiling = const Duration(seconds: 90),
  });

  /// Screen share legs: the same ladder on a shorter fuse. A frozen picture
  /// is more obvious than an audio blip, the leg is cheap to rebuild, and
  /// giving up here drops a share, never a call.
  static const share = LinkResilienceConfig(
    graceWindow: Duration(seconds: 20),
    restartAfter: Duration(seconds: 6),
    restartCooldown: Duration(seconds: 5),
    absoluteCeiling: Duration(seconds: 40),
  );
}

enum _Phase { up, wobbling, down, closed, pending }

/// Tracks one media link's transport health and decides when to restart ICE
/// and when to give up. One instance per link: per call for a DM, per peer
/// for the mesh, per leg for a share.
class LinkResilience {
  LinkResilience({
    required this.isPolite,
    this.config = const LinkResilienceConfig(),
  });

  /// Whether this side initiates recovery first. Same lexicographic peer-id
  /// convention `shouldInitiateIceRepair` in `ice_repair.dart` arbitrates by.
  final bool isPolite;

  final LinkResilienceConfig config;

  _Phase _phase = _Phase.pending;

  DateTime? _lapseStart;

  /// When the transport last entered `failed`; null while it is merely
  /// wobbling. The restart schedule measures from here, which is what makes
  /// "never restart a `disconnected` link" expressible.
  DateTime? _downSince;
  DateTime? _lastRestart;
  int _restarts = 0;

  /// From the stats sampler. Only picks healthy vs unstable; never a teardown.
  bool _qualityDegraded = false;

  bool _everConnected = false;

  DateTime? _presenceLostAt;

  /// Whether an ICE restart could actually be DELIVERED right now: the offer
  /// carrying the fresh credentials rides the relay, so with the relay down
  /// firing one is a log line, not an attempt. While false none is made and
  /// none is counted.
  bool _signalingReady = true;

  /// Reports whether our relay link can carry a renegotiation offer now.
  void setSignalingReady(bool ready) => _signalingReady = ready;

  /// How much of this lapse was spent unable to attempt anything. It pushes
  /// the give-up deadline out, because [graceWindow] is a budget of time we
  /// could USE and not a wall clock.
  Duration _unusable = Duration.zero;

  DateTime? _lastTick;

  /// Ceiling on one tick's contribution to [_unusable]: a much larger gap
  /// means the machine slept, which must not buy the call an extension.
  static const _maxTickCredit = Duration(seconds: 3);

  bool get isLapsing => _lapseStart != null;
  int get restartsSpent => _restarts;
  bool get everConnected => _everConnected;

  /// Relay presence says the peer went offline. Deliberately NOT a hangup:
  /// presence and media are different sockets, and a WS reconnect makes a
  /// peer vanish from the rooms while a healthy media path carries on. It
  /// only corroborates: with the media link ALSO lapsing the window shrinks
  /// to [LinkResilienceConfig.corroboratedGrace].
  void notePeerPresenceLost(DateTime now) => _presenceLostAt ??= now;

  /// The peer is back in the relay's rooms. Withdraws the corroboration.
  void notePeerPresenceReturned() => _presenceLostAt = null;

  /// Health as the UI should show it. Transport trouble outranks a quality
  /// complaint: a link with no consent is "reconnecting" however good the
  /// last stats sample looked.
  LinkHealth get health {
    if (_phase == _Phase.closed) return LinkHealth.lost;
    if (isLapsing) return LinkHealth.reconnecting;
    return _qualityDegraded ? LinkHealth.unstable : LinkHealth.healthy;
  }

  /// How much grace is left, for a UI countdown. Null when not lapsing.
  Duration? remainingGrace(DateTime now) {
    if (_lapseStart == null) return null;
    final left = _deadline().difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Reports the outbound quality verdict. Never restarts or tears down on
  /// its own: a bad path that still carries media is the video ladder's job.
  void setQualityDegraded(bool degraded) => _qualityDegraded = degraded;

  /// Feeds a raw peer-connection state.
  ///
  /// CRITICAL: never call this with `closed` from your own teardown path.
  /// `closed` also means the remote end went away, and this type reads it
  /// as terminal.
  LinkAction onTransportState(RTCPeerConnectionState state, DateTime now) {
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _everConnected = true;
        return _settle(_Phase.up, now);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        return _settle(_Phase.wobbling, now);
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return _settle(_Phase.down, now);
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        return _settle(_Phase.closed, now);
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        return LinkAction.none;
    }
  }

  /// Drives the ladder from a periodic timer (about once a second). Returns
  /// [LinkAction.none] in the overwhelmingly common case.
  LinkAction tick(DateTime now) {
    final previousTick = _lastTick;
    _lastTick = now;

    if (_phase == _Phase.closed) return LinkAction.giveUp;
    if (!isLapsing) return LinkAction.none;

    // Time we could not have used counts for nothing, or a lapse runs its
    // whole window unable to signal and is then declared unrecoverable.
    if (!_signalingReady && previousTick != null) {
      final elapsed = now.difference(previousTick);
      _unusable += elapsed > _maxTickCredit ? _maxTickCredit : elapsed;
    }

    if (!now.isBefore(_deadline())) return LinkAction.giveUp;
    return _considerRestart(now);
  }

  /// When this lapse runs out of patience. Corroboration can only ever
  /// shorten the wait, never extend it.
  DateTime _deadline() {
    final ceiling = _lapseStart!.add(config.absoluteCeiling);
    var full = _lapseStart!.add(config.graceWindow + _unusable);
    if (full.isAfter(ceiling)) full = ceiling;

    final presence = _presenceLostAt;
    if (presence == null) return full;
    final corroborated = (presence.isAfter(_lapseStart!) ? presence : _lapseStart!)
        .add(config.corroboratedGrace);
    return corroborated.isBefore(full) ? corroborated : full;
  }

  /// Forgets the current lapse without acting on it. For a lane that rebuilt
  /// the peer connection underneath the tracker: a fresh PC, a fresh budget.
  void reset() {
    _phase = _Phase.pending;
    _lapseStart = null;
    _lastRestart = null;
    _restarts = 0;
    _qualityDegraded = false;
    _presenceLostAt = null;
    _signalingReady = true;
    _unusable = Duration.zero;
    _lastTick = null;
    _downSince = null;
  }

  LinkAction _settle(_Phase phase, DateTime now) {
    final previous = _phase;
    _phase = phase;

    switch (phase) {
      case _Phase.up:
        if (previous == _Phase.wobbling || previous == _Phase.down) {
          // A recovered lapse hands its whole budget back: the next outage
          // is a new event, or a long call on a flaky line would burn its
          // restarts by the evening.
          _lapseStart = null;
          _lastRestart = null;
          _restarts = 0;
          _presenceLostAt = null;
          _unusable = Duration.zero;
          _downSince = null;
          return LinkAction.recovered;
        }
        return LinkAction.none;

      case _Phase.wobbling:
        _lapseStart ??= now;
        // A link that has ONLY wobbled is never restarted: consent checks
        // resume by themselves. But `_downSince` is deliberately NOT cleared
        // here: falling back from `failed` to `disconnected` is a link that
        // already proved it cannot heal itself, and clearing the escalation
        // strands it one-way for the rest of the call.
        return LinkAction.none;

      case _Phase.down:
        // A link that has NEVER been up is failing to SET UP, which belongs
        // to the lane's own call-establishment timeout, not to a window this
        // long.
        if (!_everConnected) return LinkAction.giveUp;
        // `failed` is the only state that earns a restart, and not at once:
        // consent can still return on the pair it already has.
        _lapseStart ??= now;
        _downSince ??= now;
        return _considerRestart(now);

      case _Phase.closed:
        return LinkAction.giveUp;

      case _Phase.pending:
        return LinkAction.none;
    }
  }

  LinkAction _considerRestart(DateTime now) {
    // Only a link that reached `failed` during THIS lapse. A climb back to
    // `disconnected` is a half-recovery, not a cure, so eligibility survives.
    final down = _downSince;
    if (down == null) return LinkAction.none;

    // Nothing to deliver an offer over: wait rather than burn the attempt.
    if (!_signalingReady) return LinkAction.none;

    final due = _lastRestart != null
        ? _lastRestart!.add(config.restartCooldown)
        : down
            .add(config.restartAfter)
            .add(isPolite ? Duration.zero : config.impoliteOffset);

    if (now.isBefore(due)) return LinkAction.none;

    _restarts++;
    _lastRestart = now;
    return LinkAction.restartIce;
  }
}
