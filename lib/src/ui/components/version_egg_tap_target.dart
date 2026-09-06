import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/providers/shop_unlock_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// The easter egg that wakes the Hollow Shop: seven taps on the version row in
/// Settings > About bring it back, seven more put it away.
///
/// Deliberately silent until the seventh tap: no counter, no hover paint, no
/// button semantics, so someone who is not looking for this never finds it by
/// accident. Wrapping ONE widget keeps desktop and mobile identical by
/// construction.
class VersionEggTapTarget extends ConsumerStatefulWidget {
  /// The version row itself. Painted untouched.
  final Widget child;

  const VersionEggTapTarget({super.key, required this.child});

  @override
  ConsumerState<VersionEggTapTarget> createState() =>
      _VersionEggTapTargetState();
}

class _VersionEggTapTargetState extends ConsumerState<VersionEggTapTarget> {
  static const int _tapsToFlip = 7;

  /// How long a tap waits for the next one before the run is forgotten.
  static const Duration _window = Duration(seconds: 2);

  int _taps = 0;
  Timer? _reset;

  @override
  void dispose() {
    // A live Timer outliving the tree is both a leak and a test failure.
    _reset?.cancel();
    super.dispose();
  }

  void _onTap() {
    // A store build has no shop to wake (Apple 3.1.1 / Play policy), so the
    // taps are inert and nothing is said about them.
    if (!ShopAvailability.available) return;

    _reset?.cancel();
    _taps++;
    if (_taps < _tapsToFlip) {
      _reset = Timer(_window, () => _taps = 0);
      return;
    }

    _taps = 0;
    final open = !ref.read(shopUnlockedProvider);
    // State first, then the write, so the dock icon appears on this frame; a
    // failed save is swallowed inside the notifier, never in the zone.
    ref.read(shopUnlockedProvider.notifier).setUnlocked(open).catchError((_) {});
    // Putting it away while the shop tab still covers the chat would leave a
    // blank centre pane, so it closes through the one switch that knows every
    // centre tab rather than by writing the flag.
    if (!open && ref.read(shopTabOpenProvider)) {
      setShellTab(ref.read, null);
    }
    HollowToast.show(
      context,
      open ? 'The Hollow Shop is open' : 'The Hollow Shop is closed',
      type: open ? HollowToastType.success : HollowToastType.info,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Opaque so the whole row answers, gap included. There is no control
      // here, so the row's own text semantics are the whole story.
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: _onTap,
      child: widget.child,
    );
  }
}
