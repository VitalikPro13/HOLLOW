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

/// Avatar frames (issue #54): decoration painted IN FRONT of an avatar, so
/// hats, hands, ears and wings work.
///
/// A frame takes ZERO layout space. The avatar's slot stays exactly `size` and
/// the art is a non-participating overlay in a `size * kFrameScale` box scaled
/// to FIT, so tall art is scaled DOWN and can never stretch a row. Asserted in
/// `test/widget/avatar_frame_test.dart`.
const double kFrameScale = 1.33;

/// Below this the art is mush, so it is skipped entirely. [HollowAvatar] is
/// used from 18px up; a frame on an 18px avatar reads as dirt on the screen.
const double kFrameMinAvatarSize = 24.0;

/// One surface deliberately opts out: where a SPEAKING ring is drawn around the
/// avatar itself (inline call panel, mobile voice avatars) the frame is
/// suppressed with `frameId: ''`, because a built-in frame is a coloured ring in
/// the same accent family and would make a quiet person read as a talking one.
/// Cues drawn as a TILE RIM keep their frames.

/// How much the frame overhangs the avatar on each side.
double frameOverhang(double size) => size * (kFrameScale - 1) / 2;

/// Wraps [child] (an avatar of exactly [size]) with its frame art.
///
/// [animate] un-gates playback for surfaces being looked at directly.
/// Everywhere else an animated frame holds frame 0 and plays only while
/// hovered, which is what bounds the decode cost (see [AvatarFrameCache]).
class AvatarFrame extends ConsumerStatefulWidget {
  final String id;
  final double size;

  /// The avatar's corner radius, so a built-in ring follows its shape.
  final double radius;

  /// The pull hint for art we hold no copy of; empty for a preview of art
  /// already in hand.
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
  /// Only used where no [HoverScope] encloses us; inside a row the ROW's hover
  /// plays the frame.
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

  /// Armed for the CURRENT frame's delay, never a [Ticker]: a Ticker asks the
  /// engine for a frame every vsync, so a 10fps animation costs 240 rendered
  /// frames a second on a 240Hz display. Losing TickerMode's automatic mute
  /// costs nothing, because playback already needs hover AND window focus.
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

  /// Acquires or drops the fully decoded frame set as playback turns on and
  /// off, so a list row costs ONE shared still until the pointer is over it.
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
    // Read the row's hover FIRST: it decides whether we need a MouseRegion at
    // all.
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

    // Nothing animates in a window nobody is looking at.
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
        // The ONLY non-positioned child, so the Stack is exactly the avatar's
        // size and the overlay below cannot change the layout.
        widget.child,
        Positioned(
          left: -overhang,
          top: -overhang,
          right: -overhang,
          bottom: -overhang,
          // The art overhangs its neighbours, so it must never eat their
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

    // A MouseRegion of our own ONLY where no row supplies hover, so a still
    // frame in a list adds no hit-testing at all.
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
    // Built-in frames are zero bytes on the wire, which also gives the widget
    // tests something to render with no network.
    final avatar = Rect.fromLTWH(
      overhang,
      overhang,
      size.width - overhang * 2,
      size.height - overhang * 2,
    );
    final width = (avatar.width * 0.07).clamp(1.5, 5.0);
    // A stroke is centred on its path, so the path sits HALF a stroke outside
    // the avatar; the full width leaves a hairline of background between them.
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

/// Shared, ID-keyed decode cache for frame art, and the reason frames are
/// affordable: a decoder per widget would be gigabytes, since one 512px
/// 30-frame source is ~30 MB decoded and a member panel holds sixty avatars.
///
///  * [still] is frame 0 only, shared by ID and LRU-capped, so N rows sharing a
///    frame cost ONE image.
///  * [acquire] / [release] refcount the full frame list, decoded only while
///    something plays it and disposed as soon as nothing does.
class AvatarFrameCache {
  AvatarFrameCache._();
  static final AvatarFrameCache instance = AvatarFrameCache._();

  /// Frame-0 images decoded down to [_stillDecodeWidth], so the ceiling is
  /// ~27 MB and only with forty-eight DIFFERENT frames on screen at once.
  static const int maxStills = 48;

  final Map<String, ui.Image> _stills = {};
  final List<String> _stillOrder = [];
  final Set<String> _decodingStill = {};
  final Map<String, AvatarFrameArt> _art = {};
  final Map<String, Completer<AvatarFrameArt?>> _decodingArt = {};

  /// Registered by widgets so a late decode repaints them. Keyed by frame ID so
  /// sixty avatars across four frames do not all rebuild when one decodes.
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

  /// A frame paints at most ~146 logical px, so 384 covers a 2.6x device pixel
  /// ratio and quarters what a native-resolution still would cost, which matters
  /// with [maxStills] of them held at once. A single-axis target preserves the
  /// art's aspect ratio.
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

  /// Takes a reference on [id]'s full frame list, null if it never decoded.
  /// Every non-null result must be matched by a [release].
  Future<AvatarFrameArt?> acquire(String id, Uint8List bytes) async {
    final held = _art[id];
    if (held != null) {
      held.refs++;
      return held;
    }
    final inFlight = _decodingArt[id];
    if (inFlight != null) {
      // Another widget is already decoding this frame; wait on ITS future
      // rather than decoding the same bytes twice.
      await inFlight.future;
      // Re-read the map: the decoder's own reference can have been released
      // while we waited, and that DISPOSES the images.
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

  /// Drops a reference taken by [acquire]; frames are disposed as soon as
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
