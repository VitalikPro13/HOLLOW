import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/peer_id_label.dart';

/// A peer id on one line that always keeps its ending: the whole id when it
/// fits the width, else as much of its start and ending as fits around an
/// ellipsis. Copy actions take the id itself, never this text.
///
/// A render object rather than a LayoutBuilder, so a parent that asks for
/// intrinsic sizes (dialogs, list rows) gets real answers.
class PeerIdText extends LeafRenderObjectWidget {
  const PeerIdText(this.peerId, {super.key, this.style});

  final String peerId;
  final TextStyle? style;

  @override
  RenderPeerIdText createRenderObject(BuildContext context) => RenderPeerIdText(
        peerId: peerId,
        style: DefaultTextStyle.of(context).style.merge(style),
        textScaler: MediaQuery.textScalerOf(context),
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(BuildContext context, RenderPeerIdText renderObject) {
    renderObject
      ..peerId = peerId
      ..style = DefaultTextStyle.of(context).style.merge(style)
      ..textScaler = MediaQuery.textScalerOf(context)
      ..textDirection = Directionality.of(context);
  }
}

class RenderPeerIdText extends RenderBox {
  RenderPeerIdText({
    required String peerId,
    required TextStyle style,
    required TextScaler textScaler,
    required TextDirection textDirection,
  })  : _peerId = peerId,
        _style = style,
        _textScaler = textScaler,
        _textDirection = textDirection;

  final TextPainter _painter = TextPainter(maxLines: 1);

  /// What is painted now, for tests and semantics.
  String get shown => _shown;
  String _shown = '';

  String get peerId => _peerId;
  String _peerId;
  set peerId(String value) {
    if (value == _peerId) return;
    _peerId = value;
    markNeedsLayout();
    markNeedsSemanticsUpdate();
  }

  TextStyle get style => _style;
  TextStyle _style;
  set style(TextStyle value) {
    if (value == _style) return;
    _style = value;
    markNeedsLayout();
  }

  TextScaler get textScaler => _textScaler;
  TextScaler _textScaler;
  set textScaler(TextScaler value) {
    if (value == _textScaler) return;
    _textScaler = value;
    markNeedsLayout();
  }

  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  Size _measure(String text) {
    _painter
      ..text = TextSpan(text: text, style: _style)
      ..textScaler = _textScaler
      ..textDirection = _textDirection
      ..layout();
    return _painter.size;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      _measure(fitPeerId(_peerId, (_) => false)).width;

  @override
  double computeMaxIntrinsicWidth(double height) => _measure(_peerId).width;

  @override
  double computeMinIntrinsicHeight(double width) => _measure(_peerId).height;

  @override
  double computeMaxIntrinsicHeight(double width) => _measure(_peerId).height;

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      constraints.constrain(_measure(_fit(constraints.maxWidth)));

  String _fit(double room) => room.isFinite
      ? fitPeerId(_peerId, (s) => _measure(s).width <= room)
      : _peerId;

  @override
  void performLayout() {
    final shown = _fit(constraints.maxWidth);
    if (shown != _shown) {
      _shown = shown;
      markNeedsSemanticsUpdate();
    }
    size = constraints.constrain(_measure(_shown));
  }

  @override
  double? computeDryBaseline(
      covariant BoxConstraints constraints, TextBaseline baseline) {
    _measure(_fit(constraints.maxWidth));
    return _painter.computeDistanceToActualBaseline(baseline);
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    _measure(_shown);
    return _painter.computeDistanceToActualBaseline(baseline);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _measure(_shown);
    final clip = _painter.width > size.width;
    if (clip) {
      context.canvas
        ..save()
        ..clipRect(offset & size);
    }
    _painter.paint(context.canvas, offset);
    if (clip) context.canvas.restore();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config
      ..isSemanticBoundary = true
      ..label = _shown
      ..textDirection = _textDirection;
  }

  @override
  void dispose() {
    _painter.dispose();
    super.dispose();
  }
}

/// A person's name on one line in a tight slot: a chosen name ellipsizes at
/// its end like any text, the id fallback keeps its ending as [PeerIdText].
class PeerNameText extends StatelessWidget {
  const PeerNameText({
    super.key,
    required this.name,
    required this.peerId,
    this.style,
  });

  final String name;
  final String peerId;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => name == shortPeerLabel(peerId)
      ? PeerIdText(peerId, style: style)
      : Text(name, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
}
