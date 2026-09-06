import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Which desktop capture source types the CURRENT session can actually produce.
///
/// Wayland is the only case that differs: windows cannot be enumerated there
/// at all (a media list pops a portal dialog, and a window list used to
/// SIGSEGV inside libwebrtc, issue #30), so shares ride the
/// `wayland-portal:<gen>` sentinel and the portal's own picker
/// (`flutter_screen_capture.cc`).
class DesktopCaptureSupport {
  /// A Wayland session, decided exactly as libwebrtc's
  /// `DesktopCapturer::IsRunningUnderWayland()`, so our answer and its
  /// capturer choice cannot disagree.
  static bool get isWaylandSession {
    if (!Platform.isLinux) return false;
    final env = Platform.environment;
    if (!(env['XDG_SESSION_TYPE'] ?? '').startsWith('wayland')) return false;
    return (env['WAYLAND_DISPLAY'] ?? '').isNotEmpty;
  }

  /// Whether windows can be ENUMERATED. False on Wayland (portal picker only).
  static bool get canShareWindows => !isWaylandSession;

  /// Whether the picker delegates the choice to xdg-desktop-portal.
  static bool get usePortalPicker => isWaylandSession;

  /// Source types worth enumerating. Empty under the portal picker, where
  /// enumeration itself pops a prompt.
  static List<SourceType> get sourceTypes => usePortalPicker
      ? const []
      : const [SourceType.Screen, SourceType.Window];

  // Reusing the SAME portal generation restores the previous pick without a
  // prompt; bumping it forces a fresh one. RAM-only by design: the native
  // side's restore tokens die with the process.

  static int _portalGeneration = 0;

  /// True once a portal share succeeded this run, so the next can reuse it.
  static bool portalGrantLikely = false;

  /// The deviceId sentinel `getDisplayMedia` understands.
  static String get portalSourceId => 'wayland-portal:$_portalGeneration';

  /// Whether [sourceId] is a portal-first sentinel. Such a share must NEVER
  /// re-enumerate sources first: enumeration pops a portal dialog of its own.
  static bool isPortalSourceId(String sourceId) =>
      sourceId.startsWith('wayland-portal:');

  /// Forgets the current portal grant so the NEXT share prompts afresh.
  static void bumpPortalGeneration() {
    _portalGeneration++;
    portalGrantLikely = false;
  }
}
