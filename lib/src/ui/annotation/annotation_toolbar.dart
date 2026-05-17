import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import 'annotation_controller.dart';
import 'annotation_models.dart';

/// Floating control panel for the annotation overlay: tool picker, color
/// palette, width slider, line-style picker, undo/redo, clear, close.
///
/// Stateless — reads everything from [controller] and rebuilds on changes.
class AnnotationToolbar extends StatelessWidget {
  final AnnotationController controller;
  final VoidCallback onClose;

  const AnnotationToolbar({
    super.key,
    required this.controller,
    required this.onClose,
  });

  static const _palette = <Color>[
    Color(0xFFEF4444), // red
    Color(0xFFF59E0B), // amber
    Color(0xFFFACC15), // yellow
    Color(0xFF22C55E), // green
    Color(0xFF06B6D4), // cyan
    Color(0xFF3B82F6), // blue
    Color(0xFF8B5CF6), // purple
    Color(0xFFEC4899), // pink
    Color(0xFFFFFFFF), // white
    Color(0xFF000000), // black
  ];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xCC1A1D24),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0x33FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x80000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toolButton(AnnotationTool.freehand, LucideIcons.pencil, 'Freehand'),
              _toolButton(AnnotationTool.line, LucideIcons.minus, 'Line'),
              _toolButton(AnnotationTool.arrow, LucideIcons.arrowUpRight, 'Arrow'),
              _toolButton(AnnotationTool.eraser, LucideIcons.eraser, 'Eraser'),
              const _Divider(),
              _styleButton(LineStyle.solid, 'Solid'),
              _styleButton(LineStyle.dashed, 'Dashed'),
              _styleButton(LineStyle.dotted, 'Dotted'),
              const _Divider(),
              SizedBox(
                width: 110,
                child: Slider(
                  min: 1,
                  max: 24,
                  value: controller.width,
                  onChanged: controller.setWidth,
                  activeColor: controller.color,
                  inactiveColor: const Color(0x33FFFFFF),
                ),
              ),
              const _Divider(),
              ..._palette.map(_colorSwatch),
              const _Divider(),
              _iconButton(LucideIcons.undo2, 'Undo (⌘Z)',
                  enabled: controller.canUndo, onPressed: controller.undo),
              _iconButton(LucideIcons.redo2, 'Redo (⇧⌘Z)',
                  enabled: controller.canRedo, onPressed: controller.redo),
              _iconButton(LucideIcons.trash2, 'Clear',
                  enabled: controller.hasContent, onPressed: controller.clear),
              const _Divider(),
              _iconButton(LucideIcons.x, 'Close (Esc)', onPressed: onClose),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolButton(AnnotationTool t, IconData icon, String tooltip) {
    final active = controller.tool == t;
    return _iconButton(
      icon,
      tooltip,
      active: active,
      onPressed: () => controller.setTool(t),
    );
  }

  Widget _styleButton(LineStyle s, String tooltip) {
    final active = controller.style == s;
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 18,
        onTap: () => controller.setStyle(s),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? const Color(0x33FFFFFF) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: CustomPaint(
            size: const Size(22, 4),
            painter: _LineStylePreview(style: s, color: controller.color),
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(Color c) {
    final active = controller.color.toARGB32() == c.toARGB32();
    return Tooltip(
      message: '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      child: InkResponse(
        radius: 16,
        onTap: () => controller.setColor(c),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? const Color(0xFFFFFFFF) : const Color(0x66FFFFFF),
              width: active ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, String tooltip,
      {VoidCallback? onPressed, bool enabled = true, bool active = false}) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 18,
        onTap: enabled ? onPressed : null,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: enabled ? 1.0 : 0.35,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? const Color(0x33FFFFFF) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: const Color(0xFFE6E6E6)),
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 20,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: const Color(0x33FFFFFF),
      );
}

class _LineStylePreview extends CustomPainter {
  final LineStyle style;
  final Color color;
  _LineStylePreview({required this.style, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    switch (style) {
      case LineStyle.solid:
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        break;
      case LineStyle.dashed:
        var x = 0.0;
        const dash = 5.0;
        const gap = 3.0;
        while (x < size.width) {
          final next = (x + dash).clamp(0.0, size.width);
          canvas.drawLine(Offset(x, y), Offset(next, y), paint);
          x = next + gap;
        }
        break;
      case LineStyle.dotted:
        var x = 1.0;
        const step = 4.0;
        final dot = Paint()
          ..color = color
          ..style = PaintingStyle.fill;
        while (x < size.width) {
          canvas.drawCircle(Offset(x, y), 1.2, dot);
          x += step;
        }
        break;
    }
  }

  @override
  bool shouldRepaint(covariant _LineStylePreview old) =>
      old.style != style || old.color != color;
}
