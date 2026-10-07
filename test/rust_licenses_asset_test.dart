// The licenses page's two hand-off files: the cargo-about output for the Rust
// core and the hand-kept credits for what no generator sees.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/rust_licenses.dart';

Set<String> _packages(String asset) => {
      for (final LicenseEntry e
          in parseLicenseFile(File(asset).readAsStringSync()))
        ...e.packages,
    };

void main() {
  test('the Rust credits cover the crates the app ships', () {
    final rust = _packages('assets/rust_licenses.txt');
    expect(rust.length, greaterThan(500));
    // Only built with `--features forwarder`, which every app build passes.
    expect(rust, contains('str0m 0.21.0'));
    expect(rust, contains('deep_filter 0.5.6'));
    expect(rust, contains('libsqlite3-sys 0.38.2'));
  });

  test('the hand-kept credits name the natives, the fonts and the crates '
      'cargo-about misses', () {
    final extra = _packages('assets/extra_licenses.txt');
    for (final name in [
      'OpenSSL',
      'SQLCipher',
      'WebRTC',
      'libwebrtc (webrtc-sdk)',
      'boringssl (in WebRTC)',
      'openh264 (in WebRTC)',
      'ffmpeg (in WebRTC)',
      'flutter_webrtc',
      'svpng',
      'FFmpeg (ffmpeg.exe and ffmpeg-8.dll, Windows)',
      'libwebp',
      'Firebase (Firebase, Android)',
      'Kotlin (Firebase, Android)',
      'Onest',
      'Geist Mono',
      'Noto Color Emoji',
      'Simple Icons',
      'rust-ini 0.19.0',
      'ordered-multimap 0.6.0',
      'dlv-list 0.5.2',
      'hashbrown 0.13.2',
      'const-random 0.1.18',
      'const-random-macro 0.1.16',
    ]) {
      expect(extra, contains(name));
    }
  });

  test('every hand-kept entry names its package and carries a text', () {
    final entries =
        parseLicenseFile(File('assets/extra_licenses.txt').readAsStringSync());
    expect(entries.length, greaterThanOrEqualTo(70));
    for (final LicenseEntry e in entries) {
      expect(e.packages, isNotEmpty);
      expect(e.paragraphs.map((p) => p.text).join().trim(), isNotEmpty);
    }
  });

  test('both files are listed as assets', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/rust_licenses.txt'));
    expect(pubspec, contains('- assets/extra_licenses.txt'));
  });
}
