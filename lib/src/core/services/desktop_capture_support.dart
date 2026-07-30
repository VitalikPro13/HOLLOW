import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Which desktop capture source types the CURRENT session can actually produce.
///
/// Linux is the only platform where this varies. libwebrtc m144 picks a Linux
/// capturer like this (`modules/desktop_capture/{screen,window}_capturer_linux.cc`):
///
///   allow_pipewire + wayland session -> PipeWire / xdg-desktop-portal
///   NOT a wayland session            -> X11 capturer
///   otherwise                        -> nullptr
///
/// and the libwebrtc C++ wrapper only sets `allow_pipewire` for SCREEN capture.
/// A Wayland session therefore has no window capturer at all, and asking for
/// one used to kill the app with a SIGSEGV inside libwebrtc.so (issue #30).
/// The plugin now refuses to build that list (`flutter_screen_capture.cc`);
/// this class keeps the UI honest about what's on offer.
///
/// Window sharing on Wayland comes back once the wrapper enables PipeWire for
/// windows too — `third_party/libwebrtc/hollow-wayland-desktop-capture.patch`,
/// which needs a libwebrtc rebuild.
class DesktopCaptureSupport {
  /// A Wayland session. Mirrors libwebrtc's
  /// `DesktopCapturer::IsRunningUnderWayland()` exactly, so our answer and its
  /// capturer choice can't disagree.
  static bool get isWaylandSession {
    if (!Platform.isLinux) return false;
    final env = Platform.environment;
    if (!(env['XDG_SESSION_TYPE'] ?? '').startsWith('wayland')) return false;
    return (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
  }

  /// Whether a single WINDOW can be shared. False on Wayland, where the
  /// desktop portal only hands out whole screens.
  static bool get canShareWindows => !isWaylandSession;

  /// The source types worth enumerating on this session. Passing a type that
  /// can't be produced is harmless (the plugin skips it) but pointless.
  static List<SourceType> get sourceTypes => canShareWindows
      ? const [SourceType.Screen, SourceType.Window]
      : const [SourceType.Screen];
}
