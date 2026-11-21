import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:hollow/src/core/profile_registry.dart';
import 'package:path_provider/path_provider.dart';

String? _cached;
bool _portable = false;
bool _pinned = false;
bool _forcedPortable = false;
bool _portableByDetection = false;

/// True when the app is running in portable mode: a `portable.txt` marker (or
/// an already-created `hollow_data` folder) next to the executable moved the
/// data root to `<app folder>/hollow_data` — or a pinned profile points there.
bool get isPortableMode => _portable;

/// True when a profile pin from profiles.json chose the data root this launch
/// (Settings > Profile switcher, issue #47). Rust's data_dir() must be
/// overridden via setDataDir, like portable mode.
bool get isPinnedProfile => _pinned;

/// Returns the Hollow data directory path, consistent with Rust's data_dir():
/// mobile `getApplicationDocumentsDirectory()/hollow`; desktop portable root ->
/// `HOLLOW_DATA_DIR` -> `APPDATA/Hollow` (Win) -> `HOME/hollow`. Call
/// [initHollowDataDir] once at startup before using this synchronously.
String get hollowDataDir {
  if (_cached != null) return _cached!;
  final custom = Platform.environment['HOLLOW_DATA_DIR'];
  if (custom != null && custom.isNotEmpty) return custom;
  final appData = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      '.';
  return '$appData${Platform.pathSeparator}Hollow';
}

/// One-line record of what portable detection saw at boot, logged into
/// hollow_debug.log so a "why isn't portable working" report is diagnosable.
String portableDetectionNote = 'not run';

/// The `hollow_data` folder next to the executable (next to the .app bundle on
/// macOS), whether or not it exists yet. Null on mobile or if the executable
/// path can't be resolved. Also listed by the Settings profile switcher.
String? portableCandidatePath() {
  if (Platform.isAndroid || Platform.isIOS) return null;
  try {
    var appDir = File(Platform.resolvedExecutable).parent;
    if (Platform.isMacOS) {
      // The marker lives next to the .app bundle, not inside it.
      appDir = appDir.parent.parent.parent;
    }
    return '${appDir.path}${Platform.pathSeparator}hollow_data';
  } catch (_) {
    return null;
  }
}

/// Portable-mode detection. The data folder is `hollow_data`, NOT `data`: the
/// Flutter runner already ships a `data` folder next to the exe. Markers:
/// `portable.txt`, `portable.txt.txt` (Explorer's hidden-extensions trap),
/// bare `portable`, an existing `hollow_data`, or `--portable`. Env var wins.
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
      // The marker lives next to the .app bundle, not inside it.
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
      // an identity. A fresh/empty hollow_data next to the exe must NOT hijack
      // the default profile (issue #47); it shows as a row in Settings > Profile.
      if (portableFolderHoldsIdentity(dataDir.path)) {
        portableDetectionNote =
            'existing hollow_data folder with identity data → ${dataDir.path}';
        _portableByDetection = true;
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

/// Whether a `hollow_data` folder beside the exe holds an identity of its own.
/// A database alone is not one: releases 0.12.1 to 0.14.1 shipped a stray
/// `hollow_data/messages.db`, and counting it moved every updated copy off the
/// person's profile onto an empty one (#155).
bool portableFolderHoldsIdentity(String dir) {
  final sep = Platform.pathSeparator;
  return const ['identity.key', 'identity.device']
      .any((m) => File('$dir$sep$m').existsSync());
}

/// A file Windows releases 0.12.1 to 0.14.1 shipped in `<app>\hollow_data` (#155):
/// the build machine's database and lock, byte-identical in every one of them.
class ShippedStrayFile {
  final String name;
  final int size;
  final String sha256;

  const ShippedStrayFile(this.name, this.size, this.sha256);
}

/// Taken from the published hollow-0.14.1-win64.zip; 0.12.1 to 0.14.0 carry the same bytes.
const shippedStrayFiles = [
  ShippedStrayFile('messages.db', 475136,
      'c69bfe5028c930ad5e69fab0ae3977f45d269ea758437473707d728d0b0e7499'),
  ShippedStrayFile('hollow.lock', 5,
      '9614e2d3d87b46db466fc1ee4d7cbe57ee95a24458c311796db423364a54eff1'),
];

/// Removes from [dir] what the old releases shipped there: only files whose size
/// and SHA-256 match [shipped], only while the folder holds no `identity.*` file,
/// then the folder itself if that left it empty. A database that differs by one
/// byte is someone's and stays. Returns the names it removed. Never throws.
List<String> removeShippedStrayData(String dir,
    {List<ShippedStrayFile> shipped = shippedStrayFiles}) {
  final removed = <String>[];
  try {
    final folder = Directory(dir);
    if (!folder.existsSync()) return removed;
    final sep = Platform.pathSeparator;
    final names = folder
        .listSync(followLinks: false)
        .map((e) => e.path.substring(e.path.lastIndexOf(sep) + 1))
        .toList();
    if (names.any((n) => n.toLowerCase().startsWith('identity.'))) {
      return removed;
    }
    for (final f in shipped) {
      final file = File('$dir$sep${f.name}');
      try {
        if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            file.lengthSync() != f.size ||
            sha256.convert(file.readAsBytesSync()).toString() != f.sha256) {
          continue;
        }
        file.deleteSync();
        removed.add(f.name);
      } catch (_) {}
    }
    if (removed.isNotEmpty && folder.listSync(followLinks: false).isEmpty) {
      folder.deleteSync();
    }
  } catch (_) {}
  return removed;
}

/// The OS default profile, when it holds an identity and this launch went to the
/// folder beside the exe only because that folder holds one too (no flag, marker
/// or pin chose it). An update of 0.14.1 or older could move a copy there (#155).
String? defaultProfileLeftBehind() {
  if (!_portableByDetection) return null;
  final root = defaultDesktopDataRoot();
  if (sameProfilePath(root, hollowDataDir)) return null;
  return profileHasIdentity(root) ? root : null;
}

/// Must be called once at startup (after WidgetsFlutterBinding.ensureInitialized).
/// Mobile resolves the async path_provider directory and caches it; desktop
/// detects portable mode and pins the data root.
Future<void> initHollowDataDir({bool forcePortable = false}) async {
  if (Platform.isAndroid || Platform.isIOS) {
    final appDir = await getApplicationDocumentsDirectory();
    _cached = '${appDir.path}${Platform.pathSeparator}hollow';
    final dir = Directory(_cached!);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  } else {
    _forcedPortable = forcePortable;
    // Profile pin (issue #47) beats portable MARKER detection ON PURPOSE: an
    // installed copy with a hollow_data folder next to the exe must be able to
    // switch back to its OS-default profile. A pure stick has no profiles.json.
    // Ephemeral explicit overrides (env var, --portable) beat the stored pin.
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
          // Unreachable pin (unplugged drive): boot the normal profile instead of dying.
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

// Profile rows (issue #47): one list, two surfaces (Settings > Profile and the
// first-run welcome). They must agree on which profiles exist and which runs.

/// A profile as the UI lists it: the OS-default root, the portable
/// `hollow_data` folder next to the executable, then the user's own entries.
class ProfileRow {
  final String name;
  final String path;

  /// Default and Portable are derived from the environment, never stored, and
  /// so cannot be renamed or removed from the list.
  final bool builtin;

  /// The `hollow_data` folder next to the executable.
  final bool portable;

  const ProfileRow({
    required this.name,
    required this.path,
    required this.builtin,
    required this.portable,
  });
}

/// Every profile on this computer, deduplicated by path.
///
/// The portable row is listed whether or not the folder exists yet: an empty
/// `hollow_data` no longer auto-activates portable, so this row IS the way in.
List<ProfileRow> listProfileRows(ProfileRegistry registry) {
  final rows = <ProfileRow>[
    ProfileRow(
      name: 'Default',
      path: defaultDesktopDataRoot(),
      builtin: true,
      portable: false,
    ),
  ];
  final portable = portableCandidatePath();
  if (portable != null) {
    rows.add(ProfileRow(
      name: 'Portable folder',
      path: portable,
      builtin: true,
      portable: true,
    ));
  }
  for (final custom in registry.custom) {
    if (rows.any((r) => sameProfilePath(r.path, custom.path))) continue;
    rows.add(ProfileRow(
      name: custom.name,
      path: custom.path,
      builtin: false,
      portable: false,
    ));
  }
  return rows;
}

/// The data root this process is actually running on, environment override
/// included. What the ACTIVE badge marks, and what decides whether erasing a
/// profile takes the restart route or the direct-delete one.
String runningProfileRoot() {
  final env = Platform.environment['HOLLOW_DATA_DIR'];
  if (env != null && env.isNotEmpty) return env;
  if (isPinnedProfile || isPortableMode) return hollowDataDir;
  return defaultDesktopDataRoot();
}

/// True while `HOLLOW_DATA_DIR` is pointing the app somewhere: the pin in
/// profiles.json is still written, but it will not decide the next launch.
bool get dataDirEnvOverrideActive {
  final env = Platform.environment['HOLLOW_DATA_DIR'];
  return env != null && env.isNotEmpty;
}

/// True when a profile folder already holds an identity, as opposed to being
/// empty and waiting for first-time setup.
bool profileHasIdentity(String path) =>
    File('$path${Platform.pathSeparator}identity.key').existsSync();

/// The data root a launch would open now, by [initHollowDataDir]'s precedence.
String nextLaunchRoot() {
  final env = Platform.environment['HOLLOW_DATA_DIR'];
  if (env != null && env.isNotEmpty) return env;
  final portable = portableCandidatePath();
  if (_forcedPortable && portable != null) return portable;
  final pin = readProfileRegistrySync().activePath;
  if (pin != null) return pin;
  final bootNote = portableDetectionNote;
  final bootDetected = _portableByDetection;
  final detected = _portableDataRoot(false);
  portableDetectionNote = bootNote;
  _portableByDetection = bootDetected;
  return detected ?? defaultDesktopDataRoot();
}

/// True when a launch now would open a different profile than [root].
bool nextLaunchLeaves(String root) {
  if (Platform.isAndroid || Platform.isIOS) return false;
  return !sameProfilePath(nextLaunchRoot(), root);
}

/// Settles profiles.json after the profile at [wipedRoot] was wiped, by
/// [registryAfterWipe]. Phones have no profiles.
Future<void> forgetWipedProfile(String wipedRoot) async {
  if (Platform.isAndroid || Platform.isIOS) return;
  final registry = readProfileRegistrySync();
  final next = registryAfterWipe(
    registry,
    wipedRoot,
    runningRoot: runningProfileRoot(),
    profilePaths: listProfileRows(registry).map((r) => r.path),
    holdsIdentity: profileHasIdentity,
  );
  await saveProfileRegistryIfChanged(registry, next);
}
