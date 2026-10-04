import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Keeps what a phone shows out of screenshots and the app switcher where it
/// must: the recovery phrase screens (Android FLAG_SECURE, an iOS switcher
/// cover), and on iOS the switcher whenever App Lock is on. Screenshots are
/// never blocked app-wide. A no-op on desktops.
class PrivacyScreen {
  PrivacyScreen._();

  static const _channel = MethodChannel('hollow/privacy');

  /// Lets a test drive the phone path on a desktop host.
  @visibleForTesting
  static bool debugForceMobile = false;

  static bool get _mobile =>
      debugForceMobile || Platform.isAndroid || Platform.isIOS;

  static int _holds = 0;

  /// How many phrase screens are open. A test reads it.
  @visibleForTesting
  static int get holds => _holds;

  /// Phrase screens nest (a reveal opens its check), so the flag is held while
  /// any of them is up.
  static void hold() {
    if (++_holds == 1) _invoke('setSecureScreen', true);
  }

  static void release() {
    if (_holds == 0) return;
    if (--_holds == 0) _invoke('setSecureScreen', false);
  }

  /// App Lock on: the iOS switcher shows a cover, and Android 13+ keeps no
  /// recents thumbnail. The lock rises only on return, so without this the
  /// last conversation sits in the switcher.
  static void setAppLockOn(bool on) => _invoke('setSwitcherCover', on);

  static void _invoke(String method, bool on) {
    if (!_mobile) return;
    _channel.invokeMethod<void>(method, on).catchError((Object e) {
      debugPrint('[HOLLOW-PRIVACY] $method failed: $e');
    });
  }
}

/// Wraps a screen that shows or takes the recovery phrase: while it is up the
/// phone keeps it out of screenshots, recordings and the app switcher.
class SecretScreen extends StatefulWidget {
  final Widget child;

  const SecretScreen({super.key, required this.child});

  @override
  State<SecretScreen> createState() => _SecretScreenState();
}

class _SecretScreenState extends State<SecretScreen> {
  @override
  void initState() {
    super.initState();
    PrivacyScreen.hold();
  }

  @override
  void dispose() {
    PrivacyScreen.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
