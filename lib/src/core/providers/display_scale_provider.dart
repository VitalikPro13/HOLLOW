import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

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

/// A tablet's default interface scale lays it out as if its shortest side were
/// about this many logical pixels, so a 13" iPad does not read as a giant phone.
const double kTabletScaleReference = 690;

/// The most a screen alone may scale the interface; the slider can go no
/// higher on a phone or tablet either ([uiScaleMax]).
const double kTabletScaleMax = 1.5;

/// The interface scale a screen gets while the user has never chosen one.
///
/// Phones land under the reference and stay at 1.0; desktop never auto-scales
/// (the OS display scaling already covers it).
double autoUiScaleFor(double shortestSide, {required bool mobileForm}) {
  if (!mobileForm || shortestSide <= 0) return kUiScaleDefault;
  return (shortestSide / kTabletScaleReference)
      .clamp(kUiScaleDefault, kTabletScaleMax)
      .toDouble();
}

/// The shortest side of the screen this app runs on, in logical pixels. The
/// display, not the window, so an iPad split view keeps the full-screen
/// default; the first view stands in where a platform reports no display.
double _screenShortestSide() {
  final dispatcher = PlatformDispatcher.instance;
  for (final display in dispatcher.displays) {
    if (display.size.isEmpty || display.devicePixelRatio <= 0) continue;
    return (display.size / display.devicePixelRatio).shortestSide;
  }
  final views = dispatcher.views;
  if (views.isEmpty) return 0;
  final view = views.first;
  if (view.devicePixelRatio <= 0) return 0;
  return (view.physicalSize / view.devicePixelRatio).shortestSide;
}

/// Interface scale ("zoom"), persisted under `ui_scale`. Until the user moves
/// the slider it follows the screen ([autoUiScaleFor]); an empty saved value
/// means "never chosen".
final uiScaleProvider =
    NotifierProvider<UiScaleNotifier, double>(UiScaleNotifier.new);

class UiScaleNotifier extends Notifier<double> {
  UiScaleNotifier({
    double Function()? screenShortestSide,
    bool? mobileForm,
    Future<String?> Function(String key)? readSetting,
    Future<void> Function(String key, String value)? writeSetting,
  })  : _shortestSide = screenShortestSide ?? _screenShortestSide,
        _mobileForm = mobileForm,
        _read = readSetting ?? ((k) => storage_api.loadSetting(key: k)),
        _write = writeSetting ??
            ((k, v) => storage_api.saveSetting(key: k, value: v));

  final double Function() _shortestSide;
  final bool? _mobileForm;
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  bool _chosen = false;

  /// True once the user picked a scale; false while it follows the screen.
  bool get isChosen => _chosen;

  /// The scale this screen gets while nothing is chosen, and what Reset
  /// returns to.
  double get defaultScale => _clamp(autoUiScaleFor(
        _shortestSide(),
        mobileForm: _mobileForm ?? _isMobileForm,
      ));

  @override
  double build() => defaultScale;

  /// Called from `_bootstrap` once the store is open.
  Future<void> load() async {
    try {
      final val = await _read('ui_scale');
      final parsed = val == null ? null : double.tryParse(val);
      if (parsed == null) {
        _chosen = false;
        state = defaultScale;
        return;
      }
      _chosen = true;
      state = _clamp(parsed);
    } catch (e) {
      debugPrint('[HOLLOW] uiScale.load() failed: $e');
    }
  }

  /// Applies [scale] immediately, then persists. The state moves first so a
  /// keyboard zoom lands on the next frame instead of after a DB round trip; a
  /// failed write only costs the setting on next launch, so it is logged. A
  /// choice equal to the screen default still persists, so it stops following
  /// the screen.
  Future<void> setScale(double scale) async {
    final clamped = _clamp(scale);
    if (_chosen && state == clamped) return;
    _chosen = true;
    state = clamped;
    await _persist(clamped.toStringAsFixed(2));
  }

  /// Ctrl + / Ctrl −: move [steps] stops along the 5% grid.
  Future<void> nudge(int steps) =>
      setScale(snapScale(state) + steps * kUiScaleStep);

  /// Back to following the screen.
  Future<void> reset() async {
    final wasChosen = _chosen;
    _chosen = false;
    state = defaultScale;
    if (wasChosen) await _persist('');
  }

  Future<void> _persist(String value) async {
    try {
      await _write('ui_scale', value);
    } catch (e) {
      debugPrint('[HOLLOW] uiScale save failed: $e');
    }
  }

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
