import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:haven/src/rust/api/storage.dart' as storage_api;
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/ui/app.dart';
import 'package:haven/src/ui/shader_warmup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-compile GPU shaders before the first frame to eliminate
  // shader compilation jank during animations.
  await HavenShaderWarmUp().execute();

  await RustLib.init();

  final container = ProviderContainer();

  // Custom window chrome on desktop — hide native title bar.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(800, 500),
      center: true,
      backgroundColor: Color(0xFF0D0F14), // Haven dark background
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setAsFrameless();
      // Intercept close so we can minimize to tray instead.
      await windowManager.setPreventClose(true);
      windowManager.addListener(_HavenWindowListener());
      await windowManager.show();
      await windowManager.focus();
    });

    // Set up tray listener (icon is only created when minimizing).
    trayManager.addListener(_HavenTrayListener());
  }

  runApp(UncontrolledProviderScope(
    container: container,
    child: const HavenApp(),
  ));
}

/// Show the system tray icon with context menu.
Future<void> _showTrayIcon() async {
  // Resolve icon path relative to the executable.
  // During debug: exe is in build/windows/x64/runner/Debug/
  // The ico is at windows/runner/resources/app_icon.ico from project root.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  String iconPath;
  // Check if running from build dir (debug) or installed location.
  final projectIcon = File('windows/runner/resources/app_icon.ico');
  if (projectIcon.existsSync()) {
    iconPath = projectIcon.absolute.path;
  } else {
    // Release: icon should be next to the exe.
    iconPath = '$exeDir/app_icon.ico';
  }
  await trayManager.setIcon(iconPath);
  await trayManager.setToolTip('Haven — Running in background');
  final menu = Menu(
    items: [
      MenuItem(key: 'show', label: 'Show Haven'),
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
class _HavenTrayListener extends TrayListener {
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
  }

  Future<void> _quitApp() async {
    try {
      await network_api.notifyShutdown();
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    await _hideTrayIcon();
    await windowManager.destroy();
  }
}

/// Handles window close — minimizes to tray or quits based on user setting.
class _HavenWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    // Check user preference.
    bool minimizeToTray = true;
    try {
      final val = await storage_api.loadSetting(key: 'minimize_to_tray');
      minimizeToTray = val != 'false';
    } catch (_) {}

    if (minimizeToTray) {
      // Minimize to system tray — app keeps running.
      await _showTrayIcon();
      await windowManager.hide();
    } else {
      // Quit the app.
      await windowManager.hide();
      try {
        await network_api.notifyShutdown();
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (_) {}
      await windowManager.destroy();
    }
  }
}
