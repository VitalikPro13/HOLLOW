import 'package:integration_test/integration_test_driver.dart';

/// Driver for the UI probe (`integration_test/ui_probe_test.dart`).
///
/// Deliberately the stock driver. Screenshots are written by the probe itself
/// straight to `build/ui_probe/`, because the integration_test plugin has no
/// `captureScreenshot` implementation on Windows desktop, and because a driver
/// that touched that directory would race the app: `flutter drive` starts the
/// app FIRST and the driver second, so cleanup here deleted screenshots that
/// had already been taken. `scripts/ui_probe.ps1` clears the directory before
/// either process starts.
Future<void> main() => integrationDriver();
