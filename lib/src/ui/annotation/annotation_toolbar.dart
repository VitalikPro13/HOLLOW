import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'annotation_controller.dart';
import 'annotation_models.dart';

/// Floating control panel for the annotation overlay: tools, colours, width,
/// line style, undo and redo.
class AnnotationToolbar extends StatelessWidget {
  final AnnotationController controller;
  final VoidCallback onClose;

  const AnnotationToolbar({
    super.key,
    required this.controller,
    required this.onClose,
  });

  static const _palette = <Color>[
    Color(0xFFEF4444), // design-ignore: drawing ink (red)
    Color(0xFFF59E0B), // design-ignore: drawing ink (amber)
    Color(0xFFFACC15), // design-ignore: drawing ink (yellow)
    Color(0xFF22C55E), // design-ignore: drawing ink (green)
    Color(0xFF06B6D4), // design-ignore: drawing ink (cyan)
    Color(0xFF3B82F6), // design-ignore: drawing ink (blue)
    Color(0xFF8B5CF6), // design-ignore: drawing ink (purple)
    Color(0xFFEC4899), // design-ignore: drawing ink (pink)
    Color(0xFFFFFFFF), // design-ignore: drawing ink (white)
    Color(0xFF000000), // design-ignore: drawing ink (black)
  ];

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) => Material( // design-ignore: overlay host, the slider needs a Material ancestor
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
          decoration: BoxDecoration(
            color: hollow.overlay,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.border),
            boxShadow: HollowShadows.float,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _toolButton(hollow, AnnotationTool.freehand, LucideIcons.pencil, 'Freehand'),
              _toolButton(hollow, AnnotationTool.line, LucideIcons.minus, 'Line'),
              _toolButton(hollow, AnnotationTool.arrow, LucideIcons.arrowUpRight, 'Arrow'),
              _toolButton(hollow, AnnotationTool.eraser, LucideIcons.eraser, 'Eraser'),
              const _Divider(),
              _styleButton(hollow, LineStyle.solid, 'Solid'),
              _styleButton(hollow, LineStyle.dashed, 'Dashed'),
              _styleButton(hollow, LineStyle.dotted, 'Dotted'),
              const _Divider(),
              SizedBox(
                width: 110,
                child: HollowSlider(
                  min: 1,
                  max: 24,
                  value: controller.width,
                  onChanged: controller.setWidth,
                  activeColor: controller.color,
                  onMedia: true,
                ),
              ),
              const _Divider(),
              ..._palette.map((c) => _colorSwatch(hollow, c)),
              const _Divider(),
              _iconButton(hollow, LucideIcons.undo2, 'Undo (⌘Z)',
                  enabled: controller.canUndo, onPressed: controller.undo),
              _iconButton(hollow, LucideIcons.redo2, 'Redo (⇧⌘Z)',
                  enabled: controller.canRedo, onPressed: controller.redo),
              _iconButton(hollow, LucideIcons.trash2, 'Clear',
                  enabled: controller.hasContent, onPressed: controller.clear),
              const _Divider(),
              _iconButton(hollow, LucideIcons.x, 'Close (Esc)', onPressed: onClose),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toolButton(HollowTheme hollow, AnnotationTool t, IconData icon, String tooltip) {
    final active = controller.tool == t;
    return _iconButton(
      hollow,
      icon,
      tooltip,
      active: active,
      onPressed: () => controller.setTool(t),
    );
  }

  Widget _styleButton(HollowTheme hollow, LineStyle s, String tooltip) {
    final active = controller.style == s;
    return HollowTooltip(
      message: tooltip,
      child: InkResponse(
        radius: 18,
        onTap: () => controller.setStyle(s),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? hollow.hover : null,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          child: CustomPaint(
            size: const Size(22, 4),
            painter: _LineStylePreview(style: s, color: controller.color),
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch(HollowTheme hollow, Color c) {
    final active = controller.color.toARGB32() == c.toARGB32();
    return HollowTooltip(
      message: '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
      child: InkResponse(
        radius: 16,
        onTap: () => controller.setColor(c),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: HollowSpacing.xxs),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(
              color: active ? hollow.textPrimary : hollow.textTertiary,
              width: active ? 2.5 : 1,
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(HollowTheme hollow, IconData icon, String tooltip,
      {VoidCallback? onPressed, bool enabled = true, bool active = false}) {
    return HollowTooltip(
      message: tooltip,
      child: InkResponse(
        radius: 18,
        onTap: enabled ? onPressed : null,
        child: AnimatedOpacity(
          duration: HollowDurations.fast,
          opacity: enabled ? 1.0 : 0.35,
          child: Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? hollow.hover : null,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            child: Icon(icon, size: 18, color: hollow.textPrimary),
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
        margin: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
        color: HollowTheme.of(context).border,
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
