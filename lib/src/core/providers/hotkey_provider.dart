import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_backend.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';
import 'package:hollow/src/core/services/hotkeys/inapp_key_backend.dart';
import 'package:hollow/src/core/services/hotkeys/win32_key_poller.dart';
import 'package:hollow/src/core/services/hotkeys/x11_key_poller.dart';

/// Voice hotkeys (issue #38): PTT + mute/deafen toggles, live ONLY while in
/// a voice channel or an active DM call. Kept alive by one `ref.watch` in
/// HollowShell (desktop builds). Exactly one backend handles each binding —
/// poller platforms (Windows, Linux X11) never double-register the in-app
/// handler for the same combo.
final hotkeyControllerProvider = Provider<HotkeyController>((ref) {
  final controller = HotkeyController(ref);
  ref.onDispose(controller.dispose);
  controller.init();
  return controller;
});

/// UI-only PTT state (issue #38 follow-up): the mic button must SHOW the
/// gate — mic reads muted while PTT idles and live while the key is held.
/// Deliberately outside VoiceChannelState/CallState (key edges must not
/// rebuild every call-state watcher); written only by [HotkeyController].
final pttStateProvider =
    StateProvider<({bool enabled, bool transmitting})>(
        (_) => (enabled: false, transmitting: false));

class HotkeyController {
  HotkeyController(this._ref);

  final Ref _ref;

  /// System-wide poller (Windows / Linux X11), null on macOS/Wayland or
  /// when initialization failed — the in-app backend covers everything then.
  HotkeyBackend? _poller;
  final InAppKeyBackend _inApp = InAppKeyBackend();

  Timer? _pttReleaseTimer;
  bool _running = false;
  bool _suspended = false;

  /// One-shot: the voice-hotkey settings providers load in build(), which
  /// runs the moment this controller LISTENS them — at app start, before
  /// storage is ready. That first load can cache the defaults forever
  /// (the load-persisted-settings-from-bootstrap-not-build trap), leaving
  /// PTT mode stuck on Voice Activity. Refresh them once when the first
  /// call starts — storage is definitely up by then, and the change
  /// listeners re-run everything with the real values.
  bool _settingsRefreshed = false;

  void init() {
    if (Platform.isWindows) {
      _poller = Win32KeyPoller.tryCreate();
    } else if (Platform.isLinux) {
      _poller = X11KeyPoller.tryCreate();
    }

    // Call lifecycle → start/stop the backends.
    _ref.listen(voiceChannelProvider.select((s) => s.isInVoiceChannel),
        (_, _) => _reevaluate());
    _ref.listen(callProvider.select((s) => s.status == CallStatus.active),
        (_, _) => _reevaluate());

    // Binding / mode / delay changes → restart with fresh config.
    _ref.listen(pttKeybindProvider, (_, _) => _reevaluate());
    _ref.listen(muteKeybindProvider, (_, _) => _reevaluate());
    _ref.listen(deafenKeybindProvider, (_, _) => _reevaluate());
    _ref.listen(voiceInputModeProvider, (_, _) {
      _pushMode();
      _reevaluate();
    });

    // Settings capture field armed → suspend so captures never fire actions.
    _ref.listen(keybindCaptureActiveProvider, (_, active) {
      _suspended = active;
      _reevaluate();
    });

    // Window blur: the in-app backend never gets its KeyUp — force-release.
    _ref.listen(windowFocusedProvider, (_, focused) {
      if (!focused) _inApp.releaseAll();
    });

    // Microtask: init() runs during this provider's OWN initialization,
    // where writing other providers (pttStateProvider, the notifiers'
    // mode push) is illegal in Riverpod.
    Future.microtask(() {
      _pushMode();
      _reevaluate();
    });
  }

  bool get _inCall =>
      _ref.read(voiceChannelProvider).isInVoiceChannel ||
      _ref.read(callProvider).status == CallStatus.active;

  bool get _pttMode =>
      (_ref.read(voiceInputModeProvider).valueOrNull ??
          kVoiceInputActivity) ==
      kVoiceInputPtt;

  /// Push the current input mode into both call notifiers (they gate the
  /// capture; this controller only reports key edges).
  void _pushMode() {
    final ptt = _pttMode;
    debugPrint('[HOLLOW-HOTKEY] Voice input mode → ${ptt ? 'PTT' : 'activity'}');
    _ref.read(voiceChannelProvider.notifier).setVoiceInputMode(ptt);
    _ref.read(callProvider.notifier).setVoiceInputMode(ptt);
    _ref.read(pttStateProvider.notifier).state =
        (enabled: ptt, transmitting: false);
  }

  void _reevaluate() {
    _stopBackends();
    if (!_inCall || _suspended) return;

    if (!_settingsRefreshed) {
      _settingsRefreshed = true;
      debugPrint('[HOLLOW-HOTKEY] First call — refreshing hotkey settings');
      _ref.invalidate(voiceInputModeProvider);
      _ref.invalidate(pttKeybindProvider);
      _ref.invalidate(muteKeybindProvider);
      _ref.invalidate(deafenKeybindProvider);
      _ref.invalidate(pttReleaseDelayProvider);
      // Continue with whatever we have now; the reloads fire the change
      // listeners, which push the mode + restart the backend with the
      // real values as each one lands.
    }

    final bindings = <HotkeyAction, HotkeyBinding>{};
    void add(HotkeyAction action, AsyncValue<String> value, String fallback) {
      final binding = HotkeyBinding.parse(value.valueOrNull ?? fallback);
      if (binding != null) bindings[action] = binding;
    }

    // PTT only participates in PTT mode — in Voice Activity its combo must
    // stay free for whatever else the user maps it to system-wide.
    if (_pttMode) {
      add(HotkeyAction.pushToTalk, _ref.read(pttKeybindProvider),
          'ctrl+space');
    }
    add(HotkeyAction.toggleMute, _ref.read(muteKeybindProvider),
        'ctrl+shift+m');
    add(HotkeyAction.toggleDeafen, _ref.read(deafenKeybindProvider),
        'ctrl+shift+d');
    if (bindings.isEmpty) return;

    final poller = _poller;
    if (poller == null) {
      _inApp.start(bindings, _onEdge, _isTextEditing);
    } else {
      // A binding the poller can't map (no VK/keysym entry) falls back to
      // the in-app backend — focused-only beats silently dead.
      final mapped = <HotkeyAction, HotkeyBinding>{};
      final unmapped = <HotkeyAction, HotkeyBinding>{};
      for (final e in bindings.entries) {
        final ok = Platform.isWindows
            ? e.value.windowsVk != null
            : e.value.x11Keysym != null;
        (ok ? mapped : unmapped)[e.key] = e.value;
      }
      if (mapped.isNotEmpty) poller.start(mapped, _onEdge, _isTextEditing);
      if (unmapped.isNotEmpty) {
        _inApp.start(unmapped, _onEdge, _isTextEditing);
      }
    }
    _running = true;
    debugPrint('[HOLLOW-HOTKEY] Backend started '
        '(${poller != null ? 'poller (system-wide)' : 'in-app'}): '
        '${bindings.entries.map((e) => '${e.key.name}=${e.value.serialize()}').join(', ')}');
  }

  void _stopBackends() {
    if (!_running) return;
    _running = false;
    _poller?.stop();
    _inApp.stop();
    _pttReleaseTimer?.cancel();
    _pttReleaseTimer = null;
    _routePtt(false);
  }

  /// Bare bindings must not fire while typing in Hollow itself. Pollers see
  /// keys with the window unfocused too — typing there is not our typing.
  bool _isTextEditing() {
    if (!_ref.read(windowFocusedProvider)) return false;
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _onEdge(HotkeyAction action, bool pressed) {
    debugPrint('[HOLLOW-HOTKEY] Edge: ${action.name} '
        '${pressed ? 'pressed' : 'released'}');
    switch (action) {
      case HotkeyAction.pushToTalk:
        _pttReleaseTimer?.cancel();
        _pttReleaseTimer = null;
        if (pressed) {
          _routePtt(true);
        } else {
          // Release delay: keep the mic open briefly so word ends survive.
          final ms = _ref.read(pttReleaseDelayProvider).valueOrNull ??
              kPttReleaseDefaultMs;
          _pttReleaseTimer = Timer(Duration(milliseconds: ms), () {
            _pttReleaseTimer = null;
            _routePtt(false);
          });
        }
      case HotkeyAction.toggleMute:
        if (!pressed) return;
        if (_ref.read(voiceChannelProvider).isInVoiceChannel) {
          _ref.read(voiceChannelProvider.notifier).toggleMute();
        } else if (_ref.read(callProvider).status == CallStatus.active) {
          _ref.read(callProvider.notifier).toggleMute();
        }
      case HotkeyAction.toggleDeafen:
        if (!pressed) return;
        if (_ref.read(voiceChannelProvider).isInVoiceChannel) {
          _ref.read(voiceChannelProvider.notifier).toggleDeafen();
        } else if (_ref.read(callProvider).status == CallStatus.active) {
          _ref.read(callProvider.notifier).toggleDeafen();
        }
    }
  }

  /// Both notifiers get the edge — only the live call acts on it (the gate
  /// is a no-op without a running service). try/catch: this also runs on
  /// provider dispose, when reading other providers may already be illegal.
  void _routePtt(bool active) {
    try {
      _ref.read(voiceChannelProvider.notifier).setPttTransmit(active);
      _ref.read(callProvider.notifier).setPttTransmit(active);
      final ptt = _ref.read(pttStateProvider);
      if (ptt.transmitting != active) {
        _ref.read(pttStateProvider.notifier).state =
            (enabled: ptt.enabled, transmitting: active);
      }
    } catch (e) {
      // Reached on provider dispose (expected); anything else must be LOUD —
      // a swallowed error here reads as "PTT silently does nothing".
      debugPrint('[HOLLOW-HOTKEY] PTT route failed: $e');
    }
  }

  void dispose() {
    _stopBackends();
  }
}
