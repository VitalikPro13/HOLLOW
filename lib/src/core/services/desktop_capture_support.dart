import 'dart:io';

import 'package:flutter/foundation.dart';
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

/// Our own share's capture and self-preview, shared by voice channels and
/// DM calls.
class ShareCapture {
  /// Test seams: stand-ins for the platform picker and the preview renderer.
  @visibleForTesting
  static Future<MediaStream> Function()? debugOpen;
  @visibleForTesting
  static RTCVideoRenderer Function()? debugRenderer;

  /// Opens the platform capture. The picker (Android consent, the iOS
  /// broadcast sheet, the Wayland portal) is up for as long as this waits,
  /// and the app stays usable meanwhile.
  static Future<MediaStream> open({
    required String sourceId,
    required int width,
    required int height,
    required int fps,
    required bool shareAudio,
  }) async {
    final seam = debugOpen;
    if (seam != null) return seam();
    // Capture screen ONCE. Source enumeration is desktop-only; mobile
    // captures THE screen (MediaProjection / ReplayKit broadcast).
    if (Platform.isAndroid) {
      // Constraints are ignored by the Android plugin (MediaProjection captures
      // at native display size); the per-peer encoder cap does the downscaling.
      return navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });
    } else if (Platform.isIOS) {
      // 'broadcast' selects the ReplayKit Broadcast Upload Extension path.
      return navigator.mediaDevices.getDisplayMedia({
        'video': {'deviceId': 'broadcast'},
        'audio': false,
      });
    } else {
      // A Wayland portal-first share MUST NOT re-enumerate: enumerating here
      // would pop an extra xdg-desktop-portal dialog.
      if (!DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        await desktopCapturer.getSources(
          types: DesktopCaptureSupport.sourceTypes,
        );
      }
      // Windows and Linux carry share audio over a data channel, so never ask
      // getDisplayMedia for audio: the WASAPI path crashes Windows.
      final getDisplayAudio =
          shareAudio && !Platform.isWindows && !Platform.isLinux;

      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': {
          'deviceId': {'exact': sourceId},
          'mandatory': {
            'frameRate': fps.toDouble(),
            'width': width,
            'height': height,
          },
        },
        'audio': getDisplayAudio,
      });
      // The portal grant now exists: the next share can reuse it promptless.
      if (DesktopCaptureSupport.isPortalSourceId(sourceId)) {
        DesktopCaptureSupport.portalGrantLikely = true;
      }
      return stream;
    }
  }

  static RTCVideoRenderer newPreview() =>
      debugRenderer?.call() ?? RTCVideoRenderer();

  /// Closes a capture and preview no share owns; either may be null.
  static Future<void> close(
    MediaStream? capture,
    RTCVideoRenderer? preview,
  ) async {
    if (preview != null) {
      try {
        preview.srcObject = null;
        await preview.dispose();
      } catch (_) {}
    }
    if (capture == null) return;
    for (final t in capture.getTracks()) {
      try {
        await t.stop();
      } catch (_) {}
    }
    try {
      await capture.dispose();
    } catch (_) {}
  }
}
