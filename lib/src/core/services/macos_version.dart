import 'dart:io';

/// macOS version detection + screen-share-audio capability tiers.
///
/// `Platform.operatingSystemVersion` on macOS looks like:
///   "Version 13.5.2 (Build 22G91)"
/// We parse the leading major.minor to decide which system-audio CAPTURE path
/// (for SENDING shared audio) is available:
///
///   >= 14.2  : CoreAudio Process Tap (MacScreenShareAudioTap) -> WebRTC track
///   >= 13.0  : ScreenCaptureKit audio-only -> data channel (MacSckScreenAudioCapturer)
///   <  13.0  : no public system-audio capture API exists -> SEND unavailable
///
/// RECEIVE works on every supported version (10.15+) via the bundled renderer.
class MacOsScreenAudioSupport {
  /// (major, minor) parsed from the OS version string, or null off macOS / on
  /// parse failure (treated as "unknown" -> most capable, fail open at runtime).
  static (int, int)? get version {
    if (!Platform.isMacOS) return null;
    final raw = Platform.operatingSystemVersion; // "Version 13.5.2 (Build ...)"
    final match = RegExp(r'(\d+)\.(\d+)').firstMatch(raw);
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  /// Human label like "13.5" (or null off macOS / unknown).
  static String? get versionLabel {
    final v = version;
    if (v == null) return null;
    return '${v.$1}.${v.$2}';
  }

  static bool _atLeast(int major, int minor) {
    final v = version;
    if (v == null) return true; // unknown -> fail open
    if (v.$1 != major) return v.$1 > major;
    return v.$2 >= minor;
  }

  /// macOS 14.2+ — Process Tap path.
  static bool get hasProcessTap => _atLeast(14, 2);

  /// macOS 13.0+ — ScreenCaptureKit audio-only capture path.
  static bool get hasSckAudio => _atLeast(13, 0);

  /// Whether this Mac can SEND screen-share audio at all (13.0+).
  static bool get canSendScreenAudio => Platform.isMacOS && hasSckAudio;

  /// True when the user is on a macOS that can share a screen but CANNOT send
  /// audio (10.15–12.x) — used to lock the audio toggle + show a warning.
  static bool get audioSendBlockedByOldOs =>
      Platform.isMacOS && !hasSckAudio;
}
