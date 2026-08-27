/// Hold-open policy for a real-time media link that loses its transport.
///
/// ## The bug this exists for
///
/// Every media lane used to treat `RTCPeerConnectionStateDisconnected` as a
/// hangup. That state does not mean "the call is over": it means ICE consent
/// checks have gone unanswered for a couple of seconds, which is the ordinary
/// signature of a Wi-Fi stutter, a mobile handover, or a saturated uplink. It
/// clears itself most of the time. The DM call lane made it worse than a local
/// blink by ALSO signalling `end` to the peer, so one side's three-second
/// hiccup hung the call up on both machines. Users read that as a hard line in
/// the network: past some amount of congestion, the call dies.
///
/// The correct behaviour is a ladder, not a switch:
///
///   1. `disconnected` starts a lapse. The peer connection, its tracks and the
///      call all stay alive; the UI says the link is unstable. Most lapses end
///      here, silently, within a second or two.
///   2. A `disconnected` link is NEVER restarted, however long it lasts:
///      libwebrtc resumes its own consent checks when the path returns, and
///      that is what has recovered every outage on record.
///   3. Only a link that reaches `failed` earns an ICE restart, and only after
///      [LinkResilienceConfig.restartAfter] there. It stays eligible for the
///      rest of the lapse even if it climbs back to `disconnected`.
///   4. Restarts then repeat on a steady cadence for as long as the lapse
///      lasts, but ONLY while signalling can actually deliver the offer that
///      carries them (see [LinkResilience.setSignalingReady]).
///   5. Only when the whole [LinkResilienceConfig.graceWindow] expires does the
///      lane give up and tear the call down.
///
/// ## Why both sides may restart
///
/// An ICE restart is a renegotiation trigger, so two simultaneous ones are
/// textbook glare. The usual fix is to let the polite peer (lower id) own it.
/// That is not enough here: the polite peer may be exactly the machine whose
/// network died, and a recovery nobody is allowed to start is not a recovery.
/// So both sides are eligible and the impolite one simply waits
/// [LinkResilienceConfig.impoliteOffset] longer, which turns a collision into
/// a rare case that the lanes' existing renegotiation queues already absorb.
///
/// ## Scope
///
/// This type is pure and lane-agnostic: it owns no timers, no peer connection
/// and no Riverpod state. Callers feed it transport states and a periodic
/// [tick], and act on the [LinkAction] it returns. That is what makes the
/// hold-open policy testable without a device, and identical across DM calls,
/// the voice-channel mesh and screen share legs.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// How a real-time media link is doing, in the terms the UI shows.
enum LinkHealth {
  /// Media is flowing over a transport with no complaints.
  healthy,

  /// Media is still flowing, but the path is degraded: loss, latency, or an
  /// encoder that has been pushed down the quality ladder. Nothing is broken.
  unstable,

  /// ICE stopped answering. The link is being held open while it recovers,
  /// and the call has NOT ended.
  reconnecting,

  /// The grace window expired, or the peer connection closed for real. This
  /// is the only health that justifies tearing a call down.
  lost,
}

/// What [LinkResilience] wants the caller to do at this moment.
enum LinkAction {
  /// Nothing to do.
  none,

  /// The transport came back. Clear the flair and resume normal operation.
  recovered,

  /// Restart ICE now, then send this lane's renegotiation offer. The caller
  /// owns the glare rules for that offer.
  restartIce,

  /// The budget is spent. Tear this link down for real.
  giveUp,
}

/// Timings for the hold-open ladder.
///
/// The defaults are the DM-call values, chosen so a call survives a router
/// reboot or a Wi-Fi to mobile handover without the participants noticing more
/// than a flair, while a genuinely dead peer still resolves inside a minute.
class LinkResilienceConfig {
  /// Total time a link may sit in [LinkHealth.reconnecting] before the lane
  /// gives up. Measured from the first lapse, NOT from the last restart, so a
  /// link that keeps flapping cannot extend its own reprieve forever.
  final Duration graceWindow;

  /// How long a link must sit in `failed` before the first ICE restart.
  ///
  /// A merely `disconnected` link is NEVER restarted, at any age. That is the
  /// opposite of what this ladder did originally, and the field data is the
  /// reason. Across every recorded outage, an ICE restart has never once been
  /// the thing that recovered a link: recovery always coincided with the
  /// network returning, and libwebrtc restoring consent on the pair it already
  /// had. What the restarts DID do was rebuild the transport underneath
  /// SFrame, and a rebuilt transport left the cryptors wedged in
  /// `DecryptionFailed` no matter how carefully they were re-asserted. The
  /// clean recoveries in the logs are exactly the ones with zero restarts.
  ///
  /// So a restart is now a last resort for a link ICE itself has given up on,
  /// not a routine step. If it turns out to be needed sooner, the evidence for
  /// that will be a `failed` link that sits there and never comes back.
  final Duration restartAfter;

  /// Spacing between ICE restarts. An ICE restart needs a full offer and
  /// answer round trip plus fresh connectivity checks, so firing them faster
  /// than this just stacks renegotiations on a sick link.
  ///
  /// There is deliberately NO cap on the number of attempts. An earlier
  /// version allowed three, which sounded prudent and was wrong: a field test
  /// on 2026-08-27 pulled a VM's network card for 25 seconds, and all three
  /// attempts fired into a relay connection that was itself down, every offer
  /// logging `DROPPED — not in any WS room`. By the time the relay came back
  /// the budget was gone. Attempts are cheap, make-before-break, and only
  /// useful when they can actually be delivered, so the right controls are a
  /// steady cadence, the [graceWindow], and [LinkResilience.setSignalingReady].
  final Duration restartCooldown;

  /// Extra delay before the impolite side (higher peer id) initiates. Keeps
  /// the two ends from restarting into each other in the common case while
  /// still letting recovery happen when the polite side is the broken one.
  final Duration impoliteOffset;

  /// The window that applies once something OUTSIDE the media path agrees the
  /// peer is gone (see [LinkResilience.notePeerPresenceLost]). Much shorter,
  /// because the long window exists to out-wait a network that might come
  /// back, and a peer who closed their laptop is not coming back.
  final Duration corroboratedGrace;

  /// Hard ceiling on a single lapse, no matter how much of it was spent unable
  /// to attempt anything. [graceWindow] is a budget of time we could actually
  /// USE (see [LinkResilience.tick]); this is the backstop that keeps a link
  /// with no signalling at all from being held forever.
  final Duration absoluteCeiling;

  const LinkResilienceConfig({
    this.graceWindow = const Duration(seconds: 45),
    this.restartAfter = const Duration(seconds: 8),
    this.restartCooldown = const Duration(seconds: 5),
    this.impoliteOffset = const Duration(seconds: 3),
    this.corroboratedGrace = const Duration(seconds: 10),
    this.absoluteCeiling = const Duration(seconds: 90),
  });

  /// Screen share legs: the same ladder on a shorter fuse. A frozen picture is
  /// far more obvious than a blip in audio, the leg is cheap to rebuild, and
  /// the share lane already has its own receiver-initiated reconnect behind
  /// this. Giving up here drops a share, never a call.
  static const share = LinkResilienceConfig(
    graceWindow: Duration(seconds: 20),
    restartAfter: Duration(seconds: 6),
    restartCooldown: Duration(seconds: 5),
    absoluteCeiling: Duration(seconds: 40),
  );
}

/// The transport phase a lane observed, mapped off its own state enum.
enum _Phase { up, wobbling, down, closed, pending }

/// Tracks one media link's transport health and decides when to restart ICE
/// and when to finally give up. Pure: no timers, no I/O. One instance per
/// link (per call for a DM, per peer for the mesh, per leg for a share).
class LinkResilience {
  LinkResilience({
    required this.isPolite,
    this.config = const LinkResilienceConfig(),
  });

  /// Whether this side initiates recovery first. Use the same lexicographic
  /// peer-id convention the rest of the codebase arbitrates glare with
  /// (`shouldInitiateIceRepair` in `ice_repair.dart`).
  final bool isPolite;

  final LinkResilienceConfig config;

  _Phase _phase = _Phase.pending;

  /// When the current lapse began. Null whenever the link is not lapsing.
  DateTime? _lapseStart;

  /// When the transport last entered `failed`. Null while it is merely
  /// wobbling, which is what makes "never restart a `disconnected` link"
  /// expressible: the restart schedule is measured from here, not from the
  /// start of the lapse.
  DateTime? _downSince;
  DateTime? _lastRestart;
  int _restarts = 0;

  /// Set from the stats sampler. Only decides between [LinkHealth.healthy] and
  /// [LinkHealth.unstable]; it can never mask a lapse or trigger a teardown.
  bool _qualityDegraded = false;

  /// True once the link has been up at least once. A link that has NEVER
  /// connected is still in setup, and setup failures belong to the lane's own
  /// call-establishment timeout, not to the hold-open ladder.
  bool _everConnected = false;

  /// When the relay last told us this peer went offline, while the media link
  /// was already in trouble. Null whenever presence is not corroborating.
  DateTime? _presenceLostAt;

  /// Whether an ICE restart could actually be DELIVERED right now.
  ///
  /// An ICE restart is only half a recovery: `restartIce()` arms fresh
  /// credentials, and the renegotiation offer that carries them travels over
  /// the relay. With the relay down, that offer is dropped on the floor, and
  /// firing one is not a recovery attempt, it is a log line.
  ///
  /// So attempts are not merely paced, they are gated: while this is false no
  /// attempt is made and none is counted, and the moment signalling returns
  /// the next tick fires one immediately (the cooldown runs from the last
  /// attempt actually made, which was before the outage or never).
  bool _signalingReady = true;

  /// Report whether this node's relay connection can carry a renegotiation
  /// offer right now.
  void setSignalingReady(bool ready) => _signalingReady = ready;

  /// How much of this lapse was spent unable to attempt anything at all.
  ///
  /// The give-up deadline is pushed out by this, because [graceWindow] is a
  /// budget of time we could USE and not a wall clock. Field-caught
  /// 2026-08-27: a VM lost its network for 25 seconds, its relay client went
  /// into a 30 second reconnect backoff, and the window ran out ELEVEN SECONDS
  /// before the relay came back. Zero ICE restarts had been attempted. The
  /// call was killed for failing a recovery it was never allowed to start,
  /// while the peer, whose network was fine, had recovered its own side five
  /// restarts earlier and sat in a call with nobody in it.
  Duration _unusable = Duration.zero;

  /// Wall clock of the previous [tick], for measuring that.
  DateTime? _lastTick;

  /// Ceiling on how much one tick may contribute to [_unusable]. Ticks arrive
  /// about once a second; anything much larger means the app was suspended or
  /// the machine slept, and that time must not buy the call an extension.
  static const _maxTickCredit = Duration(seconds: 3);

  bool get isLapsing => _lapseStart != null;
  int get restartsSpent => _restarts;
  bool get everConnected => _everConnected;

  /// Relay presence says the peer went offline.
  ///
  /// This is deliberately NOT a hangup. Relay presence and the media path are
  /// different sockets: a WS reconnect on a flaky line makes the peer vanish
  /// from the relay's rooms for a few seconds while a perfectly healthy TURN
  /// or peer-to-peer media path carries on. Ending the call on this event
  /// alone is what let a signalling blip kill a working call.
  ///
  /// What it does instead is corroborate. If the media link is ALSO lapsing,
  /// two independent sources now agree the peer is gone, so the long window
  /// shrinks to [LinkResilienceConfig.corroboratedGrace] and a peer who really
  /// did close their laptop resolves in seconds rather than in a minute. While
  /// media is healthy it is recorded and otherwise ignored.
  void notePeerPresenceLost(DateTime now) => _presenceLostAt ??= now;

  /// The peer is back in the relay's rooms. Withdraws the corroboration.
  void notePeerPresenceReturned() => _presenceLostAt = null;

  /// Health as the UI should show it. Transport trouble always outranks a
  /// quality complaint: a degraded encoder on a live link is "unstable", but a
  /// link with no consent is "reconnecting" no matter how good the last
  /// stats sample looked.
  LinkHealth get health {
    if (_phase == _Phase.closed) return LinkHealth.lost;
    if (isLapsing) return LinkHealth.reconnecting;
    return _qualityDegraded ? LinkHealth.unstable : LinkHealth.healthy;
  }

  /// How much of the grace window is left, for a UI countdown. Null when the
  /// link is not lapsing.
  Duration? remainingGrace(DateTime now) {
    if (_lapseStart == null) return null;
    final left = _deadline().difference(now);
    return left.isNegative ? Duration.zero : left;
  }

  /// Report the outbound quality verdict from the stats sampler. Never causes
  /// a restart or a teardown on its own: a bad path that still carries media
  /// is a job for the video ladder, not for the hold-open ladder.
  void setQualityDegraded(bool degraded) => _qualityDegraded = degraded;

  /// Feed a raw peer-connection state.
  ///
  /// CRITICAL: do NOT call this with `closed` from your own teardown path.
  /// `closed` is reported both when the remote end goes away and when we call
  /// `pc.close()` ourselves, and this type reads it as terminal.
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

  /// Drive the ladder from a periodic timer (about once a second) while a
  /// lapse is open. Returns [LinkAction.none] when there is nothing to do,
  /// which is the overwhelmingly common case.
  LinkAction tick(DateTime now) {
    final previousTick = _lastTick;
    _lastTick = now;

    if (_phase == _Phase.closed) return LinkAction.giveUp;
    if (!isLapsing) return LinkAction.none;

    // Time we could not have used counts for nothing. Without this, a lapse
    // could run its whole window while the relay was unreachable and then be
    // declared unrecoverable, having attempted precisely nothing.
    if (!_signalingReady && previousTick != null) {
      final elapsed = now.difference(previousTick);
      _unusable += elapsed > _maxTickCredit ? _maxTickCredit : elapsed;
    }

    if (!now.isBefore(_deadline())) return LinkAction.giveUp;
    return _considerRestart(now);
  }

  /// When this lapse runs out of patience. Normally the full window from the
  /// first lapse; shorter once relay presence corroborates that the peer is
  /// gone. Never later than the full window, so corroboration can only ever
  /// shorten the wait.
  DateTime _deadline() {
    // The window, pushed out by however long we spent unable to try, and then
    // clamped so a link that can never signal still resolves.
    final ceiling = _lapseStart!.add(config.absoluteCeiling);
    var full = _lapseStart!.add(config.graceWindow + _unusable);
    if (full.isAfter(ceiling)) full = ceiling;

    final presence = _presenceLostAt;
    if (presence == null) return full;
    final corroborated = (presence.isAfter(_lapseStart!) ? presence : _lapseStart!)
        .add(config.corroboratedGrace);
    return corroborated.isBefore(full) ? corroborated : full;
  }

  /// Forget the current lapse without acting on it. For a lane that rebuilt
  /// the peer connection underneath the tracker (a fresh PC has a fresh
  /// budget) or that is deliberately parking the link.
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

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  LinkAction _settle(_Phase phase, DateTime now) {
    final previous = _phase;
    _phase = phase;

    switch (phase) {
      case _Phase.up:
        if (previous == _Phase.wobbling || previous == _Phase.down) {
          // Came back. A recovered lapse hands its whole budget back: the next
          // outage is a new event and deserves the full ladder, otherwise a
          // long call on a flaky line would burn its restarts early in the
          // day and be defenceless by the evening.
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
        // A link that has ONLY ever wobbled is never restarted, however long it
        // lasts: consent checks resume by themselves when the path returns.
        //
        // But `_downSince` is deliberately NOT cleared here. Falling back from
        // `failed` to `disconnected` is not a fresh wobble, it is a link that
        // already proved it could not heal itself, and clearing the escalation
        // on the way past strands it.
        //
        // Field-caught 2026-08-27, and it is precisely a one-way call: the
        // host went failed, restarted, and connected four seconds later. The
        // VM went failed, fell back to disconnected when that restart landed
        // half-way, and then sat there for seventy seconds with no mechanism
        // left to push its own side over the line. Audio flowed host to VM and
        // never back, and the VM's "Reconnecting" flair never cleared.
        return LinkAction.none;

      case _Phase.down:
        // A link that has NEVER been up is not lapsing, it is failing to set
        // up, and that belongs to the lane's own call-establishment timeout.
        // Holding a never-connected call open for the full window would leave
        // a call that cannot possibly complete ringing for the better part of
        // a minute.
        if (!_everConnected) return LinkAction.giveUp;
        // `failed` is the only state that earns a restart, and even then not
        // immediately: consent can still return, and waiting has recovered
        // every outage on record without touching the transport.
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
    // Only a link that has reached `failed` at some point during THIS lapse.
    // A pure wobble is left to heal itself; one that has been down stays
    // eligible even after it climbs back to `disconnected`, because that climb
    // is a half-recovery, not a cure.
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
