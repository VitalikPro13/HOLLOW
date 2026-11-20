import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/color_utils.dart';

/// A person's name in its [NamePaint]: one colour as a plain text colour, two or
/// three stops as a gradient across the name (#140).
///
/// The gradient is the text's own foreground shader, so a name costs no extra
/// compositing layer and an emoji in it keeps its colours. The gradient is the
/// person's chosen colour, content rather than decoration, so it is drawn here
/// and nowhere else. It spans the name as laid out: an ellipsized name ends on
/// its last stop, and every line of a wrapped one runs across the widest line.
class NameText extends StatelessWidget {
  final String text;
  final NamePaint paint;
  final TextStyle style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  const NameText(
    this.text, {
    super.key,
    required this.paint,
    required this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  @override
  Widget build(BuildContext context) {
    if (!paint.isGradient) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
        style: style.copyWith(color: paint.color),
      );
    }
    return _GradientName(
      paint: paint,
      child: Text(
        text,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
        // The first stop until layout knows the name's box; copyWith
        // (foreground:) drops any colour the style carries.
        style: style.copyWith(foreground: Paint()..color = paint.color),
      ),
    );
  }
}

/// A name leading a short sentence ("Ada is sharing"): the name in its paint,
/// shortened first, so the rest of the sentence shows. [style] is the
/// sentence's style; [nameStyle] is laid over it for the names.
/// [NameLine.several] names a few people ("Ada and Bo are typing").
class NameLine extends StatelessWidget {
  final List<(String, NamePaint)> names;

  /// What sits between two names: one fewer than [names].
  final List<String> joins;
  final String rest;
  final TextStyle style;
  final TextStyle? nameStyle;

  NameLine({
    super.key,
    required String name,
    required NamePaint paint,
    required this.rest,
    required this.style,
    this.nameStyle,
  })  : names = [(name, paint)],
        joins = const [];

  const NameLine.several({
    super.key,
    required this.names,
    required this.joins,
    required this.rest,
    required this.style,
    this.nameStyle,
  }) : assert(joins.length == names.length - 1);

  @override
  Widget build(BuildContext context) {
    final sentence = StringBuffer();
    for (var i = 0; i < names.length; i++) {
      sentence.write(names[i].$1);
      if (i < joins.length) sentence.write(joins[i]);
    }
    sentence.write(rest);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final base = DefaultTextStyle.of(context).style.merge(style);
    final nameBase = base.merge(nameStyle);
    double widthOf(String s, TextStyle st) {
      final p = TextPainter(
        text: TextSpan(text: s, style: st),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    Widget plain(String s) => Text(s,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: style);
    final parts = <(Widget, double, bool)>[];
    for (var i = 0; i < names.length; i++) {
      final (name, paint) = names[i];
      parts.add((
        NameText(name,
            paint: paint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.merge(nameStyle)),
        widthOf(name, nameBase),
        true,
      ));
      if (i < joins.length) {
        parts.add((plain(joins[i]), widthOf(joins[i], base), false));
      }
    }
    parts.add((plain(rest), widthOf(rest, base), false));
    final words =
        parts.where((p) => !p.$3).fold<double>(0, (sum, p) => sum + p.$2);

    // One sentence to a screen reader, never a name and a fragment.
    return Semantics(
      container: true,
      label: sentence.toString(),
      child: ExcludeSemantics(
        child: LayoutBuilder(builder: (context, c) {
          Row row(List<Widget> children) => Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: children,
              );
          // Unbounded (a FittedBox) has nothing to shorten for.
          if (!c.hasBoundedWidth) return row([for (final p in parts) p.$1]);
          // The names give way first. Once the words around them would take
          // most of the line, every part shortens by the same share, so
          // nothing spills past the row.
          final allShrink = words > c.maxWidth * 0.6;
          return row([
            for (final (child, width, isName) in parts)
              if (isName || allShrink)
                Flexible(flex: width.ceil().clamp(1, 1 << 20), child: child)
              else
                child,
          ]);
        }),
      ),
    );
  }
}

/// Lays the gradient over its child's text as laid out, and paints the child
/// with the canvas at the child's own origin so the shader lines up with the
/// text wherever it sits (a paragraph paints its shader in the layer's space,
/// not its own).
class _GradientName extends SingleChildRenderObjectWidget {
  final NamePaint paint;

  const _GradientName({required this.paint, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGradientName(paint);

  @override
  void updateRenderObject(
      BuildContext context, _RenderGradientName renderObject) {
    // The child Text hands its paragraph a fresh foreground on every rebuild.
    // That relays the paragraph out, but in tight constraints it is its own
    // relayout boundary and this box would never hear of it.
    renderObject
      ..namePaint = paint
      ..markNeedsLayout();
  }
}

class _RenderGradientName extends RenderProxyBox {
  _RenderGradientName(this.namePaint);

  NamePaint namePaint;
  final _layer = LayerHandle<OffsetLayer>();

  /// The span carrying the gradient, and the box it was made for.
  InlineSpan? _shaded;
  (NamePaint, Rect)? _shadedFor;

  // A foreground is a LAYOUT change to a paragraph, so the gradient goes on
  // inside a layout callback (where a render object may change what it lays
  // out) and the paragraph is laid out again; its lines do not depend on the
  // shader, so the second layout finds the same box and stops there. A
  // rebuild that kept the name's box costs one layout: the known box goes on
  // first.
  @override
  void performLayout() {
    final child = this.child;
    final paragraph = _paragraphOf(child);
    if (child == null || paragraph == null) {
      super.performLayout();
      return;
    }
    final known = _shadedFor;
    if (known != null &&
        known.$1 == namePaint &&
        !identical(paragraph.text, _shaded)) {
      invokeLayoutCallback<BoxConstraints>((_) => _shade(paragraph, known.$2));
    }
    child.layout(constraints, parentUsesSize: true);
    final box = _laidOutBox(paragraph, child.size);
    if (!identical(paragraph.text, _shaded) || _shadedFor != (namePaint, box)) {
      invokeLayoutCallback<BoxConstraints>((_) => _shade(paragraph, box));
      child.layout(constraints, parentUsesSize: true);
    }
    size = child.size;
  }

  static RenderParagraph? _paragraphOf(RenderObject? node) {
    while (node != null && node is! RenderParagraph) {
      RenderObject? next;
      node.visitChildren((c) => next ??= c);
      node = next;
    }
    return node as RenderParagraph?;
  }

  /// The text as laid out: the box of every line it shows (an ellipsized line
  /// ends at its ellipsis). [size] is the paragraph's (everything between is
  /// a proxy).
  static Rect _laidOutBox(RenderParagraph paragraph, Size size) {
    final length =
        paragraph.text.toPlainText(includeSemanticsLabels: false).length;
    Rect? box;
    for (final b in paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: length))) {
      final r = b.toRect();
      box = box == null ? r : box.expandToInclude(r);
    }
    box ??= Offset.zero & size;
    return box.width < 1
        ? Rect.fromLTWH(box.left, box.top, 1, box.height)
        : box;
  }

  void _shade(RenderParagraph paragraph, Rect box) {
    final span = paragraph.text;
    if (span is! TextSpan || span.style == null) return;
    _shadedFor = (namePaint, box);
    paragraph.text = _shaded = TextSpan(
      text: span.text,
      children: span.children,
      style: span.style!
          .copyWith(foreground: Paint()..shader = namePaint.shader(box)),
      recognizer: span.recognizer,
      semanticsLabel: span.semanticsLabel,
      locale: span.locale,
      spellOut: span.spellOut,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    // A child that pushes layers (a name inside a SelectionArea, every chat
    // row) would swap the canvas under a translation, and the shader would
    // clamp to its last stop (#149): its own layer starts where it does.
    if (child.needsCompositing) {
      final layer = _layer.layer ??= OffsetLayer();
      layer.offset = offset;
      context.pushLayer(
          layer, (inner, _) => inner.paintChild(child, Offset.zero), Offset.zero);
      return;
    }
    _layer.layer = null;
    final canvas = context.canvas
      ..save()
      ..translate(offset.dx, offset.dy);
    context.paintChild(child, Offset.zero);
    canvas.restore();
  }

  @override
  void dispose() {
    _layer.layer = null;
    super.dispose();
  }
}
