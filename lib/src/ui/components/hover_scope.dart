import 'package:flutter/widgets.dart';

/// Publishes "the pointer is somewhere over this ROW" to everything inside it.
///
/// Hover-gated motion (an animated avatar or frame) starts when the pointer
/// reaches the row, not the 32px of artwork: the row already lights up on
/// hover and the motion should agree with it. Provided by [HollowPressable]
/// and `MessageHoverWrapper`, which publish a [ValueNotifier] so a pointer
/// crossing a list rebuilds only the avatars that listen.
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
