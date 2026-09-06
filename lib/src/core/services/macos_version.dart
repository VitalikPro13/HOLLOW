import 'dart:io';

/// macOS version detection for screen-share-audio and recording tiers.
///
/// Both SENDING system audio and the native recorder need ScreenCaptureKit,
/// so both need 13.0+: below that no public system-audio capture API exists
/// and the recorder answers "Recording requires macOS 13+". RECEIVE of shared
/// audio works on every supported version. Parsed from
/// `Platform.operatingSystemVersion`, which reads "Version 13.5.2 (Build ...)".
class MacOsScreenAudioSupport {
  /// (major, minor), or null off macOS or on a parse failure, which callers
  /// read as unknown and therefore most capable.
  static (int, int)? get version {
    if (!Platform.isMacOS) return null;
    final raw = Platform.operatingSystemVersion;
    final match = RegExp(r'(\d+)\.(\d+)').firstMatch(raw);
    if (match == null) return null;
    return (int.parse(match.group(1)!), int.parse(match.group(2)!));
  }

  /// Human label like "13.5", or null off macOS.
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

  /// macOS 13.0+, the ScreenCaptureKit audio-only capture path.
  static bool get hasSckAudio => _atLeast(13, 0);

  /// macOS 13.0+, the native ScreenCaptureKit screen recorder.
  static bool get hasNativeRecorder => _atLeast(13, 0);

  /// Whether this Mac can RECORD a call (needs 13.0+). True off macOS, where
  /// recording is gated elsewhere.
  static bool get canRecord => !Platform.isMacOS || hasNativeRecorder;

  /// True on a macOS that can join a call but cannot record (10.15 to 12.x),
  /// which disables the record button.
  static bool get recordBlockedByOldOs =>
      Platform.isMacOS && !hasNativeRecorder;

  /// Whether this Mac can SEND screen-share audio at all (13.0+).
  static bool get canSendScreenAudio => Platform.isMacOS && hasSckAudio;

  /// True on a macOS that can share a screen but cannot send audio, which
  /// locks the audio toggle.
  static bool get audioSendBlockedByOldOs =>
      Platform.isMacOS && !hasSckAudio;
}
