import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/android_platform.dart';
import 'package:hollow/src/core/providers/shop_unlock_provider.dart';

/// Store builds show NO shop UI at all (Apple 3.1.1 / Play policy): no gallery,
/// no prices, no import, no redeem. The safest sentence is no sentence.
///
/// Rendering is unaffected: purchased art is ordinary profile data and paints
/// everywhere. Only the commerce surfaces are gone.
const bool kStoreBuild = bool.fromEnvironment('HOLLOW_STORE_BUILD');

/// Android package names of the app stores whose policy this gate exists for.
/// An APK installed by anything else (adb, a browser download, F-Droid, a file
/// manager) is a sideload and gets the full shop.
const Set<String> _kAndroidStoreInstallers = {
  'com.android.vending', // Google Play
  'com.amazon.venezia', // Amazon Appstore
  'com.sec.android.app.samsungapps', // Samsung Galaxy Store
};

/// Whether this build may show shop UI at all. Resolved ONCE at startup rather
/// than per-widget: the answer cannot change while the process lives, and
/// every read site is a `build()`.
class ShopAvailability {
  ShopAvailability._();

  static bool _primed = false;
  static bool _available = false;

  /// The verdict. False until [prime] has run, which is deliberate: an
  /// unprimed read must never flash a shop button onto a store build.
  static bool get available => _available;

  /// True once [prime] has resolved. Diagnostics only.
  static bool get primed => _primed;

  /// Resolve the verdict. Call once before `runApp`. Desktop yes; iOS and web no
  /// (the App Store is the only channel); Android no when a store installed us,
  /// yes for a sideload.
  static Future<void> prime() async {
    if (_primed) return;
    _primed = true;
    if (kStoreBuild || kIsWeb) {
      _available = false;
      return;
    }
    if (Platform.isIOS) {
      _available = false;
      return;
    }
    if (Platform.isAndroid) {
      final installer = await androidInstallerPackage();
      _available = installer == null
          ? true // unknown installer: a store always reports its own package
          : !_kAndroidStoreInstallers.contains(installer);
      return;
    }
    _available = true;
  }

  /// Test seam: forces the verdict without a platform channel.
  @visibleForTesting
  static void debugSet(bool value) {
    _primed = true;
    _available = value;
  }
}

/// The effective shop gate: watch this, never [ShopAvailability.available]
/// directly, so a widget test can override the verdict.
///
/// Two things have to agree. [ShopAvailability.available] is the STORE verdict,
/// fixed for the life of the process. [shopUnlockedProvider] is the install's
/// own answer, flipped by seven taps. A store build stays false regardless.
final shopAvailableProvider = Provider<bool>(
  (ref) => ShopAvailability.available && ref.watch(shopUnlockedProvider),
);
