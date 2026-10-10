// The shared debug build (lib/src/shared_build.dart). Run it with
// `dart run test/shared_build_test.dart`: `dart test` on the pinned test
// package cannot start with current Dart SDKs.
import 'dart:io';

import 'package:build_tool/src/artifacts_provider.dart';
import 'package:build_tool/src/builder.dart';
import 'package:build_tool/src/cargo.dart';
import 'package:build_tool/src/options.dart';
import 'package:build_tool/src/shared_build.dart';
import 'package:build_tool/src/target.dart';
import 'package:build_tool/src/util.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const triple = 'x86_64-pc-windows-msvc';

late Directory scratch;

/// A Hollow-shaped tree: hollow_core with a path dependency on hollow_dfn.
String makeTree(String name, {String marker = 'A'}) {
  final root = path.join(scratch.path, name);
  void write(String rel, String content) {
    final f = File(path.join(root, rel));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  write('rust/hollow_core/Cargo.toml', '''
[package]
name = "hollow_core"
version = "0.1.0"

[dependencies]
serde = "1"
hollow_dfn = { path = "../hollow_dfn" }

[profile.dev.package."*"]
opt-level = 2
''');
  write('rust/hollow_core/Cargo.lock', '''
version = 4

[[package]]
name = "hollow_core"
version = "0.1.0"

[[package]]
name = "hollow_dfn"
version = "0.1.0"

[[package]]
name = "serde"
version = "1.0.0"
source = "registry+https://github.com/rust-lang/crates.io-index"
''');
  write('rust/hollow_core/cargokit.yaml', 'cargo: {}\n');
  write('rust/hollow_core/.cargo/config.toml', '[env]\nOPENSSL_DIR = "x"\n');
  write('rust/hollow_core/src/lib.rs', 'pub const MARKER: &str = "$marker";\n');
  write('rust/hollow_core/src/node/swarm.rs', 'pub fn run() {}\n');
  write('rust/hollow_core/target/debug/junk.rlib', 'old build output');
  write('rust/hollow_dfn/Cargo.toml', '[package]\nname = "hollow_dfn"\nversion = "0.1.0"\n');
  write('rust/hollow_dfn/src/lib.rs', 'pub fn denoise() {}\n');
  return root;
}

String crateDir(String tree) => path.join(tree, 'rust', 'hollow_core');

BuildKeyInputs inputs(String tree,
    {Map<String, String> env = const {},
    String rustc = 'rustc 1.93.1',
    String target = triple,
    List<String> flags = const ['--features', 'forwarder'],
    String configuration = 'debug'}) {
  return BuildKeyInputs(
    packages: discoverPathPackages(crateDir(tree)),
    rustTarget: target,
    configuration: configuration,
    cargoArgs: flags,
    toolchain: 'stable',
    rustcVersion: rustc,
    env: env,
    configSearchDir: path.join(tree, 'build', 'tool'),
    cargoHome: null,
  );
}

void main() {
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('hollow_shared_build_');
  });
  tearDown(() {
    testRunCommandOverride = null;
    DllCache.releaseHeld();
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('options', () {
    test('off when the variable is unset', () {
      expect(
          SharedBuildOptions.from(
              configuration: BuildConfiguration.debug, env: {}),
          isNull);
    });
    test('off for release and profile even when the variable is set', () {
      for (final c in [BuildConfiguration.release, BuildConfiguration.profile]) {
        expect(
            SharedBuildOptions.from(
                configuration: c, env: {sharedDirEnvVar: scratch.path}),
            isNull,
            reason: c.name);
      }
    });
    test('off for an empty, 0 or off value', () {
      for (final v in ['', ' ', '0', 'off', 'OFF']) {
        expect(
            SharedBuildOptions.from(
                configuration: BuildConfiguration.debug,
                env: {sharedDirEnvVar: v}),
            isNull,
            reason: v);
      }
    });
    test('debug with the variable set shares one root', () {
      final o = SharedBuildOptions.from(
          configuration: BuildConfiguration.debug,
          env: {sharedDirEnvVar: scratch.path})!;
      expect(o.targetDir, path.join(scratch.path, 'target'));
      expect(o.keep, 3);
    });
  });

  group('path packages', () {
    test('the root crate and its path dependencies', () {
      final tree = makeTree('t');
      final names = discoverPathPackages(crateDir(tree)).map((p) => p.name);
      expect(names.toSet(), {'hollow_core', 'hollow_dfn'});
    });
    test('a lock naming a path package the manifests never reach refuses',
        () {
      final tree = makeTree('t');
      final lock = File(path.join(crateDir(tree), 'Cargo.lock'));
      lock.writeAsStringSync(
          '${lock.readAsStringSync()}\n[[package]]\nname = "ghost"\nversion = "0.1.0"\n');
      expect(() => discoverPathPackages(crateDir(tree)),
          throwsA(isA<SharedBuildUnsupported>()));
    });
  });

  group('build key', () {
    test('the same content in another tree gives the same key, mtimes aside',
        () {
      final a = makeTree('a');
      final b = makeTree('b');
      final old = DateTime(2020);
      for (final f in Directory(b).listSync(recursive: true).whereType<File>()) {
        f.setLastModifiedSync(old);
      }
      expect(computeBuildKey(inputs(b)), computeBuildKey(inputs(a)));
    });

    test('every input of the library changes it', () {
      final tree = makeTree('t');
      final base = computeBuildKey(inputs(tree));
      final seen = <String>{base};
      void expectChanged(String what, String key) {
        expect(seen.contains(key), isFalse, reason: what);
        seen.add(key);
      }

      void edit(String rel, String content) {
        File(path.join(tree, rel)).writeAsStringSync(content);
        expectChanged(rel, computeBuildKey(inputs(tree)));
      }

      edit('rust/hollow_core/src/lib.rs', 'pub const MARKER: &str = "B";\n');
      edit('rust/hollow_core/src/node/swarm.rs', 'pub fn run() { }\n');
      edit('rust/hollow_dfn/src/lib.rs', 'pub fn denoise() { }\n');
      edit('rust/hollow_core/Cargo.toml', '[package]\nname = "hollow_core"\n'
          '[dependencies]\nhollow_dfn = { path = "../hollow_dfn" }\n');
      edit('rust/hollow_core/Cargo.lock',
          'version = 4\n[[package]]\nname = "hollow_core"\n[[package]]\nname = "hollow_dfn"\n');
      edit('rust/hollow_core/cargokit.yaml', 'cargo: {debug: {}}\n');
      edit('rust/hollow_core/.cargo/config.toml', '[env]\nOPENSSL_DIR = "y"\n');
      File(path.join(tree, 'rust/hollow_core/src/new_module.rs'))
          .writeAsStringSync('');
      expectChanged('a new source file', computeBuildKey(inputs(tree)));

      final now = computeBuildKey(inputs(tree));
      expectChanged('rustc version',
          computeBuildKey(inputs(tree, rustc: 'rustc 1.94.0')));
      expectChanged('target', computeBuildKey(inputs(tree, target: 'x86_64-unknown-linux-gnu')));
      expectChanged('flags', computeBuildKey(inputs(tree, flags: [])));
      expectChanged('configuration',
          computeBuildKey(inputs(tree, configuration: 'profile')));
      for (final name in [
        'RUSTFLAGS',
        'CARGO_ENCODED_RUSTFLAGS',
        'CARGO_PROFILE_DEV_OPT_LEVEL',
        'OPENSSL_DIR',
        'X86_64_LINUX_ANDROID_OPENSSL_LIB_DIR',
        'CFLAGS',
        'CC',
      ]) {
        expectChanged(name, computeBuildKey(inputs(tree, env: {name: '1'})));
      }
      expect(computeBuildKey(inputs(tree)), now);
    });

    test('a cargo config on the cargo working directory path counts', () {
      final tree = makeTree('t');
      final base = computeBuildKey(inputs(tree));
      final cfg = File(path.join(tree, '.cargo', 'config.toml'));
      cfg.parent.createSync(recursive: true);
      cfg.writeAsStringSync('[build]\nrustflags = ["-Cdebuginfo=0"]\n');
      expect(computeBuildKey(inputs(tree)), isNot(base));
    });

    test('build output, per-tree paths and unrelated variables do not count',
        () {
      final tree = makeTree('t');
      final base = computeBuildKey(inputs(tree));
      File(path.join(tree, 'rust/hollow_core/target/debug/junk.rlib'))
          .writeAsStringSync('new build output');
      File(path.join(tree, 'build/other.txt'))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
      expect(computeBuildKey(inputs(tree)), base);
      expect(
          computeBuildKey(inputs(tree, env: {
            'CARGOKIT_OUTPUT_DIR': r'D:\dev\wt\x\build',
            'CARGOKIT_TOOL_TEMP_DIR': r'D:\dev\wt\x\build\tool',
            'HOLLOW_TEST_TMP': r'D:\dev\tmp',
            'TEMP': r'C:\tmp',
          })),
          base);
    });
  });

  group('fingerprint reset', () {
    test('drops exactly the path packages, host and target side', () {
      final td = path.join(scratch.path, 'target');
      final names = [
        '$triple/debug/.fingerprint/hollow_core-037fc2fbbb496bae',
        '$triple/debug/.fingerprint/hollow_dfn-05821a35723ce20f',
        '$triple/debug/.fingerprint/hollow_dfn-35dad1bd7a2c2c1d',
        'debug/.fingerprint/hollow_dfn-1111111111111111',
        '$triple/debug/.fingerprint/serde-0123456789abcdef',
        '$triple/debug/.fingerprint/hollow_core_extra-0123456789abcdef',
        '$triple/debug/.fingerprint/hollow_dfn-sys-0123456789abcdef',
        'debug/.fingerprint/serde_derive-0123456789abcdef',
      ];
      for (final n in names) {
        File(path.join(td, n, 'lib-x')).createSync(recursive: true);
      }
      resetPathFingerprints(td, triple, ['hollow_core', 'hollow_dfn']);
      bool exists(String n) => Directory(path.join(td, n)).existsSync();
      expect(names.take(4).where(exists), isEmpty);
      expect(names.skip(4).every(exists), isTrue);
    });
  });

  group('dll cache', () {
    List<String> files(String dir, String marker) {
      Directory(dir).createSync(recursive: true);
      return [
        for (final n in ['hollow_core.dll', 'hollow_core.pdb'])
          (File(path.join(dir, n))..writeAsStringSync('$marker $n')).path
      ];
    }

    test('a stored set comes back byte for byte under its key', () {
      final cache = DllCache(path.join(scratch.path, 'dll'));
      expect(cache.acquire('k1'), isNull);
      cache.store('k1', files(path.join(scratch.path, 'out'), 'one'));
      final got = cache.acquire('k1')!;
      expect(got.map(path.basename).toSet(), {'hollow_core.dll', 'hollow_core.pdb'});
      expect(File(got.firstWhere((p) => p.endsWith('.dll'))).readAsStringSync(),
          'one hollow_core.dll');
    });

    test('a set without its completion mark is a miss', () {
      final cache = DllCache(path.join(scratch.path, 'dll'));
      cache.store('k1', files(path.join(scratch.path, 'out'), 'one'));
      File(path.join(scratch.path, 'dll', 'k1', 'complete')).deleteSync();
      expect(DllCache(path.join(scratch.path, 'dll')).acquire('k1'), isNull);
    });

    test('eviction keeps the newest sets and the one just built', () async {
      final root = path.join(scratch.path, 'dll');
      for (final k in ['k1', 'k2', 'k3', 'k4']) {
        DllCache(root).store(k, files(path.join(scratch.path, 'out$k'), k));
        await Future.delayed(const Duration(milliseconds: 20));
      }
      DllCache(root).evict(keep: 2, protect: 'k1');
      final left = Directory(root)
          .listSync()
          .map((e) => path.basename(e.path))
          .toSet();
      expect(left, {'k1', 'k4'});
    });

    test('eviction leaves a set another build is copying from', () {
      final root = path.join(scratch.path, 'dll');
      DllCache(root).store('k1', files(path.join(scratch.path, 'o1'), 'k1'));
      DllCache(root).store('k2', files(path.join(scratch.path, 'o2'), 'k2'));
      final reader = DllCache(root);
      expect(reader.acquire('k1'), isNotNull);
      DllCache(root).evict(keep: 1, protect: 'k2');
      expect(reader.acquire('k1'), isNotNull);
      DllCache.releaseHeld();
      DllCache(root).evict(keep: 1, protect: 'k2');
      expect(DllCache(root).acquire('k1'), isNull);
    }, skip: Platform.isWindows ? false : 'POSIX record locks are per process');
  });

  group('build through the provider', () {
    late List<List<String>> cargoCalls;
    late List<List<String>> fingerprintsAtCall;
    late List<Map<String, String>?> cargoEnvs;
    String? midBuildEdit;
    var failAfterCompile = false;

    setUp(() {
      cargoCalls = [];
      fingerprintsAtCall = [];
      cargoEnvs = [];
      midBuildEdit = null;
      failAfterCompile = false;
      testRunCommandOverride = (args) {
        final a = args.arguments;
        if (args.executable != 'rustup') {
          throw StateError('unexpected ${args.executable}');
        }
        if (a.length >= 2 && a[0] == 'toolchain' && a[1] == 'list') {
          return TestRunCommandResult(stdout: 'stable-$triple (default)\n');
        }
        if (a.isNotEmpty && a[0] == 'target') {
          return TestRunCommandResult(stdout: '$triple\n');
        }
        if (a.length >= 3 && a[0] == 'run' && a[2] == 'rustc') {
          return TestRunCommandResult(stdout: 'rustc 1.93.1 (fake)\nhost: $triple\n');
        }
        if (a.length >= 4 && a[0] == 'run' && a[2] == 'cargo' && a[3] == 'build') {
          cargoCalls.add(List.of(a));
          cargoEnvs.add(args.environment);
          final td = a[a.indexOf('--target-dir') + 1];
          final manifest = a[a.indexOf('--manifest-path') + 1];
          final profile = a.contains('--release') ? 'release' : 'debug';
          final fpDir = Directory(path.join(td, triple, profile, '.fingerprint'));
          fingerprintsAtCall.add(fpDir.existsSync()
              ? fpDir.listSync().map((e) => path.basename(e.path)).toList()
              : []);
          // An editor saving after the key was taken, before cargo reads.
          if (midBuildEdit != null) {
            File(path.join(path.dirname(manifest), 'src', 'lib.rs'))
                .writeAsStringSync(midBuildEdit!);
          }
          // Like cargo with the mtime trap: a path crate whose fingerprint is
          // still there counts as fresh, so its old output stays.
          final fresh = fpDir.existsSync() &&
              fpDir.listSync().any((e) => path.basename(e.path).startsWith('hollow_core-'));
          if (!fresh) {
            final marker = File(path.join(path.dirname(manifest), 'src', 'lib.rs'))
                .readAsStringSync();
            final out = path.join(td, triple, profile);
            Directory(out).createSync(recursive: true);
            File(path.join(out, 'hollow_core.dll')).writeAsStringSync(marker);
            File(path.join(out, 'hollow_core.dll.lib')).writeAsStringSync('lib');
            File(path.join(out, 'hollow_core.pdb')).writeAsStringSync('pdb $marker');
            Directory(path.join(fpDir.path, 'hollow_core-037fc2fbbb496bae'))
                .createSync(recursive: true);
            Directory(path.join(fpDir.path, 'serde-0123456789abcdef'))
                .createSync(recursive: true);
          }
          if (failAfterCompile) {
            throw CommandFailedException(
                executable: 'rustup',
                arguments: a,
                result: ProcessResult(1, 101, '', 'error: linking failed'));
          }
          return TestRunCommandResult();
        }
        throw StateError('unexpected rustup ${a.join(' ')}');
      };
    });

    BuildEnvironment env(String tree, BuildConfiguration c) => BuildEnvironment(
          configuration: c,
          crateOptions: CargokitCrateOptions(cargo: {
            for (final b in BuildConfiguration.values)
              b: CargoBuildOptions(
                  toolchain: Toolchain.stable, flags: ['--features', 'forwarder'])
          }),
          targetTempDir: path.join(tree, 'build', 'cargokit_build'),
          manifestDir: crateDir(tree),
          crateInfo: CrateInfo(packageName: 'hollow_core'),
          isAndroid: false,
        );

    final windows = Target.all.firstWhere((t) => t.rust == triple);

    Future<Map<String, String>> build(String tree,
        {BuildConfiguration c = BuildConfiguration.debug,
        Map<String, String>? vars}) async {
      final toolDir = Directory(path.join(tree, 'build', 'tool'))
        ..createSync(recursive: true);
      final provider = ArtifactProvider(
        environment: env(tree, c),
        userOptions: CargokitUserOptions(
            usePrecompiledBinaries: false, verboseLogging: false),
        processEnvironment: vars ??
            {sharedDirEnvVar: path.join(scratch.path, 'shared')},
        cargoWorkingDirectory: toolDir.path,
      );
      final artifacts = (await provider.getArtifacts([windows]))[windows]!;
      return {
        for (final a in artifacts)
          a.finalFileName: File(a.path).readAsStringSync(),
        for (final a in artifacts) '${a.finalFileName}@': a.path,
      };
    }

    String marker(String m) => 'pub const MARKER: &str = "$m";\n';

    test('A, then B, then A: each tree gets its own code', () async {
      final a = makeTree('a', marker: 'A');
      final b = makeTree('b', marker: 'B');
      // B's files are older than A's build, the shape of the mtime trap.
      for (final f in Directory(b).listSync(recursive: true).whereType<File>()) {
        f.setLastModifiedSync(DateTime(2020));
      }
      expect((await build(a))['hollow_core.dll'], marker('A'));
      expect((await build(b))['hollow_core.dll'], marker('B'));
      expect((await build(a))['hollow_core.dll'], marker('A'));
      expect(cargoCalls.length, 2, reason: 'A again reuses its cached set');
      expect(fingerprintsAtCall[1].where((n) => n.startsWith('hollow_core-')),
          isEmpty,
          reason: 'B built only after the path fingerprints were reset');
      expect(fingerprintsAtCall[1], contains('serde-0123456789abcdef'),
          reason: 'dependencies stay built');
      final shared = path.join(scratch.path, 'shared', 'target');
      expect(cargoCalls.every((c) => c[c.indexOf('--target-dir') + 1] == shared),
          isTrue);
    });

    test('a change outside rust/ runs no cargo at all', () async {
      final a = makeTree('a');
      await build(a);
      File(path.join(a, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}');
      final second = await build(a);
      expect(cargoCalls.length, 1);
      expect(second['hollow_core.dll@']!,
          startsWith(path.join(scratch.path, 'shared', 'dll')));
    });

    test('a cached set is served while another build holds the lock',
        () async {
      final a = makeTree('a');
      await build(a);
      final held = File(path.join(scratch.path, 'shared', 'build.lock'))
          .openSync(mode: FileMode.append)
        ..lockSync(FileLock.exclusive);
      try {
        final second = await build(a);
        expect(cargoCalls.length, 1);
        expect(second['hollow_core.dll'], marker('A'));
      } finally {
        held.closeSync();
      }
    },
        timeout: const Timeout(Duration(seconds: 20)),
        skip: Platform.isWindows ? false : 'POSIX record locks are per process');

    test('an edit to a Rust file rebuilds even when the tree looks older',
        () async {
      final a = makeTree('a', marker: 'A');
      await build(a);
      final lib = File(path.join(crateDir(a), 'src', 'lib.rs'));
      lib.writeAsStringSync(marker('A2'));
      lib.setLastModifiedSync(DateTime(2020));
      expect((await build(a))['hollow_core.dll'], marker('A2'));
    });

    test('a failed cargo run leaves no key behind, so the next run resets',
        () async {
      final a = makeTree('a', marker: 'A');
      final b = makeTree('b', marker: 'B');
      await build(a);
      final ok = testRunCommandOverride!;
      testRunCommandOverride = (args) {
        if (args.arguments.contains('build')) {
          throw CommandFailedException(
              executable: 'rustup',
              arguments: args.arguments,
              result: ProcessResult(1, 101, '', 'error'));
        }
        return ok(args);
      };
      await expectLater(build(b), throwsA(isA<CommandFailedException>()));
      testRunCommandOverride = ok;
      // The A build left hollow_core's fingerprint; a stale key would keep it.
      final fp = Directory(path.join(
          scratch.path, 'shared', 'target', triple, 'debug', '.fingerprint',
          'hollow_core-037fc2fbbb496bae'))
        ..createSync(recursive: true);
      expect(fp.existsSync(), isTrue);
      expect((await build(b))['hollow_core.dll'], marker('B'));
    });

    test('a build that failed after compiling never stands in for the last key',
        () async {
      final a = makeTree('a', marker: 'A');
      final b = makeTree('b', marker: 'B');
      for (final f in Directory(a).listSync(recursive: true).whereType<File>()) {
        f.setLastModifiedSync(DateTime(2020));
      }
      await build(a);
      // A's set is evicted, then B compiles and fails to link.
      DllCache.releaseHeld();
      Directory(path.join(scratch.path, 'shared', 'dll')).deleteSync(recursive: true);
      failAfterCompile = true;
      await expectLater(build(b), throwsA(isA<CommandFailedException>()));
      failAfterCompile = false;
      expect((await build(a))['hollow_core.dll'], marker('A'));
    });

    test('sources edited during the build are not cached under the old key',
        () async {
      final a = makeTree('a', marker: 'A');
      midBuildEdit = marker('X');
      expect((await build(a))['hollow_core.dll'], marker('X'));
      midBuildEdit = null;
      File(path.join(crateDir(a), 'src', 'lib.rs')).writeAsStringSync(marker('A'));
      expect((await build(a))['hollow_core.dll'], marker('A'));
    });

    test('the MSBuild project path reaches cargo as one value for every tree',
        () async {
      final a = makeTree('a');
      final b = makeTree('b', marker: 'B');
      final shared = path.join(scratch.path, 'shared');
      await build(a, vars: {
        sharedDirEnvVar: shared,
        msbuildProjectEnvVar: r'D:\a\build\plugins\hollow_core\x.vcxproj'
      });
      await build(b, vars: {
        sharedDirEnvVar: shared,
        msbuildProjectEnvVar: r'D:\b\build\plugins\hollow_core\x.vcxproj'
      });
      await build(makeTree('c', marker: 'C'), vars: {sharedDirEnvVar: shared});
      expect(cargoCalls.length, 3);
      final seen = [for (final e in cargoEnvs) e?[msbuildProjectEnvVar]];
      expect(seen[0], isNotNull);
      expect(seen[1], seen[0]);
      expect(seen[2], isNull, reason: 'never added where MSBuild did not set it');
    });

    test('release and profile ignore the variable', () async {
      final a = makeTree('a');
      for (final c in [BuildConfiguration.release, BuildConfiguration.profile]) {
        cargoCalls.clear();
        final got = await build(a, c: c);
        final call = cargoCalls.single;
        expect(call[call.indexOf('--target-dir') + 1],
            path.join(a, 'build', 'cargokit_build'));
        expect(call, contains('--release'));
        expect(got['hollow_core.dll@'],
            path.join(a, 'build', 'cargokit_build', triple, 'release', 'hollow_core.dll'));
      }
      expect(Directory(path.join(scratch.path, 'shared')).existsSync(), isFalse);
    });

    test('without the variable the cargo call is the original one', () async {
      final a = makeTree('a');
      final got = await build(a, vars: {});
      final temp = path.join(a, 'build', 'cargokit_build');
      expect(cargoCalls.single, [
        'run',
        'stable',
        'cargo',
        'build',
        '--features',
        'forwarder',
        '--manifest-path',
        path.join(crateDir(a), 'Cargo.toml'),
        '-p',
        'hollow_core',
        '--target',
        triple,
        '--target-dir',
        temp,
      ]);
      expect(got['hollow_core.dll@'], path.join(temp, triple, 'debug', 'hollow_core.dll'));
    });
  });
}
