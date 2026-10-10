/// One cargo target shared by every source tree (Hollow worktrees) for DEBUG
/// builds, opt-in through [sharedDirEnvVar].
///
/// Cargo judges a path crate fresh by comparing source mtimes with dep-info
/// stored relative to the package, so a shared target would happily link an
/// older tree to a newer tree's code. Every build here is therefore keyed by
/// content: a key cargo did not build last resets the path crates'
/// fingerprints first, and a key already built is served from an immutable
/// cache without running cargo at all.
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:toml/toml.dart';

import 'artifacts_provider.dart';
import 'builder.dart';
import 'target.dart';
import 'util.dart';

final _log = Logger('shared_build');

const sharedDirEnvVar = 'HOLLOW_CARGOKIT_SHARED_DIR';
const sharedKeepEnvVar = 'HOLLOW_CARGOKIT_SHARED_KEEP';

/// MSBuild sets it to the project being built, so every tree has its own
/// value. The `cc` crate reads only whether it is set, yet registers it as a
/// build-script input: unchanged, each switch of trees rebuilds every C
/// dependency (SQLCipher, ring, aws-lc, libwebp) and what links them.
const msbuildProjectEnvVar = 'VSTEL_MSBuildProjectFullPath';

class SharedBuildOptions {
  SharedBuildOptions({required this.root, this.keep = 3});

  final String root;

  /// How many built DLL sets the cache keeps (each ~0.8 GB with its PDB).
  final int keep;

  String get targetDir => path.join(root, 'target');
  String get cacheDir => path.join(root, 'dll');
  String get stateDir => path.join(root, 'state');
  String get lockPath => path.join(root, 'build.lock');

  /// Null unless this is a debug build and the variable names a directory:
  /// release and profile builds always compile in their own tree.
  static SharedBuildOptions? from({
    required BuildConfiguration configuration,
    required Map<String, String> env,
  }) {
    if (configuration != BuildConfiguration.debug) return null;
    final raw = (env[sharedDirEnvVar] ?? '').trim();
    if (raw.isEmpty || raw == '0' || raw.toLowerCase() == 'off') return null;
    final keep = int.tryParse(env[sharedKeepEnvVar] ?? '') ?? 3;
    return SharedBuildOptions(
        root: path.normalize(path.absolute(raw)), keep: keep < 1 ? 1 : keep);
  }
}

/// A tree whose path crates cannot all be found; it builds on its own.
class SharedBuildUnsupported implements Exception {
  SharedBuildUnsupported(this.message);
  final String message;
  @override
  String toString() => 'SharedBuildUnsupported: $message';
}

class PathPackage {
  PathPackage(this.name, this.dir);
  final String name;
  final String dir;
}

Map<String, dynamic> _readToml(String file) =>
    TomlDocument.parse(File(file).readAsStringSync()).toMap();

/// The root crate and every crate it reaches by `path`, checked against the
/// lock file: a path package the lock names but the walk misses refuses.
List<PathPackage> discoverPathPackages(String manifestDir) {
  final found = <String, PathPackage>{};

  Iterable<Map> depTables(Map<String, dynamic> doc) sync* {
    for (final k in ['dependencies', 'build-dependencies', 'dev-dependencies']) {
      if (doc[k] is Map) yield doc[k] as Map;
    }
    if (doc['target'] is Map) {
      for (final t in (doc['target'] as Map).values) {
        if (t is! Map) continue;
        for (final k in ['dependencies', 'build-dependencies', 'dev-dependencies']) {
          if (t[k] is Map) yield t[k] as Map;
        }
      }
    }
    if (doc['patch'] is Map) {
      for (final p in (doc['patch'] as Map).values) {
        if (p is Map) yield p;
      }
    }
    if (doc['replace'] is Map) yield doc['replace'] as Map;
  }

  void visit(String dir) {
    final canonical = path.canonicalize(dir);
    if (found.containsKey(canonical)) return;
    final manifest = path.join(dir, 'Cargo.toml');
    if (!File(manifest).existsSync()) {
      throw SharedBuildUnsupported('no Cargo.toml in $dir');
    }
    final doc = _readToml(manifest);
    final name = (doc['package'] is Map) ? doc['package']['name'] : null;
    if (name is! String) throw SharedBuildUnsupported('no package name in $manifest');
    found[canonical] = PathPackage(name, path.normalize(dir));
    for (final table in depTables(doc)) {
      for (final spec in table.values) {
        if (spec is Map && spec['path'] is String) {
          visit(path.join(dir, spec['path'] as String));
        }
      }
    }
  }

  visit(manifestDir);
  final lock = File(path.join(manifestDir, 'Cargo.lock'));
  if (!lock.existsSync()) throw SharedBuildUnsupported('no Cargo.lock');
  final packages = _readToml(lock.path)['package'];
  final names = found.values.map((p) => p.name).toSet();
  if (packages is List) {
    for (final p in packages) {
      if (p is Map && p['source'] == null && !names.contains(p['name'])) {
        throw SharedBuildUnsupported(
            'Cargo.lock names path package ${p['name']} the manifests never reach');
      }
    }
  }
  return found.values.sortedBy((p) => p.name);
}

class BuildKeyInputs {
  BuildKeyInputs({
    required this.packages,
    required this.rustTarget,
    required this.configuration,
    required this.cargoArgs,
    required this.toolchain,
    required this.rustcVersion,
    required this.env,
    required this.configSearchDir,
    required this.cargoHome,
  });

  final List<PathPackage> packages;
  final String rustTarget;
  final String configuration;
  final List<String> cargoArgs;
  final String toolchain;
  final String rustcVersion;
  final Map<String, String> env;

  /// Cargo's working directory: it reads `.cargo/config*` from here upwards.
  final String configSearchDir;
  final String? cargoHome;
}

// Variables a build script, the C compilers or cargo itself read. Per-tree
// paths (CARGOKIT_*, TEMP) stay out, or no two trees would ever share a key.
final _keyEnv = RegExp(
    r'^(RUST.*|CARGO_(BUILD|PROFILE|TARGET|ENCODED|INCREMENTAL|UNSTABLE|HOME|NET|REGISTRIES).*'
    r'|.*OPENSSL.*|SQLCIPHER.*|LIBSQLITE3.*|AWS_LC.*|CMAKE.*|NASM.*|PKG_CONFIG.*'
    r'|(.*_)?(CC|CXX|AR|RANLIB|LINKER|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|RUSTFLAGS)(_.*)?'
    r'|ANDROID_NDK.*|NDK_.*|VCTOOLS.*|VCINSTALLDIR|WINDOWSSDK.*|UCRTVERSION'
    r'|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|SDKROOT|DEVELOPER_DIR)$');

bool _isKeyEnv(String name) {
  final upper = name.toUpperCase();
  if (upper.startsWith('CARGOKIT_')) return false;
  return _keyEnv.hasMatch(upper);
}

/// A content key over every input of the built library: path crates' files
/// (raw bytes, so line endings count), the lock and manifests, cargo configs,
/// the toolchain, target, configuration, flags and build variables. Paths and
/// mtimes never count, so identical trees share a key.
String computeBuildKey(BuildKeyInputs inputs) {
  final output = AccumulatorSink<Digest>();
  final sink = sha256.startChunkedConversion(output);
  void field(String tag, String value) {
    final bytes = utf8.encode(value);
    sink.add(utf8.encode('$tag:${bytes.length}:'));
    sink.add(bytes);
  }

  void fileBytes(String tag, File file) {
    final bytes = file.readAsBytesSync();
    sink.add(utf8.encode('$tag:${bytes.length}:'));
    sink.add(bytes);
  }

  field('v', 'hollow-shared-build-1');
  field('target', inputs.rustTarget);
  field('configuration', inputs.configuration);
  field('toolchain', inputs.toolchain);
  field('rustc', inputs.rustcVersion);
  for (final a in inputs.cargoArgs) {
    field('arg', a);
  }
  final envNames = inputs.env.keys.where(_isKeyEnv).toList()
    ..sort((a, b) => a.toUpperCase().compareTo(b.toUpperCase()));
  for (final name in envNames) {
    field('env', '${name.toUpperCase()}=${inputs.env[name]}');
  }

  for (final pkg in inputs.packages) {
    field('package', pkg.name);
    for (final file in _packageFiles(pkg.dir)) {
      field('file', path.relative(file.path, from: pkg.dir).replaceAll('\\', '/'));
      fileBytes('bytes', file);
    }
  }

  var dir = path.normalize(path.absolute(inputs.configSearchDir));
  while (true) {
    for (final name in ['config.toml', 'config']) {
      final f = File(path.join(dir, '.cargo', name));
      if (f.existsSync()) fileBytes('cwd-config', f);
    }
    final parent = path.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  final home = inputs.cargoHome;
  if (home != null) {
    for (final name in ['config.toml', 'config']) {
      final f = File(path.join(home, name));
      if (f.existsSync()) fileBytes('home-config', f);
    }
  }

  sink.close();
  return hex.encode(output.events.single.bytes.sublist(0, 16));
}

/// Every file of a package except its build output and hidden folders other
/// than `.cargo`, in a stable order.
List<File> _packageFiles(String dir) {
  final files = <File>[];
  void walk(Directory d, bool top) {
    final entries = d.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final e in entries) {
      final name = path.basename(e.path);
      if (e is Directory) {
        if (top && name == 'target') continue;
        if (name.startsWith('.') && name != '.cargo') continue;
        walk(e, false);
      } else if (e is File) {
        files.add(e);
      }
    }
  }

  walk(Directory(dir), true);
  return files;
}

/// Deletes the fingerprints of the named path packages on both the target
/// and the host side, so cargo recompiles them whatever their mtimes say.
List<String> resetPathFingerprints(
    String targetDir, String rustTarget, Iterable<String> names) {
  final deleted = <String>[];
  final patterns = [
    for (final n in names)
      RegExp('^(${RegExp.escape(n)}|${RegExp.escape(n.replaceAll('-', '_'))}|'
          '${RegExp.escape(n.replaceAll('_', '-'))})-[0-9a-f]{16}\$')
  ];
  for (final side in [
    path.join(targetDir, rustTarget, 'debug', '.fingerprint'),
    path.join(targetDir, 'debug', '.fingerprint'),
  ]) {
    final dir = Directory(side);
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync()) {
      if (e is Directory && patterns.any((p) => p.hasMatch(path.basename(e.path)))) {
        e.deleteSync(recursive: true);
        deleted.add(e.path);
      }
    }
  }
  return deleted;
}

/// Built DLL sets by key. A set is written once and never changed; a reader
/// holds a shared lock on its `use.lock` until the process exits, and
/// eviction removes only sets it can lock exclusively.
class DllCache {
  DllCache(this.root);

  final String root;

  /// Process-wide: the build tool exits right after copying what it got.
  static final _held = <RandomAccessFile>[];

  static const _marker = 'complete';
  static const _useLock = 'use.lock';
  static final _keyShape = RegExp(r'^[0-9A-Za-z]+$');

  /// The set's files, or null when it is missing or incomplete.
  List<String>? acquire(String key) {
    final dir = path.join(root, key);
    final lockFile = File(path.join(dir, _useLock));
    if (!lockFile.existsSync()) return null;
    RandomAccessFile raf;
    try {
      raf = lockFile.openSync(mode: FileMode.append);
    } on FileSystemException {
      return null;
    }
    try {
      raf.lockSync(FileLock.blockingShared);
      final marker = File(path.join(dir, _marker));
      if (!marker.existsSync()) throw const FileSystemException('incomplete');
      final names = (jsonDecode(marker.readAsStringSync()) as List).cast<String>();
      final files = [for (final n in names) path.join(dir, n)];
      if (files.any((f) => !File(f).existsSync())) {
        throw const FileSystemException('incomplete');
      }
      try {
        File(path.join(dir, 'used')).writeAsStringSync(DateTime.now().toIso8601String());
      } on FileSystemException {
        // Another reader is stamping it at the same moment; either stamp will do.
      }
      _held.add(raf);
      return files;
    } on Object {
      raf.closeSync();
      return null;
    }
  }

  static void releaseHeld() {
    for (final raf in _held) {
      raf.closeSync();
    }
    _held.clear();
  }

  /// Copies [files] in under [key]; the completion mark goes last.
  void store(String key, List<String> files) {
    Directory(root).createSync(recursive: true);
    final dest = Directory(path.join(root, key));
    if (dest.existsSync() && !_remove(dest)) {
      throw FileSystemException('cache set is in use and incomplete', dest.path);
    }
    final tmp = Directory(path.join(root, '$key.partial-$pid'));
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    tmp.createSync(recursive: true);
    File(path.join(tmp.path, _useLock)).writeAsStringSync('-');
    for (final f in files) {
      File(f).copySync(path.join(tmp.path, path.basename(f)));
    }
    File(path.join(tmp.path, _marker))
        .writeAsStringSync(jsonEncode([for (final f in files) path.basename(f)]));
    tmp.renameSync(dest.path);
  }

  /// Keeps the [keep] most recently used sets plus [protect]; leftovers of
  /// crashed writers go too. Callers hold the build lock.
  void evict({required int keep, required String protect}) {
    final dir = Directory(root);
    if (!dir.existsSync()) return;
    final sets = <Directory>[];
    for (final e in dir.listSync().whereType<Directory>()) {
      final name = path.basename(e.path);
      if (!_keyShape.hasMatch(name)) {
        if (name.contains('.partial-')) _tryDelete(e);
        continue;
      }
      if (!File(path.join(e.path, _marker)).existsSync()) {
        _remove(e);
        continue;
      }
      sets.add(e);
    }
    DateTime used(Directory d) {
      for (final n in ['used', _marker]) {
        final f = File(path.join(d.path, n));
        if (f.existsSync()) return f.lastModifiedSync();
      }
      return DateTime(1970);
    }

    sets.sort((a, b) => used(b).compareTo(used(a)));
    var kept = sets.any((d) => path.basename(d.path) == protect) ? 1 : 0;
    for (final d in sets) {
      if (path.basename(d.path) == protect) continue;
      if (kept < keep) {
        kept++;
        continue;
      }
      _remove(d);
    }
  }

  /// Removes a set unless a reader holds it; the mark goes first so a reader
  /// arriving mid-removal sees a miss.
  bool _remove(Directory d) {
    final lockFile = File(path.join(d.path, _useLock));
    RandomAccessFile? raf;
    if (lockFile.existsSync()) {
      try {
        raf = lockFile.openSync(mode: FileMode.append);
        raf.lockSync(FileLock.exclusive);
      } on FileSystemException {
        raf?.closeSync();
        return false;
      }
    }
    try {
      final marker = File(path.join(d.path, _marker));
      if (marker.existsSync()) marker.deleteSync();
      for (final e in d.listSync()) {
        if (path.basename(e.path) != _useLock) e.deleteSync(recursive: true);
      }
    } finally {
      raf?.closeSync();
    }
    _tryDelete(d);
    return true;
  }

  static void _tryDelete(FileSystemEntity e) {
    try {
      e.deleteSync(recursive: true);
    } on FileSystemException {
      // A reader opened it after all; the next eviction takes it.
    }
  }
}

/// One debug build through the shared target, for one target triple.
class SharedBuild {
  SharedBuild({
    required this.options,
    required this.environment,
    required this.processEnvironment,
    required this.cargoWorkingDirectory,
  });

  final SharedBuildOptions options;
  final BuildEnvironment environment;
  final Map<String, String> processEnvironment;
  final String cargoWorkingDirectory;

  /// The artifacts for [target], or null when this tree cannot share.
  Future<List<Artifact>?> artifacts({
    required Target target,
    required RustBuilder builder,
    required Set<String> artifactNames,
  }) async {
    final List<PathPackage> packages;
    try {
      packages = discoverPathPackages(environment.manifestDir);
    } on SharedBuildUnsupported catch (e) {
      _log.warning('Shared Rust build off for this tree: $e');
      return null;
    }
    final keyInputsEnv = {
      ...processEnvironment,
      ...await builder.cargoEnvironment(),
    };
    final rustc = runCommand('rustup', ['run', builder.toolchain, 'rustc', '-vV'])
        .stdout
        .toString()
        .trim();
    String key() => computeBuildKey(BuildKeyInputs(
          packages: packages,
          rustTarget: target.rust,
          configuration: environment.configuration.name,
          cargoArgs: builder.cargoFlags,
          toolchain: builder.toolchain,
          rustcVersion: rustc,
          env: keyInputsEnv,
          configSearchDir: cargoWorkingDirectory,
          cargoHome: processEnvironment['CARGO_HOME'],
        ));

    final before = key();
    final cache = DllCache(options.cacheDir);
    final hit = cache.acquire(before);
    if (hit != null) {
      _log.info('Reusing the shared Rust build $before');
      return _artifacts(hit);
    }

    Directory(options.stateDir).createSync(recursive: true);
    final lock = File(options.lockPath).openSync(mode: FileMode.append);
    try {
      try {
        lock.lockSync(FileLock.exclusive);
      } on FileSystemException {
        _log.info('Waiting for another tree\'s shared Rust build to finish');
        lock.lockSync(FileLock.blockingExclusive);
      }
      final built = cache.acquire(before);
      if (built != null) {
        _log.info('Reusing the shared Rust build $before (built meanwhile)');
        return _artifacts(built);
      }
      final state = File(path.join(options.stateDir, '${target.rust}-debug.key'));
      final last = state.existsSync() ? state.readAsStringSync().trim() : null;
      if (last != before) {
        final gone = resetPathFingerprints(
            options.targetDir, target.rust, packages.map((p) => p.name));
        _log.info('Shared Rust build: ${gone.length} path fingerprints reset');
      }
      if (state.existsSync()) state.deleteSync();

      final outDir = await builder.build(
          targetDir: options.targetDir,
          extraEnvironment: {
            for (final name in processEnvironment.keys)
              if (name.toUpperCase() == msbuildProjectEnvVar.toUpperCase())
                name: 'hollow-shared-build',
          });
      final files = artifactNames
          .map((n) => path.join(outDir, n))
          .where((f) => File(f).existsSync())
          .toList();

      final after = key();
      if (after != before) {
        // The sources moved under cargo: what it built matches neither key.
        _log.warning('Rust sources changed during the build; not caching it');
        final private = Directory(path.join(environment.targetTempDir, 'shared_uncached'));
        if (private.existsSync()) private.deleteSync(recursive: true);
        private.createSync(recursive: true);
        return _artifacts([
          for (final f in files)
            File(f).copySync(path.join(private.path, path.basename(f))).path
        ]);
      }
      state.writeAsStringSync(before);
      cache.store(before, files);
      cache.evict(keep: options.keep, protect: before);
      final stored = cache.acquire(before);
      if (stored == null) {
        throw BuildException('shared Rust build $before vanished after storing');
      }
      return _artifacts(stored);
    } finally {
      lock.closeSync();
    }
  }

  List<Artifact> _artifacts(List<String> files) => [
        for (final f in files) Artifact(path: f, finalFileName: path.basename(f))
      ];
}
