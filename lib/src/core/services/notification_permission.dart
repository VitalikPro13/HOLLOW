import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hollow/src/core/android_platform.dart'
    show openAndroidNotificationSettings;
import 'package:hollow/src/core/services/desktop_notification_service.dart';
import 'package:hollow/src/core/services/push_notification_service.dart'
    show
        mobileNotificationsEnabled,
        requestMobileNotificationPermission,
        showTestNotification;
import 'package:url_launcher/url_launcher.dart';

/// Whether the OS lets Hollow post notifications, as the OS reports it.
enum NotificationPermissionState { granted, denied, unknown }

/// One OS-permission answer plus what the settings page may offer about it.
class NotificationPermissionInfo {
  final NotificationPermissionState state;

  /// One plain sentence for the settings page, no em dashes.
  final String detail;

  /// The OS can show a permission prompt from inside the app right now.
  final bool canRequest;

  /// A system settings page for this app's notifications can be opened.
  final bool canOpenSettings;

  const NotificationPermissionInfo({
    required this.state,
    required this.detail,
    this.canRequest = false,
    this.canOpenSettings = false,
  });
}

/// Current OS-level permission for Hollow's notifications on this device.
Future<NotificationPermissionInfo> checkNotificationPermission() async {
  if (kIsWeb) return _unsupported;
  if (Platform.isMacOS) return _macInfo();
  if (Platform.isWindows) return _windowsInfo();
  if (Platform.isLinux) return _linuxInfo();
  if (Platform.isAndroid) return _mobileInfo(isAndroid: true);
  if (Platform.isIOS) return _mobileInfo(isAndroid: false);
  return _unsupported;
}

/// Prompts when the OS allows it, then returns the fresh status.
Future<NotificationPermissionInfo> requestNotificationPermission() async {
  if (kIsWeb) return _unsupported;
  try {
    if (Platform.isMacOS) {
      await DesktopNotificationService.instance.requestPermission();
    } else if (Platform.isAndroid || Platform.isIOS) {
      await requestMobileNotificationPermission();
    }
  } catch (_) {
    // A refused or unavailable prompt is not an error worth surfacing: the
    // fresh status below already says where the user stands.
  }
  return checkNotificationPermission();
}

/// Opens the OS notification settings page for Hollow. False when unsupported.
Future<bool> openSystemNotificationSettings() async {
  if (kIsWeb) return false;
  try {
    if (Platform.isMacOS) {
      // The pane moved in macOS 13; the older URL still answers below that.
      if (await _launch(
          'x-apple.systempreferences:com.apple.Notifications-Settings.extension')) {
        return true;
      }
      return await _launch(
          'x-apple.systempreferences:com.apple.preference.notifications');
    }
    if (Platform.isWindows) return await _launch('ms-settings:notifications');
    if (Platform.isAndroid) return await openAndroidNotificationSettings();
    if (Platform.isIOS) return await _launch('app-settings:');
  } catch (_) {
    return false;
  }
  return false;
}

/// Posts one real OS notification through the same backend live messages use.
/// Throws on failure so the caller can toast the error.
Future<void> sendTestNotification() async {
  if (kIsWeb) {
    throw StateError('This platform cannot post a test notification.');
  }
  if (Platform.isAndroid || Platform.isIOS) {
    await showTestNotification();
    return;
  }
  if (DesktopNotificationService.isSupported) {
    await DesktopNotificationService.instance.showTest();
    return;
  }
  throw StateError('This platform cannot post a test notification.');
}

const NotificationPermissionInfo _unsupported = NotificationPermissionInfo(
  state: NotificationPermissionState.unknown,
  detail: 'This platform does not report a notification permission.',
);

Future<bool> _launch(String url) async {
  try {
    return await launchUrl(Uri.parse(url),
        mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<NotificationPermissionInfo> _macInfo() async {
  // Idempotent, and the first call is what raises the OS prompt at startup.
  await DesktopNotificationService.instance.init();
  final opts = await DesktopNotificationService.instance.checkPermission();
  if (opts == null) {
    return const NotificationPermissionInfo(
      state: NotificationPermissionState.unknown,
      detail: 'macOS did not report a notification status for Hollow.',
      canRequest: true,
      canOpenSettings: true,
    );
  }
  return NotificationPermissionInfo(
    state: opts.isEnabled
        ? NotificationPermissionState.granted
        : NotificationPermissionState.denied,
    detail: opts.isEnabled
        ? 'macOS is allowing Hollow to post notifications.'
        : 'macOS is blocking Hollow notifications. Turn them back on in '
            'System Settings > Notifications > Hollow.',
    canRequest: true,
    canOpenSettings: true,
  );
}

Future<NotificationPermissionInfo> _windowsInfo() async {
  await DesktopNotificationService.instance.init();
  final ready = DesktopNotificationService.instance.isReady;
  return NotificationPermissionInfo(
    state: ready
        ? NotificationPermissionState.granted
        : NotificationPermissionState.denied,
    detail: ready
        ? 'Registered with Windows. If toasts never appear, check the Windows '
            'notification settings for Hollow.'
        : 'Hollow could not register with Windows notifications.',
    canOpenSettings: true,
  );
}

Future<NotificationPermissionInfo> _linuxInfo() async {
  await DesktopNotificationService.instance.init();
  final ready = DesktopNotificationService.instance.isReady;
  return NotificationPermissionInfo(
    state: ready
        ? NotificationPermissionState.granted
        : NotificationPermissionState.denied,
    detail: ready
        ? "Uses your desktop's notification service. Send a test notification "
            'to confirm it is reachable.'
        : "Hollow could not reach your desktop's notification service.",
  );
}

Future<NotificationPermissionInfo> _mobileInfo({required bool isAndroid}) async {
  final os = isAndroid ? 'Android' : 'iOS';
  final settingsPath = isAndroid
      ? 'the system settings'
      : 'Settings > Notifications > Hollow';
  final enabled = await mobileNotificationsEnabled();
  if (enabled == null) {
    return NotificationPermissionInfo(
      state: NotificationPermissionState.unknown,
      detail: '$os did not report a notification status for Hollow.',
      canRequest: true,
      canOpenSettings: true,
    );
  }
  return NotificationPermissionInfo(
    state: enabled
        ? NotificationPermissionState.granted
        : NotificationPermissionState.denied,
    detail: enabled
        ? '$os is allowing Hollow to post notifications.'
        : '$os is blocking Hollow notifications. Turn them back on in '
            '$settingsPath.',
    canRequest: true,
    canOpenSettings: true,
  );
}
