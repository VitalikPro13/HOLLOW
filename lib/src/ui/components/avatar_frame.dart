import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart'
    show windowFocusedProvider;
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';

/// Avatar frames (issue #54): decoration painted IN FRONT of an avatar, the
/// way Steam and Discord do it, so hats, hands, ears and bird wings work.
///
/// **The hard rule is that a frame takes ZERO layout space.** The avatar's
/// slot in every list stays exactly `size`; the art is a non-participating
/// overlay in a box of `size * kFrameScale` centred on it, scaled to FIT
/// ([BoxFit.contain]). Tall art is scaled DOWN, never allowed to grow the
/// box. That is what stops somebody shipping metre-long rabbit ears that
/// stretch across the chat, and it is asserted directly in
/// `test/widget/avatar_frame_test.dart`: an avatar's rect with a frame is
/// identical to one without.
const double kFrameScale = 1.33;

/// Below this the art is mush, so it is skipped entirely. [HollowAvatar] is
/// used from 18px up; a frame on an 18px avatar reads as dirt on the screen.
const double kFrameMinAvatarSize = 24.0;

/// **One surface deliberately opts out.** Where a SPEAKING ring is drawn
/// around the avatar itself (the inline call panel, mobile voice avatars),
/// the frame is suppressed with `frameId: ''`. A built-in frame is a coloured
/// ring in the same accent family the speaking cue uses, so a quiet person
/// with a teal frame is pixel-for-pixel a talking person with none - a
/// functional cue lost to decoration. Cues drawn as a TILE RIM (the VC grid,
/// video PiPs) are a different shape in a different place and keep their
/// frames.

/// How much the frame overhangs the avatar on each side.
double frameOverhang(double size) => size * (kFrameScale - 1) / 2;

/// Wraps [child] (an avatar of exactly [size]) with its frame art.
///
/// [animate] un-gates playback for surfaces that are actually being looked
/// at (the profile card, the settings preview). Everywhere else an animated
/// frame holds frame 0 and plays only while hovered, which is also what
/// bounds the decode cost - see [AvatarFrameCache].
class AvatarFrame extends ConsumerStatefulWidget {
  final String id;
  final double size;

  /// The avatar's corner radius, so a built-in ring follows its shape.
  final double radius;

  /// The person the art belongs to, used as the pull hint when we hold no
  /// copy of it. Empty for previews of art we already have in hand.
  final String peerHint;

  final bool animate;
  final Widget child;

  const AvatarFrame({
    super.key,
    required this.id,
    required this.size,
    required this.radius,
    required this.child,
    this.peerHint = '',
    this.animate = false,
  });

  @override
  ConsumerState<AvatarFrame> createState() => _AvatarFrameState();
}

class _AvatarFrameState extends ConsumerState<AvatarFrame> {
  /// Only used where no [HoverScope] encloses us (a picker tile, a preview).
  /// Inside a row, the ROW's hover is what plays the frame - see
  /// [_rowHovered].
  bool _selfHovering = false;

  /// The enclosing row's hover, or null when there is no enclosing row.
  bool? _rowHovered;

  bool get _hovering => _rowHovered ?? _selfHovering;

  @visibleForTesting
  bool get hoveringForTest => _hovering;

  /// The frame set we hold a reference on, so the release is exact.
  String? _heldId;
  AvatarFrameArt? _art;
  int _frame = 0;

  /// Armed for the CURRENT frame's delay, never a [Ticker]. A Ticker asks the
  /// engine for a frame every vsync and then this only changes the picture
  /// when one is actually due, so a 10fps frame animation was costing 240
  /// rendered frames a second on a 240Hz display. Same fix, same reason, as
  /// AnimatedGifImage: one rendered frame per animation frame.
  ///
  /// Losing the Ticker also loses TickerMode's automatic mute under a pushed
  /// route, which costs nothing here: playback already requires hover AND
  /// window focus, and a dialog on top takes both.
  Timer? _timer;

  bool get _wantsPlayback =>
      (widget.animate || _hovering) &&
      !ReduceMotionController.instance.isReduced;

  @override
  void initState() {
    super.initState();
    ReduceMotionController.instance.effective.addListener(_redraw);
    AvatarFrameCache.instance.addListener(widget.id, _redraw);
  }

  @override
  void didUpdateWidget(AvatarFrame old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) {
      AvatarFrameCache.instance.removeListener(old.id, _redraw);
      AvatarFrameCache.instance.addListener(widget.id, _redraw);
      _release();
      _frame = 0;
    }
  }

  @override
  void dispose() {
    ReduceMotionController.instance.effective.removeListener(_redraw);
    AvatarFrameCache.instance.removeListener(widget.id, _redraw);
    _release();
    super.dispose();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  void _release() {
    _timer?.cancel();
    _timer = null;
    if (_heldId != null) {
      AvatarFrameCache.instance.release(_heldId!);
      _heldId = null;
    }
    _art = null;
  }

  /// Acquire (or drop) the fully decoded frame set as playback turns on and
  /// off. A list row therefore costs ONE shared still image until the moment
  /// the pointer is over it.
  void _syncArt(bool playing, Uint8List? bytes) {
    if (playing && bytes != null) {
      if (_heldId == widget.id) return;
      _release();
      final id = widget.id;
      _heldId = id;
      AvatarFrameCache.instance.acquire(id, bytes).then((art) {
        if (art == null) return;
        if (!mounted || _heldId != id) {
          AvatarFrameCache.instance.release(id);
          return;
        }
        setState(() {
          _art = art;
          _frame = 0;
        });
        if (art.images.length > 1) _scheduleNext();
      });
    } else if (_heldId != null) {
      _release();
    }
  }

  void _scheduleNext() {
    final art = _art;
    if (art == null || art.images.length <= 1) return;
    _timer?.cancel();
    _timer = Timer(art.delays[_frame], _advance);
  }

  void _advance() {
    _timer = null;
    final art = _art;
    if (!mounted || art == null || art.images.length <= 1) return;
    setState(() => _frame = (_frame + 1) % art.images.length);
    _scheduleNext();
  }

  @override
  Widget build(BuildContext context) {
    // Read the row's hover FIRST: it decides whether we need a MouseRegion
    // of our own at all.
    _rowHovered = HoverScope.maybeOf(context);

    final hue = builtinFrameHue(widget.id);
    Uint8List? bytes;
    if (hue == null) {
      bytes = ref.watch(avatarFrameProvider.select((m) => m[widget.id]));
      if (bytes == null) {
        final frames = ref.read(avatarFrameProvider.notifier);
        final id = widget.id;
        final hint = widget.peerHint;
        Future.microtask(() => frames.ensure(id, peerHint: hint));
      }
    }

    // Window focus gates playback the same way server icons and banners are
    // gated: nothing animates in a window nobody is looking at.
    final focused = _wantsPlayback ? ref.watch(windowFocusedProvider) : false;
    final playing = _wantsPlayback && focused;
    _syncArt(playing, bytes);

    ui.Image? image;
    if (hue == null && bytes != null) {
      final art = _art;
      image = playing && art != null
          ? art.images[_frame.clamp(0, art.images.length - 1)]
          : AvatarFrameCache.instance.still(widget.id, bytes);
    }

    final overhang = frameOverhang(widget.size);
    Widget stack = Stack(
      clipBehavior: Clip.none,
      children: [
        // The ONLY non-positioned child, so the Stack is exactly the
        // avatar's size and the overlay below cannot change the layout.
        widget.child,
        Positioned(
          left: -overhang,
          top: -overhang,
          right: -overhang,
          bottom: -overhang,
          // The art overhangs its neighbours: it must never eat their
          // clicks, and it is decoration to a screen reader.
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: CustomPaint(
                painter: _AvatarFramePainter(
                  image: image,
                  ringColor: hue == null ? null : accentFromHue(hue),
                  avatarRadius: widget.radius,
                  overhang: overhang,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    // A MouseRegion of our own ONLY where no row supplies hover, and only for
    // an animated frame that is not already playing: inside a list the row's
    // hover drives this, and a still frame adds no hit-testing at all.
    if (_rowHovered == null &&
        !widget.animate &&
        hue == null &&
        bytes != null) {
      stack = MouseRegion(
        opaque: false,
        onEnter: (_) => setState(() => _selfHovering = true),
        onExit: (_) => setState(() => _selfHovering = false),
        child: stack,
      );
    }
    return stack;
  }
}

class _AvatarFramePainter extends CustomPainter {
  final ui.Image? image;
  final Color? ringColor;
  final double avatarRadius;
  final double overhang;

  const _AvatarFramePainter({
    required this.image,
    required this.ringColor,
    required this.avatarRadius,
    required this.overhang,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: img,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
      return;
    }
    final color = ringColor;
    if (color == null) return;
    // Built-in: one stroke hugging the avatar's own rounded square. Zero
    // bytes on the wire, and it gives the widget tests something to render
    // with no network.
    final avatar = Rect.fromLTWH(
      overhang,
      overhang,
      size.width - overhang * 2,
      size.height - overhang * 2,
    );
    final width = (avatar.width * 0.07).clamp(1.5, 5.0);
    // A stroke is centred on its path, so the path has to sit HALF a stroke
    // outside the avatar for the ring's inner edge to land exactly on the
    // avatar's edge. Inflating by the full width leaves a visible hairline of
    // background between the two, which is what it did first.
    final inset = width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        avatar.inflate(inset),
        Radius.circular(avatarRadius + inset),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_AvatarFramePainter old) =>
      old.image != image ||
      old.ringColor != ringColor ||
      old.avatarRadius != avatarRadius ||
      old.overhang != overhang;
}

/// One frame's decoded animation frames plus their delays.
class AvatarFrameArt {
  final List<ui.Image> images;
  final List<Duration> delays;
  int refs = 0;

  AvatarFrameArt(this.images, this.delays);

  void _disposeImages() {
    for (final img in images) {
      img.dispose();
    }
  }
}

/// Shared, ID-keyed decode cache for frame art.
///
/// **This class is the reason frames are affordable.** Decoding every frame
/// of an animated WebP into a `ui.Image` costs ~30 MB for a 512px 30-frame
/// source (512x512 RGBA is 1 MB a frame), and a member panel can hold sixty
/// avatars, so the naive one-decoder-per-widget approach is gigabytes for
/// decoration. Two tiers instead:
///
///  * [still] - frame 0 only, shared by ID, LRU-capped. This is what every
///    list row renders, so N rows sharing a frame cost ONE image.
///  * [acquire] / [release] - the full frame list, refcounted, decoded only
///    while something is actually playing it and disposed the moment nothing
///    is. The hover gate is what keeps that to one or two at a time.
class AvatarFrameCache {
  AvatarFrameCache._();
  static final AvatarFrameCache instance = AvatarFrameCache._();

  /// Frame-0 images, decoded down to [_stillDecodeWidth]: 384x384 RGBA is
  /// ~576 KB each, so this ceiling is ~27 MB and only if forty-eight
  /// DIFFERENT frames are on screen at once. Uncapped, 512px art would have
  /// made the same ceiling ~48 MB.
  static const int maxStills = 48;

  final Map<String, ui.Image> _stills = {};
  final List<String> _stillOrder = [];
  final Set<String> _decodingStill = {};
  final Map<String, AvatarFrameArt> _art = {};
  final Map<String, Completer<AvatarFrameArt?>> _decodingArt = {};

  /// Registered by widgets so a decode that finishes later repaints them.
  /// Keyed by frame ID: a member panel showing sixty avatars across four
  /// different frames must not rebuild all sixty when one of the four
  /// finishes decoding.
  final Map<String, Set<VoidCallback>> _listeners = {};

  void addListener(String id, VoidCallback cb) =>
      _listeners.putIfAbsent(id, () => {}).add(cb);

  void removeListener(String id, VoidCallback cb) {
    final set = _listeners[id];
    if (set == null) return;
    set.remove(cb);
    if (set.isEmpty) _listeners.remove(id);
  }

  void _notify(String id) {
    final set = _listeners[id];
    if (set == null) return;
    for (final cb in set.toList()) {
      cb();
    }
  }

  /// Frame 0 for [id], decoding it in the background on first ask.
  ui.Image? still(String id, Uint8List bytes) {
    final cached = _stills[id];
    if (cached != null) {
      _touch(id);
      return cached;
    }
    if (_decodingStill.add(id)) {
      _decodeStill(id, bytes);
    }
    return null;
  }

  void _touch(String id) {
    _stillOrder.remove(id);
    _stillOrder.add(id);
  }

  /// Frame art is stored at up to 512px, and a frame paints at most ~146
  /// logical px (a 110px profile-card avatar in its `size * kFrameScale`
  /// box). 384 covers that to a 2.6x device pixel ratio and quarters what a
  /// native-resolution still would cost, which matters because [maxStills] of
  /// them are held at once. `allowUpscaling: false` keeps a SMALLER source at
  /// its own size, and a single-axis target preserves the art's aspect ratio.
  static const int _stillDecodeWidth = 384;

  Future<void> _decodeStill(String id, Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: _stillDecodeWidth,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      _stills[id] = frame.image;
      _touch(id);
      while (_stillOrder.length > maxStills) {
        final evicted = _stillOrder.removeAt(0);
        _stills.remove(evicted)?.dispose();
      }
      _notify(id);
    } catch (_) {
      // A frame that will not decode simply never paints.
    } finally {
      _decodingStill.remove(id);
    }
  }

  /// Take a reference on [id]'s full frame list. Returns null if it never
  /// decoded. Every non-null result must be matched by a [release].
  Future<AvatarFrameArt?> acquire(String id, Uint8List bytes) async {
    final held = _art[id];
    if (held != null) {
      held.refs++;
      return held;
    }
    final inFlight = _decodingArt[id];
    if (inFlight != null) {
      // Another widget is already decoding this exact frame: wait on ITS
      // future rather than decoding the same bytes twice.
      await inFlight.future;
      // Re-read the map instead of trusting what the completer carried. The
      // decoder's own reference can have been released while we waited (its
      // widget unmounted mid-decode), and that DISPOSES the images - taking a
      // reference on that object would paint disposed frames.
      final live = _art[id];
      if (live == null) return null;
      live.refs++;
      return live;
    }
    final completer = Completer<AvatarFrameArt?>();
    _decodingArt[id] = completer;
    AvatarFrameArt? decoded;
    final images = <ui.Image>[];
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final delays = <Duration>[];
      for (int i = 0; i < codec.frameCount; i++) {
        final frame = await codec.getNextFrame();
        images.add(frame.image);
        // Browser behaviour: delays under 20ms are treated as 100ms.
        delays.add(frame.duration.inMilliseconds < 20
            ? const Duration(milliseconds: 100)
            : frame.duration);
      }
      codec.dispose();
      if (images.isEmpty) return null;
      decoded = AvatarFrameArt(images, delays)..refs = 1;
      _art[id] = decoded;
      return decoded;
    } catch (_) {
      // A frame that fails PART WAY through still holds decoded images.
      for (final img in images) {
        img.dispose();
      }
      return null;
    } finally {
      _decodingArt.remove(id);
      completer.complete(decoded);
    }
  }

  /// Drop a reference taken by [acquire]; the frames are disposed as soon as
  /// nothing is playing them.
  void release(String id) {
    final art = _art[id];
    if (art == null) return;
    art.refs--;
    if (art.refs <= 0) {
      _art.remove(id);
      art._disposeImages();
    }
  }

  @visibleForTesting
  int get heldArtCount => _art.length;

  @visibleForTesting
  int get stillCount => _stills.length;

  @visibleForTesting
  void clearForTest() {
    for (final img in _stills.values) {
      img.dispose();
    }
    _stills.clear();
    _stillOrder.clear();
    _decodingStill.clear();
    for (final art in _art.values) {
      art._disposeImages();
    }
    _art.clear();
    _listeners.clear();
  }
}
