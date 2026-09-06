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
import 'package:hollow/src/core/services/hotkeys/wayland_portal_backend.dart';
import 'package:hollow/src/core/services/hotkeys/win32_key_poller.dart';
import 'package:hollow/src/core/services/hotkeys/x11_key_poller.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Hotkey diagnostics must survive into RELEASE builds (hollow_debug.log): a
/// Windows PTT bug stayed undiagnosable because debugPrint has no installed build.
void _log(String msg) {
  debugPrint(msg);
  try {
    network_api.logFromDart(message: msg).catchError((_) {});
  } catch (_) {
    // FFI not up yet (tests, pre-init) — console-only then.
  }
}

/// Voice hotkeys (issue #38): PTT + mute/deafen toggles, live ONLY in a voice
/// channel or DM call. Exactly one backend handles each binding.
final hotkeyControllerProvider = Provider<HotkeyController>((ref) {
  final controller = HotkeyController(ref);
  ref.onDispose(controller.dispose);
  controller.init();
  return controller;
});

/// UI-only PTT state: the mic button must SHOW the gate. Outside
/// VoiceChannelState/CallState so key edges don't rebuild every watcher.
final pttStateProvider =
    StateProvider<({bool enabled, bool transmitting})>(
        (_) => (enabled: false, transmitting: false));

class HotkeyController {
  HotkeyController(this._ref, {@visibleForTesting HotkeyBackend? testPoller})
      : _testPoller = testPoller;

  final Ref _ref;

  /// Test seam: a fake system-wide backend so the controller's registration
  /// and edge routing are testable without user32/libX11.
  final HotkeyBackend? _testPoller;

  /// System-wide backend: Win32/X11 poller, or the Wayland GlobalShortcuts
  /// portal. Null on macOS / portal-less Wayland / init failure.
  HotkeyBackend? _poller;
  final InAppKeyBackend _inApp = InAppKeyBackend();

  Timer? _pttReleaseTimer;
  bool _running = false;
  bool _suspended = false;
  bool _disposed = false;

  /// One-shot: the voice-hotkey settings providers load in build(), which runs
  /// before storage is ready and can cache the defaults forever. Refresh once
  /// when the first call starts.
  bool _settingsRefreshed = false;

  void init() {
    if (_testPoller != null) {
      _poller = _testPoller;
    } else if (Platform.isWindows) {
      _poller = Win32KeyPoller.tryCreate();
    } else if (Platform.isLinux) {
      _poller = X11KeyPoller.tryCreate();
      if (_poller == null) {
        // Wayland: system-wide observation only exists via the XDG GlobalShortcuts
        // portal, whose availability is only knowable async. The in-app backend covers it.
        WaylandPortalBackend.detect().then((backend) {
          if (backend == null) return;
          if (_disposed) {
            backend.close();
            return;
          }
          _poller = backend;
          _log('[HOLLOW-HOTKEY] Wayland GlobalShortcuts portal backend up');
          _reevaluate();
        }).catchError((Object e) {
          _log('[HOLLOW-HOTKEY] Portal detection failed: $e');
        });
      }
    }

    _ref.listen(voiceChannelProvider.select((s) => s.isInVoiceChannel),
        (_, _) => _reevaluate());
    _ref.listen(callProvider.select((s) => s.status == CallStatus.active),
        (_, _) => _reevaluate());

    _ref.listen(pttKeybindProvider, (_, _) => _reevaluate());
    _ref.listen(muteKeybindProvider, (_, _) => _reevaluate());
    _ref.listen(deafenKeybindProvider, (_, _) => _reevaluate());
    _ref.listen(voiceInputModeProvider, (_, _) {
      _pushMode();
      _reevaluate();
    });
    // Keep the release delay LOADED: it is only read at a release edge, and
    // without a listener the first read returns AsyncLoading and uses the default.
    _ref.listen(pttReleaseDelayProvider, (_, _) {});

    // Settings capture field armed → suspend so captures never fire actions.
    _ref.listen(keybindCaptureActiveProvider, (_, active) {
      _suspended = active;
      _reevaluate();
    });

    // Window blur: the in-app backend never gets its KeyUp — force-release.
    _ref.listen(windowFocusedProvider, (_, focused) {
      if (!focused) _inApp.releaseAll();
    });

    // Microtask: init() runs during this provider's OWN initialization, where
    // writing other providers is illegal in Riverpod.
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
    _log('[HOLLOW-HOTKEY] Voice input mode → ${ptt ? 'PTT' : 'activity'}');
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
      _log('[HOLLOW-HOTKEY] First call — refreshing hotkey settings');
      _ref.invalidate(voiceInputModeProvider);
      _ref.invalidate(pttKeybindProvider);
      _ref.invalidate(muteKeybindProvider);
      _ref.invalidate(deafenKeybindProvider);
      _ref.invalidate(pttReleaseDelayProvider);
      // Continue with whatever we have now; the reloads fire the change listeners,
      // which push the mode and restart the backend as each real value lands.
    }

    final bindings = <HotkeyAction, HotkeyBinding>{};
    void add(HotkeyAction action, AsyncValue<String> value, String fallback) {
      final raw = value.valueOrNull;
      var binding = HotkeyBinding.parse(raw ?? fallback);
      if (binding == null && raw != null) {
        // A stored string the current parser can't read must not silently kill the
        // action, with nothing in the UI to say why.
        _log('[HOLLOW-HOTKEY] Stored ${action.name} binding "$raw" is '
            'unparseable — falling back to $fallback');
        binding = HotkeyBinding.parse(fallback);
      }
      if (binding != null) bindings[action] = binding;
    }

    // PTT only participates in PTT mode: in Voice Activity its combo stays free.
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
      // A binding the poller can't map falls back to the in-app backend.
      final mapped = <HotkeyAction, HotkeyBinding>{};
      final unmapped = <HotkeyAction, HotkeyBinding>{};
      for (final e in bindings.entries) {
        (poller.canHandle(e.value) ? mapped : unmapped)[e.key] = e.value;
      }
      if (mapped.isNotEmpty) poller.start(mapped, _onEdge, _isTextEditing);
      if (unmapped.isNotEmpty) {
        _inApp.start(unmapped, _onEdge, _isTextEditing);
      }
    }
    _running = true;
    final mode = _ref.read(voiceInputModeProvider);
    _log('[HOLLOW-HOTKEY] Backend started '
        '(${poller != null ? 'poller (system-wide)' : 'in-app'}): '
        '${bindings.entries.map((e) => '${e.key.name}=${e.value.serialize()}').join(', ')} '
        '| mode=${mode.valueOrNull ?? '<none>'}'
        '${mode.isLoading ? ' (loading)' : ''}'
        '${mode.hasError ? ' (ERROR: ${mode.error})' : ''}'
        ' pttMode=$_pttMode');
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
    _log('[HOLLOW-HOTKEY] Edge: ${action.name} '
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

  /// Both notifiers get the edge; only the live call acts on it. try/catch because
  /// this also runs on dispose, when reading other providers may be illegal.
  void _routePtt(bool active) {
    try {
      // UI state FIRST: the mic icon must reflect the key even if a notifier
      // throws below. A key press with zero visible reaction is undebuggable.
      final ptt = _ref.read(pttStateProvider);
      if (ptt.transmitting != active) {
        _ref.read(pttStateProvider.notifier).state =
            (enabled: ptt.enabled, transmitting: active);
      }
      _ref.read(voiceChannelProvider.notifier).setPttTransmit(active);
      _ref.read(callProvider.notifier).setPttTransmit(active);
    } catch (e) {
      // Reached on provider dispose (expected); anything else must be LOUD —
      // a swallowed error here reads as "PTT silently does nothing".
      _log('[HOLLOW-HOTKEY] PTT route failed: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _stopBackends();
    final poller = _poller;
    if (poller is WaylandPortalBackend) {
      // The portal session is kept across calls; only a teardown closes it.
      poller.close();
    }
  }
}
