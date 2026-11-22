import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

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
  static final Set<Object> _keyHolders = {};

  @visibleForTesting
  static int get openCount => _open.length;

  /// [holdsKeys]: the host owns the keyboard while open (a kept preview), so
  /// screen-level [HardwareKeyboard] handlers stand aside: Flutter runs every
  /// such handler beside focus, and an Escape meant for the host would also
  /// close the screen under it.
  static void register(Object token, VoidCallback dismiss,
      {bool holdsKeys = false}) {
    _open[token] = dismiss;
    if (holdsKeys) _keyHolders.add(token);
  }

  static void unregister(Object token) {
    _open.remove(token);
    _keyHolders.remove(token);
  }

  /// True while a host that owns the keyboard is open; a screen-level key
  /// handler returns false at once while it is.
  static bool get keysHeld => _keyHolders.isNotEmpty;

  /// A dismiss unregisters itself, so the copy is what makes this safe.
  static void dismissAll() {
    final open = List<VoidCallback>.of(_open.values);
    _open.clear();
    _keyHolders.clear();
    for (final dismiss in open) {
      dismiss();
    }
  }
}
