import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const _hueKey = 'accent_hue';
const _presetsKey = 'accent_presets';

/// Default teal hue (matching HollowColors.accent = 0xFF00BFA6).
const double defaultAccentHue = 168.0;

/// Generate accent colors from a hue value (0-360).
Color accentFromHue(double hue) =>
    HSLColor.fromAHSL(1.0, hue, 0.85, 0.37).toColor();

Color accentHoverFromHue(double hue) =>
    HSLColor.fromAHSL(1.0, hue, 0.85, 0.45).toColor();

Color accentMutedFromHue(double hue) =>
    HSLColor.fromAHSL(0.2, hue, 0.85, 0.37).toColor();

Color accentMutedLightFromHue(double hue) =>
    HSLColor.fromAHSL(0.1, hue, 0.85, 0.37).toColor();

/// Accent hue provider (0-360).
class AccentHueNotifier extends Notifier<double> {
  @override
  double build() => defaultAccentHue;

  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: _hueKey);
      if (val != null && val.isNotEmpty) {
        state = double.tryParse(val) ?? defaultAccentHue;
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load accent hue: $e');
    }
  }

  Future<void> setHue(double hue) async {
    state = hue % 360;
    try {
      await storage_api.saveSetting(key: _hueKey, value: state.toString());
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save accent hue: $e');
    }
  }

  void reset() => setHue(defaultAccentHue);
}

final accentHueProvider = NotifierProvider<AccentHueNotifier, double>(
  AccentHueNotifier.new,
);

/// Saved color presets (list of hue values).
class AccentPresetsNotifier extends Notifier<List<double>> {
  @override
  List<double> build() => [];

  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: _presetsKey);
      if (val != null && val.isNotEmpty) {
        state = List<double>.from(
          (jsonDecode(val) as List).map((e) => (e as num).toDouble()),
        );
      }
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load accent presets: $e');
    }
  }

  Future<void> addPreset(double hue) async {
    if (state.any((h) => (h - hue).abs() < 1)) return;
    state = [...state, hue];
    await _save();
  }

  Future<void> removePreset(double hue) async {
    state = state.where((h) => (h - hue).abs() >= 1).toList();
    await _save();
  }

  Future<void> _save() async {
    try {
      await storage_api.saveSetting(
        key: _presetsKey,
        value: jsonEncode(state),
      );
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save accent presets: $e');
    }
  }
}

final accentPresetsProvider =
    NotifierProvider<AccentPresetsNotifier, List<double>>(
  AccentPresetsNotifier.new,
);
