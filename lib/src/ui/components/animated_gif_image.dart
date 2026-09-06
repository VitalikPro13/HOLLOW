import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:hollow/src/core/reduce_motion.dart';

/// Whether [bytes] actually carry more than one frame.
///
/// Mirrors Rust's `image_convert::is_animated_image`, and must stay in step
/// with it: the pickers gate their cropper on this and Rust routes uploads on
/// the same question.
///
/// Decide from the BYTES, never a filename. A `.gif` extension branch sends an
/// animated WebP or an APNG through the still cropper, frozen and silent.
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
/// Walks the chunk table by length rather than searching for the literal bytes,
/// which occur by chance inside compressed pixel data. `acTL` must precede the
/// first `IDAT`, so the walk stops there.
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

/// Renders an animated image from raw bytes, or a static one when there is only
/// a single frame.
///
/// `Image.memory` plays a GIF too fast because it takes 0ms and 10ms delays
/// literally; this defaults anything under 20ms to 100ms, as browsers do, and
/// drives playback from a per-frame Timer (see [_AnimatedGifImageState._timer]).
class AnimatedGifImage extends StatefulWidget {
  final Uint8List bytes;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? errorWidget;

  /// False pauses playback on frame 0, for surfaces that animate only while
  /// watched. Reduce motion is enforced internally whatever this says.
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

  /// Armed for the CURRENT frame's display duration, NOT a [Ticker]: a Ticker
  /// is a standing request for a frame every vsync, so a 10fps image costs 240
  /// rendered frames a second on a 240Hz monitor. With no accruing `elapsed`
  /// there is also nothing to fast-forward
  /// (feedback_gif_ticker_mute_fast_forward).
  Timer? _timer;

  /// Mirrors [TickerMode], which a Ticker would get for free and a Timer has
  /// to ask for.
  bool _tickerModeEnabled = true;

  /// devicePixelRatio the frames were decoded at, so an interface-zoom change
  /// re-decodes instead of stretching a now-too-small texture.
  double _decodedDpr = 0;
  bool _decodeStarted = false;

  @override
  void initState() {
    super.initState();
    // MediaQuery.devicePixelRatio cannot be read in initState, so the first
    // decode runs from didChangeDependencies.
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
    // UiScale folds the interface zoom INTO devicePixelRatio, so this is the
    // whole logical-to-physical conversion for the decode.
    final dpr = MediaQuery.of(context).devicePixelRatio;
    if (!_decodeStarted || (dpr - _decodedDpr).abs() > 0.01) {
      _decodedDpr = dpr;
      _decode();
    }
  }

  void _syncPlayback() {
    if (!mounted || _frames == null || _frames!.length <= 1) return;
    if (!_shouldPlay) {
      _timer?.cancel();
      _timer = null;
      // Reduce motion is a request to SHOW THE STILL, so rewind; being muted
      // under a dialog only pauses in place, with no blink on close.
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

  /// Physical-pixel decode target for one axis, or null when this widget is
  /// laid out flexibly on that axis and the size is not knowable here.
  int? _targetPx(double? logical) {
    if (logical == null || !logical.isFinite || logical <= 0) return null;
    return (logical * (_decodedDpr > 0 ? _decodedDpr : 1.0)).ceil();
  }

  Future<void> _decode() async {
    _decodeStarted = true;
    try {
      // Decode at the size actually painted: every frame is a live GPU
      // texture, so a 512px source in a 32px slot costs ~256x the memory it
      // needs, times the frame count. `allowUpscaling: false` also stops a
      // small source being blown up past its own size.
      final codec = await ui.instantiateImageCodec(
        widget.bytes,
        targetWidth: _targetPx(widget.width),
        targetHeight: _targetPx(widget.height),
        allowUpscaling: false,
      );
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
      // Pinned, not inherited: this path always downscales (512px art painted
      // at 110), and `low` is bilinear, which aliases hard edges past ~1.33x.
      // `medium` is triangle plus mipmap, the correct downscale filter.
      filterQuality: FilterQuality.medium,
    );
  }
}

class _GifFrame {
  final ui.Image image;
  final Duration duration;
  const _GifFrame({required this.image, required this.duration});
}

/// Loads an image from disk and renders it through [AnimatedGifImage], falling
/// back to [Image.file] for a still.
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
