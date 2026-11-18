import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/color_utils.dart';

/// A person's name in its [NamePaint]: one colour as a plain text colour, two or
/// three stops as a gradient across the name (#140).
///
/// The gradient is the text's own foreground shader, so a name costs no extra
/// compositing layer and an emoji in it keeps its colours. The gradient is the
/// person's chosen colour, content rather than decoration, so it is drawn here
/// and nowhere else.
class NameText extends StatelessWidget {
  final String text;
  final NamePaint paint;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;

  const NameText(
    this.text, {
    super.key,
    required this.paint,
    required this.style,
    this.maxLines,
    this.overflow,
  });

  @override
  Widget build(BuildContext context) {
    if (!paint.isGradient) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: overflow,
        style: style.copyWith(color: paint.color),
      );
    }
    final shader = _gradientShader(
      text,
      DefaultTextStyle.of(context).style.merge(style),
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
      paint,
    );
    return _PaintAtOrigin(
      child: Text(
        text,
        maxLines: maxLines,
        overflow: overflow,
        // copyWith(foreground:) drops any colour the style carries.
        style: style.copyWith(foreground: Paint()..shader = shader),
      ),
    );
  }
}

const _maxShaders = 512;
final _shaders =
    <(String, TextStyle, TextScaler, TextDirection, NamePaint), Shader>{};

/// The gradient across [text]'s own unbroken width, measured once per name,
/// style and scale.
Shader _gradientShader(String text, TextStyle style, TextScaler scaler,
    TextDirection direction, NamePaint paint) {
  final key = (text, style, scaler, direction, paint);
  final hit = _shaders[key];
  if (hit != null) return hit;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final bounds = Rect.fromLTWH(
      0, 0, painter.width < 1 ? 1 : painter.width, painter.height);
  painter.dispose();
  if (_shaders.length >= _maxShaders) _shaders.clear();
  return _shaders[key] = paint.shader(bounds);
}

/// Paints its child with the canvas moved to the child's own origin, so a
/// foreground shader sized to the text lines up with the text wherever it
/// sits (a paragraph paints its shader in the layer's space, not its own).
class _PaintAtOrigin extends SingleChildRenderObjectWidget {
  const _PaintAtOrigin({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderAtOrigin();
}

class _RenderAtOrigin extends RenderProxyBox {
  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // A child that pushes layers would swap the canvas under the translation.
    if (child.needsCompositing) {
      context.paintChild(child, offset);
      return;
    }
    final canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    context.paintChild(child, Offset.zero);
    canvas.restore();
  }
}
