import '../rust/api/network.dart' as network_api;

/// One DM call's setup timeline, from the press (or the ring) to media flowing.
///
/// "Should we pre-gather ICE for calls?" cannot be answered by reading the
/// code, because gathering runs CONCURRENTLY with the SDP round trip: if it
/// finishes inside that wait it cost nothing. [gatherExposedMs] is that
/// subtraction, and it is the whole point of the file.
///
/// Not a PerfSentinel: sentinels log only anomalies, and the interesting
/// result here is the spread across networks and machines. A call is a rare
/// user-initiated event, so two lines per call is not a stream. Nothing
/// logged fingerprints a person.
class CallSetupTrace {
  CallSetupTrace({
    required this.callId,
    required this.outgoing,
    void Function(String line)? sink,
    int Function()? clockMs,
  })  : _sink = sink ?? _defaultSink,
        _clockMs = clockMs ?? _defaultClock {
    _origin = _clockMs();
  }

  // Mark names, roughly in the order they occur. Both sides share names so a
  // caller log and a callee log can be read side by side.

  /// Outgoing: the user pressed Call. Incoming: the invite arrived (ring on).
  static const kStart = 'start';

  /// The human answered. Everything before this is THEIR time, not ours, and
  /// is reported separately so it can never be mistaken for machine cost.
  static const kAccept = 'accept';

  static const kGumAudio = 'gum-audio';
  static const kGumVideo = 'gum-video';
  static const kPc = 'pc';
  static const kSdp = 'sdp';

  /// setLocalDescription returned. ICE gathering starts here.
  static const kSld = 'sld';

  /// Our offer/answer handed to the relay.
  static const kSdpSent = 'sdp-sent';

  /// The peer's answer (caller) or offer (callee) arrived. For the caller this
  /// is the deadline gathering has to beat in order to be free.
  static const kRemoteSdp = 'remote-sdp';

  static const kCandHost = 'cand-host';
  static const kCandSrflx = 'cand-srflx';
  static const kCandRelay = 'cand-relay';

  /// Every local candidate type in the order gathered. The LAST to arrive is
  /// what "gathering is done enough to connect" means; see [candsReadyMs].
  static const kCandTypes = [kCandHost, kCandSrflx, kCandRelay];

  /// The peer's first ICE candidate reached us. Its ABSENCE on a call that got
  /// an SDP answer means candidates travelled one way only.
  static const kRemoteCand = 'remote-cand';

  /// Queued candidates were thrown away because the peer connection was
  /// rebuilt underneath them. Should never appear on a healthy call.
  static const kCandDropped = 'cand-dropped';

  static const kGatherDone = 'gather-done';
  static const kIceConnected = 'ice-connected';
  static const kConnected = 'connected';

  final String callId;
  final bool outgoing;
  final void Function(String line) _sink;
  final int Function() _clockMs;

  late final int _origin;
  bool _finished = false;

  /// Insertion-ordered so the emitted line reads as a timeline. First write
  /// wins: `cand-srflx` fires per candidate and a retried step must not move.
  final Map<String, int> _marks = <String, int>{};

  /// Record [name] at the current time, unless it is already recorded.
  void mark(String name) {
    if (_finished) return;
    _marks.putIfAbsent(name, () => _clockMs() - _origin);
  }

  int? elapsed(String name) => _marks[name];

  /// Time the human spent deciding: press to pickup, or ring to accept.
  /// Null until both ends are known. Never part of [machineMs].
  int? get humanMs {
    final start = _marks[kStart];
    final accept = _marks[kAccept];
    if (start == null || accept == null) return null;
    return accept - start;
  }

  /// Everything the app is responsible for: pickup to media flowing.
  int? get machineMs {
    final accept = _marks[kAccept];
    final connected = _marks[kConnected];
    if (accept == null || connected == null) return null;
    return connected - accept;
  }

  /// setLocalDescription to ICE gathering state `complete`.
  ///
  /// Reported, but NOT the basis of any verdict: "complete" also waits on
  /// transports nothing will use, so reading a cost off it overstates it.
  int? get gatherDoneMs {
    final sld = _marks[kSld];
    final done = _marks[kGatherDone];
    if (sld == null || done == null) return null;
    return done - sld;
  }

  /// Elapsed time of the LAST local candidate type to arrive.
  int? get _lastCandidateAt {
    int? last;
    for (final t in kCandTypes) {
      final at = _marks[t];
      if (at == null) continue;
      if (last == null || at > last) last = at;
    }
    return last;
  }

  /// setLocalDescription to the last usable local candidate.
  ///
  /// This, not [gatherDoneMs], is what pre-gathering could shorten.
  int? get candsReadyMs {
    final sld = _marks[kSld];
    final last = _lastCandidateAt;
    if (sld == null || last == null) return null;
    return last - sld;
  }

  /// **The number this file exists for.** How much of candidate gathering was
  /// NOT already paid for by waiting on the peer's SDP.
  ///
  /// Zero means pre-gathering would have saved nothing on this call; a positive
  /// value is the upper bound on what it could return. Measured against the last
  /// CANDIDATE, not gathering `complete` (see [gatherDoneMs]).
  ///
  /// Caller-only: all of the callee's gathering is on the critical path by
  /// construction.
  int? get gatherExposedMs {
    if (!outgoing) return null;
    final last = _lastCandidateAt;
    final remote = _marks[kRemoteSdp];
    if (last == null || remote == null) return null;
    final exposed = last - remote;
    return exposed > 0 ? exposed : 0;
  }

  /// Emit the timeline. [reason] is `connected` for a normal finish, or why
  /// the call never got there. Idempotent.
  void finish({String reason = 'connected'}) {
    if (_finished) return;
    final dir = outgoing ? 'out' : 'in';
    final parts = <String>[];
    var prev = 0;
    for (final e in _marks.entries) {
      parts.add('${e.key}=+${e.value - prev}');
      prev = e.value;
    }
    // Latch AFTER reading the marks so an abort still reports how far it got.
    _finished = true;

    _sink('[CALL-SETUP] $dir call=$callId $reason '
        'human=${_fmt(humanMs)} machine=${_fmt(machineMs)} '
        'cands-ready=${_fmt(candsReadyMs)} '
        'gather-exposed=${_fmt(gatherExposedMs)} '
        'gather-done=${_fmt(gatherDoneMs)}');
    _sink('[CALL-SETUP] $dir call=$callId marks: ${parts.join(' ')}');
  }

  static String _fmt(int? ms) => ms == null ? 'n/a' : '${ms}ms';

  static int _defaultClock() => DateTime.now().millisecondsSinceEpoch;

  static void _defaultSink(String line) {
    // Fire-and-forget FFI: swallow rejections or they hit the zone crash
    // handler (see feedback_ffi_fire_and_forget_catcherror).
    network_api.logFromDart(message: line).catchError((_) {});
  }

  // Exactly one DM call exists at a time, and the marks come from two layers:
  // the provider owns signalling, the service owns the peer connection.
  // Threading a trace through VoiceService would be worse than a scoped static.

  static CallSetupTrace? _current;

  static CallSetupTrace? get current => _current;

  /// Start a trace, replacing any stale one — an abandoned call that never
  /// reached [finish] must not swallow the next call's marks.
  static CallSetupTrace begin({
    required String callId,
    required bool outgoing,
  }) {
    _current?.finish(reason: 'superseded');
    final t = CallSetupTrace(callId: callId, outgoing: outgoing);
    _current = t;
    t.mark(kStart);
    return t;
  }

  /// Mark on the current trace, if there is one. Safe to call from anywhere.
  static void markCurrent(String name) => _current?.mark(name);

  /// Finish and clear the current trace. No-op when there is none.
  static void finishCurrent({String reason = 'connected'}) {
    _current?.finish(reason: reason);
    _current = null;
  }
}
