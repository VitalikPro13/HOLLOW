import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/version_compare.dart';
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

const kManifestUrl = 'https://anonlisten.com/hollow/releases/manifest.json';

class VersionInfo {
  final String version;
  final String date;
  final String urlWindows;
  final String urlMacos;
  final String urlLinux;

  /// SHA-256 (hex) of each platform's download, written into the signed
  /// manifest by `hollow-manifest fill-hashes`. Rust refuses to hand a zip
  /// to `apply_update` unless the bytes it downloaded hash to this, so a
  /// release entry without one cannot be installed by the updater.
  final String sha256Windows;
  final String sha256Macos;
  final String sha256Linux;
  final String notes;

  const VersionInfo({
    required this.version,
    required this.date,
    this.urlWindows = '',
    this.urlMacos = '',
    this.urlLinux = '',
    this.sha256Windows = '',
    this.sha256Macos = '',
    this.sha256Linux = '',
    required this.notes,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) => VersionInfo(
        version: json['version'] as String? ?? '',
        date: json['date'] as String? ?? '',
        urlWindows: json['url_windows'] as String? ?? '',
        urlMacos: json['url_macos'] as String? ?? '',
        urlLinux: json['url_linux'] as String? ?? '',
        sha256Windows: json['sha256_windows'] as String? ?? '',
        sha256Macos: json['sha256_macos'] as String? ?? '',
        sha256Linux: json['sha256_linux'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
      );

  /// The download URL for the current platform (empty if unsupported).
  String get platformUrl {
    if (Platform.isMacOS) return urlMacos;
    if (Platform.isLinux) return urlLinux;
    return urlWindows; // Windows
  }

  /// The expected SHA-256 of [platformUrl] (empty when the manifest entry
  /// carries none, which the updater treats as "not installable").
  String get platformSha256 {
    if (Platform.isMacOS) return sha256Macos;
    if (Platform.isLinux) return sha256Linux;
    return sha256Windows; // Windows
  }

  /// Whether an update is actually downloadable on this platform.
  bool get hasPlatformUrl => platformUrl.isNotEmpty;
}

class VersionManifest {
  final String latest;
  final List<VersionInfo> versions;

  const VersionManifest({required this.latest, required this.versions});

  factory VersionManifest.fromJson(Map<String, dynamic> json) =>
      VersionManifest(
        latest: json['latest'] as String? ?? '',
        versions: (json['versions'] as List<dynamic>?)
                ?.map((v) => VersionInfo.fromJson(v as Map<String, dynamic>))
                .toList() ??
            [],
      );
}

enum UpdateStatus { idle, checking, downloading, extracting, readyToInstall, error }

class UpdateState {
  final UpdateStatus status;
  final VersionManifest? manifest;
  final String? selectedVersion;
  final double downloadProgress;
  final int bytesDownloaded;
  final int totalBytes;
  final String? downloadedZipPath;
  final String? batPath;
  final String? error;
  final String currentVersion;

  const UpdateState({
    this.status = UpdateStatus.idle,
    this.manifest,
    this.selectedVersion,
    this.downloadProgress = 0.0,
    this.bytesDownloaded = 0,
    this.totalBytes = 0,
    this.downloadedZipPath,
    this.batPath,
    this.error,
    this.currentVersion = '',
  });

  UpdateState copyWith({
    UpdateStatus? status,
    VersionManifest? manifest,
    String? selectedVersion,
    double? downloadProgress,
    int? bytesDownloaded,
    int? totalBytes,
    String? downloadedZipPath,
    String? batPath,
    String? error,
    String? currentVersion,
  }) =>
      UpdateState(
        status: status ?? this.status,
        manifest: manifest ?? this.manifest,
        selectedVersion: selectedVersion ?? this.selectedVersion,
        downloadProgress: downloadProgress ?? this.downloadProgress,
        bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
        totalBytes: totalBytes ?? this.totalBytes,
        downloadedZipPath: downloadedZipPath ?? this.downloadedZipPath,
        batPath: batPath ?? this.batPath,
        error: error ?? this.error,
        currentVersion: currentVersion ?? this.currentVersion,
      );
}

class UpdateNotifier extends Notifier<UpdateState> {
  @override
  UpdateState build() {
    return UpdateState(currentVersion: updater_api.getCurrentVersion());
  }

  Future<void> checkForUpdates() async {
    if (state.status == UpdateStatus.downloading ||
        state.status == UpdateStatus.extracting ||
        state.status == UpdateStatus.readyToInstall) {
      return;
    }
    state = state.copyWith(status: UpdateStatus.checking, error: null);
    try {
      final bustCache = DateTime.now().millisecondsSinceEpoch;
      final json = await updater_api.fetchVersionManifest(
          manifestUrl: '$kManifestUrl?t=$bustCache');
      final manifest =
          VersionManifest.fromJson(jsonDecode(json) as Map<String, dynamic>);
      state = state.copyWith(status: UpdateStatus.idle, manifest: manifest);
    } catch (e) {
      state = state.copyWith(
          status: UpdateStatus.error,
          error: 'Failed to check for updates: $e');
    }
  }

  Future<void> downloadVersion(VersionInfo version) async {
    final dataDir = hollowDataDir;
    final sep = Platform.pathSeparator;
    final destPath = '$dataDir${sep}updates$sep${version.version}.zip';

    // Fail closed before a single byte moves: a manifest entry with no
    // checksum for this platform is not something the updater installs.
    if (version.platformSha256.isEmpty) {
      state = state.copyWith(
        status: UpdateStatus.error,
        error: 'This release carries no checksum for your platform, so the '
            'updater will not install it. Download it from the website '
            'instead.',
      );
      return;
    }

    state = state.copyWith(
      status: UpdateStatus.downloading,
      selectedVersion: version.version,
      downloadProgress: 0.0,
      bytesDownloaded: 0,
      totalBytes: 0,
      error: null,
    );

    try {
      final stream = updater_api.downloadUpdate(
        url: version.platformUrl,
        destPath: destPath,
        expectedSha256: version.platformSha256,
      );

      await for (final progress in stream) {
        if (state.status != UpdateStatus.downloading) break;

        // Rust reports a failed or refused download (checksum mismatch, bad
        // URL, transport error) as a final item carrying the reason. The
        // partial file is already gone by then.
        final failure = progress.error;
        if (failure != null) {
          state = state.copyWith(
            status: UpdateStatus.error,
            error: 'Download failed: $failure',
          );
          return;
        }

        final downloaded = progress.bytesDownloaded.toInt();
        final total = progress.totalBytes.toInt();
        final ratio = total > 0 ? (downloaded / total).clamp(0.0, 1.0) : 0.0;

        state = state.copyWith(
          downloadProgress: ratio,
          bytesDownloaded: downloaded,
          totalBytes: total,
        );
      }

      if (state.status != UpdateStatus.downloading) return;

      state = state.copyWith(
        status: UpdateStatus.extracting,
        downloadedZipPath: destPath,
      );

      // appDir = the directory that CONTAINS the app unit.
      // Windows/Linux: the folder holding the executable.
      // macOS: the folder holding the `.app` bundle (e.g. /Applications).
      //   resolvedExecutable = .../Hollow.app/Contents/MacOS/Hollow
      //   → up 3 dirs = Hollow.app, up 4 = its containing folder.
      final String appDir;
      if (Platform.isMacOS) {
        appDir = File(Platform.resolvedExecutable) // .../MacOS/Hollow
            .parent // .../MacOS
            .parent // .../Contents
            .parent // .../Hollow.app
            .parent // containing folder (e.g. /Applications)
            .path;
      } else {
        appDir = File(Platform.resolvedExecutable).parent.path;
      }
      // The update script copies into appDir with its errors swallowed —
      // probe writability here so a read-only location (portable copy on a
      // locked USB stick, Program Files) fails visibly instead of silently.
      try {
        final probe =
            File('$appDir${Platform.pathSeparator}.hollow_write_probe');
        probe.writeAsStringSync('probe');
        probe.deleteSync();
      } catch (_) {
        state = state.copyWith(
          status: UpdateStatus.error,
          error: 'The app folder is not writable, so the update cannot be '
              'installed in place. Move the app to a writable location and '
              'try again.',
        );
        return;
      }
      final batPath = await updater_api.applyUpdate(
        zipPath: destPath,
        appDir: appDir,
        version: version.version,
      );

      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        batPath: batPath,
      );
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        error: 'Download failed: $e',
      );
    }
  }

  Future<void> installAndRestart() async {
    final scriptPath = state.batPath;
    if (scriptPath == null) return;

    if (Platform.isMacOS) {
      // Detached shell script: waits for us to quit, swaps the .app, relaunches.
      await Process.start('/bin/sh', [scriptPath],
          mode: ProcessStartMode.detached);
    } else {
      // Windows: detached batch script via cmd.
      await Process.start('cmd', ['/c', 'start', '', scriptPath],
          mode: ProcessStartMode.detached);
    }
    exit(0);
  }

  void cancelDownload() {
    state = state.copyWith(
      status: UpdateStatus.idle,
      selectedVersion: null,
      downloadProgress: 0.0,
      bytesDownloaded: 0,
      totalBytes: 0,
    );
  }
}

final updaterProvider =
    NotifierProvider<UpdateNotifier, UpdateState>(UpdateNotifier.new);

final hasUpdateProvider = Provider<bool>((ref) {
  final state = ref.watch(updaterProvider);
  if (state.manifest == null) return false;
  // Strictly newer only: a replayed older (still validly signed) manifest
  // must not read as an update. See version_compare.dart.
  return isNewerVersion(state.manifest!.latest, state.currentVersion);
});
