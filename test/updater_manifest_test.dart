import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';

/// The manifest carries two Linux downloads: the Flatpak bundle (`url_linux`)
/// and the portable tarball (`url_linux_targz`), each with its own checksum.
/// A Linux install picks the one matching its own kind; this pins the parsing
/// and the download file name so a renamed field can never silently point a
/// tarball install at a bundle it cannot apply.
void main() {
  const entry = '''
  {
    "version": "0.10.1",
    "date": "August 23, 2026",
    "url_windows": "https://anonlisten.com/hollow/releases/hollow-0.10.1-win64.zip",
    "url_macos": "https://anonlisten.com/hollow/releases/hollow-0.10.1-macos.zip",
    "url_linux": "https://anonlisten.com/hollow/releases/hollow-0.10.1-linux-x86_64.flatpak",
    "url_linux_targz": "https://anonlisten.com/hollow/releases/hollow-0.10.1-linux.tar.gz",
    "notes": "n",
    "sha256_windows": "aa",
    "sha256_macos": "bb",
    "sha256_linux": "cc",
    "sha256_linux_targz": "dd"
  }''';

  test('both Linux downloads and both checksums are parsed', () {
    final v = VersionInfo.fromJson(jsonDecode(entry) as Map<String, dynamic>);
    expect(v.urlLinux, endsWith('.flatpak'));
    expect(v.urlLinuxTargz, endsWith('.tar.gz'));
    expect(v.sha256Linux, 'cc');
    expect(v.sha256LinuxTargz, 'dd');
  });

  test('a manifest without the tarball fields still parses', () {
    final json = jsonDecode(entry) as Map<String, dynamic>
      ..remove('url_linux_targz')
      ..remove('sha256_linux_targz');
    final v = VersionInfo.fromJson(json);
    expect(v.urlLinuxTargz, '');
    expect(v.sha256LinuxTargz, '');
  });

  test('the download file name carries the extension the installer needs', () {
    final v = VersionInfo.fromJson(jsonDecode(entry) as Map<String, dynamic>);
    if (Platform.isLinux) {
      expect(v.downloadFileName, anyOf('0.10.1.flatpak', '0.10.1.tar.gz'));
    } else {
      expect(v.downloadFileName, '0.10.1.zip');
      // Outside Linux the platform URL never points at a Linux artifact.
      expect(v.platformUrl, isNot(contains('linux')));
    }
  });
}
