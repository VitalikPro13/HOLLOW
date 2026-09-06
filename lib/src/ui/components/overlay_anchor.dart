import 'package:flutter/material.dart';

/// Coordinate helpers for widgets that anchor an [OverlayEntry] to something
/// on screen.
///
/// `UiScale` (interface zoom) puts a [Transform] between the window and the
/// Navigator, so window coordinates (`localToGlobal()`,
/// `details.globalPosition`) are not overlay space: at 150% zoom a popup
/// anchored with raw globals lands half a screen from its button. Both helpers
/// resolve the same `Overlay.of(context)` the popup helpers insert into.

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
