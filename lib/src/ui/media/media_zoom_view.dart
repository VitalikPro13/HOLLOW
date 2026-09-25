import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';
import 'package:hollow/src/ui/media/media_item.dart';

/// Largest edge a decoded still may have. Past this the GPU refuses the
/// texture, so an oversized image is resized down rather than dropped.
const int kMediaDecodeCeiling = 8192;

/// The geometry the viewer needs to turn a zoom factor into a percentage.
typedef MediaGeometry = void Function(Size viewport, Size imageSize);

/// One still or GIF page: pan and zoom over a contained image.
///
/// Owns no zoom state. The route holds the [transform] so the readout, the
/// keyboard and the double tap all speak about the same matrix.
class MediaZoomView extends StatefulWidget {
  final MediaItem item;
  final TransformationController transform;
  final int quarterTurns;
  final double minScale;
  final double maxScale;
  final FilterQuality filterQuality;

  /// True for the page the user is on. A neighbour is built for its decode and
  /// nothing else.
  final bool isCurrent;

  final MediaGeometry? onGeometry;
  final void Function(Offset local)? onTapAt;
  final void Function(Offset local)? onDoubleTapAt;

  /// Window-space position of a right click, for the overflow menu.
  final void Function(Offset global)? onSecondaryTapAt;

  const MediaZoomView({
    super.key,
    required this.item,
    required this.transform,
    this.quarterTurns = 0,
    this.minScale = 1.0,
    this.maxScale = 8.0,
    this.filterQuality = FilterQuality.high,
    this.isCurrent = true,
    this.onGeometry,
    this.onTapAt,
    this.onDoubleTapAt,
    this.onSecondaryTapAt,
  });

  @override
  State<MediaZoomView> createState() => _MediaZoomViewState();
}


class _MediaZoomViewState extends State<MediaZoomView> {
  Size? _imageSize;
  Size? _viewport;
  bool _missing = false;

  @override
  void initState() {
    super.initState();
    _resolveSize();
  }

  @override
  void didUpdateWidget(MediaZoomView old) {
    super.didUpdateWidget(old);
    if (old.item.fileId != widget.item.fileId) {
      _imageSize = null;
      _missing = false;
      _resolveSize();
    } else if (!old.isCurrent && widget.isCurrent) {
      // The route only tracks the current page's geometry, and it forgot ours
      // when it moved away. Post-frame, because this runs during a build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _publish();
      });
    }
  }

  /// The declared pixel size, else what the decoder reports. "Actual size"
  /// cannot be honest without it.
  void _resolveSize() {
    final path = widget.item.diskPath;
    if (path == null || !File(path).existsSync()) {
      _missing = true;
      return;
    }
    final declared = widget.item.pixelSize;
    if (declared != null) {
      _imageSize = declared;
      _publish();
      return;
    }
    final stream = AtRestImageProvider(path).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      final size =
          Size(info.image.width.toDouble(), info.image.height.toDouble());
      stream.removeListener(listener);
      if (!mounted) return;
      setState(() => _imageSize = size);
      _publish();
    }, onError: (_, _) {
      stream.removeListener(listener);
      if (mounted) setState(() => _missing = true);
    });
    stream.addListener(listener);
  }

  void _publish() {
    final image = _imageSize;
    final viewport = _viewport;
    if (image == null || viewport == null) return;
    widget.onGeometry?.call(viewport, image);
  }

  ImageProvider _provider(String path) {
    final size = _imageSize;
    final provider = AtRestImageProvider(path);
    final longEdge =
        size == null ? 0 : (size.width > size.height ? size.width : size.height);
    if (longEdge <= kMediaDecodeCeiling) return provider;
    return ResizeImage(
      provider,
      width: kMediaDecodeCeiling,
      height: kMediaDecodeCeiling,
      policy: ResizeImagePolicy.fit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.item.diskPath;
    if (path == null || _missing) return const _MediaMissing();

    Widget image;
    if (widget.item.kind == MediaKind.gif) {
      image = AttachmentImage(
        path: path,
        animated: true,
        fit: BoxFit.contain,
        errorWidget: const _MediaMissing(),
      );
    } else {
      image = Image(
        image: _provider(path),
        fit: BoxFit.contain,
        filterQuality: widget.filterQuality,
        errorBuilder: (_, _, _) => const _MediaMissing(),
      );
    }

    if (widget.quarterTurns % 4 != 0) {
      image = RotatedBox(quarterTurns: widget.quarterTurns, child: image);
    }

    return ZoomSurface(
      transform: widget.transform,
      minScale: widget.minScale,
      maxScale: widget.maxScale,
      enabled: widget.isCurrent,
      onViewport: (viewport) {
        if (viewport == _viewport) return;
        _viewport = viewport;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _publish();
        });
      },
      onTapAt: widget.onTapAt,
      onDoubleTapAt: widget.onDoubleTapAt,
      onSecondaryTapAt: widget.onSecondaryTapAt,
      child: Center(child: image),
    );
  }
}

/// Pan and zoom over any contained content: a still in the media viewer, a
/// live screen share on the phone. Owns no zoom state: [transform] is the
/// host's, so a readout or a reset speaks about the same matrix.
class ZoomSurface extends StatefulWidget {
  final TransformationController transform;
  final double minScale;
  final double maxScale;

  /// False lays the content out with no gestures, for a neighbour page.
  final bool enabled;
  final ValueChanged<Size>? onViewport;
  final void Function(Offset local)? onTapAt;
  final void Function(Offset local)? onDoubleTapAt;

  /// Window-space position of a right click, for the overflow menu.
  final void Function(Offset global)? onSecondaryTapAt;
  final Widget child;

  const ZoomSurface({
    super.key,
    required this.transform,
    required this.child,
    this.minScale = 1.0,
    this.maxScale = 8.0,
    this.enabled = true,
    this.onViewport,
    this.onTapAt,
    this.onDoubleTapAt,
    this.onSecondaryTapAt,
  });

  @override
  State<ZoomSurface> createState() => _ZoomSurfaceState();
}

class _ZoomSurfaceState extends State<ZoomSurface> {
  Size? _viewport;
  Offset _lastTapDown = Offset.zero;

  /// Where the pointer was last seen, in this view's own coordinates.
  Offset? _pointerLocal;

  bool _panZoomActive = false;
  Offset? _zoomAnchor;
  Offset? _zoomAnchorScene;
  bool _applyingAnchor = false;
  Timer? _settleTimer;
  TransformationController? _settlingOn;

  @override
  void dispose() {
    _endSettle();
    super.dispose();
  }

  @override
  void didUpdateWidget(ZoomSurface old) {
    super.didUpdateWidget(old);
    if (old.transform != widget.transform || old.enabled != widget.enabled) {
      _endSettle();
    }
  }

  void _panZoomStart(PointerPanZoomStartEvent event) {
    _panZoomActive = true;
    _zoomAnchor = null;
    _zoomAnchorScene = null;
    _pointerLocal ??= event.localPosition;
  }

  /// A pinch only becomes a zoom once the scale leaves 1, so a two-finger pan
  /// that turns into a pinch anchors where the fingers were then, not where
  /// the gesture began.
  void _panZoomUpdate(PointerPanZoomUpdateEvent event) {
    if (_zoomAnchor != null || (event.scale - 1.0).abs() < 0.01) return;
    final anchor = _pointerLocal ?? event.localPosition;
    _zoomAnchor = anchor;
    _zoomAnchorScene = widget.transform.toScene(anchor);
  }

  void _panZoomEnd(PointerPanZoomEndEvent event) {
    _panZoomActive = false;
    _startSettle();
  }

  /// Pins a trackpad pinch to the pointer, after InteractiveViewer applied its
  /// own scale and translation.
  ///
  /// A pan-zoom gesture's focal point is the pointer PLUS its accumulated pan,
  /// and Windows reports a pan big enough to anchor the zoom at twice the
  /// cursor, where the boundary clamp then parks it in a corner.
  void _reanchorZoom(ScaleUpdateDetails details) {
    if (!_panZoomActive) return;
    _applyAnchor();
  }

  void _applyAnchor() {
    final anchor = _zoomAnchor;
    final anchorScene = _zoomAnchorScene;
    final viewport = _viewport;
    if (anchor == null || anchorScene == null || viewport == null) return;
    final drift = widget.transform.toScene(anchor) - anchorScene;
    final next = widget.transform.value.clone()
      ..translateByDouble(drift.dx, drift.dy, 0, 1);
    final scale = next.getMaxScaleOnAxis();
    final translation = next.getTranslation();
    next.setTranslationRaw(
      _clampAxis(translation.x, viewport.width, scale),
      _clampAxis(translation.y, viewport.height, scale),
      0,
    );
    _applyingAnchor = true;
    widget.transform.value = next;
    _applyingAnchor = false;
  }

  /// InteractiveViewer carries the pinch on after the fingers lift, about the
  /// same focal point it got wrong during the gesture, so the anchor outlives
  /// the gesture until the matrix stops moving on its own.
  void _startSettle() {
    if (_zoomAnchor == null) return;
    _settlingOn = widget.transform..addListener(_onSettleTick);
    _armSettle();
  }

  void _armSettle() {
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 120), _endSettle);
  }

  void _onSettleTick() {
    if (_applyingAnchor) return;
    _armSettle();
    _applyAnchor();
  }

  void _endSettle() {
    _settleTimer?.cancel();
    _settleTimer = null;
    _settlingOn?.removeListener(_onSettleTick);
    _settlingOn = null;
    _zoomAnchor = null;
    _zoomAnchorScene = null;
  }

  /// Keeps the content covering the viewport, the boundary InteractiveViewer
  /// enforces on every translation of its own.
  static double _clampAxis(double value, double extent, double scale) {
    final lower = extent * (1 - scale);
    if (lower >= 0) return 0;
    return value.clamp(lower, 0.0);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (viewport != _viewport) {
          _viewport = viewport;
          widget.onViewport?.call(viewport);
        }
        Widget viewer = InteractiveViewer(
          transformationController: widget.transform,
          minScale: widget.minScale,
          maxScale: widget.maxScale,
          // One wheel notch is e^(100/scaleFactor); 450 puts it at 1.25x, the
          // same step the zoom keys take.
          scaleFactor: 450,
          panEnabled: widget.enabled,
          scaleEnabled: widget.enabled,
          onInteractionStart: (_) => _endSettle(),
          onInteractionUpdate: _reanchorZoom,
          child: widget.child,
        );
        if (!widget.enabled) return viewer;
        viewer = Listener(
          onPointerHover: (e) => _pointerLocal = e.localPosition,
          onPointerDown: (e) => _pointerLocal = e.localPosition,
          onPointerMove: (e) => _pointerLocal = e.localPosition,
          onPointerPanZoomStart: _panZoomStart,
          onPointerPanZoomUpdate: _panZoomUpdate,
          onPointerPanZoomEnd: _panZoomEnd,
          child: viewer,
        );
        final onDoubleTapAt = widget.onDoubleTapAt;
        return GestureDetector(
          onTapDown: (d) => _lastTapDown = d.localPosition,
          onTapUp: (d) => widget.onTapAt?.call(d.localPosition),
          onDoubleTapDown: (d) => _lastTapDown = d.localPosition,
          // Null leaves single taps undelayed when nothing wants a double.
          onDoubleTap:
              onDoubleTapAt == null ? null : () => onDoubleTapAt(_lastTapDown),
          onSecondaryTapUp: (d) =>
              widget.onSecondaryTapAt?.call(d.globalPosition),
          child: viewer,
        );
      },
    );
  }
}

/// The honest end state for a file that is no longer on this device: the
/// viewer says so instead of painting a black rectangle.
class _MediaMissing extends StatelessWidget {
  const _MediaMissing();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, size: 32, color: hollow.textSecondary),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'This file is no longer on this device',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontSize: 13,
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}
