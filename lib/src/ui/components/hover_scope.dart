import 'package:flutter/widgets.dart';

/// Publishes "the pointer is somewhere over this ROW" to everything inside it.
///
/// Hover-gated motion (an animated avatar, an animated avatar frame) has to
/// start when the pointer reaches the ROW, not when it reaches the 32px of
/// artwork itself. Aiming at a member tile's avatar to make it move is a
/// pixel-hunting game nobody should have to play, and the row already lights
/// up on hover — the motion should agree with the highlight.
///
/// Provided by the two widgets that already own a row's hover state:
/// [HollowPressable] (member tiles, conversation rows, friends bar, peer
/// cards) and `MessageHoverWrapper` (chat rows). Both keep a
/// [ValueNotifier] rather than calling `setState`, so a pointer crossing a
/// list rebuilds only the avatars that actually listen, not the whole row.
///
/// [maybeOf] returns null where no row provides one — a standalone avatar
/// then falls back to hovering itself, which is the right behaviour for a
/// preview or a picker tile that IS the whole target.
class HoverScope extends InheritedNotifier<ValueNotifier<bool>> {
  const HoverScope({
    super.key,
    required ValueNotifier<bool> hovered,
    required super.child,
  }) : super(notifier: hovered);

  /// Whether the enclosing row is hovered, or null if there is no enclosing
  /// row. Registers a dependency: call it from `build`.
  static bool? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HoverScope>()
      ?.notifier
      ?.value;
}
