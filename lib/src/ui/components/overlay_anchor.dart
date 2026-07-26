import 'package:flutter/material.dart';

/// Coordinate helpers for widgets that anchor an [OverlayEntry] to something
/// on screen.
///
/// `UiScale` (interface zoom, `ui_scale.dart`) puts a [Transform] between the
/// window and the Navigator, so window coordinates — what `localToGlobal()`
/// and `details.globalPosition` return — are NOT the coordinate space an
/// `Overlay` child is positioned in. They differ by the zoom factor, so at
/// 150% a popup anchored with raw global coordinates lands half a screen away
/// from its button.
///
/// Every anchor therefore goes through the overlay. Both helpers resolve the
/// same overlay the popup helpers insert into (`Overlay.of(context)`), so the
/// anchor and the entry always share one space — and at 100% zoom they return
/// exactly what the old code did.

/// The position of [context]'s own render box, in the coordinate space of the
/// [Overlay] it would insert into. [localOffset] picks a different corner
/// (e.g. `Offset(box.size.width, 0)` for the top-right).
Offset overlayAnchorOf(
  BuildContext context, {
  Offset localOffset = Offset.zero,
}) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return Offset.zero;
  return box.localToGlobal(localOffset, ancestor: _overlayBox(context));
}

/// Converts a pointer position from a gesture callback
/// (`details.globalPosition`, always window space) into overlay space.
Offset overlayPositionOf(BuildContext context, Offset globalPosition) {
  final overlayBox = _overlayBox(context);
  if (overlayBox == null || !overlayBox.hasSize) return globalPosition;
  return overlayBox.globalToLocal(globalPosition);
}

RenderBox? _overlayBox(BuildContext context) =>
    Overlay.maybeOf(context)?.context.findRenderObject() as RenderBox?;
