import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';

/// The smallest logical viewport the app may lay out in at any zoom. The
/// desktop floor is the Settings dialog plus its padding, or a user can zoom
/// away the one control that undoes the zoom; mobile's floor is lower because
/// nothing there is a fixed-size box.
const Size _kDesktopViewportFloor = Size(410, 470);
const Size _kMobileViewportFloor = Size(240, 400);

bool get _isMobileForm => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// The scale actually applied: the user's choice, reduced when this window is
/// too small for it, never below 1.0.
double effectiveUiScale(double requested, Size viewport) {
  if (requested <= 1.0) return requested;
  final floor = _isMobileForm ? _kMobileViewportFloor : _kDesktopViewportFloor;
  if (viewport.isEmpty) return requested;
  final fits = math.min(
    viewport.width / floor.width,
    viewport.height / floor.height,
  );
  return math.min(requested, math.max(1.0, fits));
}

/// Root-level interface scaling, the in-app equivalent of Windows' "Scale and
/// layout" (issue #20).
///
/// Everything below is laid out at `windowSize / scale` and painted through one
/// [Transform]. The rule this creates: window ("global") coordinates and widget
/// coordinates differ by the scale factor, so anything handing a position to an
/// [OverlayEntry] converts through `overlay_anchor.dart`.
class UiScale extends ConsumerWidget {
  final Widget child;

  const UiScale({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(uiScaleProvider);
    return UiScaleBox(scale: scale, child: child);
  }
}

/// The pure, provider-free half of [UiScale], kept directly testable.
class UiScaleBox extends StatelessWidget {
  final double scale;
  final Widget child;

  const UiScaleBox({super.key, required this.scale, required this.child});

  @override
  Widget build(BuildContext context) {
    // Measure the BOX WE ARE GIVEN, never `MediaQuery.size`: the window is
    // 32px taller than the space below the desktop title bar, and sizing from
    // it pushes the bottom dock off the screen at every scale but 1.0.
    return LayoutBuilder(
      builder: (context, constraints) {
        final mq = MediaQuery.of(context);
        final available = Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : mq.size.width,
          constraints.hasBoundedHeight ? constraints.maxHeight : mq.size.height,
        );
        // Clamped so no combination of zoom and window size can hide the
        // controls that undo the zoom.
        final scale = effectiveUiScale(this.scale, available);
        final isNoop = (scale - 1.0).abs() < 0.001;

        // devicePixelRatio grows as the measurements shrink, which keeps
        // `cacheWidth` image decoding sharp. At 100% this is deliberately not a
        // no-op: `size` becomes the SLOT rather than the window, so a popup
        // clamping itself into the Overlay stops working from a viewport 32px
        // taller than the one it renders in (issue #20).
        final scaledSize = available / scale;
        final scaled = mq.copyWith(
          size: scaledSize,
          devicePixelRatio: mq.devicePixelRatio * scale,
          padding: mq.padding / scale,
          viewPadding: mq.viewPadding / scale,
          viewInsets: mq.viewInsets / scale,
          systemGestureInsets: mq.systemGestureInsets / scale,
        );

        return UiScaleInfo(
          requested: this.scale,
          effective: scale,
          child: MediaQuery(
            data: scaled,
            // Published either way so the Settings slider can say why it
            // stopped.
            child: isNoop
                ? child
                : _ScaledViewport(
                    scale: scale,
                    viewport: available,
                    child: child,
                  ),
          ),
        );
      },
    );
  }
}

/// The one box that does the zoom: it occupies [viewport], lays the app out at
/// `viewport / scale` and paints and hit-tests it back through one transform.
///
/// A render object rather than `Transform.scale` over an `OverflowBox`, which
/// hit-tested wrong below 100% (issue #20): pinned to the slot by the incoming
/// tight constraints, its bounds check rejected pointers in the bottom and
/// right strips. Here this box's own size IS the slot.
class _ScaledViewport extends SingleChildRenderObjectWidget {
  final double scale;
  final Size viewport;

  const _ScaledViewport({
    required this.scale,
    required this.viewport,
    required super.child,
  });

  @override
  _RenderScaledViewport createRenderObject(BuildContext context) =>
      _RenderScaledViewport(scale: scale, viewport: viewport);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderScaledViewport renderObject,
  ) {
    renderObject
      ..scale = scale
      ..viewport = viewport;
  }
}

class _RenderScaledViewport extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _RenderScaledViewport({required double scale, required Size viewport})
      : _scale = scale,
        _viewport = viewport;

  double _scale;
  double get scale => _scale;
  set scale(double value) {
    if (_scale == value) return;
    _scale = value;
    markNeedsLayout();
  }

  Size _viewport;
  Size get viewport => _viewport;
  set viewport(Size value) {
    if (_viewport == value) return;
    _viewport = value;
    markNeedsLayout();
  }

  Matrix4 get _transform => Matrix4.diagonal3Values(_scale, _scale, 1.0);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      constraints.constrain(_viewport);

  @override
  void performLayout() {
    size = constraints.constrain(_viewport);
    child?.layout(BoxConstraints.tight(size / _scale));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    layer = context.pushTransform(
      needsCompositing,
      offset,
      _transform,
      (PaintingContext innerContext, Offset innerOffset) =>
          innerContext.paintChild(child, innerOffset),
      oldLayer: layer is TransformLayer ? layer as TransformLayer? : null,
    );
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintTransform(
      transform: _transform,
      position: position,
      hitTest: (BoxHitTestResult result, Offset transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  /// Keeps `localToGlobal`, `globalToLocal` and the semantics rects honest,
  /// which is what lets `overlay_anchor.dart` land popups correctly.
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }
}

/// What the interface scale resolved to: `requested` is the user's setting,
/// `effective` what this window could show, and the Settings slider says so.
class UiScaleInfo extends InheritedWidget {
  final double requested;
  final double effective;

  const UiScaleInfo({
    super.key,
    required this.requested,
    required this.effective,
    required super.child,
  });

  bool get isClamped => effective < requested - 0.001;

  static UiScaleInfo? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UiScaleInfo>();

  @override
  bool updateShouldNotify(UiScaleInfo old) =>
      old.requested != requested || old.effective != effective;
}

/// Zooms ONE panel's contents (issue #54).
///
/// Same machinery as [UiScale]: icon sizes live in hundreds of hardcoded `size:`
/// literals, so a text scaler alone would strand 16px icons next to 24px labels.
/// The panel's SLOT does not change, so widening stays the resize handle's job.
class PanelScale extends ConsumerWidget {
  final Widget child;

  /// Layout height this panel's UNSHRINKABLE chrome needs, if it has any.
  ///
  /// Zoom shrinks the space contents get, so as in [effectiveUiScale] it is
  /// capped at what this box can show, never below 1.0.
  final double minContentHeight;

  const PanelScale({
    super.key,
    required this.child,
    this.minContentHeight = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requested = ref.watch(panelScaleProvider);
    if ((requested - 1.0).abs() < 0.001) return child;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) {
          return child;
        }
        final slot = Size(constraints.maxWidth, constraints.maxHeight);
        final scale = minContentHeight <= 0
            ? requested
            : math.min(
                requested,
                math.max(1.0, slot.height / minContentHeight),
              );
        if ((scale - 1.0).abs() < 0.001) return child;
        final mq = MediaQuery.of(context);
        // devicePixelRatio only: `size` here is still the WINDOW, and lying
        // about it would mislead anything measuring the screen.
        return MediaQuery(
          data: mq.copyWith(devicePixelRatio: mq.devicePixelRatio * scale),
          child: _ScaledViewport(scale: scale, viewport: slot, child: child),
        );
      },
    );
  }
}

/// A [TextScaler] that multiplies whatever the platform already applies, rather
/// than replacing it: the OS scaler may be non-linear (Android 14+), and a user
/// already at 130% expects the in-app slider to be relative to that.
@immutable
class MultipliedTextScaler extends TextScaler {
  final TextScaler base;
  final double factor;

  const MultipliedTextScaler({required this.base, required this.factor});

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(1.0);

  @override
  bool operator ==(Object other) =>
      other is MultipliedTextScaler &&
      other.base == base &&
      other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);

  @override
  String toString() => 'MultipliedTextScaler($base x $factor)';
}

/// Applies the user's chat text scale to a message surface. Text only, and
/// custom emotes follow by hand because a [WidgetSpan] is out of a text scaler's
/// reach.
class ChatTextScale extends ConsumerWidget {
  final Widget child;

  const ChatTextScale({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factor = ref.watch(chatTextScaleProvider);
    if ((factor - 1.0).abs() < 0.001) return child;
    final mq = MediaQuery.of(context);
    return MediaQuery(
      data: mq.copyWith(
        textScaler: MultipliedTextScaler(base: mq.textScaler, factor: factor),
      ),
      child: child,
    );
  }
}
