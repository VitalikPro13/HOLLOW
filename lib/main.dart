import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/rust/api/network.dart' as network_api;
import 'package:haven/src/rust/frb_generated.dart';
import 'package:haven/src/ui/app.dart';
import 'package:haven/src/ui/shader_warmup.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Pre-compile GPU shaders before the first frame to eliminate
  // shader compilation jank during animations.
  await HavenShaderWarmUp().execute();

  await RustLib.init();

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
      // Intercept close so we can send a graceful disconnect signal.
      await windowManager.setPreventClose(true);
      windowManager.addListener(_HavenWindowListener());
      await windowManager.show();
      await windowManager.focus();
    });
  }

  runApp(const ProviderScope(child: HavenApp()));
}

/// Handles the window close event to send a graceful disconnect signal
/// before the app actually exits.
class _HavenWindowListener extends WindowListener {
  @override
  void onWindowClose() async {
    // Hide the window immediately so the user sees an instant close.
    await windowManager.hide();
    // Send disconnect signal and give it a moment to reach peers.
    try {
      await network_api.notifyShutdown();
      await Future.delayed(const Duration(milliseconds: 200));
    } catch (_) {}
    await windowManager.destroy();
  }
}
