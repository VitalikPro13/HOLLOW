import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Free bytes on the volume that holds [path] (the data root, which a profile
/// or portable mode may put on any drive), or null where it cannot be read
/// (iOS, which gives an app no `df`).
Future<int?> freeBytesAt(String path) async {
  try {
    final dir = _existingAncestor(path);
    if (Platform.isWindows) return _windowsFreeBytes(dir);
    if (Platform.isLinux || Platform.isMacOS || Platform.isAndroid) {
      // -P keeps the POSIX layout on both GNU and BSD df: one line per
      // filesystem, 1024-byte blocks, never wrapped.
      final result = await Process.run('df', ['-Pk', dir]);
      if (result.exitCode != 0) return null;
      return parseDfAvailableBytes(result.stdout.toString());
    }
  } catch (_) {}
  return null;
}

/// The "Available" column of `df -Pk` output, in bytes. Read from the
/// capacity column leftwards, because a filesystem name or a mount point can
/// hold spaces.
int? parseDfAvailableBytes(String stdout) {
  final lines = stdout
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
  if (lines.length < 2) return null;
  final fields = lines[1].split(RegExp(r'\s+'));
  final capacity = fields.indexWhere((f) => RegExp(r'^\d+%$').hasMatch(f));
  if (capacity < 1) return null;
  final kib = int.tryParse(fields[capacity - 1]);
  return kib == null ? null : kib * 1024;
}

/// The data root may not exist yet on a first run; the volume it will live on
/// does.
String _existingAncestor(String path) {
  var dir = path;
  while (!Directory(dir).existsSync()) {
    final parent = Directory(dir).parent.path;
    if (parent == dir) break;
    dir = parent;
  }
  return dir;
}

typedef _GetDiskFreeSpaceExNative = Int32 Function(
    Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _GetDiskFreeSpaceExDart = int Function(
    Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);

/// GetDiskFreeSpaceExW takes any directory on the volume, drive letter or
/// UNC share alike. The first value is what this user may use (quotas
/// included), which is the honest "free" for Hollow.
int? _windowsFreeBytes(String dir) {
  final fn = DynamicLibrary.open('kernel32.dll').lookupFunction<
      _GetDiskFreeSpaceExNative,
      _GetDiskFreeSpaceExDart>('GetDiskFreeSpaceExW');
  final native = dir.toNativeUtf16();
  final available = calloc<Uint64>();
  try {
    final ok = fn(native, available, nullptr, nullptr);
    return ok == 0 ? null : available.value;
  } finally {
    calloc.free(native);
    calloc.free(available);
  }
}
