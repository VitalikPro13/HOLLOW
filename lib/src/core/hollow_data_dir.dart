import 'dart:io';

import 'package:path_provider/path_provider.dart';

String? _cached;
bool _portable = false;

/// True when the app is running in portable mode: a `portable.txt` marker (or
/// an already-created `hollow_data` folder) next to the executable moved the
/// data root to `<app folder>/hollow_data`.
bool get isPortableMode => _portable;

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
      portableDetectionNote = 'existing hollow_data folder → ${dataDir.path}';
      return dataDir.path;
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
    final portable = _portableDataRoot(forcePortable);
    if (portable != null) {
      final dir = Directory(portable);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _cached = portable;
      _portable = true;
    }
  }
}

/// Override the cached data dir (iOS: after migrating into the App Group
/// container so the app + Notification Service Extension share one SQLCipher DB).
/// Must be called after [initHollowDataDir] and before `setDataDir`/`start_node`.
void overrideHollowDataDir(String path) {
  _cached = path;
}
