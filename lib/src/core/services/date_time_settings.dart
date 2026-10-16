import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hollow/src/core/android_platform.dart';

/// Whether this platform lets the app open its date and time settings page. iOS
/// opens only the app's own page and Linux has no common one, so both get words.
bool get canOpenDateTimeSettings =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isAndroid);

/// Opens the OS date and time settings. False when unsupported or refused.
Future<bool> openDateTimeSettings() async {
  if (kIsWeb) return false;
  if (Platform.isWindows) return _launch('ms-settings:dateandtime');
  if (Platform.isMacOS) {
    // The pane moved in macOS 13; the older URL still answers below that.
    if (await _launch(
        'x-apple.systempreferences:com.apple.Date-Time-Settings.extension')) {
      return true;
    }
    return _launch('x-apple.systempreferences:com.apple.preference.datetime');
  }
  if (Platform.isAndroid) return openAndroidDateSettings();
  return false;
}

Future<bool> _launch(String url) async {
  try {
    return await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
