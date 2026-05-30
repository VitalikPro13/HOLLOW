import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

class ThemeModeNotifier extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.dark;

  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'theme_mode');
      state = val == 'light' ? ThemeMode.light : ThemeMode.dark;
    } catch (e) {
      debugPrint('[HOLLOW] themeMode.load() failed: $e');
    }
  }

  Future<void> setMode(ThemeMode mode) async {
    state = mode;
    await storage_api.saveSetting(
      key: 'theme_mode',
      value: mode == ThemeMode.light ? 'light' : 'dark',
    );
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
