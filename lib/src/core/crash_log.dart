import 'dart:io';

/// `hollow_crash.log`: Flutter framework, platform and async errors, beside
/// `hollow_debug.log` in the data root. Written synchronously, so a line is on
/// disk before the error that caused it can take the process down.
class CrashLog {
  CrashLog._();

  static RandomAccessFile? _file;
  static String? _dir;
  static bool _erased = false;

  static const _name = 'hollow_crash.log';

  /// Opens the log for this launch. A wipe that has not finished yet means the
  /// lines already there belong to an identity that is gone, so they go first.
  static void init(String dataDir) {
    _dir = dataDir;
    _erased = false;
    final dir = Directory(dataDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final sep = Platform.pathSeparator;
    if (File('$dataDir${sep}pending_wipe.marker').existsSync()) {
      _deleteFiles(dataDir);
    }

    final logFile = File('$dataDir$sep$_name');
    if (logFile.existsSync() && logFile.lengthSync() > 5 * 1024 * 1024) {
      final backup = File('${logFile.path}.old');
      if (backup.existsSync()) backup.deleteSync();
      logFile.renameSync(backup.path);
    }

    _file = logFile.openSync(mode: FileMode.append);
    _write('\n=== Hollow started at ${DateTime.now().toIso8601String()} ===\n');
  }

  static void record(String kind, Object error, Object? stack) {
    if (_erased) return;
    _write('[${DateTime.now().toIso8601String()}] [$kind] $error\n'
        '${stack ?? ''}\n');
  }

  static void _write(String text) {
    try {
      _file
        ?..writeStringSync(text)
        ..flushSync();
    } catch (_) {}
  }

  /// The wipe's step: the log and its rotated copy go, and nothing more is
  /// written this launch. The file is closed first, since Windows refuses to
  /// delete a file this process still holds open.
  static Future<void> erase() async {
    _erased = true;
    final file = _file;
    _file = null;
    try {
      file?.closeSync();
    } catch (_) {}
    final dir = _dir;
    if (dir != null) _deleteFiles(dir);
  }

  static void _deleteFiles(String dataDir) {
    final sep = Platform.pathSeparator;
    for (final name in [_name, '$_name.old']) {
      try {
        final f = File('$dataDir$sep$name');
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }
}
