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
/// On Wayland there is no window ENUMERATION at all — building a media list
/// that touches the portal pops an xdg-desktop-portal dialog just to
/// enumerate, and asking for a window list used to kill the app with a
/// SIGSEGV inside libwebrtc.so (issue #30). Wayland instead uses a
/// PORTAL-FIRST picker: the share dialog shows a single entry, and starting
/// the capture opens the ONE portal prompt where the user picks a screen OR a
/// window themselves (webrtc's generic PipeWire capturer, wired through the
/// `wayland-portal:<generation>` deviceId sentinel — `flutter_screen_capture.cc`
/// and `third_party/libwebrtc/hollow-screencast.patch`).
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

  /// Whether individual windows can be ENUMERATED (thumbnail grid). False on
  /// Wayland — windows are still shareable there, but only through the portal
  /// picker ([usePortalPicker]).
  static bool get canShareWindows => !isWaylandSession;

  /// Whether the share picker should skip enumeration entirely and delegate
  /// the choice to the desktop's own xdg-desktop-portal dialog.
  static bool get usePortalPicker => isWaylandSession;

  /// The source types worth enumerating on this session. Passing a type that
  /// can't be produced is harmless (the plugin skips it) but pointless.
  /// Empty under the portal picker: enumeration itself prompts there.
  static List<SourceType> get sourceTypes => usePortalPicker
      ? const []
      : const [SourceType.Screen, SourceType.Window];

  // --- Portal-first restore-token generation -------------------------------
  //
  // The native side banks the xdg-desktop-portal restore token under the
  // generation number inside the sentinel id. Reusing the SAME generation
  // restores the previous pick without a portal prompt (for the rest of this
  // process); bumping it forces a fresh prompt. RAM-only by design — tokens
  // die with the process, matching webrtc's in-memory RestoreTokenManager.

  static int _portalGeneration = 0;

  /// True once a portal share succeeded this run — the next share can reuse
  /// the banked portal grant ("share the same thing again") instead of
  /// re-prompting.
  static bool portalGrantLikely = false;

  /// The deviceId sentinel `getDisplayMedia` understands
  /// (`flutter_screen_capture.cc`).
  static String get portalSourceId => 'wayland-portal:$_portalGeneration';

  /// Whether [sourceId] is a portal-first sentinel rather than an enumerated
  /// desktop source id. Such shares must NEVER re-enumerate sources before
  /// capturing (enumeration pops a portal dialog of its own).
  static bool isPortalSourceId(String sourceId) =>
      sourceId.startsWith('wayland-portal:');

  /// Forget the current portal grant so the NEXT share prompts afresh — the
  /// picker's "choose something else" entry.
  static void bumpPortalGeneration() {
    _portalGeneration++;
    portalGrantLikely = false;
  }
}
