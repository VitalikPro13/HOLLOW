import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:hollow/src/core/reduce_motion.dart';

/// Whether [bytes] actually carry more than one frame.
///
/// Mirrors Rust's `image_convert::is_animated_image` — GIF magic, a WebP VP8X
/// chunk with the animation bit set, or a PNG carrying an `acTL` chunk (APNG).
/// Keep the two in step: the pickers gate their cropper on this, and Rust
/// decides on the same question when routing an upload.
///
/// Deciding from the BYTES rather than a filename is the rule. The pickers
/// used to branch on a `.gif` extension, so an animated WebP or an APNG went
/// through the still cropper and came out frozen, with no error and no
/// warning.
bool isAnimatedImageBytes(Uint8List bytes) {
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 && // G
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46) {
    return true;
  }
  if (bytes.length > 20 &&
      bytes[0] == 0x52 && // R
      bytes[1] == 0x49 && // I
      bytes[2] == 0x46 && // F
      bytes[3] == 0x46 && // F
      bytes[8] == 0x57 && // W
      bytes[9] == 0x45 && // E
      bytes[10] == 0x42 && // B
      bytes[11] == 0x50 && // P
      bytes[12] == 0x56 && // V
      bytes[13] == 0x50 && // P
      bytes[14] == 0x38 && // 8
      bytes[15] == 0x58 && // X
      (bytes[20] & 0x02) != 0) {
    return true;
  }
  return _isApng(bytes);
}

/// Whether [bytes] are a PNG carrying an `acTL` (animation control) chunk.
///
/// Walks the chunk table by length rather than searching for the literal
/// bytes, which can occur by chance inside compressed pixel data. `acTL` is
/// required to precede the first `IDAT`, so the walk stops there instead of
/// scanning a whole multi-megabyte file.
bool _isApng(Uint8List b) {
  const sig = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (b.length < sig.length + 12) return false;
  for (var i = 0; i < sig.length; i++) {
    if (b[i] != sig[i]) return false;
  }
  var i = sig.length;
  // Each chunk: 4-byte big-endian length, 4-byte type, payload, 4-byte CRC.
  while (i + 8 <= b.length) {
    final len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
    final t = String.fromCharCodes(b, i + 4, i + 8);
    if (t == 'acTL') return true;
    if (t == 'IDAT' || t == 'IEND') return false;
    if (len < 0) return false; // length overflowed into the sign bit
    i += 12 + len;
  }
  return false;
}

/// Renders an animated GIF from raw bytes with proper frame delay handling.
///
/// Unlike Flutter's built-in Image.memory which can play GIFs too fast
/// (treating 0ms/10ms delays literally), this widget:
/// - Defaults frame delays < 20ms to 100ms (matching browser behavior)
/// - Drives animation from a per-frame Timer, so a 10fps GIF costs 10
///   frames a second rather than one per vsync (see [_AnimatedGifImageState._timer])
/// - Properly loops the animation
///
/// For non-GIF images (PNG, WebP, JPEG), shows a static image.
class AnimatedGifImage extends StatefulWidget {
  final Uint8List bytes;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? errorWidget;

  /// When false, playback pauses on frame 0 (used by surfaces that only
  /// animate while actually watched, e.g. the server banner gates on window
  /// focus). Reduce-motion is enforced internally regardless of this flag.
  final bool animate;

  const AnimatedGifImage({
    super.key,
    required this.bytes,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorWidget,
    this.animate = true,
  });

  @override
  State<AnimatedGifImage> createState() => _AnimatedGifImageState();
}

class _AnimatedGifImageState extends State<AnimatedGifImage> {
  List<_GifFrame>? _frames;
  int _currentFrame = 0;
  bool _failed = false;

  /// Playback is driven by a [Timer] armed for the CURRENT frame's display
  /// duration, NOT by a [Ticker].
  ///
  /// A Ticker is a standing request for a frame every vsync, and the engine
  /// then renders one whether or not the picture changed. A 10fps avatar was
  /// therefore costing 240 frames a second on a 240Hz monitor: measured, the
  /// idle Home screen ran at fps=240 with raster=1.81ms per frame, which is
  /// 43% of a CPU core to show two small looping images. Arming a timer for
  /// exactly as long as the current frame is shown produces one frame per GIF
  /// frame, which is all there ever was to draw.
  ///
  /// It also retires the fast-forward bug this widget used to have: there is
  /// no accruing `elapsed` to fall behind and then catch up on
  /// (feedback_gif_ticker_mute_fast_forward). A missed deadline just means
  /// the next frame shows a little late, once.
  Timer? _timer;

  /// Mirrors [TickerMode], which is how Flutter tells widgets under a pushed
  /// route to stop animating. A Ticker got that for free; a Timer has to ask.
  bool _tickerModeEnabled = true;

  @override
  void initState() {
    super.initState();
    _decode();
    // Reduce-motion treats GIF playback as motion: show the static first
    // frame. React live when the OS / in-app flag flips.
    ReduceMotionController.instance.effective.addListener(_syncPlayback);
  }

  /// Reduce motion holds the still; a pushed route pauses in place.
  bool get _shouldPlay =>
      widget.animate &&
      _tickerModeEnabled &&
      !ReduceMotionController.instance.isReduced;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final enabled = TickerMode.valuesOf(context).enabled;
    if (enabled != _tickerModeEnabled) {
      _tickerModeEnabled = enabled;
      _syncPlayback();
    }
  }

  void _syncPlayback() {
    if (!mounted || _frames == null || _frames!.length <= 1) return;
    if (!_shouldPlay) {
      _timer?.cancel();
      _timer = null;
      // Reduce motion is a request to SHOW THE STILL, so rewind to it. Being
      // muted under a dialog is not — that pauses where it stands and picks
      // up from the same frame, with no blink when the dialog closes.
      if (ReduceMotionController.instance.isReduced && _currentFrame != 0) {
        setState(() => _currentFrame = 0);
      }
    } else if (_timer == null) {
      _scheduleNext();
    }
  }

  void _scheduleNext() {
    final frames = _frames;
    if (frames == null || frames.length <= 1) return;
    _timer?.cancel();
    _timer = Timer(frames[_currentFrame].duration, _advance);
  }

  void _advance() {
    if (!mounted || !_shouldPlay) {
      _timer = null;
      return;
    }
    final frames = _frames;
    if (frames == null || frames.length <= 1) {
      _timer = null;
      return;
    }
    setState(() => _currentFrame = (_currentFrame + 1) % frames.length);
    _scheduleNext();
  }

  @override
  void didUpdateWidget(AnimatedGifImage old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      _disposeFrames();
      _currentFrame = 0;
      _failed = false;
      _decode();
    } else if (old.animate != widget.animate) {
      _syncPlayback();
    }
  }

  Future<void> _decode() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.bytes);
      final frameCount = codec.frameCount;
      final frames = <_GifFrame>[];

      for (int i = 0; i < frameCount; i++) {
        final frame = await codec.getNextFrame();
        // Browser behavior: delays < 20ms treated as 100ms
        var delay = frame.duration;
        if (delay.inMilliseconds < 20) {
          delay = const Duration(milliseconds: 100);
        }
        frames.add(_GifFrame(image: frame.image, duration: delay));
      }

      codec.dispose();

      if (!mounted) {
        for (final f in frames) {
          f.image.dispose();
        }
        return;
      }

      setState(() => _frames = frames);

      // Start animation if multi-frame (unless gated: hold frame 0).
      if (frames.length > 1 && _shouldPlay) {
        _scheduleNext();
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _disposeFrames() {
    _timer?.cancel();
    _timer = null;
    if (_frames != null) {
      for (final f in _frames!) {
        f.image.dispose();
      }
      _frames = null;
    }
  }

  @override
  void dispose() {
    ReduceMotionController.instance.effective.removeListener(_syncPlayback);
    _disposeFrames();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return widget.errorWidget ??
          SizedBox(width: widget.width, height: widget.height);
    }
    if (_frames == null || _frames!.isEmpty) {
      return SizedBox(width: widget.width, height: widget.height);
    }
    return RawImage(
      image: _frames![_currentFrame].image,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      // Explicit, not inherited: stored animated avatars are 184px and the
      // profile card paints them at 110, so this path now ALWAYS downscales.
      // `low` is plain bilinear, which undersamples past ~1.33x and aliases
      // the hard edges this art is made of; `medium` is triangle + mipmap and
      // is the correct filter for a downscale. It happens to be RawImage's
      // default today — pinning it means a framework default can't silently
      // move under us. Matches AvatarFrame, which sets the same.
      filterQuality: FilterQuality.medium,
    );
  }
}

class _GifFrame {
  final ui.Image image;
  final Duration duration;
  const _GifFrame({required this.image, required this.duration});
}

/// Loads a GIF from disk and renders it with [AnimatedGifImage] for correct
/// frame delay handling (< 20ms → 100ms, matching browser behavior).
/// For non-GIF paths, falls back to [Image.file].
class GifFileImage extends StatefulWidget {
  final String diskPath;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? errorWidget;

  const GifFileImage({
    super.key,
    required this.diskPath,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.errorWidget,
  });

  @override
  State<GifFileImage> createState() => _GifFileImageState();
}

class _GifFileImageState extends State<GifFileImage> {
  Uint8List? _bytes;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadBytes();
  }

  @override
  void didUpdateWidget(GifFileImage old) {
    super.didUpdateWidget(old);
    if (old.diskPath != widget.diskPath) {
      _bytes = null;
      _failed = false;
      _loadBytes();
    }
  }

  Future<void> _loadBytes() async {
    try {
      final bytes = await File(widget.diskPath).readAsBytes();
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.errorWidget ?? const SizedBox.shrink();
    if (_bytes == null) return SizedBox(width: widget.width, height: widget.height);
    return AnimatedGifImage(
      bytes: _bytes!,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      errorWidget: widget.errorWidget,
    );
  }
}
