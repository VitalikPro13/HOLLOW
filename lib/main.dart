import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/rust_licenses.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/webrtc_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:hollow/src/ui/shader_warmup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Global provider container — used by window/tray listeners.
late final ProviderContainer _container;

/// Lock file path — prevents multiple instances.
late final String _lockFilePath;

/// Check if another instance is already running via lock file.
/// Returns true if this is the only instance (safe to proceed).
bool _acquireSingleInstanceLock() {
  final appDataDir = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      '.';
  final sep = Platform.pathSeparator;
  _lockFilePath = '$appDataDir${sep}Hollow${sep}hollow.lock';

  // Ensure directory exists.
  final dir = Directory('$appDataDir${sep}Hollow');
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }

  final lockFile = File(_lockFilePath);
  if (lockFile.existsSync()) {
    try {
      final pidStr = lockFile.readAsStringSync().trim();
      final pid = int.tryParse(pidStr);
      if (pid != null && _isProcessRunning(pid)) {
        // Another instance is alive — exit.
        return false;
      }
    } catch (_) {}
    // Stale lock file — remove it.
    try {
      lockFile.deleteSync();
    } catch (_) {}
  }

  // Write our PID.
  try {
    lockFile.writeAsStringSync('$pid');
  } catch (_) {}

  return true;
}

/// Check if a Hollow process with the given PID is still running.
/// Also verifies the process name contains "hollow" to avoid false
/// positives from PID reuse after a crash.
bool _isProcessRunning(int targetPid) {
  try {
    if (Platform.isWindows) {
      final result = Process.runSync(
          'tasklist', ['/FI', 'PID eq $targetPid', '/NH']);
      final output = result.stdout.toString().toLowerCase();
      // Must match both PID and our process name.
      return output.contains('$targetPid') && output.contains('hollow');
    } else {
      // Linux/macOS: check /proc or ps for both PID and name.
      final result = Process.runSync('ps', ['-p', '$targetPid', '-o', 'comm=']);
      return result.exitCode == 0 &&
          result.stdout.toString().toLowerCase().contains('hollow');
    }
  } catch (_) {
    return false;
  }
}

/// Remove the lock file on exit.
void _releaseLock() {
  try {
    File(_lockFilePath).deleteSync();
  } catch (_) {}
}

/// Crash log file for Flutter errors.
IOSink? _crashLogSink;

/// Initialize crash logging — captures Flutter framework errors and
/// platform/async errors to hollow_crash.log alongside hollow_debug.log.
void _initCrashLogging() {
  try {
    final dataDir = Platform.environment['HOLLOW_DATA_DIR'] ??
        '${Platform.environment['APPDATA'] ?? Platform.environment['HOME'] ?? '.'}${Platform.pathSeparator}Hollow';
    final logFile = File('$dataDir${Platform.pathSeparator}hollow_crash.log');

    // Rotate if over 5MB.
    if (logFile.existsSync() && logFile.lengthSync() > 5 * 1024 * 1024) {
      final backup = File('${logFile.path}.old');
      if (backup.existsSync()) backup.deleteSync();
      logFile.renameSync(backup.path);
    }

    _crashLogSink = logFile.openWrite(mode: FileMode.append);
    _crashLogSink!.writeln('\n=== Hollow started at ${DateTime.now().toIso8601String()} ===');

    // Flutter framework errors (widget build, rendering, etc.).
    FlutterError.onError = (details) {
      FlutterError.presentError(details); // still print to console
      _crashLogSink?.writeln(
        '[${DateTime.now().toIso8601String()}] [FLUTTER-ERROR] ${details.exceptionAsString()}\n${details.stack}',
      );
      _crashLogSink?.flush();
    };

    // Async/platform errors not caught by Flutter framework.
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('[HOLLOW-CRASH] $error\n$stack');
      _crashLogSink?.writeln(
        '[${DateTime.now().toIso8601String()}] [PLATFORM-ERROR] $error\n$stack',
      );
      _crashLogSink?.flush();
      return true; // handled
    };
  } catch (e) {
    debugPrint('[HOLLOW] Failed to init crash logging: $e');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  registerRustLicenses();

  // Single-instance check — exit if another instance is running.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    if (!_acquireSingleInstanceLock()) {
      exit(0);
    }
  }

  // Pre-compile GPU shaders before the first frame to eliminate
  // shader compilation jank during animations.
  await HollowShaderWarmUp().execute();

  await RustLib.init();

  // fvp provides the video_player backend on Windows/Linux (where the official
  // plugin has no native support). Skip on mobile — official plugin works natively.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    fvp.registerWith();
  }

  final container = ProviderContainer();
  _container = container;

  // Custom window chrome on desktop — hide native title bar.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(800, 500),
      center: true,
      backgroundColor: Color(0xFF0D0F14), // Hollow dark background
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setAsFrameless();
      // Intercept close so we can minimize to tray instead.
      await windowManager.setPreventClose(true);
      windowManager.addListener(_HollowWindowListener());
      await windowManager.show();
      await windowManager.focus();
    });

    // Set up tray listener (icon is only created when minimizing).
    trayManager.addListener(_HollowTrayListener());
  }

  // Set up crash dump logging to hollow_crash.log.
  _initCrashLogging();

  // Start shared animation tickers (one ticker drives all decorative anims).
  // The disable-animations setting is restored in _bootstrap() after the DB
  // opens — loadSetting requires SQLCipher which isn't available until login.
  SharedTickers.instance.start();

  runApp(UncontrolledProviderScope(
    container: container,
    child: const HollowApp(),
  ));
}

/// Show the system tray icon with context menu.
/// Cached path to the extracted tray icon file.
String? _trayIconPath;

Future<String?> _ensureTrayIcon() async {
  if (_trayIconPath != null && File(_trayIconPath!).existsSync()) {
    return _trayIconPath;
  }

  // Try file system locations first (faster, no extraction needed).
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final candidates = [
    '$exeDir/data/flutter_assets/assets/app_icon.ico',
    '$exeDir/app_icon.ico',
    'windows/runner/resources/app_icon.ico',
    '${File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path}/windows/runner/resources/app_icon.ico',
  ];

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      _trayIconPath = File(candidate).absolute.path;
      return _trayIconPath;
    }
  }

  // Extract from Flutter assets as last resort.
  try {
    final byteData = await rootBundle.load('assets/app_icon.ico');
    final tempDir = Directory.systemTemp;
    final iconFile = File('${tempDir.path}/hollow_tray_icon.ico');
    await iconFile.writeAsBytes(byteData.buffer.asUint8List());
    _trayIconPath = iconFile.path;
    return _trayIconPath;
  } catch (e) {
    debugPrint('[HOLLOW] Failed to extract tray icon: $e');
    return null;
  }
}

Future<void> _showTrayIcon() async {
  final iconPath = await _ensureTrayIcon();
  if (iconPath == null) return;
  await trayManager.setIcon(iconPath);
  await trayManager.setToolTip('Hollow — Running in background');
  final menu = Menu(
    items: [
      MenuItem(key: 'show', label: 'Show Hollow'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit'),
    ],
  );
  await trayManager.setContextMenu(menu);
}

/// Remove the system tray icon.
Future<void> _hideTrayIcon() async {
  await trayManager.destroy();
}

/// Handles tray icon interactions.
class _HollowTrayListener extends TrayListener {
  @override
  void onTrayIconMouseDown() {
    _restoreWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _restoreWindow();
        break;
      case 'quit':
        _quitApp();
        break;
    }
  }

  void _restoreWindow() async {
    await _hideTrayIcon();
    await windowManager.show();
    await windowManager.focus();
    _container.read(windowVisibleProvider.notifier).state = true;
    SharedTickers.instance.resume();
  }

  Future<void> _quitApp() async {
    try {
      // Phase 6.25: Dispose WebRTC resources before shutdown.
      await _container.read(webRtcProvider.notifier).disposeAll();
    } catch (_) {}
    try {
      await network_api.notifyShutdown();
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    await _hideTrayIcon();
    _releaseLock();
    await windowManager.destroy();
  }
}

/// Handles window close, minimize, restore — pauses animations when hidden.
class _HollowWindowListener extends WindowListener {
  @override
  void onWindowMinimize() {
    SharedTickers.instance.pause();
  }

  @override
  void onWindowRestore() {
    SharedTickers.instance.resume();
  }

  @override
  void onWindowFocus() {
    SharedTickers.instance.resume();
  }

  @override
  void onWindowClose() async {
    // Check user preference.
    bool minimizeToTray = true;
    try {
      final val = await storage_api.loadSetting(key: 'minimize_to_tray');
      minimizeToTray = val != 'false';
    } catch (_) {}

    if (minimizeToTray) {
      // Minimize to system tray — app keeps running in background.
      await _showTrayIcon();
      _container.read(windowVisibleProvider.notifier).state = false;
      SharedTickers.instance.pause();
      await windowManager.hide();
    } else {
      // Quit the app.
      await windowManager.hide();
      try {
        await network_api.notifyShutdown();
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {}
      await _hideTrayIcon();
      _releaseLock();
      await windowManager.destroy();
    }
  }
}
