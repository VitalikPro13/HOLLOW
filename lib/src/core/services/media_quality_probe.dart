import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'video_quality_ladder.dart';

/// Reads one peer connection's `getStats()` and turns it into the two verdicts
/// the resilience machinery needs: is this link degraded (drives the flair),
/// and can it still carry the picture (drives the video ladder).
///
/// Stateful on purpose. Inbound loss is only reported as a running total, so a
/// rate needs the previous sample to subtract from; a fresh probe per call
/// would report a call's whole lifetime of loss as though it just happened.
///
/// Every field is read defensively. Stats key names and types differ between
/// the desktop, Android and iOS backends (`kind` vs `mediaType`, ints arriving
/// as doubles, whole tables missing for the first seconds of a connection), so
/// a missing value always means "no opinion" and never zero. A probe that
/// invents a zero here would report a perfect link as catastrophic loss, or a
/// dying one as fine.
class MediaQualityProbe {
  /// Cumulative counters from the previous sample, for the inbound rate.
  int? _prevPacketsLost;
  int? _prevPacketsReceived;

  /// Forget the previous sample. For a rebuilt peer connection: its counters
  /// restart at zero, and subtracting the old ones yields a negative rate that
  /// reads as a suspiciously perfect link.
  void reset() {
    _prevPacketsLost = null;
    _prevPacketsReceived = null;
  }

  /// Take one sample. Returns null when the connection is gone or stats are
  /// unreadable, which `getStats()` signals by throwing once a PC is closed.
  Future<MediaQualitySample?> sample(RTCPeerConnection pc) async {
    final List<StatsReport> stats;
    try {
      stats = await pc.getStats();
    } catch (_) {
      return null;
    }

    double? audioLossOut;
    double? videoLossOut;
    double? rttMs;
    int? availableOut;
    int? packetsLost;
    int? packetsReceived;
    var sendingVideo = false;

    for (final report in stats) {
      final v = report.values;
      switch (report.type) {
        case 'remote-inbound-rtp':
          // The far end's report card on what WE sent. The only loss figure
          // that describes our uplink.
          final loss = _asDouble(v['fractionLost']);
          final kind = _kindOf(v);
          if (kind == 'audio') {
            audioLossOut = loss ?? audioLossOut;
          } else if (kind == 'video') {
            videoLossOut = loss ?? videoLossOut;
          }
          rttMs ??= _secondsToMs(_asDouble(v['roundTripTime']));

        case 'inbound-rtp':
          if (_kindOf(v) != 'audio') continue;
          packetsLost = _asInt(v['packetsLost']) ?? packetsLost;
          packetsReceived = _asInt(v['packetsReceived']) ?? packetsReceived;

        case 'outbound-rtp':
          if (_kindOf(v) == 'video') sendingVideo = true;

        case 'candidate-pair':
          if (v['state'] != 'succeeded') continue;
          availableOut =
              _asInt(v['availableOutgoingBitrate']) ?? availableOut;
          final pairRtt = _secondsToMs(_asDouble(v['currentRoundTripTime']));
          if (pairRtt != null) rttMs = pairRtt;
      }
    }

    final audioLossIn = _inboundLossRate(packetsLost, packetsReceived);

    return MediaQualitySample(
      audioLossOut: audioLossOut,
      audioLossIn: audioLossIn,
      videoLossOut: videoLossOut,
      rttMs: rttMs,
      availableOutgoingBps: availableOut,
      isSendingVideo: sendingVideo,
    );
  }

  /// Inbound loss as a rate over the interval, from two cumulative counters.
  double? _inboundLossRate(int? lost, int? received) {
    if (lost == null || received == null) return null;
    final prevLost = _prevPacketsLost;
    final prevReceived = _prevPacketsReceived;
    _prevPacketsLost = lost;
    _prevPacketsReceived = received;
    if (prevLost == null || prevReceived == null) return null;

    final dLost = lost - prevLost;
    final dReceived = received - prevReceived;
    // A counter that went backwards means the PC was rebuilt under us; a
    // window with no arrivals says nothing about loss either way.
    if (dLost < 0 || dReceived < 0) return null;
    final total = dLost + dReceived;
    if (total <= 0) return null;
    return dLost / total;
  }

  static String? _kindOf(Map<dynamic, dynamic> v) =>
      (v['kind'] ?? v['mediaType']) as String?;

  static double? _asDouble(Object? raw) => switch (raw) {
        final double d => d,
        final int i => i.toDouble(),
        final String s => double.tryParse(s),
        _ => null,
      };

  static int? _asInt(Object? raw) => switch (raw) {
        final int i => i,
        final double d => d.round(),
        final String s => int.tryParse(s) ?? double.tryParse(s)?.round(),
        _ => null,
      };

  static double? _secondsToMs(double? seconds) =>
      seconds == null ? null : seconds * 1000.0;
}

/// One reading of a link's health.
class MediaQualitySample {
  /// Fraction of OUR audio the far end reported lost, 0..1. Null when the
  /// remote report has not arrived yet.
  final double? audioLossOut;

  /// Fraction of THEIR audio we lost over the last interval, 0..1.
  final double? audioLossIn;

  /// Fraction of OUR video the far end reported lost, 0..1.
  final double? videoLossOut;

  final double? rttMs;
  final int? availableOutgoingBps;

  /// Whether a video sender is actually active. Without this, a governor would
  /// keep adjusting a camera that is switched off.
  final bool isSendingVideo;

  const MediaQualitySample({
    this.audioLossOut,
    this.audioLossIn,
    this.videoLossOut,
    this.rttMs,
    this.availableOutgoingBps,
    this.isSendingVideo = false,
  });

  /// The worst loss figure in either direction. What the flair should key on:
  /// the user does not care which way the packets went missing.
  double get worstLoss {
    var worst = 0.0;
    for (final l in [audioLossOut, audioLossIn]) {
      if (l != null && l > worst) worst = l;
    }
    return worst;
  }

  /// Whether this reading should raise the "unstable connection" flair.
  ///
  /// Audio loss, not video loss: the video ladder exists precisely so that
  /// video loss gets absorbed by dropping quality, and flagging the call as
  /// unstable every time the picture steps down would cry wolf. Once AUDIO is
  /// losing packets, the user is hearing it, and the flair is telling them
  /// something they already suspect.
  bool get isDegraded => worstLoss >= 0.05 || (rttMs ?? 0) >= 500;

  /// This reading as the video ladder wants it.
  VideoSendSample get videoSample => VideoSendSample(
        // Video loss when the far end reports it, audio loss as the stand-in
        // before the first video report lands: they share one uplink, so audio
        // loss is evidence about the video's path too.
        fractionLost: videoLossOut ?? audioLossOut ?? 0.0,
        availableOutgoingBps: availableOutgoingBps,
        roundTripMs: rttMs,
      );

  @override
  String toString() => 'loss out=${_pct(audioLossOut)} in=${_pct(audioLossIn)} '
      'video=${_pct(videoLossOut)} rtt=${rttMs?.round()}ms '
      'avail=${availableOutgoingBps == null ? '?' : '${(availableOutgoingBps! / 1000).round()}kbps'}';

  static String _pct(double? v) =>
      v == null ? '?' : '${(v * 100).toStringAsFixed(1)}%';
}
