import 'package:flutter/material.dart';

import 'annotation_controller.dart';
import 'annotation_models.dart';
import 'annotation_painter.dart';

/// Captures pointer input, drives the [AnnotationController] and renders its
/// strokes through [AnnotationPainter].
class AnnotationCanvas extends StatefulWidget {
  final AnnotationController controller;
  const AnnotationCanvas({super.key, required this.controller});

  @override
  State<AnnotationCanvas> createState() => _AnnotationCanvasState();
}

class _AnnotationCanvasState extends State<AnnotationCanvas> {
  // The stroke currently being drawn (before pointer up).
  List<Offset>? _liveFreehand;
  Offset? _lineStart;
  Offset? _lineEnd;

  AnnotationController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant AnnotationCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChange);
      widget.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    _c.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  void _onPointerDown(PointerDownEvent e) {
    final p = e.localPosition;
    switch (_c.tool) {
      case AnnotationTool.freehand:
        setState(() => _liveFreehand = [p]);
        break;
      case AnnotationTool.line:
      case AnnotationTool.arrow:
        setState(() {
          _lineStart = p;
          _lineEnd = p;
        });
        break;
      case AnnotationTool.eraser:
        _c.eraseAt(p, _eraserRadius);
        break;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    final p = e.localPosition;
    switch (_c.tool) {
      case AnnotationTool.freehand:
        if (_liveFreehand == null) return;
        setState(() => _liveFreehand!.add(p));
        break;
      case AnnotationTool.line:
      case AnnotationTool.arrow:
        if (_lineStart == null) return;
        setState(() => _lineEnd = p);
        break;
      case AnnotationTool.eraser:
        _c.eraseAt(p, _eraserRadius);
        break;
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    switch (_c.tool) {
      case AnnotationTool.freehand:
        if (_liveFreehand == null || _liveFreehand!.length < 2) {
          // Treat a single tap as a tiny dot.
          if (_liveFreehand != null) {
            final dot = _liveFreehand!.first;
            _c.commitStroke(Stroke(
              tool: AnnotationTool.freehand,
              points: [dot, dot + const Offset(0.5, 0.5)],
              color: _c.color,
              width: _c.width,
              style: _c.style,
            ));
          }
        } else {
          _c.commitStroke(Stroke(
            tool: AnnotationTool.freehand,
            points: List.unmodifiable(_liveFreehand!),
            color: _c.color,
            width: _c.width,
            style: _c.style,
          ));
        }
        setState(() => _liveFreehand = null);
        break;
      case AnnotationTool.line:
      case AnnotationTool.arrow:
        if (_lineStart != null && _lineEnd != null) {
          _c.commitStroke(Stroke(
            tool: _c.tool,
            points: [_lineStart!, _lineEnd!],
            color: _c.color,
            width: _c.width,
            style: _c.style,
          ));
        }
        setState(() {
          _lineStart = null;
          _lineEnd = null;
        });
        break;
      case AnnotationTool.eraser:
        // Eraser commits on pointer move/down; nothing to do here.
        break;
    }
  }

  double get _eraserRadius => (_c.width * 4).clamp(12.0, 60.0);

  @override
  Widget build(BuildContext context) {
    Stroke? preview;
    if (_liveFreehand != null && _liveFreehand!.length >= 2) {
      preview = Stroke(
        tool: AnnotationTool.freehand,
        points: List.unmodifiable(_liveFreehand!),
        color: _c.color,
        width: _c.width,
        style: _c.style,
      );
    } else if (_lineStart != null && _lineEnd != null) {
      preview = Stroke(
        tool: _c.tool,
        points: [_lineStart!, _lineEnd!],
        color: _c.color,
        width: _c.width,
        style: _c.style,
      );
    }

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      child: MouseRegion(
        cursor: _cursorFor(_c.tool),
        child: CustomPaint(
          painter: AnnotationPainter(
            strokes: _c.visibleStrokes,
            preview: preview,
          ),
          size: Size.infinite,
        ),
      ),
    );
  }

  MouseCursor _cursorFor(AnnotationTool t) {
    switch (t) {
      case AnnotationTool.freehand:
      case AnnotationTool.line:
      case AnnotationTool.arrow:
        return SystemMouseCursors.precise;
      case AnnotationTool.eraser:
        return SystemMouseCursors.cell;
    }
  }
}
