import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

const _opacityKey = 'bg_panel_opacity';
const _bgFileName = 'custom_background.img';

Directory _hollowDir() {
  final dir = Directory(hollowDataDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return dir;
}

class BackgroundState {
  final Uint8List? imageBytes;
  final double panelOpacity; // 0.0 = fully transparent panels, 1.0 = solid (default)

  const BackgroundState({this.imageBytes, this.panelOpacity = 1.0});

  bool get hasBackground => imageBytes != null && imageBytes!.isNotEmpty;

  BackgroundState copyWith({Uint8List? imageBytes, double? panelOpacity, bool clearImage = false}) {
    return BackgroundState(
      imageBytes: clearImage ? null : (imageBytes ?? this.imageBytes),
      panelOpacity: panelOpacity ?? this.panelOpacity,
    );
  }
}

class BackgroundNotifier extends Notifier<BackgroundState> {
  @override
  BackgroundState build() => const BackgroundState();

  Future<void> load() async {
    try {
      // Load opacity
      final opacityStr = await storage_api.loadSetting(key: _opacityKey);
      final opacity = opacityStr != null ? (double.tryParse(opacityStr) ?? 1.0) : 1.0;

      // Load image from file
      final dir = _hollowDir();
      final file = File('${dir.path}/$_bgFileName');
      Uint8List? bytes;
      if (await file.exists()) {
        bytes = await file.readAsBytes();
      }

      state = BackgroundState(imageBytes: bytes, panelOpacity: opacity);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to load background: $e');
    }
  }

  Future<void> setImage(Uint8List bytes) async {
    try {
      final dir = _hollowDir();
      final file = File('${dir.path}/$_bgFileName');
      await file.writeAsBytes(bytes);
      state = state.copyWith(imageBytes: bytes);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save background: $e');
    }
  }

  Future<void> clearImage() async {
    try {
      final dir = _hollowDir();
      final file = File('${dir.path}/$_bgFileName');
      if (await file.exists()) await file.delete();
      state = state.copyWith(clearImage: true);
    } catch (e) {
      debugPrint('[HOLLOW] Failed to clear background: $e');
    }
  }

  Future<void> setOpacity(double opacity) async {
    state = state.copyWith(panelOpacity: opacity.clamp(0.0, 1.0));
    try {
      await storage_api.saveSetting(key: _opacityKey, value: state.panelOpacity.toString());
    } catch (e) {
      debugPrint('[HOLLOW] Failed to save bg opacity: $e');
    }
  }
}

final backgroundProvider = NotifierProvider<BackgroundNotifier, BackgroundState>(
  BackgroundNotifier.new,
);
