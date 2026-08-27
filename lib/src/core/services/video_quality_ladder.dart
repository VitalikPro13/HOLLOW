/// Outbound video quality ladder: what to send when the uplink cannot carry
/// full quality, so that the voice never pays for the picture.
///
/// ## The bug this exists for
///
/// Call cameras were added with a bare `pc.addTrack`: no `sendEncodings`, no
/// `maxBitrate`, no `degradationPreference`. Screen shares have had a full
/// bitrate governor for a year; the camera in a DM call and in the voice mesh
/// had nothing. On a congested uplink that leaves the encoder probing upward
/// into a link that cannot take it, which raises loss, which starves the ICE
/// consent checks sharing that uplink, which reads to the transport as a dead
/// link. Two cameras in one call meant two unbounded senders doing it at once.
///
/// So the picture did not degrade under load. It took the call down with it,
/// which is exactly what "there is a line, and past it the call dies" feels
/// like from the outside.
///
/// ## The policy
///
/// Video is the compressible part of a call and voice is not: 32 kbps of Opus
/// is the whole point of the session, and 700 kbps of VP8 is a courtesy. The
/// ladder therefore always has somewhere further to fall, ending at
/// [VideoRung.paused], where the camera stops sending entirely and the call
/// carries on as audio. Every rung below the top is a better outcome than a
/// dropped call, and the bottom rung is still a call.
///
/// ## Why we steer it at all
///
/// libwebrtc has its own bandwidth estimator and will adapt on its own, but it
/// adapts against whatever ceiling it was given, and an uncapped VP8 sender's
/// ceiling is "as much as I can talk myself into". Naming the rungs gives us
/// three things the built-in loop does not: a ceiling that never probes into
/// congestion in the first place, a floor that protects audio by getting out
/// of its way completely, and an observable quality level that the UI flair
/// and the resilience tracker can both read.
///
/// Pure: no peer connection, no timers, no I/O. The lanes own the sampling and
/// the `setParameters` call; this decides only which rung they should be on.
library;

import 'package:flutter/foundation.dart';

/// One rung of the outbound video ladder.
@immutable
class VideoRung {
  /// Short label for logs and the quality chip. Sentence case, no em dashes:
  /// these reach the UI.
  final String label;

  /// `scaleResolutionDownBy` for the sender's encoding. 1.0 keeps the capture
  /// resolution; 2.0 halves each dimension (a quarter of the pixels).
  final double scaleDownBy;

  /// Ceiling for `maxBitrate`, in bits per second. Zero means "send nothing",
  /// which only [paused] uses.
  final int maxBitrateBps;

  /// Ceiling for `maxFramerate`. Dropping frame rate before resolution keeps
  /// faces legible for longer, which is what a call is for; the screen share
  /// lane makes the opposite trade for text.
  final int maxFramerate;

  const VideoRung({
    required this.label,
    required this.scaleDownBy,
    required this.maxBitrateBps,
    required this.maxFramerate,
  });

  /// The bottom of every ladder: the camera stops sending. The transceiver,
  /// the SFrame cryptor and the negotiated m-line all stay in place, so coming
  /// back up is a `setParameters`, not a renegotiation.
  static const paused = VideoRung(
    label: 'Video paused',
    scaleDownBy: 4.0,
    maxBitrateBps: 0,
    maxFramerate: 1,
  );

  bool get isPaused => maxBitrateBps == 0;
}

/// The camera ladder for calls and the voice mesh.
///
/// Anchored to the 640x480@30 capture the call lane requests, so the top rung
/// is the capture itself and every step down is a real reduction rather than a
/// cap the encoder was already under.
const List<VideoRung> kCameraLadder = <VideoRung>[
  VideoRung(
      label: 'Full quality',
      scaleDownBy: 1.0,
      maxBitrateBps: 700000,
      maxFramerate: 30),
  VideoRung(
      label: 'Reduced', scaleDownBy: 1.5, maxBitrateBps: 380000, maxFramerate: 24),
  VideoRung(
      label: 'Low', scaleDownBy: 2.0, maxBitrateBps: 180000, maxFramerate: 20),
  VideoRung(
      label: 'Minimum', scaleDownBy: 4.0, maxBitrateBps: 80000, maxFramerate: 12),
  VideoRung.paused,
];

/// One stats observation of our own outbound video.
@immutable
class VideoSendSample {
  /// Fraction of our packets the RECEIVER reported lost, 0..1. This is the
  /// load-bearing signal: it comes from `remote-inbound-rtp`, so it is the far
  /// end's verdict on our uplink rather than our own optimistic guess.
  final double fractionLost;

  /// The transport's estimate of what our uplink can carry, in bits per
  /// second, from the succeeded candidate pair. Null when libwebrtc has not
  /// reported one yet, which is normal for the first few seconds and on some
  /// platforms indefinitely, so it is treated as "no opinion", never as zero.
  final int? availableOutgoingBps;

  /// Round trip time in milliseconds, when the candidate pair reports one.
  final double? roundTripMs;

  const VideoSendSample({
    required this.fractionLost,
    this.availableOutgoingBps,
    this.roundTripMs,
  });
}

/// How many consecutive samples justify a move. Asymmetric on purpose: falling
/// has to be quick because the user is already suffering, climbing has to be
/// slow because a premature climb re-creates the congestion we just escaped.
const int _dropStreak = 2;
const int _raiseStreak = 6;

/// Loss at or above this is severe enough to skip a rung. At a quarter of the
/// packets gone the picture is already unwatchable, so a polite single step
/// just spends another sampling interval in the same state.
const double _severeLoss = 0.25;

/// Loss at or above this counts as a bad sample.
const double _badLoss = 0.10;

/// Loss at or below this counts as a good sample.
const double _goodLoss = 0.02;

/// Round trip time above which a sample counts as bad regardless of loss:
/// a link this deep into its buffers is about to start dropping.
const double _badRttMs = 400;

/// Decides which rung of [ladder] the sender should be on.
///
/// Feed it one [VideoSendSample] per sampling interval (about two seconds) and
/// act on it when [observe] returns true.
class VideoLadderGovernor {
  VideoLadderGovernor({this.ladder = kCameraLadder});

  final List<VideoRung> ladder;

  int _index = 0;
  int _bad = 0;
  int _good = 0;

  int get index => _index;
  VideoRung get rung => ladder[_index];

  /// True while the sender is anywhere below full quality. Drives the
  /// "unstable connection" flair, so the user is told why their picture got
  /// soft instead of being left to wonder.
  bool get isDegraded => _index > 0;

  /// True when video has been given up entirely to protect the audio.
  bool get isPaused => rung.isPaused;

  /// Observe one sample. Returns true when the rung changed and the caller
  /// should apply [rung] to the sender.
  bool observe(VideoSendSample sample) {
    final verdict = _classify(sample);

    switch (verdict) {
      case _Verdict.severe:
        _good = 0;
        _bad = 0;
        return _moveTo(_index + 2);
      case _Verdict.bad:
        _good = 0;
        _bad++;
        if (_bad >= _dropStreak) {
          _bad = 0;
          return _moveTo(_index + 1);
        }
        return false;
      case _Verdict.good:
        _bad = 0;
        _good++;
        if (_good >= _raiseStreak) {
          _good = 0;
          return _moveTo(_index - 1);
        }
        return false;
      case _Verdict.neutral:
        // The grey band: lossy enough not to be healthy, not lossy enough to
        // act on. It clears the climb streak, because a climb has to be earned
        // by a genuinely clean run, but it deliberately does NOT forgive a
        // pending bad sample. Forgiving one here made a link alternating
        // bad/grey cancel itself out and hold full quality forever, which is
        // the exact pattern a congested uplink produces.
        _good = 0;
        return false;
    }
  }

  /// Where the ladder stood when [collapse] was called, so the climb back is
  /// not re-earned from scratch. Null when not collapsed.
  int? _collapsedFrom;

  /// True while video is being withheld for the transport's sake rather than
  /// because the ladder measured its way down here.
  bool get isCollapsed => _collapsedFrom != null;

  /// Drop straight to the bottom rung. For the moment a link starts lapsing:
  /// whatever the uplink is doing, spending it on video while the transport is
  /// failing its consent checks is the one certain way to keep it failing.
  bool collapse() {
    _bad = 0;
    _good = 0;
    _collapsedFrom ??= _index;
    return _moveTo(ladder.length - 1);
  }

  /// Undo a [collapse], returning to the rung the ladder had genuinely earned
  /// before the lapse.
  ///
  /// NOT [restore]: a two second stutter on a link that had already been
  /// measured down to "Low" says nothing new about its bandwidth, and jumping
  /// back to full quality would re-create the congestion and start the whole
  /// descent again. Climbing further is left to the normal streak rules.
  bool releaseCollapse() {
    final from = _collapsedFrom;
    if (from == null) return false;
    _collapsedFrom = null;
    _bad = 0;
    _good = 0;
    return _moveTo(from);
  }

  /// Reset to full quality. For a recovered lapse or a fresh sender: the new
  /// path deserves to be measured, not to inherit the old one's verdict.
  bool restore() {
    _bad = 0;
    _good = 0;
    _collapsedFrom = null;
    return _moveTo(0);
  }

  _Verdict _classify(VideoSendSample s) {
    if (s.fractionLost >= _severeLoss) return _Verdict.severe;

    final rtt = s.roundTripMs;
    if (s.fractionLost >= _badLoss || (rtt != null && rtt >= _badRttMs)) {
      return _Verdict.bad;
    }

    final available = s.availableOutgoingBps;
    if (available != null) {
      // The estimator has an opinion. Below 70% of what this rung asks for,
      // the encoder is being squeezed and the next sample's loss is already
      // written; treat it as bad before it becomes loss.
      if (available < (rung.maxBitrateBps * 0.7).round()) return _Verdict.bad;
      // Climbing needs headroom for the rung ABOVE this one, with margin, or
      // we would step up into exactly the ceiling we just fell through.
      if (_index > 0 && s.fractionLost <= _goodLoss) {
        final target = ladder[_index - 1].maxBitrateBps;
        return available >= (target * 1.4).round()
            ? _Verdict.good
            : _Verdict.neutral;
      }
    }

    if (s.fractionLost <= _goodLoss) return _Verdict.good;
    return _Verdict.neutral;
  }

  bool _moveTo(int target) {
    final clamped = target.clamp(0, ladder.length - 1);
    if (clamped == _index) return false;
    _index = clamped;
    return true;
  }
}

enum _Verdict { good, neutral, bad, severe }
