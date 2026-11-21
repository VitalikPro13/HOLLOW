import 'dart:async';
import 'dart:io';

import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/profile_registry.dart';

/// Every test file starts on throwaway roots: code that falls back to the default
/// data folder (`%APPDATA%\Hollow`, `$HOME/Hollow`) or the profile registry's
/// anchor wrote into the real profile of whoever ran the suite (#155 review).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final sep = Platform.pathSeparator;
  final root = Directory.systemTemp.createTempSync('hollow_flutter_test_');
  overrideHollowDataDir('${root.path}${sep}data');
  debugDefaultDesktopDataRoot = '${root.path}${sep}default';
  await testMain();
}
