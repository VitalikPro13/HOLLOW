import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// Shows a crop dialog for an image. Returns the cropped region as raw PNG bytes,
/// or null if cancelled.
///
/// [aspectRatio] is width/height (e.g. 1.0 for square avatar, 3.0 for banner).
/// [title] is the dialog title (e.g. "Crop Avatar").
Future<Uint8List?> showImageCropDialog({
  required BuildContext context,
  required Uint8List imageBytes,
  required double aspectRatio,
  required String title,
}) {
  return showHollowDialog<Uint8List?>(
    context: context,
    builder: (ctx) => _ImageCropDialog(
      imageBytes: imageBytes,
      aspectRatio: aspectRatio,
      title: title,
    ),
  );
}

class _ImageCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final double aspectRatio;
  final String title;

  const _ImageCropDialog({
    required this.imageBytes,
    required this.aspectRatio,
    required this.title,
  });

  @override
  State<_ImageCropDialog> createState() => _ImageCropDialogState();
}

class _ImageCropDialogState extends State<_ImageCropDialog> {
  ui.Image? _decodedImage;
  bool _imageLoaded = false;

  // Display area (image scaled to fit the dialog)
  static const double _maxDisplayWidth = 420.0;
  static const double _maxDisplayHeight = 380.0;

  // The image display size (scaled to fit within max bounds)
  double _displayW = 0;
  double _displayH = 0;

  // Crop rect in display coordinates
  late Rect _cropRect;

  // Drag state
  _DragMode _dragMode = _DragMode.none;
  Offset _dragStart = Offset.zero;
  late Rect _cropAtDragStart;

  // Minimum crop size in display px
  static const double _minCropSide = 40;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final codec = await ui.instantiateImageCodec(widget.imageBytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;

    final img = frame.image;
    final imgW = img.width.toDouble();
    final imgH = img.height.toDouble();

    // Scale image to fit within display bounds
    final scaleX = _maxDisplayWidth / imgW;
    final scaleY = _maxDisplayHeight / imgH;
    final scale = min(scaleX, scaleY).clamp(0.0, 1.0); // never upscale
    // But if image is small, allow some upscaling so it's usable
    final finalScale = min(scaleX, scaleY);

    _displayW = imgW * finalScale;
    _displayH = imgH * finalScale;

    // Initial crop: largest rect with target aspect that fits the display image
    final ar = widget.aspectRatio;
    double cropW, cropH;
    if (_displayW / _displayH > ar) {
      // Image is wider than aspect — constrain by height
      cropH = _displayH;
      cropW = cropH * ar;
    } else {
      // Image is taller than aspect — constrain by width
      cropW = _displayW;
      cropH = cropW / ar;
    }
    final cropX = (_displayW - cropW) / 2;
    final cropY = (_displayH - cropH) / 2;
    _cropRect = Rect.fromLTWH(cropX, cropY, cropW, cropH);

    setState(() {
      _decodedImage = img;
      _imageLoaded = true;
    });
  }

  void _clampCrop() {
    double l = _cropRect.left;
    double t = _cropRect.top;
    double w = _cropRect.width;
    double h = _cropRect.height;
    // Clamp position
    l = l.clamp(0.0, _displayW - w);
    t = t.clamp(0.0, _displayH - h);
    _cropRect = Rect.fromLTWH(l, t, w, h);
  }

  void _onPanStart(DragStartDetails details, _DragMode mode) {
    _dragMode = mode;
    _dragStart = details.localPosition;
    _cropAtDragStart = _cropRect;
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_dragMode == _DragMode.none) return;

    final delta = details.localPosition - _dragStart;
    final ar = widget.aspectRatio;

    setState(() {
      if (_dragMode == _DragMode.move) {
        _cropRect = Rect.fromLTWH(
          (_cropAtDragStart.left + delta.dx).clamp(0.0, _displayW - _cropRect.width),
          (_cropAtDragStart.top + delta.dy).clamp(0.0, _displayH - _cropRect.height),
          _cropRect.width,
          _cropRect.height,
        );
      } else {
        // Resize from a corner/edge — compute new size with fixed aspect ratio
        double newW = _cropAtDragStart.width;
        double newH = _cropAtDragStart.height;
        double newL = _cropAtDragStart.left;
        double newT = _cropAtDragStart.top;

        switch (_dragMode) {
          case _DragMode.topLeft:
            newW = (_cropAtDragStart.width - delta.dx).clamp(_minCropSide, _displayW);
            newH = newW / ar;
            newL = _cropAtDragStart.right - newW;
            newT = _cropAtDragStart.bottom - newH;
          case _DragMode.topRight:
            newW = (_cropAtDragStart.width + delta.dx).clamp(_minCropSide, _displayW);
            newH = newW / ar;
            newT = _cropAtDragStart.bottom - newH;
          case _DragMode.bottomLeft:
            newW = (_cropAtDragStart.width - delta.dx).clamp(_minCropSide, _displayW);
            newH = newW / ar;
            newL = _cropAtDragStart.right - newW;
          case _DragMode.bottomRight:
            newW = (_cropAtDragStart.width + delta.dx).clamp(_minCropSide, _displayW);
            newH = newW / ar;
          default:
            break;
        }

        // Ensure minimum height
        if (newH < _minCropSide) {
          newH = _minCropSide;
          newW = newH * ar;
        }

        // Clamp to image bounds
        if (newL < 0) { newL = 0; newW = _cropAtDragStart.right; newH = newW / ar; }
        if (newT < 0) { newT = 0; newH = _cropAtDragStart.bottom; newW = newH * ar; }
        if (newL + newW > _displayW) { newW = _displayW - newL; newH = newW / ar; }
        if (newT + newH > _displayH) { newH = _displayH - newT; newW = newH * ar; }

        _cropRect = Rect.fromLTWH(newL, newT, newW, newH);
      }
    });
  }

  void _onPanEnd(DragEndDetails details) {
    _dragMode = _DragMode.none;
  }

  Future<void> _onConfirm() async {
    if (_decodedImage == null) return;

    final imgW = _decodedImage!.width.toDouble();
    final imgH = _decodedImage!.height.toDouble();

    // Convert crop rect from display coords to image coords
    final scaleX = imgW / _displayW;
    final scaleY = imgH / _displayH;
    final srcRect = Rect.fromLTWH(
      _cropRect.left * scaleX,
      _cropRect.top * scaleY,
      _cropRect.width * scaleX,
      _cropRect.height * scaleY,
    );

    // Render cropped region
    final outW = srcRect.width.round();
    final outH = srcRect.height.round();

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
  }

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: max(_displayW, 300) + HollowSpacing.xl * 2,
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HollowSpacing.xl,
                  HollowSpacing.lg,
                  HollowSpacing.xl,
                  HollowSpacing.md,
                ),
                child: Row(
                  children: [
                    Text(
                      widget.title,
                      style: HollowTypography.subheading.copyWith(
                        color: hollow.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Drag to move, corners to resize',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              // Image + crop overlay
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                child: _imageLoaded && _decodedImage != null
                    ? SizedBox(
                        width: _displayW,
                        height: _displayH,
                        child: Stack(
                          children: [
                            // Full image
                            Positioned.fill(
                              child: Image.memory(
                                widget.imageBytes,
                                fit: BoxFit.fill,
                                width: _displayW,
                                height: _displayH,
                              ),
                            ),

                            // Dark overlay outside crop
                            Positioned.fill(
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  painter: _CropOverlayPainter(
                                    cropRect: _cropRect,
                                    overlayColor: Colors.black.withValues(alpha: 0.6),
                                    borderColor: hollow.accent,
                                  ),
                                ),
                              ),
                            ),

                            // Drag: move the crop rect
                            Positioned.fromRect(
                              rect: _cropRect,
                              child: GestureDetector(
                                onPanStart: (d) => _onPanStart(d, _DragMode.move),
                                onPanUpdate: _onPanUpdate,
                                onPanEnd: _onPanEnd,
                                child: MouseRegion(
                                  cursor: SystemMouseCursors.move,
                                  child: Container(color: Colors.transparent),
                                ),
                              ),
                            ),

                            // Corner handles
                            _buildHandle(hollow, _cropRect.topLeft, _DragMode.topLeft, SystemMouseCursors.resizeUpLeft),
                            _buildHandle(hollow, _cropRect.topRight, _DragMode.topRight, SystemMouseCursors.resizeUpRight),
                            _buildHandle(hollow, _cropRect.bottomLeft, _DragMode.bottomLeft, SystemMouseCursors.resizeDownLeft),
                            _buildHandle(hollow, _cropRect.bottomRight, _DragMode.bottomRight, SystemMouseCursors.resizeDownRight),
                          ],
                        ),
                      )
                    : SizedBox(
                        width: 300,
                        height: 200,
                        child: Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: hollow.accent,
                            ),
                          ),
                        ),
                      ),
              ),

              // Actions
              Padding(
                padding: const EdgeInsets.all(HollowSpacing.lg),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    HollowButton.ghost(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    HollowButton.filled(
                      onPressed: _onConfirm,
                      child: const Text('Apply'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHandle(HollowTheme hollow, Offset center, _DragMode mode, MouseCursor cursor) {
    const handleSize = 18.0;
    const visualSize = 10.0;
    return Positioned(
      left: center.dx - handleSize / 2,
      top: center.dy - handleSize / 2,
      width: handleSize,
      height: handleSize,
      child: GestureDetector(
        onPanStart: (d) => _onPanStart(d, mode),
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: MouseRegion(
          cursor: cursor,
          child: Center(
            child: Container(
              width: visualSize,
              height: visualSize,
              decoration: BoxDecoration(
                color: hollow.accent,
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: Colors.white, width: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _DragMode { none, move, topLeft, topRight, bottomLeft, bottomRight }

/// Paints a dark overlay around the crop rect and a border on the crop rect.
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

    // Rule-of-thirds grid lines (subtle)
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
  }

  @override
  bool shouldRepaint(_CropOverlayPainter old) =>
      cropRect != old.cropRect;
}
