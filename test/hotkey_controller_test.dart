// HotkeyController registration + edge-routing tests (issue #38 Windows PTT
// debugging). The Win32 poller's tick logic was verified standalone against
// real GetAsyncKeyState — these tests cover the layer above it: does the
// controller actually REGISTER the PTT binding (across slow settings loads
// and the first-call invalidate dance), and do edges reach pttStateProvider
// and the call notifiers?
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/hotkey_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_backend.dart';
import 'package:hollow/src/core/services/hotkeys/hotkey_binding.dart';

/// Records every start()'s binding set and exposes the edge callback so a
/// test can fire synthetic key edges.
class _RecordingBackend implements HotkeyBackend {
  final List<Map<HotkeyAction, HotkeyBinding>> starts = [];
  HotkeyEdgeCallback? onEdge;
  int stops = 0;

  @override
  bool get isSystemWide => true;

  @override
  bool canHandle(HotkeyBinding binding) => true;

  @override
  void start(
    Map<HotkeyAction, HotkeyBinding> bindings,
    HotkeyEdgeCallback onEdge,
    bool Function() isTextEditing,
  ) {
    starts.add(Map.of(bindings));
    this.onEdge = onEdge;
  }

  @override
  void stop() {
    stops++;
    onEdge = null;
  }
}

class _FakeModeNotifier extends VoiceInputModeNotifier {
  _FakeModeNotifier(this._load);
  final Future<String> Function() _load;
  @override
  Future<String> build() => _load();
}

class _FakeKeybindNotifier extends KeybindNotifier {
  _FakeKeybindNotifier(super.key, super.def, this._load);
  final Future<String> Function() _load;
  @override
  Future<String> build() => _load();
}

class _FakeReleaseDelayNotifier extends PttReleaseDelayNotifier {
  _FakeReleaseDelayNotifier(this.ms);
  final int ms;
  @override
  Future<int> build() async => ms;
}

class _TestVcNotifier extends VoiceChannelNotifier {
  @override
  VoiceChannelState build() => const VoiceChannelState();

  void enterVc() => state = state.copyWith(
        currentServerId: 'srv',
        currentChannelId: 'chan',
        currentChannelName: 'General',
      );

  void exitVc() => state = state.copyWith(clearCurrent: true);
}

Future<void> _flush([int turns = 6]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ({
    ProviderContainer container,
    _RecordingBackend backend,
    _TestVcNotifier Function() vc,
  }) makeRig({
    required Future<String> Function() loadMode,
    Future<String> Function()? loadPttKeybind,
    int releaseMs = 50,
  }) {
    final backend = _RecordingBackend();
    final controllerProvider = Provider<HotkeyController>((ref) {
      final c = HotkeyController(ref, testPoller: backend);
      ref.onDispose(c.dispose);
      c.init();
      return c;
    });
    final container = ProviderContainer(overrides: [
      voiceChannelProvider.overrideWith(_TestVcNotifier.new),
      voiceInputModeProvider.overrideWith(() => _FakeModeNotifier(loadMode)),
      pttKeybindProvider.overrideWith(() => _FakeKeybindNotifier(
          'ptt_keybind', 'ctrl+space',
          loadPttKeybind ?? () async => 'ctrl+space')),
      muteKeybindProvider.overrideWith(() => _FakeKeybindNotifier(
          'mute_keybind', 'ctrl+shift+m', () async => 'ctrl+shift+m')),
      deafenKeybindProvider.overrideWith(() => _FakeKeybindNotifier(
          'deafen_keybind', 'ctrl+shift+d', () async => 'ctrl+shift+d')),
      pttReleaseDelayProvider
          .overrideWith(() => _FakeReleaseDelayNotifier(releaseMs)),
    ]);
    addTearDown(container.dispose);
    container.read(controllerProvider);
    return (
      container: container,
      backend: backend,
      vc: () => container.read(voiceChannelProvider.notifier) as _TestVcNotifier,
    );
  }

  test('PTT registers when settings were loaded before the call', () async {
    final rig = makeRig(loadMode: () async => kVoiceInputPtt);
    await _flush();

    rig.vc().enterVc();
    await _flush();

    expect(rig.backend.starts, isNotEmpty,
        reason: 'joining a VC must start the backend');
    final last = rig.backend.starts.last;
    expect(last.keys, contains(HotkeyAction.pushToTalk),
        reason: 'PTT binding must be registered in PTT mode');
    expect(last[HotkeyAction.pushToTalk]!.serialize(), 'ctrl+space');
    expect(last.keys, contains(HotkeyAction.toggleMute));
    expect(last.keys, contains(HotkeyAction.toggleDeafen));
  });

  test('PTT registers even when the mode loads AFTER the call started',
      () async {
    // Simulates the field trap: storage slow/not ready, VC joined while the
    // mode provider is still AsyncLoading — the controller must re-register
    // once the real value lands.
    final modeReady = Completer<String>();
    final rig = makeRig(loadMode: () => modeReady.future);
    await _flush();

    rig.vc().enterVc();
    await _flush();
    // While loading, PTT may legitimately be absent…
    modeReady.complete(kVoiceInputPtt);
    await _flush();

    // …but once the load lands it MUST be registered.
    expect(rig.backend.starts.last.keys, contains(HotkeyAction.pushToTalk),
        reason: 'controller must self-heal after a late settings load');
  });

  test('mid-call settings invalidation (settings card open) keeps PTT alive',
      () async {
    final rig = makeRig(loadMode: () async => kVoiceInputPtt);
    await _flush();
    rig.vc().enterVc();
    await _flush();

    // audio_section.dart initState invalidates all five voice providers.
    rig.container.invalidate(voiceInputModeProvider);
    rig.container.invalidate(pttKeybindProvider);
    rig.container.invalidate(muteKeybindProvider);
    rig.container.invalidate(deafenKeybindProvider);
    rig.container.invalidate(pttReleaseDelayProvider);
    await _flush();

    expect(rig.backend.starts.last.keys, contains(HotkeyAction.pushToTalk));
  });

  test('unparseable stored PTT keybind falls back to the default', () async {
    final rig = makeRig(
      loadMode: () async => kVoiceInputPtt,
      loadPttKeybind: () async => 'bogus+nonsense',
    );
    await _flush();
    rig.vc().enterVc();
    await _flush();

    final last = rig.backend.starts.last;
    expect(last.keys, contains(HotkeyAction.pushToTalk),
        reason: 'a corrupt stored binding must not silently kill the action');
    expect(last[HotkeyAction.pushToTalk]!.serialize(), 'ctrl+space');
  });

  test('PTT edges reach pttStateProvider and honor the release delay',
      () async {
    final rig = makeRig(loadMode: () async => kVoiceInputPtt);
    await _flush();
    rig.vc().enterVc();
    await _flush();

    expect(rig.container.read(pttStateProvider).enabled, isTrue,
        reason: 'PTT mode must be reflected in pttStateProvider');
    expect(rig.container.read(pttStateProvider).transmitting, isFalse);

    rig.backend.onEdge!(HotkeyAction.pushToTalk, true);
    expect(rig.container.read(pttStateProvider).transmitting, isTrue,
        reason: 'press edge must open the PTT state immediately');

    rig.backend.onEdge!(HotkeyAction.pushToTalk, false);
    // Still transmitting during the release delay…
    expect(rig.container.read(pttStateProvider).transmitting, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(rig.container.read(pttStateProvider).transmitting, isFalse,
        reason: 'release delay must close the gate afterwards');
  });

  test('mute edge toggles the VC notifier', () async {
    final rig = makeRig(loadMode: () async => kVoiceInputPtt);
    await _flush();
    rig.vc().enterVc();
    await _flush();

    expect(rig.container.read(voiceChannelProvider).isMuted, isFalse);
    rig.backend.onEdge!(HotkeyAction.toggleMute, true);
    expect(rig.container.read(voiceChannelProvider).isMuted, isTrue);
    rig.backend.onEdge!(HotkeyAction.toggleMute, false); // release: no-op
    expect(rig.container.read(voiceChannelProvider).isMuted, isTrue);
  });

  test('leaving the call stops the backend and clears PTT state', () async {
    final rig = makeRig(loadMode: () async => kVoiceInputPtt);
    await _flush();
    rig.vc().enterVc();
    await _flush();
    rig.backend.onEdge!(HotkeyAction.pushToTalk, true);
    expect(rig.container.read(pttStateProvider).transmitting, isTrue);

    rig.vc().exitVc();
    await _flush();
    expect(rig.backend.stops, greaterThan(0));
    expect(rig.container.read(pttStateProvider).transmitting, isFalse,
        reason: 'leaving a call must never leave PTT stuck transmitting');
  });
}
