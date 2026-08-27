import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../providers/link_health_provider.dart';
import 'link_resilience.dart';
import 'media_quality_probe.dart';
import 'video_quality_ladder.dart';

/// Drives one media link's resilience: the hold-open ladder, the stats
/// sampler, the outbound video ladder, and the health the UI shows.
///
/// One of these per link (per call for a DM, per peer for the voice mesh, per
/// leg for a screen share). It owns the timer; the policy lives in the pure
/// modules it composes, and the lane supplies the four things only it can
/// know: how to restart ICE, how to apply a video rung, what to do when the
/// budget is finally spent, and where to publish health.
///
/// ## Why this is one class and not three copies
///
/// The lanes disagreed before. DM calls hung up on `disconnected`, the voice
/// mesh closed the peer on `failed` with no restart, and the screen share leg
/// had its own consent watchdog. Three behaviours meant three sets of bugs and
/// no single place to fix "the call dies when the network wobbles". The lanes
/// differ in their timings (see [LinkResilienceConfig.share]) and in whether
/// they govern video at all, and in nothing else.
class LinkWatchdog {
  LinkWatchdog({
    required this.peerConnection,
    required this.isPolite,
    required this.onHealth,
    required this.onRecoverLink,
    required this.onGiveUp,
    this.onApplyRung,
    this.onTransportRebuilt,
    this.canSignal,
    this.config = const LinkResilienceConfig(),
    this.label = 'LINK',
    this.log,
  });

  /// The live peer connection, read lazily: the lanes rebuild it under us
  /// (a renegotiation, an ICE restart, a reconnect) and a captured reference
  /// would go on sampling a corpse.
  final RTCPeerConnection? Function() peerConnection;

  /// Whether this side initiates recovery first. Same lexicographic peer-id
  /// convention the rest of the codebase arbitrates glare with.
  final bool isPolite;

  final LinkResilienceConfig config;

  /// Publish health for the UI. Called only when the snapshot changes.
  final void Function(LinkHealthSnapshot snapshot) onHealth;

  /// Recover the link. The lane decides what that means.
  ///
  /// Deliberately NOT "restart ICE". An in-place ICE restart recovers the
  /// transport and destroys SFrame with it: repairing the cryptors afterwards
  /// was attempted four separate ways in the field and never once produced
  /// working audio. Rebuilding the media session from scratch does both, and
  /// it is the path every successful call start already takes.
  final Future<void> Function() onRecoverLink;

  /// The hold-open budget is spent. Tear this link down for real.
  final void Function() onGiveUp;

  /// The link came back after we had attempted at least one ICE restart, so
  /// the transport underneath may have been rebuilt.
  ///
  /// Belt for the SFrame re-assert. The lane's own detector keys on the remote
  /// ICE credentials changing, which needs an offer/answer to COMPLETE, and a
  /// recovery does not always involve one: field-caught 2026-08-27, a peer
  /// restarted ICE four times into a relay that was down and then recovered
  /// anyway, because libwebrtc restored consent on the original candidate
  /// pair. No SDP was exchanged, so nothing announced the change.
  final void Function()? onTransportRebuilt;

  /// Hold the outbound video sender to a rung. Null for a lane with no video
  /// of its own to govern (or one, like screen share, that already has its
  /// own resolution governor).
  final Future<bool> Function(VideoRung rung)? onApplyRung;

  /// Whether this node's relay connection can carry a renegotiation offer
  /// right now. An ICE restart fired while the relay is down is not a recovery
  /// attempt: `restartIce()` arms credentials, and the offer that carries them
  /// is dropped before it leaves the machine. Null means "assume it can",
  /// which is the right default for a lane with no relay of its own.
  final bool Function()? canSignal;

  final String label;
  final void Function(String line)? log;

  late final LinkResilience _resilience =
      LinkResilience(isPolite: isPolite, config: config);
  final MediaQualityProbe _probe = MediaQualityProbe();
  final VideoLadderGovernor _video = VideoLadderGovernor();

  Timer? _timer;
  bool _sampleTurn = false;
  bool _rungApplied = true;
  bool _stopped = false;

  /// Counted here rather than read back off the tracker: a recovery RESETS the
  /// tracker's counter as part of the same transition that reports it, so the
  /// log line always said "after 0 restart(s)" no matter what had happened.
  int _restartsThisLapse = 0;

  LinkHealthSnapshot _published = const LinkHealthSnapshot();

  LinkHealth get health => _resilience.health;
  bool get isLapsing => _resilience.isLapsing;
  VideoRung get videoRung => _video.rung;

  /// Begin watching. Idempotent.
  void start() {
    if (_timer != null) return;
    _stopped = false;
    // One second, because the ladder's decisions are all measured in seconds
    // and a lapse has to be noticed promptly. Stats are read on every OTHER
    // tick: `getStats()` is a round trip into the native layer, and sampling
    // it once a second on every peer of a full voice mesh is real work for a
    // machine that is, by hypothesis, already struggling.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  /// Stop watching and forget this link's state. Safe to call twice.
  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _resilience.reset();
    _probe.reset();
    _video.restore();
    _rungApplied = true;
    _restartsThisLapse = 0;
    _publish(const LinkHealthSnapshot());
  }

  /// Feed a raw transport state from the lane's `onConnectionState`.
  ///
  /// CRITICAL: never call this with `closed` from the lane's own teardown.
  /// `closed` is reported both when the remote end goes away and when we close
  /// the peer connection ourselves, and it is read here as terminal.
  void noteTransportState(RTCPeerConnectionState state) {
    if (_stopped) return;
    final wasLapsing = _resilience.isLapsing;
    final action = _resilience.onTransportState(state, DateTime.now());

    if (!wasLapsing && _resilience.isLapsing) {
      // The transport just lost consent. Whatever the uplink is doing, feeding
      // it video while its own connectivity checks are going unanswered is the
      // one certain way to keep them unanswered.
      _log('lapse opened, collapsing video while the link recovers');
      _probe.reset();
      if (_video.collapse()) _applyRung();
    }

    _handle(action);
    _publishCurrent();
  }

  /// The relay says this peer went offline. Corroboration, never a hangup:
  /// see [LinkResilience.notePeerPresenceLost].
  void notePeerPresenceLost() {
    if (_stopped) return;
    _resilience.notePeerPresenceLost(DateTime.now());
    _log('relay presence lost (media link '
        '${_resilience.isLapsing ? 'also lapsing, shortening the window' : 'still healthy, ignoring'})');
  }

  /// The relay says this peer is back.
  void notePeerPresenceReturned() {
    if (_stopped) return;
    _resilience.notePeerPresenceReturned();
  }

  /// Forget the current lapse because the lane rebuilt the peer connection
  /// underneath us: a fresh transport deserves a fresh budget.
  void noteConnectionRebuilt() {
    _resilience.reset();
    _probe.reset();
    _video.restore();
    _rungApplied = false;
    // A rebuilt connection has FRESH cryptors, so the transport-rebuilt belt
    // must not fire on the recovery that follows: it would drop and re-create
    // cryptors that are already correct.
    _restartsThisLapse = 0;
    _publishCurrent();
  }

  // ---------------------------------------------------------------------------
  // Private
  // ---------------------------------------------------------------------------

  void _tick() {
    if (_stopped) return;
    _resilience.setSignalingReady(canSignal?.call() ?? true);
    _handle(_resilience.tick(DateTime.now()));
    if (_stopped) return;

    _sampleTurn = !_sampleTurn;
    if (_sampleTurn) {
      unawaited(_sample());
    } else {
      _publishCurrent();
    }
  }

  Future<void> _sample() async {
    final pc = peerConnection();
    if (pc == null) return;
    final sample = await _probe.sample(pc);
    if (_stopped) return;
    if (sample == null) {
      _publishCurrent();
      return;
    }

    _resilience.setQualityDegraded(sample.isDegraded);

    // The video ladder only has an opinion while a camera is actually sending,
    // and only while the transport is up: during a lapse the sender is already
    // collapsed on purpose, and measuring a link with no consent would read
    // every sample as catastrophic and walk the ladder down for no reason.
    if (onApplyRung != null &&
        sample.isSendingVideo &&
        !_resilience.isLapsing) {
      if (_video.observe(sample.videoSample)) {
        _log('video ladder to "${_video.rung.label}" (${sample.toString()})');
        _rungApplied = false;
      }
      // Retry until the sender accepts it. A pre-negotiation `setParameters`
      // is dropped on the native path, so the rung applied at camera-enable
      // time routinely does not take; this is what makes the cap real.
      if (!_rungApplied) _applyRung();
    }

    _publishCurrent();
  }

  void _applyRung() {
    final apply = onApplyRung;
    if (apply == null) return;
    unawaited(apply(_video.rung).then((ok) {
      _rungApplied = ok;
    }).catchError((Object e) {
      _log('applying rung "${_video.rung.label}" failed: $e');
      _rungApplied = false;
    }));
  }

  void _handle(LinkAction action) {
    switch (action) {
      case LinkAction.none:
        return;
      case LinkAction.recovered:
        _log('link recovered after $_restartsThisLapse restart(s)');
        if (_restartsThisLapse > 0) onTransportRebuilt?.call();
        _restartsThisLapse = 0;
        _probe.reset();
        if (_video.releaseCollapse()) _applyRung();
      case LinkAction.restartIce:
        _restartsThisLapse++;
        _log('recovering the link (attempt $_restartsThisLapse)');
        unawaited(onRecoverLink().catchError((Object e) {
          _log('link recovery failed: $e');
        }));
      case LinkAction.giveUp:
        _log('giving up: the hold-open window is spent');
        // Stop BEFORE handing control back: onGiveUp tears the lane down, and
        // a tick that fired in between would drive a dead link.
        _timer?.cancel();
        _timer = null;
        _stopped = true;
        _publish(const LinkHealthSnapshot(health: LinkHealth.lost));
        onGiveUp();
    }
  }

  void _publishCurrent() {
    if (_stopped) return;
    _publish(LinkHealthSnapshot(
      health: _resilience.health,
      // A collapse is the transport's doing, not a bandwidth verdict, and the
      // "Reconnecting" line already explains it. Reporting it as a video
      // decision too would put two competing explanations on screen.
      videoDegraded: _video.isDegraded && !_video.isCollapsed,
      videoPaused: _video.isPaused && !_video.isCollapsed,
    ));
  }

  void _publish(LinkHealthSnapshot snapshot) {
    if (snapshot == _published) return;
    _published = snapshot;
    onHealth(snapshot);
  }

  void _log(String line) => log?.call('[HOLLOW-$label] $line');
}
