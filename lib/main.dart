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
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/core/services/deep_link_service.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/services/ios_data_dir_migration.dart';
import 'package:hollow/src/ui/shader_warmup.dart';
import 'package:firebase_core/firebase_core.dart';
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
Future<void> _initCrashLogging() async {
  try {
    final dataDir = hollowDataDir;
    final dir = Directory(dataDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);

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

  // Release builds: debugPrint is a real print on every platform, and the
  // event dispatcher interpolates + prints per network event. Silence it —
  // release diagnostics go through hollow_log!/logFromDart (hollow_debug.log).
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

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

  // Resolve app data directory (async on mobile, sync on desktop).
  // Must be called before RustLib.init crash logging or any file I/O.
  await initHollowDataDir();

  // iOS: migrate the data dir into the App Group container so the Notification
  // Service Extension can open the SAME SQLCipher DB + identity to fetch &
  // decrypt push messages on-device. Must happen BEFORE RustLib opens the DB.
  // No-op on other platforms; falls back to the private dir if the App Group is
  // unavailable or migration fails.
  if (Platform.isIOS) {
    final migrated =
        await IosDataDirMigration.resolveAndMigrate(hollowDataDir);
    if (migrated != null) {
      overrideHollowDataDir(migrated);
      debugPrint('████ [HOLLOW] iOS data dir → App Group: $migrated');
    }
  }

  await RustLib.init();

  // On mobile, dirs crate returns None — pass the app data path to Rust.
  if (Platform.isAndroid || Platform.isIOS) {
    await identity_api.setDataDir(path: hollowDataDir);
  }

  // Initialize Firebase early (required before FCM token generation).
  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await Firebase.initializeApp();
      debugPrint('████ [HOLLOW] Firebase initialized in main()');
    } catch (e) {
      debugPrint('████ [HOLLOW] Firebase init failed in main(): $e');
    }
  }

  // fvp provides the video_player backend on Windows/Linux (where the official
  // plugin has no native support). Skip on mobile — official plugin works natively.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    fvp.registerWith();
  }

  final container = ProviderContainer();
  _container = container;

  // Deep links (hollow:// from browsers/other apps). Initialized before
  // runApp so the cold-start protocol launch link is captured; handled links
  // buffer until HollowShell mounts. On desktop, an incoming link restores
  // the window first (it usually arrives while Hollow is hidden in tray).
  await DeepLinkService.instance.init(container);
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    DeepLinkService.instance.bringToForeground = () async {
      await _hideTrayIcon();
      if (Platform.isLinux && await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
      _container.read(windowVisibleProvider.notifier).state = true;
      SharedTickers.instance.resume();
    };
  }

  // Custom window chrome on desktop — hide native title bar.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    // On macOS we keep the native traffic-light buttons (close/minimize/zoom)
    // for a proper Mac look — `TitleBarStyle.hidden` already gives a frameless
    // content area while leaving those three circles in the top-left corner.
    // Windows/Linux hide the native controls entirely (we draw our own).
    final windowOptions = WindowOptions(
      size: const Size(1280, 800),
      minimumSize: const Size(800, 500),
      center: true,
      backgroundColor: const Color(0xFF0D0F14), // Hollow dark background
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: Platform.isMacOS,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      // setAsFrameless() strips the macOS traffic lights too — only do it on
      // Windows/Linux where we render the full custom control set ourselves.
      if (!Platform.isMacOS) {
        await windowManager.setAsFrameless();
      }
      // Intercept close so we can minimize to tray instead.
      await windowManager.setPreventClose(true);
      windowManager.addListener(_HollowWindowListener());
      await windowManager.show();
      await windowManager.focus();
    });

    // Set up tray listener (icon is only created when minimizing).
    trayManager.addListener(_HollowTrayListener());

    // Install .desktop + icon to XDG paths on first launch.
    await _installLinuxDesktopIntegration();
  }

  // Set up crash dump logging to hollow_crash.log.
  await _initCrashLogging();

  // Seed reduce-motion from the OS accessibility flag BEFORE tickers start, so
  // decorative animations never spin on the login screen when the OS has
  // Reduce Motion on. The persisted in-app override (Auto/On/Off) is applied
  // in _bootstrap() after the DB opens. This also wires the runtime listener
  // so flipping the OS setting takes effect live.
  ReduceMotionController.instance.initFromOs();

  // Start shared animation tickers (one ticker drives all decorative anims).
  // No-op if reduce-motion was already effective (controller set disabled).
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

  // Linux/macOS tray requires PNG; Windows uses ICO.
  final usesPng = !Platform.isWindows;
  final exeDir = File(Platform.resolvedExecutable).parent.path;

  // Try file system locations first (faster, no extraction needed).
  final candidates = [
    if (usesPng) '$exeDir/data/flutter_assets/assets/hollow_logo_rounded.png',
    if (!usesPng) '$exeDir/data/flutter_assets/assets/app_icon.ico',
    if (!usesPng) '$exeDir/app_icon.ico',
    if (!usesPng) 'windows/runner/resources/app_icon.ico',
    if (!usesPng) '${File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.path}/windows/runner/resources/app_icon.ico',
  ];

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      _trayIconPath = File(candidate).absolute.path;
      return _trayIconPath;
    }
  }

  // Extract from Flutter assets as last resort.
  try {
    final assetName = usesPng ? 'assets/hollow_logo_rounded.png' : 'assets/app_icon.ico';
    final byteData = await rootBundle.load(assetName);
    final tempDir = Directory.systemTemp;
    final iconFile = File('${tempDir.path}/hollow_tray_icon.${usesPng ? 'png' : 'ico'}');
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

/// Clean shutdown on Linux (no tray to clean up).
Future<void> _linuxQuit() async {
  try {
    await _container.read(webRtcProvider.notifier).disposeAll();
  } catch (_) {}
  try {
    await network_api.notifyShutdown();
    await Future.delayed(const Duration(milliseconds: 200));
  } catch (_) {}
  _releaseLock();
  await windowManager.destroy();
}

/// Install .desktop file and icon to XDG paths so the DE shows the correct
/// name and icon in the taskbar, and register the hollow:// scheme handler.
/// Re-writes the file whenever the desired content changes (exe moved, or an
/// older install predates the MimeType/%u deep-link fields).
Future<void> _installLinuxDesktopIntegration() async {
  if (!Platform.isLinux) return;
  final homeDir = Platform.environment['HOME'];
  if (homeDir == null) return;

  final appsDir = Directory('$homeDir/.local/share/applications');
  final iconsDir = Directory('$homeDir/.local/share/icons');
  final desktopFile = File('${appsDir.path}/com.anonlisten.hollow.desktop');

  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final bundledDesktop = File('$exeDir/com.anonlisten.hollow.desktop');
  final bundledIcon = File('$exeDir/com.anonlisten.hollow.png');

  if (!bundledDesktop.existsSync() || !bundledIcon.existsSync()) return;

  try {
    if (!appsDir.existsSync()) appsDir.createSync(recursive: true);
    if (!iconsDir.existsSync()) iconsDir.createSync(recursive: true);

    // Write .desktop with absolute Exec and Icon paths. %u passes a clicked
    // hollow:// URI as an argument; MimeType registers us as its handler.
    final iconDest = '${iconsDir.path}/com.anonlisten.hollow.png';
    final content = '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=Hollow\n'
        'Comment=Encrypted distributed messaging\n'
        'Exec=${Platform.resolvedExecutable} %u\n'
        'Icon=$iconDest\n'
        'Terminal=false\n'
        'Categories=Network;InstantMessaging;\n'
        'MimeType=x-scheme-handler/hollow;\n'
        'StartupWMClass=com.anonlisten.hollow\n';

    final upToDate = desktopFile.existsSync() &&
        desktopFile.readAsStringSync() == content;
    if (upToDate) return;

    bundledIcon.copySync(iconDest);
    desktopFile.writeAsStringSync(content);

    // Refresh the desktop database and claim the scheme so browsers resolve
    // hollow:// immediately (best-effort — the MimeType line alone works on
    // most DEs after the next cache refresh).
    try {
      await Process.run('update-desktop-database', [appsDir.path]);
    } catch (_) {}
    try {
      await Process.run('xdg-mime',
          ['default', 'com.anonlisten.hollow.desktop', 'x-scheme-handler/hollow']);
    } catch (_) {}
  } catch (e) {
    debugPrint('[HOLLOW] Linux desktop integration failed: $e');
  }
}

/// Handles tray icon interactions.
class _HollowTrayListener extends TrayListener {
  @override
  void onTrayIconMouseDown() {
    // On Linux, AppIndicator shows the context menu on any click —
    // don't restore here or it destroys the tray before the menu appears.
    if (!Platform.isLinux) _restoreWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    // No-op on Linux (AppIndicator shows menu automatically).
    if (!Platform.isLinux) trayManager.popUpContextMenu();
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
    if (Platform.isLinux) {
      await windowManager.restore();
    }
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
    _container.read(windowFocusedProvider.notifier).state = true;
    // On macOS the window is re-shown natively from the Dock
    // (applicationShouldHandleReopen) without going through the tray restore
    // path, so sync the visible state here.
    if (Platform.isMacOS) {
      _container.read(windowVisibleProvider.notifier).state = true;
    }
  }

  @override
  void onWindowBlur() {
    // Window lost focus (alt-tabbed / clicked another app). Drives native-toast
    // gating so messages in the open conversation still notify while we're away.
    _container.read(windowFocusedProvider.notifier).state = false;
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
      if (Platform.isLinux) {
        // Linux taskbar provides restore (click) + Quit (right-click).
        // If already minimized, the close event is from taskbar "Quit".
        if (await windowManager.isMinimized()) {
          await _linuxQuit();
        } else {
          await windowManager.minimize();
        }
      } else if (Platform.isMacOS) {
        // macOS-native idiom: hide the window, app keeps running in the Dock
        // with the active dot. No tray icon (macOS has no system tray).
        // Clicking the Dock icon re-shows it via `applicationShouldHandleReopen`
        // in AppDelegate.swift, which fires onWindowFocus → tickers resume.
        _container.read(windowVisibleProvider.notifier).state = false;
        SharedTickers.instance.pause();
        await windowManager.hide();
      } else {
        // Windows: minimize to system tray — app keeps running in background.
        await _showTrayIcon();
        _container.read(windowVisibleProvider.notifier).state = false;
        SharedTickers.instance.pause();
        await windowManager.hide();
      }
    } else {
      // Quit the app.
      if (Platform.isLinux) {
        await _linuxQuit();
      } else {
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
}
