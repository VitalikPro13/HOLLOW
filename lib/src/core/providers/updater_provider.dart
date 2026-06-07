import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

const kManifestUrl = 'https://anonlisten.com/hollow/releases/manifest.json';

class VersionInfo {
  final String version;
  final String date;
  final String urlWindows;
  final String urlMacos;
  final String urlLinux;
  final String notes;

  const VersionInfo({
    required this.version,
    required this.date,
    this.urlWindows = '',
    this.urlMacos = '',
    this.urlLinux = '',
    required this.notes,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) => VersionInfo(
        version: json['version'] as String? ?? '',
        date: json['date'] as String? ?? '',
        urlWindows: json['url_windows'] as String? ?? '',
        urlMacos: json['url_macos'] as String? ?? '',
        urlLinux: json['url_linux'] as String? ?? '',
        notes: json['notes'] as String? ?? '',
      );

  /// The download URL for the current platform (empty if unsupported).
  String get platformUrl {
    if (Platform.isMacOS) return urlMacos;
    if (Platform.isLinux) return urlLinux;
    return urlWindows; // Windows
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
      );

      await for (final progress in stream) {
        if (state.status != UpdateStatus.downloading) break;

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
  return state.manifest!.latest != state.currentVersion;
});
