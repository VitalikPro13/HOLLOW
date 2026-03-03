import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Pre-compiles GPU shaders used by Haven's UI before the first frame.
///
/// Skia lazily compiles a GPU shader the first time it encounters a draw
/// operation type. Each compilation can cost 20-200ms, causing dropped frames.
/// By drawing all our common primitives on an offscreen canvas at startup,
/// the shaders are compiled before any animation runs.
class HavenShaderWarmUp extends ShaderWarmUp {
  @override
  ui.Size get size => const ui.Size(200, 200);

  @override
  Future<void> warmUpOnCanvas(Canvas canvas) async {
    final rect = Offset.zero & size;

    // ── 1. Solid filled rectangles (backgrounds, surfaces) ──
    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFF0D0F14),
    );
    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFF14161C),
    );

    // ── 2. Rounded rectangles (buttons, cards, icons, text fields) ──
    for (final radius in [4.0, 6.0, 8.0, 12.0, 16.0, 24.0]) {
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

      // Filled
      canvas.drawRRect(
        rrect,
        Paint()..color = const Color(0xFF00BFA6),
      );

      // With border
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFF00BFA6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      // With border + alpha
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0x6600BFA6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

    // ── 3. Circles (avatars, status dots) ──
    canvas.drawCircle(
      const Offset(100, 100),
      24,
      Paint()..color = const Color(0xFF00BFA6),
    );
    canvas.drawCircle(
      const Offset(100, 100),
      7,
      Paint()..color = const Color(0xFF10B981),
    );

    // ── 4. Linear gradients (server strip bg, selection shimmer) ──
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D0F14), Color(0xFF0F1219)],
        ).createShader(rect),
    );

    // Horizontal gradient (shimmer)
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x0000BFA6), Color(0x1F00BFA6), Color(0x0000BFA6)],
        ).createShader(rect),
    );

    // ── 5. Radial gradients (ambient background blobs) ──
    canvas.drawCircle(
      const Offset(100, 100),
      100,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x0A00BFA6),
            const Color(0x0A00BFA6),
            const Color(0x0000BFA6),
          ],
          stops: const [0.0, 0.35, 1.0],
        ).createShader(Rect.fromCircle(center: const Offset(100, 100), radius: 100)),
    );
    canvas.drawCircle(
      const Offset(100, 100),
      100,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x0A6366F1),
            const Color(0x0A6366F1),
            const Color(0x006366F1),
          ],
          stops: const [0.0, 0.35, 1.0],
        ).createShader(Rect.fromCircle(center: const Offset(100, 100), radius: 100)),
    );

    // ── 6. Box shadows (dialogs, toast, hover glow) ──
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(20), const Radius.circular(12)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
    // Smaller shadow (button hover glow)
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(40), const Radius.circular(6)),
      Paint()
        ..color = const Color(0x3300BFA6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // ── 7. Clipping with rounded rect (avatar clips, RevealClip) ──
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect.deflate(10), const Radius.circular(24)),
    );
    canvas.drawRect(rect, Paint()..color = const Color(0xFF1A1D25));
    canvas.restore();

    // ── 8. Clipping with rect (RevealClip, width/height factor clips) ──
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * 0.5, size.height));
    canvas.drawRect(rect, Paint()..color = const Color(0xFF14161C));
    canvas.restore();

    // ── 9. Lines (dividers) ──
    canvas.drawLine(
      Offset.zero,
      Offset(size.width, 0),
      Paint()
        ..color = const Color(0x14FFFFFF)
        ..strokeWidth = 1.0,
    );

    // ── 10. Text rendering (trigger text shader compilation) ──
    final paragraphBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textDirection: TextDirection.ltr,
        fontSize: 14,
      ),
    )
      ..pushStyle(ui.TextStyle(color: const Color(0xFFF1F3F5)))
      ..addText('Haven shader warmup');
    final paragraph = paragraphBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 200));
    canvas.drawParagraph(paragraph, Offset.zero);

    // Bold text
    final boldBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textDirection: TextDirection.ltr,
        fontSize: 16,
        fontWeight: FontWeight.w700,
      ),
    )
      ..pushStyle(ui.TextStyle(
        color: const Color(0xFFF1F3F5),
        fontWeight: FontWeight.w700,
      ))
      ..addText('Bold Text');
    final boldParagraph = boldBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 200));
    canvas.drawParagraph(boldParagraph, const Offset(0, 20));

    // ── 11. Alpha compositing (Opacity, FadeTransition) ──
    canvas.saveLayer(rect, Paint()..color = const Color(0x80FFFFFF));
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xFF00BFA6),
    );
    canvas.restore();

    // ── 12. Transform (ScaleTransition, SlideTransition) ──
    canvas.save();
    canvas.translate(100, 100);
    canvas.scale(0.5);
    canvas.translate(-100, -100);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(24)),
      Paint()..color = const Color(0xFF1A1D25),
    );
    canvas.restore();
  }
}
