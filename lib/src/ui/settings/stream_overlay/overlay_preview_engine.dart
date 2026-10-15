import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The look editor's preview logic, a line-for-line twin of `Person.render`
/// in `node/overlay_page/overlay.js`: what OBS shows at a moment, given a
/// state and a level. Keep the two in step, or the preview lies.

/// How long a blink image shows (overlay.js `BLINK_MS`).
const Duration kOverlayBlinkDuration = Duration(milliseconds: 150);

/// The image layer that stands for the person's avatar rather than a look
/// image.
const String kOverlayAvatarLayer = '@avatar';

/// The look as the preview needs it: an image key per state ('' = none) and
/// the effects that steer timing.
@immutable
class OverlayPreviewLook {
  /// idle, talking, muted, deafened, blink, loud -> an image key or ''.
  final Map<String, String> states;
  final int holdMs;
  final int blinkEverySec;
  final double loudThreshold;
  final bool scaleWithVoice;

  /// Whether the person has an avatar to fall back on (else initials).
  final bool hasAvatar;

  const OverlayPreviewLook({
    this.states = const {},
    this.holdMs = 250,
    this.blinkEverySec = 5,
    this.loudThreshold = 0.75,
    this.scaleWithVoice = false,
    this.hasAvatar = false,
  });

  String imageOf(String state) => states[state] ?? '';

  @override
  bool operator ==(Object other) =>
      other is OverlayPreviewLook &&
      mapEquals(other.states, states) &&
      other.holdMs == holdMs &&
      other.blinkEverySec == blinkEverySec &&
      other.loudThreshold == loudThreshold &&
      other.scaleWithVoice == scaleWithVoice &&
      other.hasAvatar == hasAvatar;

  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(states.entries.map(
          (e) => Object.hash(e.key, e.value))), holdMs, blinkEverySec,
      loudThreshold, scaleWithVoice, hasAvatar);
}

/// One drawn moment.
@immutable
class OverlayPreviewFrame {
  /// idle, talking, muted or deafened: the `data-state` the page sets.
  final String shown;

  /// The image key on show, [kOverlayAvatarLayer], or null for initials.
  final String? image;
  final bool loud;
  final bool blinking;

  /// A muted or deafened person with no image of their own for it: the idle
  /// image dimmed with a badge.
  final bool standIn;

  /// The talking effect's size, 1 unless the look follows the voice.
  final double amp;

  const OverlayPreviewFrame({
    this.shown = 'idle',
    this.image,
    this.loud = false,
    this.blinking = false,
    this.standIn = false,
    this.amp = 1.0,
  });

  @override
  bool operator ==(Object other) =>
      other is OverlayPreviewFrame &&
      other.shown == shown &&
      other.image == image &&
      other.loud == loud &&
      other.blinking == blinking &&
      other.standIn == standIn &&
      other.amp == amp;

  @override
  int get hashCode =>
      Object.hash(shown, image, loud, blinking, standIn, amp);
}

/// Drives an [OverlayPreviewFrame] from a state and a level the way the page
/// does: the hold after speech, loud above the threshold with the same hold,
/// and a blink at a jittered moment while idle.
class OverlayPreviewEngine extends ValueNotifier<OverlayPreviewFrame> {
  OverlayPreviewEngine({
    OverlayPreviewLook look = const OverlayPreviewLook(),
    math.Random? random,
    int Function()? nowMs,
  })  : _look = look,
        _random = random ?? math.Random(),
        _nowMs = nowMs ?? _monotonicMs,
        super(const OverlayPreviewFrame()) {
    _render();
  }

  static final Stopwatch _clock = Stopwatch()..start();
  static int _monotonicMs() => _clock.elapsedMilliseconds;

  final math.Random _random;
  final int Function() _nowMs;
  OverlayPreviewLook _look;
  String _state = 'idle';
  double _level = 0;
  int _talkUntil = 0;
  int _loudUntil = 0;
  bool _blinking = false;
  Timer? _holdTimer;
  Timer? _blinkTimer;
  Timer? _blinkEndTimer;
  bool _disposed = false;

  OverlayPreviewLook get look => _look;
  String get state => _state;
  double get level => _level;

  /// Whether a blink is waiting to fire; for tests.
  @visibleForTesting
  bool get blinkArmed => _blinkTimer != null;

  set look(OverlayPreviewLook next) {
    if (next == _look) return;
    _look = next;
    _render();
  }

  /// The live input, as the page's `live` event carries it.
  void update({required String state, required double level}) {
    _state = state;
    _level = level.clamp(0.0, 1.0).toDouble();
    _render();
  }

  /// Shows the blink image now, for the editor's Blink button.
  void blinkNow() {
    if (_look.imageOf('blink').isEmpty) return;
    _blinkTimer?.cancel();
    _blinkTimer = null;
    _blink();
  }

  void _blink() {
    _blinking = true;
    _render();
    _blinkEndTimer?.cancel();
    _blinkEndTimer = Timer(kOverlayBlinkDuration, () {
      _blinking = false;
      _render();
    });
  }

  void _render() {
    if (_disposed) return;
    final now = _nowMs();
    final st = _look;
    final talking = _state == 'talking';
    if (talking) _talkUntil = now + st.holdMs;
    final showTalk = talking || (_state == 'idle' && now < _talkUntil);
    final loudNow = talking && _level >= st.loudThreshold;
    if (loudNow) _loudUntil = now + st.holdMs;
    final loud = showTalk && (loudNow || now < _loudUntil);
    final shown = showTalk ? 'talking' : _state;

    final idleImg = st.imageOf('idle').isNotEmpty
        ? st.imageOf('idle')
        : (st.hasAvatar ? kOverlayAvatarLayer : '');
    var img = idleImg;
    var standIn = false;
    if (shown == 'talking') {
      final loudImg = loud ? st.imageOf('loud') : '';
      img = loudImg.isNotEmpty
          ? loudImg
          : (st.imageOf('talking').isNotEmpty ? st.imageOf('talking') : idleImg);
    } else if (shown == 'muted' || shown == 'deafened') {
      final own = st.imageOf(shown);
      img = own.isNotEmpty ? own : idleImg;
      standIn = own.isEmpty;
    } else if (_blinking && st.imageOf('blink').isNotEmpty) {
      img = st.imageOf('blink');
    }

    value = OverlayPreviewFrame(
      shown: shown,
      image: img.isEmpty ? null : img,
      loud: loud,
      blinking: _blinking && shown == 'idle',
      standIn: standIn,
      amp: st.scaleWithVoice ? math.min(1.3, 0.3 + _level) : 1.0,
    );

    // Re-draw when a hold ends with no new update to trigger it.
    _holdTimer?.cancel();
    _holdTimer = null;
    final until = math.max(showTalk && !talking ? _talkUntil : 0,
        loud && !loudNow ? _loudUntil : 0);
    if (until > now) {
      _holdTimer = Timer(Duration(milliseconds: until - now + 5), _render);
    }
    _scheduleBlink(shown == 'idle' && st.imageOf('blink').isNotEmpty);
  }

  void _scheduleBlink(bool wanted) {
    if (!wanted) {
      _blinkTimer?.cancel();
      _blinkTimer = null;
      if (_blinking) {
        _blinking = false;
        _blinkEndTimer?.cancel();
      }
      return;
    }
    if (_blinkTimer != null) return;
    _blinkTimer = Timer(blinkWait(_look.blinkEverySec, _random), () {
      _blinkTimer = null;
      _blink();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _holdTimer?.cancel();
    _blinkTimer?.cancel();
    _blinkEndTimer?.cancel();
    super.dispose();
  }
}

/// The wait before the next blink: every [everySec] seconds, jittered by up
/// to 40% either way (overlay.js `scheduleBlink`).
Duration blinkWait(int everySec, math.Random random) => Duration(
    milliseconds: (everySec * 1000 * (0.6 + random.nextDouble() * 0.8)).round());
