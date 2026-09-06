import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// In-app display scaling (issue #20). Two knobs that stack ON TOP of whatever
/// the OS already applies; they never replace it.
///
/// [uiScaleProvider] is the interface zoom, applied exactly once at the root by
/// `UiScale`. A zoom is the only honest answer to the "icon size" half of the
/// request: icon sizes live in ~800 hardcoded `size:` literals, so a text-only
/// scaler strands 16px icons next to 24px labels. [chatTextScaleProvider] is an
/// extra TEXT-only multiplier for the message surfaces.
///
/// Both are synchronous [Notifier]s loaded from `HollowShell._bootstrap`, never
/// eager `AsyncNotifier`s: `loadSetting` THROWS until the SQLCipher store is
/// open, so an eager read in `build()` loses the saved value every launch
/// (feedback_load_persisted_setting_from_bootstrap_not_build).

/// True on phones/tablets, where the shell is the single-panel mobile UI.
bool get _isMobileForm => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Interface-scale floor. Below this, the 10-11px caption tokens stop being
/// legible on any display.
double get uiScaleMin => _isMobileForm ? 0.9 : 0.75;

/// Interface-scale ceiling. Desktop can afford a real zoom; a phone cannot: a
/// 360dp device at 2.0x lays out at 180dp, narrower than the mobile shell's own
/// chrome, including the Settings list needed to undo it.
double get uiScaleMax => _isMobileForm ? 1.5 : 2.0;

/// Both sliders move on a 5% grid.
const double kUiScaleStep = 0.05;
const double kUiScaleDefault = 1.0;

const double kChatTextScaleMin = 0.8;
const double kChatTextScaleMax = 2.0;
const double kChatTextScaleDefault = 1.0;

/// Slider division count for a range on the 5% grid.
int scaleDivisions(double min, double max) =>
    ((max - min) / kUiScaleStep).round();

/// Snaps a raw scale onto the 5% grid (keyboard zoom, slider drift).
double snapScale(double value) =>
    (value / kUiScaleStep).roundToDouble() * kUiScaleStep;

/// Display form of a scale factor: 1.25 -> "125%".
String scalePercentLabel(double scale) => '${(scale * 100).round()}%';

/// Interface scale ("zoom") — persisted under `ui_scale`. Default 1.0.
final uiScaleProvider =
    NotifierProvider<UiScaleNotifier, double>(UiScaleNotifier.new);

class UiScaleNotifier extends Notifier<double> {
  @override
  double build() => kUiScaleDefault;

  /// Called from `_bootstrap` once the store is open.
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'ui_scale');
      if (val == null || val.isEmpty) return;
      state = _clamp(double.tryParse(val) ?? kUiScaleDefault);
    } catch (e) {
      debugPrint('[HOLLOW] uiScale.load() failed: $e');
    }
  }

  /// Applies [scale] immediately, then persists. The state moves first so a
  /// keyboard zoom lands on the next frame instead of after a DB round trip; a
  /// failed write only costs the setting on next launch, so it is logged.
  Future<void> setScale(double scale) async {
    final clamped = _clamp(scale);
    if (state == clamped) return;
    state = clamped;
    try {
      await storage_api.saveSetting(
        key: 'ui_scale',
        value: clamped.toStringAsFixed(2),
      );
    } catch (e) {
      debugPrint('[HOLLOW] uiScale save failed: $e');
    }
  }

  /// Ctrl + / Ctrl −: move [steps] stops along the 5% grid.
  Future<void> nudge(int steps) =>
      setScale(snapScale(state) + steps * kUiScaleStep);

  Future<void> reset() => setScale(kUiScaleDefault);

  double _clamp(double v) => v.clamp(uiScaleMin, uiScaleMax).toDouble();
}

/// Chat text scale — persisted under `chat_text_scale`. Default 1.0.
final chatTextScaleProvider =
    NotifierProvider<ChatTextScaleNotifier, double>(ChatTextScaleNotifier.new);

class ChatTextScaleNotifier extends Notifier<double> {
  @override
  double build() => kChatTextScaleDefault;

  /// Called from `_bootstrap` once the store is open.
  Future<void> load() async {
    try {
      final val = await storage_api.loadSetting(key: 'chat_text_scale');
      if (val == null || val.isEmpty) return;
      state = _clamp(double.tryParse(val) ?? kChatTextScaleDefault);
    } catch (e) {
      debugPrint('[HOLLOW] chatTextScale.load() failed: $e');
    }
  }

  Future<void> setScale(double scale) async {
    final clamped = _clamp(scale);
    if (state == clamped) return;
    state = clamped;
    try {
      await storage_api.saveSetting(
        key: 'chat_text_scale',
        value: clamped.toStringAsFixed(2),
      );
    } catch (e) {
      debugPrint('[HOLLOW] chatTextScale save failed: $e');
    }
  }

  Future<void> reset() => setScale(kChatTextScaleDefault);

  double _clamp(double v) =>
      v.clamp(kChatTextScaleMin, kChatTextScaleMax).toDouble();
}
