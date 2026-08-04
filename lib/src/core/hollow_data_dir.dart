import 'dart:io';

import 'package:hollow/src/core/profile_registry.dart';
import 'package:path_provider/path_provider.dart';

String? _cached;
bool _portable = false;
bool _pinned = false;

/// True when the app is running in portable mode: a `portable.txt` marker (or
/// an already-created `hollow_data` folder) next to the executable moved the
/// data root to `<app folder>/hollow_data` — or a pinned profile points there.
bool get isPortableMode => _portable;

/// True when a profile pin from profiles.json chose the data root this launch
/// (Settings > Profile switcher, issue #47). Rust's data_dir() must be
/// overridden via setDataDir, like portable mode.
bool get isPinnedProfile => _pinned;

/// Returns the Hollow data directory path, consistent with Rust's data_dir().
/// On mobile: `getApplicationDocumentsDirectory()/hollow`
/// On desktop: portable root → `HOLLOW_DATA_DIR` env var → `APPDATA/Hollow`
/// (Win) → `HOME/hollow` (Linux/Mac)
///
/// Call [initHollowDataDir] once at startup before using this synchronously.
String get hollowDataDir {
  if (_cached != null) return _cached!;
  final custom = Platform.environment['HOLLOW_DATA_DIR'];
  if (custom != null && custom.isNotEmpty) return custom;
  final appData = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$appData${Platform.pathSeparator}Hollow';
}

/// One-line record of what portable detection saw at boot — logged into
/// hollow_debug.log once Rust is up, so a "why isn't portable working"
/// report is diagnosable from the log alone.
String portableDetectionNote = 'not run';

/// The `hollow_data` folder next to the executable (next to the .app bundle on
/// macOS) — the portable-mode data root, whether or not it exists yet. Null on
/// mobile or if the executable path can't be resolved. Also used by the
/// Settings > Profile switcher to list/pin the portable folder as a profile.
String? portableCandidatePath() {
  if (Platform.isAndroid || Platform.isIOS) return null;
  try {
    var appDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      // resolvedExecutable = <Bundle>.app/Contents/MacOS/hollow — the marker
      // lives next to the .app bundle, not inside it.
      appDir = appDir.parent.parent.parent;
    }
    return '${appDir.path}${Platform.pathSeparator}hollow_data';
  } catch (_) {
    return null;
  }
}

/// Portable-mode detection. The data folder is `hollow_data` (NOT `data` —
/// the Flutter runner already ships a `data\` folder next to the exe).
/// Accepted markers: `portable.txt`, `portable.txt.txt` (Explorer's
/// hidden-extensions trap), bare `portable`, an existing `hollow_data`
/// folder, or a `--portable` launch argument.
/// The env var wins over portable so a stick user can still redirect.
String? _portableDataRoot(bool forced) {
  if (Platform.isAndroid || Platform.isIOS) return null;
  final env = Platform.environment['HOLLOW_DATA_DIR'];
  if (env != null && env.isNotEmpty) {
    portableDetectionNote = 'HOLLOW_DATA_DIR env override active ($env) — portable ignored';
    return null;
  }
  try {
    var appDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      // resolvedExecutable = <Bundle>.app/Contents/MacOS/hollow — the marker
      // lives next to the .app bundle, not inside it.
      appDir = appDir.parent.parent.parent;
    }
    final sep = Platform.pathSeparator;
    final dataDir = Directory('${appDir.path}${sep}hollow_data');
    if (forced) {
      portableDetectionNote = 'forced via --portable → ${dataDir.path}';
      return dataDir.path;
    }
    const markerNames = ['portable.txt', 'portable.txt.txt', 'portable'];
    for (final name in markerNames) {
      if (File('${appDir.path}$sep$name').existsSync()) {
        portableDetectionNote = 'marker $name found in ${appDir.path} → ${dataDir.path}';
        return dataDir.path;
      }
    }
    if (dataDir.existsSync()) {
      // A bare folder only auto-activates portable when it actually CONTAINS
      // identity data (existing portable installs, the copy-your-AppData
      // migration path). A fresh/empty hollow_data folder next to the exe
      // must NOT hijack the default profile (issue #47) — it shows up as the
      // "Portable folder" row in Settings > Profile instead, and switching
      // there pins it explicitly.
      const identityMarkers = ['identity.key', 'identity.device', 'messages.db'];
      final hasData = identityMarkers
          .any((m) => File('${dataDir.path}$sep$m').existsSync());
      if (hasData) {
        portableDetectionNote =
            'existing hollow_data folder with identity data → ${dataDir.path}';
        return dataDir.path;
      }
      portableDetectionNote =
          'hollow_data folder in ${appDir.path} is empty — not auto-activating '
          '(switch to it in Settings > Profile)';
      return null;
    }
    portableDetectionNote =
        'no marker (portable.txt / hollow_data) in ${appDir.path} — normal install';
  } catch (e) {
    portableDetectionNote = 'detection failed: $e — normal install';
  }
  return null;
}

/// Must be called once at startup (after WidgetsFlutterBinding.ensureInitialized).
/// On mobile, resolves the async path_provider directory and caches it.
/// On desktop, detects portable mode (marker file / hollow_data folder next to
/// the executable, or a `--portable` launch argument) and pins the data root.
Future<void> initHollowDataDir({bool forcePortable = false}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final appDir = await getApplicationDocumentsDirectory();
    _cached = '${appDir.path}${Platform.pathSeparator}hollow';
    final dir = Directory(_cached!);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } else {
    // Profile pin (Settings > Profile switcher, issue #47) — beats portable
    // MARKER detection ON PURPOSE: an installed copy with a hollow_data folder
    // next to the exe (implicit portable) must be able to switch back to its
    // OS-default profile. A pure stick on a foreign machine has no
    // profiles.json, so portable detection still wins there. Ephemeral
    // explicit overrides beat the stored pin: the env var (same guard as
    // portable's) and the --portable launch arg.
    var pinFailureNote = '';
    final env = Platform.environment['HOLLOW_DATA_DIR'];
    if (!forcePortable && (env == null || env.isEmpty)) {
      final pinnedRoot = readProfileRegistrySync().activePath;
      if (pinnedRoot != null) {
        try {
          final dir = Directory(pinnedRoot);
          if (!dir.existsSync()) dir.createSync(recursive: true);
          _cached = pinnedRoot;
          _pinned = true;
          // A pin onto the app-folder hollow_data IS portable mode — the
          // lock location, updater messaging, and Security warning key off it.
          final candidate = portableCandidatePath();
          _portable =
              candidate != null && sameProfilePath(pinnedRoot, candidate);
          portableDetectionNote = 'profile pin active → $pinnedRoot'
              '${_portable ? ' (== portable folder)' : ''}';
          return;
        } catch (e) {
          // Unreachable pin (unplugged drive, revoked permissions) — boot the
          // normal profile instead of dying; the note lands in the log.
          pinFailureNote = 'profile pin $pinnedRoot unreachable ($e) — ';
        }
      }
    }
    final portable = _portableDataRoot(forcePortable);
    if (portable != null) {
      final dir = Directory(portable);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _cached = portable;
      _portable = true;
    }
    portableDetectionNote = '$pinFailureNote$portableDetectionNote';
  }
}

/// Override the cached data dir (iOS: after migrating into the App Group
/// container so the app + Notification Service Extension share one SQLCipher DB).
/// Must be called after [initHollowDataDir] and before `setDataDir`/`start_node`.
void overrideHollowDataDir(String path) {
  _cached = path;
}
