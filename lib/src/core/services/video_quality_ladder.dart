/// Outbound video quality ladder: what to send when the uplink cannot carry
/// full quality, so that the voice never pays for the picture.
///
/// Call cameras used to be added with a bare `pc.addTrack`, no
/// `sendEncodings` at all, which left the encoder probing upward into a link
/// that could not take it; the resulting loss starved the ICE consent checks
/// sharing that uplink until the transport read as dead. The picture did not
/// degrade under load, it took the call down with it.
///
/// Video is the compressible part of a call and voice is not, so the ladder
/// always has somewhere further to fall, ending at [VideoRung.paused] where
/// the camera stops sending and the call carries on as audio. libwebrtc
/// adapts on its own, but only against the ceiling it was given; naming the
/// rungs buys a ceiling that never probes into congestion, a floor that gets
/// out of audio's way, and a quality level the UI and the resilience tracker
/// can both read.
///
/// Pure: no peer connection, no timers, no I/O. The lanes own the sampling and
/// the `setParameters` call.
library;

import 'package:flutter/foundation.dart';

/// One rung of the outbound video ladder.
@immutable
class VideoRung {
  /// Short label for logs and the quality chip. Reaches the UI, so sentence
  /// case and no em dashes.
  final String label;

  /// `scaleResolutionDownBy` for the sender's encoding. 1.0 keeps the capture
  /// resolution; 2.0 halves each dimension.
  final double scaleDownBy;

  /// Ceiling for `maxBitrate`, in bits per second. Zero means send nothing,
  /// which only [paused] uses.
  final int maxBitrateBps;

  /// Ceiling for `maxFramerate`. Dropping frame rate before resolution keeps
  /// faces legible, which is what a call is for; the share lane trades the
  /// other way for text.
  final int maxFramerate;

  const VideoRung({
    required this.label,
    required this.scaleDownBy,
    required this.maxBitrateBps,
    required this.maxFramerate,
  });

  /// The bottom of every ladder: the camera stops sending. The transceiver,
  /// the SFrame cryptor and the m-line all stay, so coming back up is a
  /// `setParameters`, not a renegotiation.
  static const paused = VideoRung(
    label: 'Video paused',
    scaleDownBy: 4.0,
    maxBitrateBps: 0,
    maxFramerate: 1,
  );

  bool get isPaused => maxBitrateBps == 0;
}

/// The camera ladder for calls and the voice mesh, anchored to the 640x480@30
/// capture the call lane requests so every step down is a real reduction and
/// not a cap the encoder was already under.
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
  /// Fraction of our packets the RECEIVER reported lost, 0..1. From
  /// `remote-inbound-rtp`, so it is the far end's verdict on our uplink
  /// rather than our own optimistic guess.
  final double fractionLost;

  /// The transport's estimate of what our uplink can carry, in bits per
  /// second. Null is normal for the first few seconds and on some platforms
  /// indefinitely, so it means "no opinion", never zero.
  final int? availableOutgoingBps;

  final double? roundTripMs;

  const VideoSendSample({
    required this.fractionLost,
    this.availableOutgoingBps,
    this.roundTripMs,
  });
}

/// How many consecutive samples justify a move. Asymmetric on purpose:
/// falling is quick because the user is already suffering, climbing is slow
/// because a premature climb re-creates the congestion we just escaped.
const int _dropStreak = 2;
const int _raiseStreak = 6;

/// Loss at or above this skips a rung: at a quarter of the packets gone the
/// picture is unwatchable and a polite single step just spends another
/// sampling interval in the same state.
const double _severeLoss = 0.25;

const double _badLoss = 0.10;

const double _goodLoss = 0.02;

/// Round trip time above which a sample counts as bad regardless of loss:
/// a link this deep into its buffers is about to start dropping.
const double _badRttMs = 400;

/// Decides which rung of [ladder] the sender should be on. Feed it one
/// [VideoSendSample] per sampling interval, about two seconds.
class VideoLadderGovernor {
  VideoLadderGovernor({this.ladder = kCameraLadder});

  final List<VideoRung> ladder;

  int _index = 0;
  int _bad = 0;
  int _good = 0;

  int get index => _index;
  VideoRung get rung => ladder[_index];

  /// True while the sender is anywhere below full quality. Drives the
  /// "unstable connection" flair, so the user is told why the picture went
  /// soft instead of being left to wonder.
  bool get isDegraded => _index > 0;

  /// True when video has been given up entirely to protect the audio.
  bool get isPaused => rung.isPaused;

  /// Observes one sample. True when the rung changed and the caller should
  /// apply [rung] to the sender.
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
        // The grey band clears the climb streak, which has to be earned by a
        // clean run, but deliberately does NOT forgive a pending bad sample:
        // forgiving one made a link alternating bad and grey cancel itself
        // out and hold full quality forever.
        _good = 0;
        return false;
    }
  }

  /// Where the ladder stood at [collapse], so the climb back is not re-earned
  /// from scratch.
  int? _collapsedFrom;

  /// True while video is withheld for the transport's sake rather than
  /// measured down to here.
  bool get isCollapsed => _collapsedFrom != null;

  /// Drops straight to the bottom rung, for the moment a link starts lapsing:
  /// spending the uplink on video while the transport is failing its consent
  /// checks is the one certain way to keep it failing.
  bool collapse() {
    _bad = 0;
    _good = 0;
    _collapsedFrom ??= _index;
    return _moveTo(ladder.length - 1);
  }

  /// Undoes a [collapse], returning to the rung the ladder had genuinely
  /// earned before the lapse.
  ///
  /// NOT [restore]: a two second stutter says nothing new about a link already
  /// measured down to "Low", and jumping back to full quality would re-create
  /// the congestion. Climbing further is left to the normal streak rules.
  bool releaseCollapse() {
    final from = _collapsedFrom;
    if (from == null) return false;
    _collapsedFrom = null;
    _bad = 0;
    _good = 0;
    return _moveTo(from);
  }

  /// Resets to full quality. For a recovered lapse or a fresh sender: the new
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
      // Below 70% of what this rung asks for, the encoder is being squeezed
      // and the next sample's loss is already written.
      if (available < (rung.maxBitrateBps * 0.7).round()) return _Verdict.bad;
      // Climbing needs headroom for the rung ABOVE this one, with margin, or
      // we step up into exactly the ceiling we just fell through.
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
