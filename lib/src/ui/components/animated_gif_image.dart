import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'package:hollow/src/core/reduce_motion.dart';

/// Renders an animated GIF from raw bytes with proper frame delay handling.
///
/// Unlike Flutter's built-in Image.memory which can play GIFs too fast
/// (treating 0ms/10ms delays literally), this widget:
/// - Defaults frame delays < 20ms to 100ms (matching browser behavior)
/// - Drives animation via Ticker for smooth playback
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

class _AnimatedGifImageState extends State<AnimatedGifImage>
    with SingleTickerProviderStateMixin {
  List<_GifFrame>? _frames;
  int _currentFrame = 0;
  bool _failed = false;
  Ticker? _ticker;
  Duration _elapsed = Duration.zero;
  Duration _nextFrameAt = Duration.zero;

  @override
  void initState() {
    super.initState();
    _decode();
    // Reduce-motion treats GIF playback as motion: show the static first
    // frame. React live when the OS / in-app flag flips.
    ReduceMotionController.instance.effective.addListener(_syncPlayback);
  }

  bool get _shouldPlay =>
      widget.animate && !ReduceMotionController.instance.isReduced;

  void _syncPlayback() {
    if (!mounted || _frames == null || _frames!.length <= 1) return;
    if (!_shouldPlay) {
      _ticker?.stop();
      if (_currentFrame != 0) setState(() => _currentFrame = 0);
    } else if (_ticker != null && !_ticker!.isActive) {
      _elapsed = Duration.zero;
      _nextFrameAt = _frames![0].duration;
      _ticker!.start();
    }
  }

  @override
  void didUpdateWidget(AnimatedGifImage old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      _disposeFrames();
      _currentFrame = 0;
      _elapsed = Duration.zero;
      _nextFrameAt = Duration.zero;
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
      if (frames.length > 1) {
        _nextFrameAt = frames[0].duration;
        _ticker = createTicker(_onTick);
        if (_shouldPlay) {
          _ticker!.start();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _onTick(Duration elapsed) {
    _elapsed = elapsed;
    if (_frames == null || _frames!.length <= 1) return;

    if (_elapsed >= _nextFrameAt) {
      final nextIdx = (_currentFrame + 1) % _frames!.length;
      _nextFrameAt += _frames![nextIdx].duration;
      // NEVER play catch-up after a stall. When a dialog is pushed on top,
      // TickerMode MUTES this ticker: ticks stop but `elapsed` keeps
      // accruing, so on resume the schedule is seconds in the past and
      // advancing one frame per 60fps tick fast-forwards the GIF until it
      // "catches up" to wall clock. Resync the schedule to now instead —
      // playback just continues at normal speed from the current frame.
      if (_nextFrameAt <= _elapsed) {
        _nextFrameAt = _elapsed + _frames![nextIdx].duration;
      }
      setState(() => _currentFrame = nextIdx);
    }
  }

  void _disposeFrames() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
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
