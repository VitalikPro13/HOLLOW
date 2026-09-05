import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The probe's configuration, keyed like environment variables. Read it after
/// [loadProbeEnv] has completed (the probe does that in `setUpAll`).
///
/// On desktop this IS the process environment: `ui_probe.ps1` and `fleet.ps1`
/// hand each instance its out dir, mode and peer name that way.
///
/// On iOS and Android `Platform.environment` is EMPTY (measured: zero
/// variables in the Simulator, while `ps eww` on the same process shows every
/// `SIMCTL_CHILD_` value present), so the configuration travels as
/// `Documents/probe.env` inside the app's own data container instead: one
/// `KEY=VALUE` per line, written by the orchestrator between `simctl install`
/// and `simctl launch`. Resolving that directory needs a platform channel,
/// which is why loading is asynchronous rather than a top-level initializer.
Map<String, String> probeEnv = Map<String, String>.from(Platform.environment);

/// Where the values came from, for the one config line the probe prints at
/// boot: `environment`, or `environment + <path>` once the file was read.
String probeEnvSource = 'environment';

Future<void> loadProbeEnv() async {
  final merged = Map<String, String>.from(Platform.environment);
  if (Platform.isIOS || Platform.isAndroid) {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file = File('${docs.path}/probe.env');
      if (file.existsSync()) {
        for (final raw in file.readAsLinesSync()) {
          final line = raw.trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          final eq = line.indexOf('=');
          if (eq <= 0) continue;
          merged[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
        }
        probeEnvSource = 'environment + ${file.path}';
      } else {
        probeEnvSource = 'environment (no ${file.path})';
      }
    } catch (e) {
      probeEnvSource = 'environment (probe.env unreadable: $e)';
    }
  }
  probeEnv = merged;
}
