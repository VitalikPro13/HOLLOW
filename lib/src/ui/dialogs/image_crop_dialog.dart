import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';

/// Shows a crop dialog, returning the cropped region as raw PNG bytes or null.
///
/// [aspectRatio] is width over height: 1.0 for an avatar or server icon, 2.5 for
/// a USER profile banner (the ratio every banner surface and Rust's storage
/// share), 3.0 for a SERVER banner, 16/9 for the chat background.
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

class _ImageCropDialogState extends State<_ImageCropDialog>
    with HollowDialogAction {
  ui.Image? _decodedImage;
  bool _imageLoaded = false;

  /// The bytes are not an image Flutter can decode (HEIC, a corrupt file).
  bool _decodeFailed = false;

  static const double _maxDisplayWidth = 420.0;
  static const double _maxDisplayHeight = 380.0;

  double _displayW = 0;
  double _displayH = 0;

  late Rect _cropRect;

  _DragMode _dragMode = _DragMode.none;
  Offset _dragStart = Offset.zero;
  late Rect _cropAtDragStart;

  static const double _minCropSide = 40;

  /// The corner handle's hit area, the desktop target minimum, around a
  /// small painted square.
  static const double _handleHit = 28;
  static const double _handleMark = 10;

  /// The loading box before the image decodes.
  static const Size _placeholder = Size(300, 200);

  /// One arrow-key step of the crop, and a Shift step.
  static const double _nudge = HollowSpacing.xs;
  static const double _bigNudge = HollowSpacing.lg;

  @override
  void initState() {
    super.initState();
    _decodeImage();
  }

  Future<void> _decodeImage() async {
    final ui.FrameInfo frame;
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      frame = await codec.getNextFrame();
    } catch (_) {
      if (mounted) setState(() => _decodeFailed = true);
      return;
    }
    if (!mounted) {
      frame.image.dispose();
      return;
    }

    final img = frame.image;
    final imgW = img.width.toDouble();
    final imgH = img.height.toDouble();

    final scaleX = _maxDisplayWidth / imgW;
    final scaleY = _maxDisplayHeight / imgH;
    // A small image is allowed to upscale, or the crop is unusable.
    final finalScale = min(scaleX, scaleY);

    _displayW = imgW * finalScale;
    _displayH = imgH * finalScale;

    final ar = widget.aspectRatio;
    double cropW, cropH;
    if (_displayW / _displayH > ar) {
      cropH = _displayH;
      cropW = cropH * ar;
    } else {
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

        if (newH < _minCropSide) {
          newH = _minCropSide;
          newW = newH * ar;
        }

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
    final image = _decodedImage;
    if (image == null) return;
    Uint8List? bytes;
    final ok = await runDialogAction(() async {
      final scaleX = image.width / _displayW;
      final scaleY = image.height / _displayH;
      final srcRect = Rect.fromLTWH(
        _cropRect.left * scaleX,
        _cropRect.top * scaleY,
        _cropRect.width * scaleX,
        _cropRect.height * scaleY,
      );
      final outW = srcRect.width.round();
      final outH = srcRect.height.round();

      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        srcRect,
        Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
        Paint()..filterQuality = FilterQuality.high,
      );
      final cropped = await recorder.endRecording().toImage(outW, outH);
      final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
      cropped.dispose();
      if (data == null) throw StateError('no PNG bytes');
      bytes = data.buffer.asUint8List();
    }, fallback: "Couldn't crop that image. Try again.");
    if (ok && mounted) Navigator.of(context).pop(bytes);
  }

  /// Arrow keys move the crop; Enter applies it.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      _onConfirm();
      return KeyEventResult.handled;
    }
    if (!_imageLoaded) return KeyEventResult.ignored;
    final step = HardwareKeyboard.instance.isShiftPressed ? _bigNudge : _nudge;
    final delta = switch (key) {
      LogicalKeyboardKey.arrowLeft => Offset(-step, 0),
      LogicalKeyboardKey.arrowRight => Offset(step, 0),
      LogicalKeyboardKey.arrowUp => Offset(0, -step),
      LogicalKeyboardKey.arrowDown => Offset(0, step),
      _ => null,
    };
    if (delta == null) return KeyEventResult.ignored;
    setState(() {
      _cropRect = Rect.fromLTWH(
        (_cropRect.left + delta.dx).clamp(0.0, _displayW - _cropRect.width),
        (_cropRect.top + delta.dy).clamp(0.0, _displayH - _cropRect.height),
        _cropRect.width,
        _cropRect.height,
      );
    });
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Not HollowDialog: its scrolling body would contend with the crop drags.
    Widget dialog = HollowDialogSurface(
      width: max(_displayW, _placeholder.width) + HollowSpacing.xl * 2,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title,
            style: HollowTypography.heading.copyWith(
              color: hollow.textPrimary,
            ),
          ),
          if (!_decodeFailed) ...[
            const SizedBox(height: HollowSpacing.xs),
            Text(
              'Drag to move, corners to resize. Arrow keys move it too.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
              ),
            ),
          ],
          const SizedBox(height: HollowSpacing.lg),

          Center(
            child: _imageLoaded && _decodedImage != null
                ? SizedBox(
                    width: _displayW,
                    height: _displayH,
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Image.memory(
                            widget.imageBytes,
                            fit: BoxFit.fill,
                            width: _displayW,
                            height: _displayH,
                          ),
                        ),

                        Positioned.fill(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: _CropOverlayPainter(
                                cropRect: _cropRect,
                                overlayColor: HollowColors.mediaScrim,
                                borderColor: hollow.accent,
                              ),
                            ),
                          ),
                        ),

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

                        _buildHandle(hollow, _cropRect.topLeft, _DragMode.topLeft, SystemMouseCursors.resizeUpLeft),
                        _buildHandle(hollow, _cropRect.topRight, _DragMode.topRight, SystemMouseCursors.resizeUpRight),
                        _buildHandle(hollow, _cropRect.bottomLeft, _DragMode.bottomLeft, SystemMouseCursors.resizeDownLeft),
                        _buildHandle(hollow, _cropRect.bottomRight, _DragMode.bottomRight, SystemMouseCursors.resizeDownRight),
                      ],
                    ),
                  )
                : SizedBox.fromSize(
                    size: _placeholder,
                    child: Center(
                      child: _decodeFailed
                          ? const HollowEmptyState(
                              title: "This image can't be opened",
                              description: 'Try a JPEG or PNG.',
                            )
                          : const HollowSpinner.large(delayed: true),
                    ),
                  ),
          ),

          if (actionError != null) ...[
            const SizedBox(height: HollowSpacing.lg),
            Text(
              actionError!,
              style: HollowTypography.bodySmall.copyWith(color: hollow.error),
            ),
          ],
          SizedBox(
              height: actionError != null ? HollowSpacing.md : HollowSpacing.xl),
          HollowButtonTouchScope(
            touch: HollowDialogSurface.isCompact(context),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HollowButton.ghost(
                  onPressed: actionRunning
                      ? null
                      : () => Navigator.of(context).pop(null),
                  child: Text(_decodeFailed ? 'Close' : 'Cancel'),
                ),
                if (!_decodeFailed) ...[
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.filled(
                    onPressed: _onConfirm,
                    loading: actionRunning,
                    child: const Text('Apply'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      ),
    );
    if (actionRunning) dialog = PopScope(canPop: false, child: dialog);
    return dialog;
  }

  Widget _buildHandle(HollowTheme hollow, Offset center, _DragMode mode, MouseCursor cursor) {
    return Positioned(
      left: center.dx - _handleHit / 2,
      top: center.dy - _handleHit / 2,
      width: _handleHit,
      height: _handleHit,
      child: GestureDetector(
        onPanStart: (d) => _onPanStart(d, mode),
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: MouseRegion(
          cursor: cursor,
          child: Center(
            child: Container(
              width: _handleMark,
              height: _handleMark,
              decoration: BoxDecoration(
                color: hollow.accent,
                borderRadius: BorderRadius.circular(hollow.radiusXs),
                border: Border.all(color: HollowColors.onMedia),
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

    final overlayPaint = Paint()..color = overlayColor;
    canvas.save();
    canvas.clipRect(cropRect, clipOp: ui.ClipOp.difference);
    canvas.drawRect(fullRect, overlayPaint);
    canvas.restore();

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(cropRect, borderPaint);

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
