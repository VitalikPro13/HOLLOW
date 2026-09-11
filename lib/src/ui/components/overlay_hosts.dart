import 'package:flutter/foundation.dart';

/// Open raw `OverlayEntry` hosts: the pickers, anchored popups and hover bars
/// that live in the root overlay rather than on a route.
///
/// The Navigator re-stacks foreign entries above every route it pushes (#76),
/// so one left open would paint over the app lock cover and stay hit-testable.
/// Each host registers its own dismiss here, and the lock clears the screen
/// before it covers it.
class OverlayHosts {
  OverlayHosts._();

  static final Map<Object, VoidCallback> _open = {};

  @visibleForTesting
  static int get openCount => _open.length;

  static void register(Object token, VoidCallback dismiss) =>
      _open[token] = dismiss;

  static void unregister(Object token) => _open.remove(token);

  /// A dismiss unregisters itself, so the copy is what makes this safe.
  static void dismissAll() {
    final open = List<VoidCallback>.of(_open.values);
    _open.clear();
    for (final dismiss in open) {
      dismiss();
    }
  }
}
