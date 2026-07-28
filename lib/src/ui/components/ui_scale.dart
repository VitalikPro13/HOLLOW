import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';

/// The smallest logical viewport the app is allowed to lay out in, whatever
/// zoom the user picks. Desktop's floor is the Settings dialog's own
/// requirement (360x420 of dialog plus its 24px padding on each side): go
/// below it and the dialog cannot render whole, which is how a user zooms
/// themselves out of the one control that undoes the zoom.
///
/// Mobile's floor is far lower because nothing there is a fixed-size box; the
/// shell is verified to fit at 240dp by the interface-scale group in
/// `test/widget/text_scale_overflow_test.dart`.
const Size _kDesktopViewportFloor = Size(410, 470);
const Size _kMobileViewportFloor = Size(240, 400);

bool get _isMobileForm => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// The scale actually applied: the user's choice, reduced if this window is
/// too small to show the app at it. Never reduces below 1.0 — a window
/// smaller than the floor is the window's problem, not something to solve by
/// shrinking the UI under the user.
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

/// Root-level interface scaling — the in-app equivalent of Windows' "Scale
/// and layout" or a browser's zoom (GitHub issue #20).
///
/// Everything below this widget is laid out at `windowSize / scale` logical
/// pixels and then painted through a [Transform], so text, icons, avatars,
/// borders and padding all grow together and stay crisp (Skia rasterises
/// through the composited transform). Nothing else in the app has to know:
/// no design token changes, no per-icon `size:` edits.
///
/// **The one rule this creates:** below this widget, window ("global")
/// coordinates and widget coordinates differ by the scale factor. Anything
/// that hands a position to an [OverlayEntry] must convert it through the
/// overlay — see `overlay_anchor.dart`. A bare
/// `renderBox.localToGlobal(Offset.zero)` lands the popup off by the zoom.
class UiScale extends ConsumerWidget {
  final Widget child;

  const UiScale({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(uiScaleProvider);
    return UiScaleBox(scale: scale, child: child);
  }
}

/// The pure, provider-free half of [UiScale] (kept separate so it is
/// directly testable and reusable for previews).
class UiScaleBox extends StatelessWidget {
  final double scale;
  final Widget child;

  const UiScaleBox({super.key, required this.scale, required this.child});

  @override
  Widget build(BuildContext context) {
    // Measure the BOX WE ARE GIVEN, never `MediaQuery.size`. On desktop this
    // widget sits in the Expanded below the 32px title bar, so the window
    // size is 32px taller than the space we may paint into — sizing from it
    // pushed exactly that much of the app (the whole bottom dock) off the
    // bottom edge at every scale except 1.0.
    return LayoutBuilder(
      builder: (context, constraints) {
        final mq = MediaQuery.of(context);
        final available = Size(
          constraints.hasBoundedWidth ? constraints.maxWidth : mq.size.width,
          constraints.hasBoundedHeight ? constraints.maxHeight : mq.size.height,
        );
        // Clamp to what this window can actually show, so no combination of
        // zoom + window size can hide the controls that undo the zoom.
        final scale = effectiveUiScale(this.scale, available);
        final isNoop = (scale - 1.0).abs() < 0.001;

        // Every measurement below the transform shrinks by the same factor:
        // the viewport, the safe-area padding and the keyboard inset.
        // devicePixelRatio grows instead — one of our logical pixels now
        // covers `scale` more device pixels, which is what keeps
        // `cacheWidth`-style image decoding sharp.
        //
        // At 100% this is NOT a no-op, and that is the point: `size` becomes
        // the SLOT rather than the window. The desktop title bar owns the top
        // 32px, so everything below here — dialogs sizing themselves, every
        // popup that clamps itself into the `Overlay` — was working from a
        // viewport 32px taller than the one it actually renders in, and
        // anything anchored near the bottom edge got cut off (issue #20:
        // bottom-dock tooltips rendered below the button and off the screen).
        // The Overlay fills this box exactly, so this size IS overlay space.
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
            // stopped; at 100% the app is laid out and painted untouched.
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

/// The one box that does the zoom: it occupies [viewport] (its slot), lays the
/// app out at `viewport / scale`, and paints — and hit-tests — it back through
/// a single scale transform.
///
/// **Why this is a render object and not `Transform.scale` over an
/// `OverflowBox`.** That composition painted correctly but hit-tested wrong
/// below 100% (issue #20 follow-up). At 0.9x the app lays out LARGER than the
/// window, and every `RenderBox.hitTest` starts with `size.contains(position)`
/// — the OverflowBox in between was pinned to the slot by the incoming tight
/// constraints, so as soon as the inverse transform pushed a pointer past
/// `slot` in child space the hit test was rejected before it ever reached the
/// app. The dead strip was the bottom `slot.height * (1 - scale)` and the
/// right `slot.width * (1 - scale)` of the window: the entire bottom dock and
/// the right end of the top bar, growing as you zoomed further out.
///
/// Here there is nothing in between. This box's own size IS the slot, so every
/// pointer in the window passes its bounds check, and [hitTestChildren] hands
/// the child a position through the same matrix used to paint it.
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
    // Our size is the slot; the app inside is laid out at slot / scale and
    // painted back up (or down) to fill it exactly.
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

  /// Keeps `localToGlobal`/`globalToLocal` and the semantics rects honest —
  /// which is also what makes `overlay_anchor.dart` land popups correctly.
  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.multiply(_transform);
  }
}

/// What the interface scale actually resolved to, published to everything
/// below it. `requested` is the user's setting; `effective` is what this
/// window could show. They differ only when [effectiveUiScale] had to step
/// in, and the Settings slider says so rather than looking broken.
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

/// A [TextScaler] that multiplies whatever the platform already applies.
///
/// Composing instead of replacing matters: the OS scaler may be non-linear
/// (Android 14+ grows small text more than large text), and a user who has
/// already set 130% at the OS level expects the in-app slider to be relative
/// to that, not to override it.
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

/// Applies the user's chat text scale to a message surface (the message list
/// and the composer). Text-only: avatars, file cards and attachments keep the
/// interface scale, which is exactly how the OS/desktop chat apps behave.
/// Custom emotes are the one thing that has to follow along by hand — they
/// are [WidgetSpan]s, which a text scaler cannot reach (see
/// `message_text_parser.dart`).
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
