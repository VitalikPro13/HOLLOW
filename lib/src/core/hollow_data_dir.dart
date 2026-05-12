import 'dart:io';

import 'package:path_provider/path_provider.dart';

String? _cached;

/// Returns the Hollow data directory path, consistent with Rust's data_dir().
/// On mobile: `getApplicationDocumentsDirectory()/hollow`
/// On desktop: `HOLLOW_DATA_DIR` env var → `APPDATA/Hollow` (Win) → `HOME/hollow` (Linux/Mac)
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

/// Must be called once at startup (after WidgetsFlutterBinding.ensureInitialized).
/// On mobile, resolves the async path_provider directory and caches it.
/// On desktop, this is a no-op (env vars are synchronous).
Future<void> initHollowDataDir() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final appDir = await getApplicationDocumentsDirectory();
    _cached = '${appDir.path}${Platform.pathSeparator}hollow';
    final dir = Directory(_cached!);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }
}
