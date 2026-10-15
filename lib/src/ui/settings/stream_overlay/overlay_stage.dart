import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_preview_engine.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The effects the stage draws, already resolved to concrete values.
@immutable
class OverlayStageEffects {
  /// none, bounce, shake, pop, glow.
  final String talking;

  /// none, dim, grayscale.
  final String idle;

  /// instant, crossfade.
  final String transition;
  final bool mirror;

  /// none, soft, outline.
  final String shadow;

  const OverlayStageEffects({
    this.talking = 'bounce',
    this.idle = 'none',
    this.transition = 'crossfade',
    this.mirror = false,
    this.shadow = 'none',
  });
}

/// One person as the OBS page draws them, at [size]: the same layers, the same
/// filters and the same motion as `overlay.css`, so the look editor's preview
/// matches what OBS shows. Every number here is the page's.
class OverlayStage extends StatefulWidget {
  final double size;
  final OverlayPreviewFrame frame;
  final OverlayStageEffects effects;

  /// The person's name colour: glow, outline and the initials circle.
  final Color colour;
  final String initials;

  /// Every image key the person can show, so a state change never waits on a
  /// decode (the page keeps all layers in the frame too).
  final Set<String> layers;

  /// Draws one layer: an image key, or [kOverlayAvatarLayer].
  final Widget Function(String key, BoxFit fit) layerBuilder;

  const OverlayStage({
    super.key,
    required this.size,
    required this.frame,
    required this.effects,
    required this.colour,
    required this.initials,
    required this.layers,
    required this.layerBuilder,
  });

  @override
  State<OverlayStage> createState() => _OverlayStageState();
}

/// The page's motion cycles.
const int _bounceHalfMs = 420;
const int _shakeMs = 140;

/// The page's own colours: the stand-in mark and the soft shadow are part of
/// what OBS shows, so the preview copies them rather than the app's theme.
const Color _markRed = Color(0xFFE5484D); // design-ignore: overlay.css .badge
const Color _markInk = Color(0xFFFFFFFF); // design-ignore: overlay.css .badge svg
const Color _shade55 = Color(0x8C000000); // design-ignore: overlay.css shadows
const Color _inkDark = Color(0xFF111111); // design-ignore: overlay.js textOn

class _OverlayStageState extends State<OverlayStage> {
  /// Drives bounce and shake. A Timer at display rate, running only while a
  /// moving effect shows, never a standing Ticker.
  Timer? _clock;
  final Stopwatch _watch = Stopwatch();
  final ValueNotifier<int> _phaseMs = ValueNotifier(0);

  bool get _moving {
    final t = widget.effects.talking;
    return widget.frame.shown == 'talking' &&
        (t == 'bounce' || t == 'shake') &&
        !ReduceMotionController.instance.isReduced;
  }

  @override
  void initState() {
    super.initState();
    ReduceMotionController.instance.effective.addListener(_syncClock);
    _syncClock();
  }

  @override
  void didUpdateWidget(OverlayStage old) {
    super.didUpdateWidget(old);
    _syncClock();
  }

  void _syncClock() {
    if (_moving == (_clock != null)) return;
    if (!_moving) {
      _clock?.cancel();
      _clock = null;
      _watch
        ..stop()
        ..reset();
      _phaseMs.value = 0;
      if (mounted) setState(() {});
      return;
    }
    // A CSS animation starts from its first keyframe each time it is applied.
    _watch
      ..reset()
      ..start();
    _clock = Timer.periodic(const Duration(milliseconds: 16),
        (_) => _phaseMs.value = _watch.elapsedMilliseconds);
  }

  @override
  void dispose() {
    ReduceMotionController.instance.effective.removeListener(_syncClock);
    _clock?.cancel();
    _phaseMs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final frame = widget.frame;
    final fx = widget.effects;
    final talking = frame.shown == 'talking';
    final kind = frame.image == null
        ? 'initials'
        : (frame.image == kOverlayAvatarLayer ? 'avatar' : 'look');

    Widget look = _Frame(
      size: size,
      frame: frame,
      effects: fx,
      kind: kind,
      colour: widget.colour,
      initials: widget.initials,
      layers: widget.layers,
      layerBuilder: widget.layerBuilder,
    );
    look = switch (fx.shadow) {
      'soft' => _DropShadows(shadows: [
          (Offset(0, size * 0.03), size * 0.05, _shade55),
        ], child: look),
      'outline' => _DropShadows(shadows: [
          (const Offset(2, 0), 0, widget.colour),
          (const Offset(-2, 0), 0, widget.colour),
          (const Offset(0, 2), 0, widget.colour),
          (const Offset(0, -2), 0, widget.colour),
        ], child: look),
      _ => look,
    };

    final stageChild = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: look),
        if (frame.standIn)
          Positioned(
            right: size * 0.02,
            bottom: size * 0.02,
            child: _StateMark(size: size, shown: frame.shown),
          ),
      ],
    );

    // --amp eases over 90 ms; pop over 90 ms ease-out; glow fades in 120 ms.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: frame.amp),
      duration: const Duration(milliseconds: 90),
      builder: (context, amp, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: talking && fx.talking == 'pop' ? 1.0 : 0.0),
        duration: const Duration(milliseconds: 90),
        curve: Curves.easeOut,
        builder: (context, pop, _) => TweenAnimationBuilder<double>(
          tween: Tween(end: talking && fx.talking == 'glow' ? 1.0 : 0.0),
          duration: const Duration(milliseconds: 120),
          builder: (context, glow, _) {
            Widget stage = SizedBox.square(dimension: size, child: stageChild);
            if (glow > 0) {
              stage = _DropShadows(shadows: [
                (Offset.zero, size * 0.05 * amp * glow, widget.colour),
                (Offset.zero, size * 0.02 * amp * glow, widget.colour),
              ], child: stage);
            }
            return ValueListenableBuilder<int>(
              valueListenable: _phaseMs,
              child: stage,
              builder: (context, ms, child) => Transform(
                alignment: Alignment.bottomCenter,
                transform: _motion(ms, amp, pop),
                child: child,
              ),
            );
          },
        ),
      ),
    );
  }

  Matrix4 _motion(int ms, double amp, double pop) {
    final size = widget.size;
    final m = Matrix4.identity();
    if (_clock != null) {
      if (widget.effects.talking == 'bounce') {
        final cycle = ms % (_bounceHalfMs * 2);
        final p = cycle < _bounceHalfMs
            ? cycle / _bounceHalfMs
            : 2 - cycle / _bounceHalfMs;
        m.translateByDouble(
            0, -size * 0.07 * amp * Curves.easeInOut.transform(p), 0, 1);
      } else {
        final (dx, deg) = shakeAt(ms);
        m
          ..translateByDouble(dx * size * 0.025 * amp, 0, 0, 1)
          ..rotateZ(deg * math.pi / 180);
      }
    }
    if (pop > 0) {
      final s = 1 + 0.08 * amp * pop;
      m.scaleByDouble(s, s, 1, 1);
    }
    return m;
  }
}

/// The shake keyframes at [ms]: a sideways step in units of the page's
/// distance (-1..1) and a turn in degrees. 0% rest, 25% left, 75% right,
/// 100% rest, linear between.
(double, double) shakeAt(int ms) {
  final t = (ms % _shakeMs) / _shakeMs;
  final double k;
  if (t < 0.25) {
    k = -t / 0.25;
  } else if (t < 0.75) {
    k = -1 + (t - 0.25) / 0.25;
  } else {
    k = 1 - (t - 0.75) / 0.25;
  }
  return (k, 1.5 * k);
}

/// `.frame`: the image layers and the initials, filtered by the idle effect or
/// the stand-in dimming. The avatar layer carries its own circle, so it keeps
/// it while it fades against a look image.
class _Frame extends StatelessWidget {
  final double size;
  final OverlayPreviewFrame frame;
  final OverlayStageEffects effects;
  final String kind;
  final Color colour;
  final String initials;
  final Set<String> layers;
  final Widget Function(String key, BoxFit fit) layerBuilder;

  const _Frame({
    required this.size,
    required this.frame,
    required this.effects,
    required this.kind,
    required this.colour,
    required this.initials,
    required this.layers,
    required this.layerBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final fade = effects.transition == 'crossfade'
        ? const Duration(milliseconds: 120)
        : Duration.zero;
    final idle = frame.shown == 'idle';
    final brightness = frame.standIn
        ? 0.5
        : (idle && effects.idle == 'dim' ? 0.6 : 1.0);
    final gray = !frame.standIn && idle && effects.idle == 'grayscale' ? 1.0 : 0.0;

    Widget layer(String key) {
      final avatar = key == kOverlayAvatarLayer;
      Widget child = layerBuilder(key, avatar ? BoxFit.cover : BoxFit.contain);
      if (effects.mirror) child = Transform.flip(flipX: true, child: child);
      return avatar ? ClipOval(child: child) : child;
    }

    final content = Stack(
      fit: StackFit.expand,
      children: [
        AnimatedOpacity(
          opacity: kind == 'initials' ? 1 : 0,
          duration: fade,
          child: _Initials(colour: colour, text: initials, size: size),
        ),
        for (final key in layers)
          AnimatedOpacity(
            key: ValueKey(key),
            opacity: key == frame.image ? 1 : 0,
            duration: fade,
            child: layer(key),
          ),
      ],
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: brightness),
      duration: const Duration(milliseconds: 120),
      builder: (context, b, _) => TweenAnimationBuilder<double>(
        tween: Tween(end: gray),
        duration: const Duration(milliseconds: 120),
        builder: (context, g, child) => b == 1 && g == 0
            ? child!
            : ColorFiltered(
                colorFilter: ColorFilter.matrix(filterMatrix(b, g)), child: child),
        child: content,
      ),
    );
  }
}

/// CSS `grayscale(g) brightness(b)` as one colour matrix.
List<double> filterMatrix(double b, double g) {
  final r = 1 - g;
  return [
    (0.2126 + 0.7874 * r) * b, (0.7152 - 0.7152 * r) * b, (0.0722 - 0.0722 * r) * b, 0, 0,
    (0.2126 - 0.2126 * r) * b, (0.7152 + 0.2848 * r) * b, (0.0722 - 0.0722 * r) * b, 0, 0,
    (0.2126 - 0.2126 * r) * b, (0.7152 - 0.7152 * r) * b, (0.0722 + 0.9278 * r) * b, 0, 0,
    0, 0, 0, 1, 0,
  ];
}

/// `.initials`: a circle in the name colour with the initials in whichever of
/// near-black or white reads on it (overlay.js `textOn`).
class _Initials extends StatelessWidget {
  final Color colour;
  final String text;
  final double size;

  const _Initials({required this.colour, required this.text, required this.size});

  @override
  Widget build(BuildContext context) {
    final lum = 0.299 * (colour.r * 255) +
        0.587 * (colour.g * 255) +
        0.114 * (colour.b * 255);
    return Container(
      decoration: BoxDecoration(color: colour, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          color: lum > 150 ? _inkDark : _markInk,
          fontSize: size * 0.36, // design-ignore: scales with the stage, as overlay.css
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The red mark on a muted or deafened stand-in (`.badge`).
class _StateMark extends StatelessWidget {
  final double size;
  final String shown;

  const _StateMark({required this.size, required this.shown});

  @override
  Widget build(BuildContext context) {
    final d = size * 0.28;
    return Container(
      width: d,
      height: d,
      decoration: BoxDecoration(
        color: _markRed,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: _shade55, spreadRadius: size * 0.02),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        shown == 'deafened' ? LucideIcons.headphoneOff : LucideIcons.micOff,
        size: d * 0.62, // design-ignore: art scaled with the stage, as overlay.css
        color: _markInk,
      ),
    );
  }
}

/// CSS `drop-shadow()` filters: each is a blurred, tinted copy of the child's
/// own shape (its alpha), so a cut-out PNG casts a shadow of its outline,
/// never of its box. Blur radius r is a Gaussian of sigma r/2, as in CSS.
class _DropShadows extends StatelessWidget {
  final List<(Offset, double, Color)> shadows;
  final Widget child;

  const _DropShadows({required this.shadows, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        for (final (offset, blur, colour) in shadows)
          Positioned.fill(
            child: IgnorePointer(
              child: Transform.translate(
                offset: offset,
                child: ImageFiltered(
                  imageFilter: blur <= 0
                      ? ui.ImageFilter.matrix(Matrix4.identity().storage)
                      : ui.ImageFilter.blur(
                          sigmaX: blur / 2,
                          sigmaY: blur / 2,
                          tileMode: TileMode.decal),
                  child: ColorFiltered(
                    colorFilter: ColorFilter.mode(colour, BlendMode.srcIn),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        child,
      ],
    );
  }
}
