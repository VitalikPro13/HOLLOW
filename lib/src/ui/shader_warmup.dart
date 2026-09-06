import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Pre-compiles GPU shaders used by Hollow's UI before the first frame.
///
/// Skia compiles a shader the first time it meets a draw operation, at 20-200ms
/// each, so every primitive the UI uses is drawn offscreen at startup instead.
class HollowShaderWarmUp extends ShaderWarmUp {
  @override
  ui.Size get size => const ui.Size(200, 200);

  @override
  Future<void> warmUpOnCanvas(Canvas canvas) async {
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFF0D0F14),
    );
    canvas.drawRect(
      rect,
      Paint()..color = const Color(0xFF14161C),
    );

    for (final radius in [4.0, 6.0, 8.0, 12.0, 16.0, 24.0]) {
      final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

      canvas.drawRRect(
        rrect,
        Paint()..color = const Color(0xFF00BFA6),
      );

      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFF00BFA6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0x6600BFA6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }

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

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0D0F14), Color(0xFF0F1219)],
        ).createShader(rect),
    );

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x0000BFA6), Color(0x1F00BFA6), Color(0x0000BFA6)],
        ).createShader(rect),
    );

    canvas.drawCircle(
      const Offset(100, 100),
      100,
      Paint()
        ..shader = const RadialGradient(
          colors: [
            Color(0x0A00BFA6),
            Color(0x0A00BFA6),
            Color(0x0000BFA6),
          ],
          stops: [0.0, 0.35, 1.0],
        ).createShader(Rect.fromCircle(center: const Offset(100, 100), radius: 100)),
    );
    canvas.drawCircle(
      const Offset(100, 100),
      100,
      Paint()
        ..shader = const RadialGradient(
          colors: [
            Color(0x0A6366F1),
            Color(0x0A6366F1),
            Color(0x006366F1),
          ],
          stops: [0.0, 0.35, 1.0],
        ).createShader(Rect.fromCircle(center: const Offset(100, 100), radius: 100)),
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(20), const Radius.circular(12)),
      Paint()
        ..color = const Color(0x33000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 24),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(40), const Radius.circular(6)),
      Paint()
        ..color = const Color(0x3300BFA6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(rect.deflate(10), const Radius.circular(24)),
    );
    canvas.drawRect(rect, Paint()..color = const Color(0xFF1A1D25));
    canvas.restore();

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width * 0.5, size.height));
    canvas.drawRect(rect, Paint()..color = const Color(0xFF14161C));
    canvas.restore();

    canvas.drawLine(
      Offset.zero,
      Offset(size.width, 0),
      Paint()
        ..color = const Color(0x14FFFFFF)
        ..strokeWidth = 1.0,
    );

    final paragraphBuilder = ui.ParagraphBuilder(
      ui.ParagraphStyle(
        textDirection: TextDirection.ltr,
        fontSize: 14,
      ),
    )
      ..pushStyle(ui.TextStyle(color: const Color(0xFFF1F3F5)))
      ..addText('Hollow shader warmup');
    final paragraph = paragraphBuilder.build()
      ..layout(const ui.ParagraphConstraints(width: 200));
    canvas.drawParagraph(paragraph, Offset.zero);

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

    canvas.saveLayer(rect, Paint()..color = const Color(0x80FFFFFF));
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xFF00BFA6),
    );
    canvas.restore();

    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, Paint()..color = const Color(0xFF14161C));
    canvas.restore();
    canvas.drawRect(
      rect,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
    );

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
