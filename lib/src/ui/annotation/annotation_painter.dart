import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'annotation_models.dart';

/// Renders all committed strokes plus the in-progress preview stroke.
class AnnotationPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke? preview;

  AnnotationPainter({required this.strokes, required this.preview});

  @override
  void paint(Canvas canvas, Size size) {
    for (final s in strokes) {
      _drawStroke(canvas, s);
    }
    if (preview != null) {
      _drawStroke(canvas, preview!);
    }
  }

  void _drawStroke(Canvas canvas, Stroke s) {
    if (s.points.isEmpty) return;

    final paint = Paint()
      ..color = s.color
      ..strokeWidth = s.width
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (s.tool) {
      case AnnotationTool.freehand:
        _drawPath(canvas, _pathFromPoints(s.points), paint, s.style);
        break;
      case AnnotationTool.line:
        if (s.points.length < 2) return;
        final p = Path()
          ..moveTo(s.points.first.dx, s.points.first.dy)
          ..lineTo(s.points.last.dx, s.points.last.dy);
        _drawPath(canvas, p, paint, s.style);
        break;
      case AnnotationTool.arrow:
        if (s.points.length < 2) return;
        final a = s.points.first;
        final b = s.points.last;
        final shaft = Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy);
        _drawPath(canvas, shaft, paint, s.style);
        // The head is always solid, whatever the stroke style.
        _drawArrowHead(canvas, a, b, s.width, s.color);
        break;
      case AnnotationTool.eraser:
        // The eraser draws nothing; it only modifies the stroke list.
        break;
    }
  }

  Path _pathFromPoints(List<Offset> points) {
    final p = Path();
    p.moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      p.lineTo(points[i].dx, points[i].dy);
    }
    return p;
  }

  void _drawPath(Canvas canvas, Path source, Paint paint, LineStyle style) {
    if (style == LineStyle.solid) {
      canvas.drawPath(source, paint);
      return;
    }
    // Dotted and dashed walk the path's metrics and emit short subpaths.
    final dashLength = style == LineStyle.dotted ? paint.strokeWidth : 10.0;
    final gapLength = style == LineStyle.dotted ? paint.strokeWidth * 2 : 6.0;
    final dashed = Path();
    for (final metric in source.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final next = math.min(d + dashLength, metric.length);
        dashed.addPath(metric.extractPath(d, next), Offset.zero);
        d = next + gapLength;
      }
    }
    canvas.drawPath(dashed, paint);
  }

  void _drawArrowHead(
      Canvas canvas, Offset start, Offset end, double width, Color color) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 1e-3) return;
    final size = math.max(width * 3, 12.0);
    final angle = math.atan2(dy, dx);
    const headAngle = math.pi / 7;
    final p1 = Offset(
      end.dx - size * math.cos(angle - headAngle),
      end.dy - size * math.sin(angle - headAngle),
    );
    final p2 = Offset(
      end.dx - size * math.cos(angle + headAngle),
      end.dy - size * math.sin(angle + headAngle),
    );
    final headPath = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawPath(headPath, fill);
  }

  @override
  bool shouldRepaint(covariant AnnotationPainter old) =>
      old.strokes != strokes || old.preview != preview;
}

// Suppress unused import warning in some toolchains for ui.
// ignore: unused_element
ui.PointMode _suppress() => ui.PointMode.points;
