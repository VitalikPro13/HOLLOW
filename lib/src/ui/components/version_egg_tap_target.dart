import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Seven quick taps on the version row in Settings > About.
///
/// Deliberately silent until the seventh tap: no counter, no hover paint, no
/// button semantics, so someone who is not looking for this never finds it by
/// accident. Wrapping ONE widget keeps desktop and mobile identical by
/// construction.
class VersionEggTapTarget extends StatefulWidget {
  /// The version row itself. Painted untouched.
  final Widget child;

  const VersionEggTapTarget({super.key, required this.child});

  @override
  State<VersionEggTapTarget> createState() => _VersionEggTapTargetState();
}

class _VersionEggTapTargetState extends State<VersionEggTapTarget> {
  static const int _tapsToFire = 7;
  static const String _url = 'https://youtu.be/ADdAg_89r7Y';

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
    _reset?.cancel();
    _taps++;
    if (_taps < _tapsToFire) {
      _reset = Timer(_window, () => _taps = 0);
      return;
    }
    _taps = 0;
    launchUrl(Uri.parse(_url), mode: LaunchMode.externalApplication)
        .catchError((_) => false);
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
