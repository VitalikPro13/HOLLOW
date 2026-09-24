import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True while the Dock layout is mounted and draws the window's chrome into its
/// own header: the 32 px title bar collapses and the window controls float
/// over the header's trailing end.
///
/// Set by the dock layout after a frame and cleared when it leaves, never
/// during a build. The welcome screens, the lock cover and Classic keep the
/// title bar because nothing else of theirs can move the window.
final dockOwnsWindowChromeProvider = StateProvider<bool>((_) => false);

/// Width of the floating window controls in WINDOW pixels, reported by the
/// controls after layout so the header can keep its trailing end clear.
final windowControlsWidthProvider = StateProvider<double>((_) => 0);

/// The header's height, which the floating controls match once scaled.
const double kDockHeaderHeight = 44;

/// Platforms where the dock's header can take the title bar's place. On macOS
/// the native traffic lights move down to centre in it (`MacTrafficLights`).
bool get dockHeaderCanOwnChrome =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// Kept clear at the header's leading end on macOS for the traffic lights, in
/// window points.
const double kMacTrafficLightGap = 78;
