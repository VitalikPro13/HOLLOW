import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hollow/src/ui/guides/guides_models.dart';

/// Path to the bundled Help content. Ships inside the app (no network fetch).
const String kHelpManifestAsset = 'assets/help/manifest.json';

/// Loads and parses the bundled Help manifest from assets (Riverpod-cached).
final helpManifestProvider = FutureProvider<GuidesManifest>((ref) async {
  final raw = await rootBundle.loadString(kHelpManifestAsset);
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return GuidesManifest.fromJson(json);
});
