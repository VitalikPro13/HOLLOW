import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';

/// Shows a full-screen mobile crop route. Returns cropped PNG bytes or null.
///
/// Uses the standard mobile crop pattern: fixed crop frame in center,
/// user drags and pinch-zooms the image underneath. The image is always
/// clamped so the crop frame never shows empty space.
Future<Uint8List?> showMobileImageCrop({
  required BuildContext context,
  required Uint8List imageBytes,
  required double aspectRatio,
  required String title,
}) {
  return Navigator.push<Uint8List?>(
    context,
    MaterialPageRoute(
      builder: (_) => MobileImageCropRoute(
        imageBytes: imageBytes,
        aspectRatio: aspectRatio,
        title: title,
      ),
    ),
  );
}

class MobileImageCropRoute extends StatefulWidget {
  final Uint8List imageBytes;
  final double aspectRatio;
  final String title;

  const MobileImageCropRoute({
    super.key,
    required this.imageBytes,
    required this.aspectRatio,
    required this.title,
  });

  @override
  State<MobileImageCropRoute> createState() => _MobileImageCropRouteState();
}

class _MobileImageCropRouteState extends State<MobileImageCropRoute> {
  ui.Image? _decodedImage;
  bool _imageLoaded = false;
  bool _cropping = false;
  bool _layoutDone = false;

  // Crop frame (fixed position within the available area)
  Rect _cropFrame = Rect.zero;

  // Image base display size (at scale 1.0, fills crop frame)
  double _baseW = 0;
  double _baseH = 0;

  // Current transform state
  double _scale = 1.0;
  double _offsetX = 0;
  double _offsetY = 0;

  // Gesture tracking
  double _startScale = 1.0;
  double _startOffsetX = 0;
  double _startOffsetY = 0;
  Offset _startFocal = Offset.zero;

  static bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    // Lock orientation while cropping — a rotation re-runs _initLayout and
    // would silently discard the user's crop position.
    if (_isMobilePlatform) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    // Cap the decode size: a full-res camera photo decoded as raw RGBA can
    // exceed 100 MB and OOM budget phones. 2048px is plenty for avatar /
    // banner crops (the Rust processor downsizes further anyway).
    final codec = await ui.instantiateImageCodec(
      widget.imageBytes,
      targetWidth: 2048,
      allowUpscaling: false,
    );
    final frame = await codec.getNextFrame();
    if (!mounted) return;

    setState(() {
      _decodedImage = frame.image;
      _imageLoaded = true;
    });
  }

  void _initLayout(BoxConstraints constraints) {
    if (_decodedImage == null || _layoutDone) return;
    _layoutDone = true;

    final availW = constraints.maxWidth;
    final availH = constraints.maxHeight;
    final ar = widget.aspectRatio;

    // Crop frame: largest rect with target aspect that fits with padding
    const padded = 32.0;
    final maxCropW = availW - padded * 2;
    final maxCropH = availH - padded * 2;

    double cropW, cropH;
    if (maxCropW / maxCropH > ar) {
      cropH = maxCropH;
      cropW = cropH * ar;
    } else {
      cropW = maxCropW;
      cropH = cropW / ar;
    }

    _cropFrame = Rect.fromLTWH(
      (availW - cropW) / 2,
      (availH - cropH) / 2,
      cropW,
      cropH,
    );

    // Base image size: scale so image fills the crop frame at scale 1.0
    final imgW = _decodedImage!.width.toDouble();
    final imgH = _decodedImage!.height.toDouble();
    final fillScale = max(cropW / imgW, cropH / imgH);

    _baseW = imgW * fillScale;
    _baseH = imgH * fillScale;

    // Center image over crop frame
    _offsetX = _cropFrame.left - (_baseW - cropW) / 2;
    _offsetY = _cropFrame.top - (_baseH - cropH) / 2;
    _scale = 1.0;
  }

  void _clampOffset() {
    final w = _baseW * _scale;
    final h = _baseH * _scale;

    // Image left edge must be <= crop left, image right edge must be >= crop right
    final maxOffX = _cropFrame.left;
    final minOffX = _cropFrame.right - w;
    _offsetX = _offsetX.clamp(minOffX, maxOffX);

    final maxOffY = _cropFrame.top;
    final minOffY = _cropFrame.bottom - h;
    _offsetY = _offsetY.clamp(minOffY, maxOffY);
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startScale = _scale;
    _startOffsetX = _offsetX;
    _startOffsetY = _offsetY;
    _startFocal = d.focalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    setState(() {
      // Apply scale (clamped so image always covers crop frame)
      final newScale = (_startScale * d.scale).clamp(1.0, 8.0);

      // Zoom around the focal point
      final focalDx = d.focalPoint.dx - _startFocal.dx;
      final focalDy = d.focalPoint.dy - _startFocal.dy;

      if (newScale != _scale) {
        // Adjust offset so the focal point stays fixed on the same image pixel
        final scaleRatio = newScale / _scale;
        final focalOnImage = Offset(
          d.focalPoint.dx - _offsetX,
          d.focalPoint.dy - _offsetY,
        );
        _offsetX = d.focalPoint.dx - focalOnImage.dx * scaleRatio;
        _offsetY = d.focalPoint.dy - focalOnImage.dy * scaleRatio;
        _scale = newScale;
      }

      // Apply pan
      _offsetX = _startOffsetX + focalDx + (_offsetX - _startOffsetX);
      _offsetY = _startOffsetY + focalDy + (_offsetY - _startOffsetY);

      // But actually, let's simplify: just compute from start state
      _scale = newScale;
      final scaleChange = _scale / _startScale;
      // Focal point relative to start image position
      final focalRelX = _startFocal.dx - _startOffsetX;
      final focalRelY = _startFocal.dy - _startOffsetY;
      _offsetX = _startFocal.dx - focalRelX * scaleChange + focalDx;
      _offsetY = _startFocal.dy - focalRelY * scaleChange + focalDy;

      _clampOffset();
    });
  }

  void _onScaleEnd(ScaleEndDetails d) {
    // Ensure clamped after gesture ends
    setState(() => _clampOffset());
  }

  Future<void> _onConfirm() async {
    if (_decodedImage == null || _cropping) return;
    setState(() => _cropping = true);

    try {
      final imgW = _decodedImage!.width.toDouble();
      final imgH = _decodedImage!.height.toDouble();

      // The crop frame in image-pixel coordinates:
      // display position of a pixel = offset + pixelInBase * scale
      // so pixelInBase = (displayPos - offset) / scale
      // and imagePixel = pixelInBase * (imgW / baseW)

      final toBaseX = 1.0 / _scale;
      final toBaseY = 1.0 / _scale;
      final baseToImgX = imgW / _baseW;
      final baseToImgY = imgH / _baseH;

      final srcLeft = (_cropFrame.left - _offsetX) * toBaseX * baseToImgX;
      final srcTop = (_cropFrame.top - _offsetY) * toBaseY * baseToImgY;
      final srcW = _cropFrame.width * toBaseX * baseToImgX;
      final srcH = _cropFrame.height * toBaseY * baseToImgY;

      var srcRect = Rect.fromLTWH(srcLeft, srcTop, srcW, srcH);

      // Safety clamp
      srcRect = Rect.fromLTRB(
        srcRect.left.clamp(0, imgW),
        srcRect.top.clamp(0, imgH),
        srcRect.right.clamp(0, imgW),
        srcRect.bottom.clamp(0, imgH),
      );

      final outW = srcRect.width.round().clamp(1, imgW.round());
      final outH = srcRect.height.round().clamp(1, imgH.round());

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final paint = Paint()..filterQuality = FilterQuality.high;
      canvas.drawImageRect(
        _decodedImage!,
        srcRect,
        Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        paint,
      );

      final picture = recorder.endRecording();
      final img = await picture.toImage(outW, outH);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);

      if (byteData != null && mounted) {
        Navigator.of(context).pop(byteData.buffer.asUint8List());
      }
    } catch (_) {
      if (mounted) Navigator.of(context).pop(null);
    }
  }

  @override
  void dispose() {
    if (_isMobilePlatform) {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
    _decodedImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HollowSpacing.xs, HollowSpacing.sm,
                HollowSpacing.lg, HollowSpacing.sm,
              ),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(null),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  Text(
                    widget.title,
                    style: HollowTypography.subheading.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Pinch to zoom',
                    style: HollowTypography.caption.copyWith(
                      color: Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),

            // Image + crop overlay
            Expanded(
              child: _imageLoaded && _decodedImage != null
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        _initLayout(constraints);

                        final displayW = _baseW * _scale;
                        final displayH = _baseH * _scale;

                        return GestureDetector(
                          onScaleStart: _onScaleStart,
                          onScaleUpdate: _onScaleUpdate,
                          onScaleEnd: _onScaleEnd,
                          child: Stack(
                            children: [
                              // Image positioned by our manual transform
                              Positioned(
                                left: _offsetX,
                                top: _offsetY,
                                width: displayW,
                                height: displayH,
                                child: Image.memory(
                                  widget.imageBytes,
                                  fit: BoxFit.fill,
                                  width: displayW,
                                  height: displayH,
                                ),
                              ),

                              // Fixed crop overlay
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: CustomPaint(
                                    painter: _CropOverlayPainter(
                                      cropRect: _cropFrame,
                                      overlayColor: Colors.black.withValues(alpha: 0.6),
                                      borderColor: hollow.accent,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    )
                  : const Center(
                      child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white54,
                        ),
                      ),
                    ),
            ),

            // Bottom actions
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.lg),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HollowButton.ghost(
                    onPressed: () => Navigator.of(context).pop(null),
                    child: Text('Cancel',
                        style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.filled(
                    onPressed: _cropping ? null : _onConfirm,
                    child: Text(_cropping ? 'Cropping...' : 'Apply'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CropOverlayPainter extends CustomPainter {
  final Rect cropRect;
  final Color overlayColor;
  final Color borderColor;

  _CropOverlayPainter({
    required this.cropRect,
    required this.overlayColor,
    required this.borderColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final fullRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // Dark overlay outside crop
    final overlayPaint = Paint()..color = overlayColor;
    canvas.save();
    canvas.clipRect(cropRect, clipOp: ui.ClipOp.difference);
    canvas.drawRect(fullRect, overlayPaint);
    canvas.restore();

    // Border around crop
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(cropRect, borderPaint);

    // Rule-of-thirds grid
    final gridPaint = Paint()
      ..color = borderColor.withValues(alpha: 0.3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    final thirdW = cropRect.width / 3;
    final thirdH = cropRect.height / 3;
    for (int i = 1; i <= 2; i++) {
      canvas.drawLine(
        Offset(cropRect.left + thirdW * i, cropRect.top),
        Offset(cropRect.left + thirdW * i, cropRect.bottom),
        gridPaint,
      );
      canvas.drawLine(
        Offset(cropRect.left, cropRect.top + thirdH * i),
        Offset(cropRect.right, cropRect.top + thirdH * i),
        gridPaint,
      );
    }

    // Corner brackets
    final bracketPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const bl = 20.0;

    canvas.drawLine(cropRect.topLeft, Offset(cropRect.left + bl, cropRect.top), bracketPaint);
    canvas.drawLine(cropRect.topLeft, Offset(cropRect.left, cropRect.top + bl), bracketPaint);
    canvas.drawLine(cropRect.topRight, Offset(cropRect.right - bl, cropRect.top), bracketPaint);
    canvas.drawLine(cropRect.topRight, Offset(cropRect.right, cropRect.top + bl), bracketPaint);
    canvas.drawLine(cropRect.bottomLeft, Offset(cropRect.left + bl, cropRect.bottom), bracketPaint);
    canvas.drawLine(cropRect.bottomLeft, Offset(cropRect.left, cropRect.bottom - bl), bracketPaint);
    canvas.drawLine(cropRect.bottomRight, Offset(cropRect.right - bl, cropRect.bottom), bracketPaint);
    canvas.drawLine(cropRect.bottomRight, Offset(cropRect.right, cropRect.bottom - bl), bracketPaint);
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) =>
      cropRect != old.cropRect;
}
