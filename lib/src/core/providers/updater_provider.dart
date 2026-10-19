import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/version_compare.dart';
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

const kManifestUrl = 'https://anonlisten.com/hollow/releases/manifest.json';

/// `flatpak` or `tarball` on Linux, from the one detector in Rust; empty
/// elsewhere. Read once, since the progress card rebuilds every frame.
String get linuxInstallKind => linuxInstallKindOverride ?? _linuxInstallKind;
final String _linuxInstallKind =
    Platform.isLinux ? updater_api.linuxInstallKind() : '';

/// Tests set this: the Rust bridge is never initialised in a widget test.
@visibleForTesting
String? linuxInstallKindOverride;

/// True inside a Flatpak sandbox (Linux only).
bool get isFlatpakInstall => linuxInstallKind == 'flatpak';

/// `Platform.operatingSystem`, which tests replace to pick another platform's
/// downloads.
String get updaterPlatform => updaterPlatformOverride ?? Platform.operatingSystem;

@visibleForTesting
String? updaterPlatformOverride;

/// The highest `build` an entry may carry (`MAX_BUILD` in updater.rs).
const _kMaxBuild = 9999;

class VersionInfo {
  final String version;

  /// The quick-patch number on top of [version] (`0.12.2+1`); 0 when absent.
  /// Apps up to 0.12.1 ignore it.
  final int build;

  /// False when `build` or `critical` is malformed: that entry alone is never
  /// offered, so neither field becomes a wire limit (Rust `readable_build`).
  final bool readable;

  /// Makes the prompt louder: the release fixes something people should not
  /// wait on.
  final bool critical;
  final String date;
  final String urlWindows;
  final String urlMacos;

  /// The Flatpak bundle (`url_linux`) and the portable tarball
  /// (`url_linux_targz`): a Linux install downloads only the one matching its kind.
  final String urlLinux;
  final String urlLinuxTargz;

  /// SHA-256 (hex) of each platform's download, written into the signed manifest
  /// by `hollow-manifest fill-hashes`. Rust refuses to apply bytes that don't
  /// hash to this, so an entry without one cannot be installed by the updater.
  final String sha256Windows;
  final String sha256Macos;
  final String sha256Linux;
  final String sha256LinuxTargz;
  final String notes;

  const VersionInfo({
    required this.version,
    this.build = 0,
    this.readable = true,
    this.critical = false,
    required this.date,
    this.urlWindows = '',
    this.urlMacos = '',
    this.urlLinux = '',
    this.urlLinuxTargz = '',
    this.sha256Windows = '',
    this.sha256Macos = '',
    this.sha256Linux = '',
    this.sha256LinuxTargz = '',
    required this.notes,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) {
    final rawBuild = json['build'];
    final build = rawBuild is int ? rawBuild : 0;
    final buildOk = !json.containsKey('build') ||
        (rawBuild is int && rawBuild >= 0 && rawBuild <= _kMaxBuild);
    final criticalOk =
        !json.containsKey('critical') || json['critical'] is bool;
    String str(String key) => json[key] is String ? json[key] as String : '';
    return VersionInfo(
      version: str('version'),
      build: build,
      readable: buildOk && criticalOk,
      critical: json['critical'] == true,
      date: str('date'),
      urlWindows: str('url_windows'),
      urlMacos: str('url_macos'),
      urlLinux: str('url_linux'),
      urlLinuxTargz: str('url_linux_targz'),
      sha256Windows: str('sha256_windows'),
      sha256Macos: str('sha256_macos'),
      sha256Linux: str('sha256_linux'),
      sha256LinuxTargz: str('sha256_linux_targz'),
      notes: str('notes'),
    );
  }

  /// Null for an entry this build cannot read; such an entry is never offered.
  ReleaseId? get id => readable ? ReleaseId.of(version, build) : null;

  /// `0.12.2` or `0.12.2+1`.
  String get display => id?.display ?? version;

  /// The download URL for the current platform and install kind (empty if
  /// unsupported, phones included: they update through their stores).
  String get platformUrl => switch (updaterPlatform) {
        'macos' => urlMacos,
        'linux' => isFlatpakInstall ? urlLinux : urlLinuxTargz,
        'windows' => urlWindows,
        _ => '',
      };

  /// The expected SHA-256 of [platformUrl] (empty when the manifest entry
  /// carries none, which the updater treats as "not installable").
  String get platformSha256 => switch (updaterPlatform) {
        'macos' => sha256Macos,
        'linux' => isFlatpakInstall ? sha256Linux : sha256LinuxTargz,
        'windows' => sha256Windows,
        _ => '',
      };

  /// File name the download lands under: the tool that applies it cares
  /// about the extension (`flatpak install`, `tar`, the zip extractor).
  String get downloadFileName {
    final tag = id?.tag ?? version;
    if (updaterPlatform == 'linux') {
      return isFlatpakInstall ? '$tag.flatpak' : '$tag.tar.gz';
    }
    return '$tag.zip';
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
        versions: [
          if (json['versions'] case final List<dynamic> list)
            for (final v in list)
              if (v is Map<String, dynamic>) VersionInfo.fromJson(v)
        ],
      );

  /// The entries this install could download, newest first. An entry with no
  /// URL for this platform and install kind is a release for someone else.
  List<VersionInfo> get installable {
    final out = [
      for (final v in versions)
        if (v.id != null && v.hasPlatformUrl) v
    ];
    out.sort((a, b) => b.id!.compareTo(a.id!));
    return out;
  }

  /// The newest installable entry strictly newer than [running], or null.
  /// Strictly newer only: a replayed older, still validly signed manifest must
  /// not read as an update.
  VersionInfo? updateFor(ReleaseId running) {
    for (final v in installable) {
      if (v.id!.isNewerThan(running)) return v;
    }
    return null;
  }

  /// Whether any installable entry newer than [running] is marked critical:
  /// installing the newest one carries that fix too.
  bool criticalFor(ReleaseId running) =>
      installable.any((v) => v.critical && v.id!.isNewerThan(running));
}

enum UpdateStatus { idle, checking, downloading, extracting, readyToInstall, error }

/// Which step an [UpdateStatus.error] belongs to: the check, or getting a
/// release onto disk and started.
enum UpdateFailure { check, install }

class UpdateState {
  final UpdateStatus status;
  final VersionManifest? manifest;
  final String? selectedVersion;
  final double downloadProgress;
  final int bytesDownloaded;
  final int totalBytes;
  final String? downloadedZipPath;
  final String? batPath;
  /// A sentence for a person, never the raw exception.
  final String? error;
  final UpdateFailure? failure;
  final String currentVersion;

  /// The quick-patch number of the running build ([currentVersion]`+N`).
  final int currentBuild;

  /// When a manifest last arrived, manual or background; a failed check
  /// leaves it alone.
  final DateTime? lastChecked;

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
    this.failure,
    this.currentVersion = '',
    this.currentBuild = 0,
    this.lastChecked,
  });

  /// The running build as the updater orders it.
  ReleaseId get running =>
      ReleaseId.of(currentVersion, currentBuild) ?? ReleaseId.of('0')!;

  /// `0.12.2`, or `0.12.2+1` on a patch build.
  String get currentDisplay =>
      ReleaseId.of(currentVersion, currentBuild)?.display ?? currentVersion;

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
    UpdateFailure? failure,
    String? currentVersion,
    DateTime? lastChecked,
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
        failure: failure ?? this.failure,
        currentVersion: currentVersion ?? this.currentVersion,
        currentBuild: currentBuild,
        lastChecked: lastChecked ?? this.lastChecked,
      );
}

class UpdateNotifier extends Notifier<UpdateState> {
  /// Its own clock: a session left open for days must still see a release.
  static const recheckEvery = Duration(hours: 2);

  Timer? _recheck;

  @override
  UpdateState build() {
    ref.onDispose(() => _recheck?.cancel());
    _armRecheck();
    final running = ref.read(runningReleaseProvider);
    return UpdateState(
        currentVersion: running.version, currentBuild: running.build);
  }

  /// Desktop only: phones update through their stores.
  void _armRecheck() {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    _recheck?.cancel();
    _recheck = Timer(recheckEvery, () => checkForUpdates(background: true));
  }

  /// A [background] check shows no progress and no failure: an hour offline
  /// should not paint Settings red.
  Future<void> checkForUpdates({bool background = false}) async {
    _armRecheck();
    if (state.status == UpdateStatus.downloading ||
        state.status == UpdateStatus.extracting ||
        state.status == UpdateStatus.readyToInstall) {
      return;
    }
    if (!background) {
      state = state.copyWith(status: UpdateStatus.checking, error: null);
    }
    try {
      final bustCache = DateTime.now().millisecondsSinceEpoch;
      final json = await updater_api.fetchVersionManifest(
          manifestUrl: '$kManifestUrl?t=$bustCache');
      final manifest =
          VersionManifest.fromJson(jsonDecode(json) as Map<String, dynamic>);
      // A background result lands under whatever the user started meanwhile.
      final settled = !background ||
          state.status == UpdateStatus.idle ||
          state.status == UpdateStatus.error;
      state = state.copyWith(
          status: settled ? UpdateStatus.idle : null,
          manifest: manifest,
          lastChecked: DateTime.now());
    } catch (e) {
      if (background) return;
      state = state.copyWith(
          status: UpdateStatus.error,
          failure: UpdateFailure.check,
          error: friendlyError(e,
              fallback: "Couldn't reach the update server. Try again."));
    }
  }

  Future<void> downloadVersion(VersionInfo version) async {
    final dataDir = hollowDataDir;
    final sep = Platform.pathSeparator;
    final destPath = '$dataDir${sep}updates$sep${version.downloadFileName}';

    // Fail closed before a single byte moves: a manifest entry with no
    // checksum for this platform is not something the updater installs.
    if (version.platformSha256.isEmpty) {
      state = state.copyWith(
        status: UpdateStatus.error,
        failure: UpdateFailure.install,
        error: 'This release carries no checksum for your platform, so the '
            'updater will not install it. Download it from the website '
            'instead.',
      );
      return;
    }

    state = state.copyWith(
      status: UpdateStatus.downloading,
      selectedVersion: version.display,
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

        // Rust reports a failed or refused download (checksum mismatch, bad URL,
        // transport error) as a final item carrying the reason.
        final failure = progress.error;
        if (failure != null) {
          state = state.copyWith(
            status: UpdateStatus.error,
            failure: UpdateFailure.install,
            error: friendlyError(failure,
                fallback: "The download didn't finish. Try again."),
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

      // appDir = the directory that CONTAINS the app unit: the executable's folder
      // on Windows/Linux, the folder holding the `.app` bundle on macOS (so
      // resolvedExecutable goes up 3 dirs to the bundle, 4 to its container).
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
      // The update script copies into appDir with its errors swallowed, so probe
      // writability here: a read-only location must fail visibly. A flatpak never
      // writes to its own /app, so there is nothing to probe there.
      final flatpak = Platform.isLinux && isFlatpakInstall;
      if (!flatpak && !_dirWritable(appDir)) {
        state = state.copyWith(
          status: UpdateStatus.error,
          failure: UpdateFailure.install,
          error: 'The app folder is not writable, so the update cannot be '
              'installed in place. Move the app to a writable location and '
              'try again.',
        );
        return;
      }
      // The Linux tarball update renames the whole bundle folder aside, which needs
      // the PARENT folder too: a root-owned /opt extract must fail loudly here.
      if (Platform.isLinux &&
          !flatpak &&
          !_dirWritable(Directory(appDir).parent.path)) {
        state = state.copyWith(
          status: UpdateStatus.error,
          failure: UpdateFailure.install,
          error: 'The folder that contains Hollow is not writable, so the '
              'update cannot swap the app in place. Move Hollow to a folder '
              'you own and try again.',
        );
        return;
      }
      final batPath = await updater_api.applyUpdate(
        zipPath: destPath,
        appDir: appDir,
        version: version.version,
        build: version.build,
      );

      state = state.copyWith(
        status: UpdateStatus.readyToInstall,
        batPath: batPath,
      );
    } catch (e) {
      state = state.copyWith(
        status: UpdateStatus.error,
        failure: UpdateFailure.install,
        error: friendlyError(e,
            fallback: "The download didn't finish. Try again."),
      );
    }
  }

  /// Whether we can create and delete a file inside [dir].
  static bool _dirWritable(String dir) {
    try {
      final probe = File('$dir${Platform.pathSeparator}.hollow_write_probe');
      probe.writeAsStringSync('probe');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> installAndRestart() async {
    final scriptPath = state.batPath;
    if (scriptPath == null) return;

    if (Platform.isLinux) {
      // Rust starts the script so it outlives this process: a detached session for
      // the tarball swap, the HOST via flatpak-spawn for a flatpak relaunch.
      try {
        await updater_api.launchUpdateScript(scriptPath: scriptPath);
      } catch (e) {
        final flatpak = isFlatpakInstall;
        state = state.copyWith(
          status: UpdateStatus.error,
          failure: UpdateFailure.install,
          error: flatpak
              ? "The update is installed, but Hollow couldn't restart itself. "
                  'Close and reopen Hollow to finish.'
              : friendlyError(e,
                  fallback: "Hollow couldn't start the update. Try again."),
        );
        return;
      }
    } else if (Platform.isMacOS) {
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

/// Fetches a signed release feed (`status`, `news`) by URL and feed name; any
/// failure, a missing or bad signature included, throws. Tests replace it.
typedef SignedFeedFetch = Future<String> Function(String url, String feed);

final signedFeedFetchProvider = Provider<SignedFeedFetch>(
    (ref) => (url, feed) => updater_api.fetchSignedFeed(url: url, feed: feed));

/// The running build, from Rust's `APP_VERSION` + `APP_BUILD`. Tests override it:
/// the Rust bridge is never initialised in a widget test.
final runningReleaseProvider = Provider<ReleaseId>((ref) =>
    ReleaseId.of(updater_api.getCurrentVersion(),
        updater_api.getCurrentBuild()) ??
    ReleaseId.of('0')!);

/// The release this install should move to: the newest entry with a download
/// for this platform that is newer than the running build. `latest` is for
/// apps up to 0.12.1 and the website, never consulted here.
final updateCandidateProvider = Provider<VersionInfo?>((ref) {
  final state = ref.watch(updaterProvider);
  return state.manifest?.updateFor(state.running);
});

final hasUpdateProvider =
    Provider<bool>((ref) => ref.watch(updateCandidateProvider) != null);

/// Whether the waiting update is marked critical, which makes its prompt louder.
final criticalUpdateProvider = Provider<bool>((ref) {
  final state = ref.watch(updaterProvider);
  return state.manifest?.criticalFor(state.running) ?? false;
});
