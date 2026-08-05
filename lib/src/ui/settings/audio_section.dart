import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/linux_pulse_capture.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/ringtone_clip_editor_dialog.dart';
import 'package:hollow/src/ui/settings/keybind_capture_field.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:record/record.dart' as rec;
import 'package:win32audio/win32audio.dart' as win32audio;

/// Audio & Video category of the desktop Settings dialog: device selection,
/// mic gain + Voice Enhancement chain controls, mic test, and ringtone.
class AudioVideoSettingsView extends StatelessWidget {
  const AudioVideoSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return settingsCardList([
      const SettingsCard(
        title: 'Devices',
        children: [_AudioDeviceSettings()],
      ),
      // Voice input mode + hotkeys (issue #38) — desktop only (hotkeys need
      // a keyboard; mobile transmits via voice activity).
      if (!Platform.isAndroid && !Platform.isIOS)
        const SettingsCard(
          title: 'Voice',
          children: [_VoiceInputSettings()],
        ),
    ]);
  }
}

/// Voice input mode (Voice Activity / Push-to-Talk) + call hotkeys.
class _VoiceInputSettings extends ConsumerStatefulWidget {
  const _VoiceInputSettings();

  @override
  ConsumerState<_VoiceInputSettings> createState() =>
      _VoiceInputSettingsState();
}

class _VoiceInputSettingsState extends ConsumerState<_VoiceInputSettings> {
  @override
  void initState() {
    super.initState();
    // These providers may have loaded BEFORE storage was ready at app start
    // and cached the defaults (the bootstrap-not-build settings trap) —
    // re-read from disk whenever the card opens so the chips show truth.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(voiceInputModeProvider);
      ref.invalidate(pttKeybindProvider);
      ref.invalidate(muteKeybindProvider);
      ref.invalidate(deafenKeybindProvider);
      ref.invalidate(pttReleaseDelayProvider);
    });
  }

  SliderThemeData _slimSliderTheme(HollowTheme hollow) {
    return SliderThemeData(
      activeTrackColor: hollow.accent,
      inactiveTrackColor: hollow.border,
      thumbColor: hollow.accent,
      overlayColor: hollow.accent.withValues(alpha: 0.08),
      trackHeight: 2,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
    );
  }

  Widget _keybindRow(
    HollowTheme hollow, {
    required IconData icon,
    required String label,
    required String serialized,
    required ValueChanged<String> onChanged,
    required String semanticLabel,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            label,
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ),
        KeybindCaptureField(
          serialized: serialized,
          onChanged: onChanged,
          semanticLabel: semanticLabel,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final mode = ref.watch(voiceInputModeProvider).valueOrNull ??
        kVoiceInputActivity;
    final isPtt = mode == kVoiceInputPtt;
    final pttBind =
        ref.watch(pttKeybindProvider).valueOrNull ?? 'ctrl+space';
    final muteBind =
        ref.watch(muteKeybindProvider).valueOrNull ?? 'ctrl+shift+m';
    final deafenBind =
        ref.watch(deafenKeybindProvider).valueOrNull ?? 'ctrl+shift+d';
    final releaseMs = ref.watch(pttReleaseDelayProvider).valueOrNull ??
        kPttReleaseDefaultMs;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Input mode chips (selection state = chips, never filled buttons).
        Row(
          children: [
            Text(
              'Input mode',
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            _EngineChip(
              label: 'Voice Activity',
              hint: 'always on',
              isSelected: !isPtt,
              onTap: () => ref
                  .read(voiceInputModeProvider.notifier)
                  .setMode(kVoiceInputActivity),
            ),
            const SizedBox(width: HollowSpacing.xs),
            _EngineChip(
              label: 'Push to Talk',
              hint: 'hold a key',
              isSelected: isPtt,
              onTap: () => ref
                  .read(voiceInputModeProvider.notifier)
                  .setMode(kVoiceInputPtt),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        // PTT-only rows — dimmed + inert in Voice Activity mode.
        AnimatedOpacity(
          duration: const Duration(milliseconds: 150),
          opacity: isPtt ? 1.0 : 0.4,
          child: IgnorePointer(
            ignoring: !isPtt,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _keybindRow(
                  hollow,
                  icon: LucideIcons.mic,
                  label: 'Push-to-talk key (hold to transmit)',
                  serialized: pttBind,
                  onChanged: (v) =>
                      ref.read(pttKeybindProvider.notifier).setBinding(v),
                  semanticLabel: 'Set push-to-talk key',
                ),
                const SizedBox(height: HollowSpacing.xs),
                Row(
                  children: [
                    Icon(LucideIcons.timer,
                        size: 14, color: hollow.textSecondary),
                    const SizedBox(width: HollowSpacing.sm),
                    Text(
                      'Release delay',
                      style: HollowTypography.bodySmall.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.md),
                    Expanded(
                      child: SliderTheme(
                        data: _slimSliderTheme(hollow),
                        child: Slider(
                          value: releaseMs.toDouble().clamp(0, 1000),
                          min: 0,
                          max: 1000,
                          divisions: 20,
                          onChanged: (v) => ref
                              .read(pttReleaseDelayProvider.notifier)
                              .setDelay(v.round()),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '$releaseMs ms',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.accentText,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _keybindRow(
          hollow,
          icon: LucideIcons.micOff,
          label: 'Toggle mute',
          serialized: muteBind,
          onChanged: (v) =>
              ref.read(muteKeybindProvider.notifier).setBinding(v),
          semanticLabel: 'Set mute toggle hotkey',
        ),
        const SizedBox(height: HollowSpacing.xs),
        _keybindRow(
          hollow,
          icon: LucideIcons.headphoneOff,
          label: 'Toggle deafen',
          serialized: deafenBind,
          onChanged: (v) =>
              ref.read(deafenKeybindProvider.notifier).setBinding(v),
          semanticLabel: 'Set deafen toggle hotkey',
        ),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Hotkeys are active while you are in a call. They work '
          'system-wide on Windows and Linux (X11); on macOS and Wayland '
          'they work while Hollow is focused. Ctrl+Shift+M now toggles '
          'mute — the member panel moved to Ctrl+Shift+P.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textTertiary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

/// Audio device selection + mic test for the System tab.
class _AudioDeviceSettings extends ConsumerStatefulWidget {
  const _AudioDeviceSettings();

  @override
  ConsumerState<_AudioDeviceSettings> createState() =>
      _AudioDeviceSettingsState();
}

/// Cross-platform shape for audio device listings — wraps either a
/// `win32audio.AudioDevice` on Windows or a `webrtc.MediaDeviceInfo` on
/// macOS/Linux so the dropdowns can render either uniformly.
typedef _AudioDeviceInfo = ({String id, String name, bool isActive});

class _AudioDeviceSettingsState extends ConsumerState<_AudioDeviceSettings> {
  List<_AudioDeviceInfo> _audioInputs = [];
  List<_AudioDeviceInfo> _audioOutputs = [];
  List<webrtc.MediaDeviceInfo> _cameras = [];
  bool _loading = true;
  bool _micTesting = false;
  AudioPlayer? _ringtonePreview;
  // Mic test (issue #40, final design): record the RAW microphone (no
  // WebRTC session at all — `record` package / LinuxPulseCapture at 48 kHz
  // mono), then offline-render it through a FRESH instance of the real
  // capture chain (hollowRenderVoiceWav — same C++ as live calls: AI-NS +
  // EQ + gate/upward + compressor + de-esser + limiter, dynamic servo
  // included), then A/B raw vs processed. Phases: idle → recording
  // (_micTesting) → rendering (_micRendering) → review (_micTestReviewing).
  rec.AudioRecorder? _micRecorder;
  LinuxPulseCapture? _micPulse;
  StreamSubscription<Uint8List>? _micChunkSub;
  BytesBuilder? _micPcmBuf;
  static const int _micRecRate = 48000;
  String? _micTestRawPath; // raw take (WAV)
  String? _micTestRecPath; // processed render (WAV)
  bool _micRendering = false;
  bool _micTestReviewing = false;
  bool _micProcessedOk = false;
  AudioPlayer? _micTestPlayer;
  String? _micPlayingPath; // which take is playing (raw/processed), if any
  Timer? _micTestCapTimer;
  // Highest capture level seen while recording (dBFS; -100 = never) — the
  // one number that discriminates "mic delivered nothing" from a recorder
  // bug (the 2026-08-05 debugging lesson).
  double _micTestPeakDb = -100.0;

  /// Mic-test diagnostics MUST reach hollow_debug.log (debugPrint is
  /// invisible in installed/release builds — the hotkey lesson).
  void _micLog(String msg) {
    debugPrint('[MIC-TEST] $msg');
    network_api.logFromDart(message: '[MIC-TEST] $msg').catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _stopMicCapture();
    _stopMicTestPlayback();
    _deleteMicTestFiles();
    _stopRingtonePreview();
    super.dispose();
  }

  void _deleteMicTestFiles() {
    for (final path in [_micTestRawPath, _micTestRecPath]) {
      if (path != null) {
        try {
          File(path).deleteSync();
        } catch (_) {}
      }
    }
    _micTestRawPath = null;
    _micTestRecPath = null;
  }

  Future<void> _startRingtonePreview(double volume) async {
    final path = ref.read(ringtonePathProvider).valueOrNull;
    final hasCustom =
        path != null && path.isNotEmpty && File(path).existsSync();

    _ringtonePreview = AudioPlayer();
    await _ringtonePreview!.setReleaseMode(ReleaseMode.loop);
    await _ringtonePreview!.setVolume(volume);
    await _ringtonePreview!.play(hasCustom
        ? DeviceFileSource(path)
        : AssetSource('sounds/default_ringtone.wav'));
  }

  void _stopRingtonePreview() {
    _ringtonePreview?.stop();
    _ringtonePreview?.dispose();
    _ringtonePreview = null;
  }

  Future<void> _showRingtoneClipEditor(
      BuildContext context, WidgetRef ref, String filePath) async {
    showRingtoneClipEditor(context, filePath);
  }

  /// Parse the `{input: [...], output: [...]}` map returned by the fork's
  /// native audio enumeration handlers (`hollowMacAudioDevices` /
  /// `hollowLinuxAudioDevices`) into the uniform record shape.
  static (List<_AudioDeviceInfo>, List<_AudioDeviceInfo>) _parseNativeDevices(
      Map<dynamic, dynamic> res) {
    List<_AudioDeviceInfo> parse(List<dynamic> raw) => raw
        .whereType<Map>()
        .map((m) => (
              id: (m['id'] as String?) ?? '',
              name: (m['name'] as String?) ?? '',
              isActive: m['isDefault'] == true || m['isDefault'] == 1,
            ))
        .where((d) => d.id.isNotEmpty)
        .toList();
    final ins = (res['input'] as List?) ?? const [];
    final outs = (res['output'] as List?) ?? const [];
    return (parse(ins), parse(outs));
  }

  /// Invoke one of the fork's native audio enumeration handlers and parse the
  /// result. Used for macOS (CoreAudio via `hollowMacAudioDevices`) and Linux
  /// (libpulse via `hollowLinuxAudioDevices`) — both share the result shape.
  Future<(List<_AudioDeviceInfo>, List<_AudioDeviceInfo>)?>
      _invokeNativeAudioEnum(String method, String logLabel) async {
    try {
      const channel = MethodChannel('FlutterWebRTC.Method');
      final res = await channel.invokeMethod<Map<dynamic, dynamic>>(method);
      if (res == null) return null;
      final parsed = _parseNativeDevices(res);
      debugPrint('[HOLLOW] $logLabel enum: ${parsed.$1.length} inputs, '
          '${parsed.$2.length} outputs');
      return parsed;
    } catch (e) {
      debugPrint('[HOLLOW] $logLabel enumeration failed: $e');
      return null;
    }
  }

  /// macOS: the WebRTC-SDK pinned by flutter_webrtc returns an empty
  /// audioDeviceModule.inputDevices/outputDevices list, so we enumerate
  /// audio devices through CoreAudio directly via a native method channel
  /// exposed by our fork (`hollowMacAudioDevices`). Microphone access
  /// still needs to be granted; we probe it with a short getUserMedia to
  /// trigger the system prompt before showing the picker.
  Future<(List<_AudioDeviceInfo>, List<_AudioDeviceInfo>)?>
      _enumerateMacAudio() async {
    try {
      final stream = await webrtc.navigator.mediaDevices
          .getUserMedia({'audio': true, 'video': false});
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
    } catch (e) {
      debugPrint('[HOLLOW] mic permission probe failed: $e');
    }

    return _invokeNativeAudioEnum('hollowMacAudioDevices', 'CoreAudio');
  }

  /// Windows audio enumeration via `win32audio`.
  Future<(List<_AudioDeviceInfo>, List<_AudioDeviceInfo>)?>
      _enumerateWindowsAudio() async {
    try {
      final inDevices =
          await win32audio.Audio.enumDevices(win32audio.AudioDeviceType.input);
      final inputs = (inDevices ?? [])
          .map((d) => (id: d.id, name: d.name, isActive: d.isActive))
          .toList();
      final outDevices =
          await win32audio.Audio.enumDevices(win32audio.AudioDeviceType.output);
      final outputs = (outDevices ?? [])
          .map((d) => (id: d.id, name: d.name, isActive: d.isActive))
          .toList();
      return (inputs, outputs);
    } catch (e) {
      debugPrint('[HOLLOW] win32audio enumeration failed: $e');
      return null;
    }
  }

  /// Auto-select the system active device if the user hasn't chosen one.
  void _autoSelectDefaults(
    List<_AudioDeviceInfo> inputs,
    List<_AudioDeviceInfo> outputs,
    List<webrtc.MediaDeviceInfo> cameras,
  ) {
    final savedInput = ref.read(audioInputDeviceProvider).valueOrNull;
    if (savedInput == null && inputs.isNotEmpty) {
      final active =
          inputs.firstWhere((d) => d.isActive, orElse: () => inputs.first);
      ref.read(audioInputDeviceProvider.notifier).setDevice(active.id);
    }
    final savedOutput = ref.read(audioOutputDeviceProvider).valueOrNull;
    if (savedOutput == null && outputs.isNotEmpty) {
      final active =
          outputs.firstWhere((d) => d.isActive, orElse: () => outputs.first);
      ref.read(audioOutputDeviceProvider.notifier).setDevice(active.id);
    }
    final savedCamera = ref.read(cameraDeviceProvider).valueOrNull;
    if (savedCamera == null && cameras.isNotEmpty) {
      ref.read(cameraDeviceProvider.notifier).setDevice(cameras.first.deviceId);
    }
  }

  Future<void> _loadDevices() async {
    try {
      List<_AudioDeviceInfo> inputs = [];
      List<_AudioDeviceInfo> outputs = [];
      List<webrtc.MediaDeviceInfo> cameras = [];

      if (Platform.isMacOS) {
        final mac = await _enumerateMacAudio();
        if (mac != null) {
          inputs = mac.$1;
          outputs = mac.$2;
        }
      }

      // Camera always comes from flutter_webrtc's `enumerateDevices()` (the
      // V4L2 video path works on Linux). Windows audio uses `win32audio`
      // (block below); Linux audio uses a native libpulse enumeration below.
      try {
        final devices = await webrtc.navigator.mediaDevices.enumerateDevices();
        cameras = devices.where((d) => d.kind == 'videoinput').toList();
      } catch (e) {
        debugPrint('[HOLLOW] Device enumeration (webrtc) failed: $e');
      }

      // Linux: the prebuilt libwebrtc AudioDeviceModule reports 0 mic/speaker
      // devices on pipewire-pulse systems (falls back to AudioDeviceDummy), so
      // `enumerateDevices()` returns no audioinput/audiooutput entries even
      // though the camera enumerates fine. Enumerate audio directly via
      // libpulse through our fork's native handler.
      if (Platform.isLinux) {
        final linux = await _invokeNativeAudioEnum(
            'hollowLinuxAudioDevices', 'libpulse');
        if (linux != null) {
          inputs = linux.$1;
          outputs = linux.$2;
        }
      }

      if (Platform.isWindows) {
        final win = await _enumerateWindowsAudio();
        if (win != null) {
          inputs = win.$1;
          outputs = win.$2;
        }
      }

      if (!mounted) return;
      setState(() {
        _audioInputs = inputs;
        _audioOutputs = outputs;
        _cameras = cameras;
        _loading = false;
      });

      _autoSelectDefaults(inputs, outputs, cameras);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Record-raw / render-offline / A-B review mic test (issue #40, final
  /// design). The raw microphone is captured at 48 kHz mono with NO WebRTC
  /// involved (`record` package; LinuxPulseCapture on Linux), then the take
  /// is rendered through a FRESH instance of the real native capture chain
  /// (`hollowRenderVoiceWav` — same C++ as live calls: AI-NS, EQ, gate +
  /// upward compression, compressor, de-esser, limiter, dynamic servo),
  /// and the user can play raw vs processed side by side.
  Future<void> _startMicTest() async {
    if (_micTesting || _micRendering || !mounted) return;

    // Re-record: drop any previous take before claiming the mic again.
    await _stopMicTestPlayback();
    _discardMicTestRecording();
    if (!mounted) return;

    // The test claims the mic and the process-global capture chain — refuse
    // while a call or voice channel is live rather than fight it for both.
    final inCall = ref.read(callProvider).status != CallStatus.idle;
    final inVoiceChannel =
        ref.read(voiceChannelProvider).currentChannelId != null;
    if (inCall || inVoiceChannel) {
      HollowToast.show(
          context, 'Leave the call before running the microphone test.',
          type: HollowToastType.info);
      return;
    }

    final selectedInput = ref.read(audioInputDeviceProvider).valueOrNull;
    final aiNs = ref.read(noiseSuppressAiProvider).valueOrNull ?? false;
    final enhance = ref.read(voiceEnhanceProvider).valueOrNull ?? true;
    final dynMode = ref.read(voiceEnhanceDynamicProvider).valueOrNull ?? true;

    try {
      // RAW capture — deliberately NO WebRTC session (final design after
      // the 2026-08-05 six-round field saga): the loopback-PC approach ran
      // the APM at session-dependent shapes that never matched real calls.
      // The raw mic is recorded at 48 kHz mono and the take is then
      // offline-rendered through a fresh instance of the SAME native chain
      // calls use (hollowRenderVoiceWav).
      final buf = BytesBuilder(copy: false);
      _micPcmBuf = buf;
      _micTestPeakDb = -100.0;

      Stream<Uint8List> chunks;
      if (Platform.isLinux) {
        // Linux NEVER via `record` (needs parecord, absent on PipeWire).
        final pulse = await LinuxPulseCapture.start(
          device: (selectedInput != null && selectedInput.isNotEmpty)
              ? selectedInput
              : null,
          sampleRate: _micRecRate,
          channels: 1,
        );
        _micPulse = pulse;
        chunks = pulse.chunks;
      } else {
        final recorder = rec.AudioRecorder();
        _micRecorder = recorder;
        try {
          chunks = await recorder.startStream(rec.RecordConfig(
            encoder: rec.AudioEncoder.pcm16bits,
            numChannels: 1,
            sampleRate: _micRecRate,
            device: (selectedInput != null && selectedInput.isNotEmpty)
                ? rec.InputDevice(id: selectedInput, label: '')
                : null,
          ));
        } catch (e) {
          // The stored id may come from a different enumerator than
          // `record`'s — fall back to the system default, visibly logged.
          _micLog('startStream with device failed ($e) — retrying default');
          chunks = await recorder.startStream(const rec.RecordConfig(
            encoder: rec.AudioEncoder.pcm16bits,
            numChannels: 1,
            sampleRate: _micRecRate,
          ));
        }
      }

      _micChunkSub = chunks.listen((chunk) {
        buf.add(chunk);
        // Peak kept for the [MIC-TEST] log line only — the on-screen level
        // meter was removed (it didn't track the record-package chunks
        // reliably in the field; the A/B playback is the real feedback).
        final level = _levelFromPcm16(chunk);
        if (level.db > _micTestPeakDb) _micTestPeakDb = level.db;
      });

      _micLog('start: input=${selectedInput ?? "default"} aiNs=$aiNs '
          'enhance=$enhance dyn=$dynMode rawRate=$_micRecRate');

      if (!mounted) {
        await _stopMicCapture();
        return;
      }
      setState(() => _micTesting = true);

      // The dynamic servo needs a few seconds of speech to settle; cap the
      // take at 10 s so an abandoned test can't record forever.
      _micTestCapTimer = Timer(const Duration(seconds: 10), () {
        _finishMicRecording();
      });
    } catch (e) {
      await _stopMicCapture();
      if (!mounted) return;
      HollowToast.show(context, 'Microphone error: $e',
          type: HollowToastType.error);
    }
  }

  /// RMS of a PCM16LE chunk → (dBFS, 0..1 bar) with the same -60..0 mapping
  /// the old meter used.
  static ({double db, double bar}) _levelFromPcm16(Uint8List chunk) {
    final samples =
        Int16List.view(chunk.buffer, chunk.offsetInBytes, chunk.length >> 1);
    if (samples.isEmpty) return (db: -100.0, bar: 0.0);
    double sumSq = 0;
    for (final s in samples) {
      sumSq += s.toDouble() * s.toDouble();
    }
    final rms = math.sqrt(sumSq / samples.length);
    final db =
        rms <= 1 ? -100.0 : 20.0 * math.log(rms / 32768.0) / math.ln10;
    const minDb = -60.0;
    final clamped = db.clamp(minDb, 0.0);
    return (db: db, bar: (clamped - minDb) / (0.0 - minDb));
  }

  /// Canonical 44-byte-header mono 16-bit WAV wrapper around raw PCM16LE.
  static Uint8List _wavFromPcm16(Uint8List pcm, int rate) {
    final header = ByteData(44);
    void ascii(int off, String s) {
      for (var i = 0; i < s.length; i++) {
        header.setUint8(off + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, 1, Endian.little); // mono
    header.setUint32(24, rate, Endian.little);
    header.setUint32(28, rate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);
    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(pcm))
        .takeBytes();
  }

  /// Recording → rendering → review: stop capture, write the raw WAV, run
  /// it through the native chain, surface both takes for A/B playback.
  Future<void> _finishMicRecording() async {
    if (!_micTesting) return;
    await _stopMicCapture();
    if (!mounted) return;

    final pcm = _micPcmBuf?.takeBytes() ?? Uint8List(0);
    _micPcmBuf = null;
    _micLog('finish: rawBytes=${pcm.length} '
        'peakDb=${_micTestPeakDb.toStringAsFixed(1)}');

    // Name the device we actually recorded from — a stale Settings pick is
    // the failure users can't see otherwise (2026-08-05 field round).
    final inputId = ref.read(audioInputDeviceProvider).valueOrNull;
    final matches = _audioInputs.where((d) => d.id == inputId).toList();
    final deviceLabel = matches.isEmpty
        ? 'the selected microphone'
        : '"${matches.first.name}"';
    if (pcm.length < _micRecRate ~/ 5) {
      // Under ~100 ms of audio: the capture never really ran.
      HollowToast.show(
          context,
          'No audio arrived from $deviceLabel — check the Input device '
          'selected above.',
          type: HollowToastType.error);
      return;
    }

    final tempDir = Directory('$hollowDataDir${Platform.pathSeparator}temp');
    if (!tempDir.existsSync()) tempDir.createSync(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final rawPath = '${tempDir.path}${Platform.pathSeparator}'
        'mic_test_${stamp}_raw.wav';
    final outPath =
        '${tempDir.path}${Platform.pathSeparator}mic_test_$stamp.wav';
    File(rawPath).writeAsBytesSync(_wavFromPcm16(pcm, _micRecRate));
    _micTestRawPath = rawPath;
    _micTestRecPath = outPath;

    // Offline-render through the real chain with the CURRENT knobs.
    final aiNs = ref.read(noiseSuppressAiProvider).valueOrNull ?? false;
    final engine = noiseSuppressEngineToNative(
        ref.read(noiseSuppressEngineProvider).valueOrNull ??
            kNoiseSuppressEngineRnnoise);
    final micGain = ref.read(micGainProvider).valueOrNull ?? kMicGainDefault;
    final enhance = ref.read(voiceEnhanceProvider).valueOrNull ?? true;
    final dynMode = ref.read(voiceEnhanceDynamicProvider).valueOrNull ?? true;
    final strength = ref.read(voiceEnhanceStrengthProvider).valueOrNull ??
        kEnhanceStrengthDefault;
    setState(() => _micRendering = true);
    var ok = false;
    try {
      ok = await webrtc.Helper.renderVoiceWav(
        inPath: rawPath,
        outPath: outPath,
        gain: micGain,
        enhance: enhance,
        makeupDb: enhanceStrengthToMakeupDb(strength),
        dynamicMode: dynMode,
        aiNs: aiNs,
        engine: engine,
      );
    } catch (e) {
      _micLog('render failed: $e');
    }
    _micProcessedOk =
        ok && File(outPath).existsSync() && File(outPath).lengthSync() > 44;
    _micLog('render: ok=$_micProcessedOk aiNs=$aiNs enhance=$enhance '
        'dyn=$dynMode');
    if (!mounted) return;
    setState(() {
      _micRendering = false;
      _micTestReviewing = true;
    });
    if (!_micProcessedOk) {
      HollowToast.show(
          context,
          'Voice processing failed — only the raw recording is available.',
          type: HollowToastType.error);
    }
  }

  Future<void> _playMicTest(String path) async {
    await _stopMicTestPlayback();
    final player = AudioPlayer();
    _micTestPlayer = player;
    player.onPlayerComplete.listen((_) {
      if (mounted) setState(() => _micPlayingPath = null);
    });
    await player.play(DeviceFileSource(path));
    if (mounted) setState(() => _micPlayingPath = path);
  }

  Future<void> _stopMicTestPlayback() async {
    final player = _micTestPlayer;
    _micTestPlayer = null;
    if (player != null) {
      try {
        await player.stop();
      } catch (_) {}
      try {
        await player.dispose();
      } catch (_) {}
    }
    if (mounted && _micPlayingPath != null) {
      setState(() => _micPlayingPath = null);
    } else {
      _micPlayingPath = null;
    }
  }

  void _discardMicTestRecording() {
    _deleteMicTestFiles();
    _micProcessedOk = false;
    if (mounted && _micTestReviewing) {
      setState(() => _micTestReviewing = false);
    } else {
      _micTestReviewing = false;
    }
  }

  /// Stop the raw capture and release the device (any platform backend).
  Future<void> _stopMicCapture() async {
    _micTestCapTimer?.cancel();
    _micTestCapTimer = null;
    await _micChunkSub?.cancel();
    _micChunkSub = null;
    final recorder = _micRecorder;
    _micRecorder = null;
    if (recorder != null) {
      try {
        await recorder.stop();
      } catch (_) {}
      try {
        await recorder.dispose();
      } catch (_) {}
    }
    final pulse = _micPulse;
    _micPulse = null;
    if (pulse != null) {
      try {
        await pulse.stop();
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _micTesting = false);
    } else {
      _micTesting = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final selectedInput = ref.watch(audioInputDeviceProvider).valueOrNull;

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.md),
        child: Text(
          'Loading devices...',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Microphone input (win32audio)
        _buildMicrophoneRow(hollow, selectedInput),
        const SizedBox(height: HollowSpacing.sm),

        // Mic gain slider (locked while Dynamic mode auto-levels)
        _buildMicGainSlider(hollow),
        Padding(
          padding: const EdgeInsets.only(left: 30, top: 4),
          child: Text(
            'Boosts your outgoing voice (applies live during calls). '
            'A limiter prevents clipping.',
            style:
                HollowTypography.caption.copyWith(color: hollow.textSecondary),
          ),
        ),
        const SizedBox(height: HollowSpacing.md),

        // Voice enhancement (EQ + compressor + limiter chain)
        _buildEnhanceToggle(),
        const SizedBox(height: HollowSpacing.sm),

        // Dynamic mode (auto-level servo)
        _buildDynamicToggle(),
        const SizedBox(height: HollowSpacing.xs),

        // Enhancement strength (compressor makeup gain; locked in Dynamic)
        _buildStrengthSlider(hollow),
        const SizedBox(height: HollowSpacing.sm),

        // AI noise suppression (DeepFilterNet3, head of the capture chain)
        _buildNoiseSuppressAiToggle(),
        const SizedBox(height: HollowSpacing.md),

        // Speaker output (win32audio)
        _buildSpeakerRow(hollow),
        const SizedBox(height: HollowSpacing.md),

        // Camera (flutter_webrtc enumerateDevices)
        if (_cameras.isNotEmpty) _buildCameraRow(hollow),
        if (_cameras.isNotEmpty) const SizedBox(height: HollowSpacing.md),

        // Audio quality preset
        _buildQualityRow(hollow),
        const SizedBox(height: HollowSpacing.md),

        // Mic test button + volume meter
        _buildMicTestRow(hollow),
        if (_micTesting || _micTestReviewing)
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 4),
            child: Text(
              _micTesting
                  ? 'Recording through your full voice processing — speak a '
                      'sentence, then press Stop (auto-stops at 10s).'
                  : 'Play it back to hear exactly what others hear in a call '
                      '— noise suppression, enhancement and gain included.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
                fontSize: 10,
              ),
            ),
          ),
        const SizedBox(height: HollowSpacing.xs),

        // Refresh devices
        Row(
          children: [
            Icon(LucideIcons.refreshCw, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              onPressed: () {
                setState(() => _loading = true);
                _loadDevices();
              },
              compact: true,
              child: const Text('Refresh Devices'),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.lg),

        // Ringtone selector
        Row(
          children: [
            Icon(LucideIcons.bellRing, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Ringtone',
              style: HollowTypography.caption.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        _buildRingtoneFileRow(hollow),
        const SizedBox(height: HollowSpacing.sm),

        // Ringtone volume slider
        _buildRingtoneVolumeRow(hollow),
        const SizedBox(height: HollowSpacing.xs),

        // 30s info label
        Text(
          'Ringtone plays for up to 30 seconds during incoming calls.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary.withValues(alpha: 0.6),
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _buildMicrophoneRow(HollowTheme hollow, String? selectedInput) {
    return _buildDeviceRow(
      hollow: hollow,
      icon: LucideIcons.mic,
      label: 'Microphone',
      items: _audioInputs
          .map((d) => DropdownMenuItem<String?>(
                value: d.id,
                child: Text(
                  d.name.isNotEmpty
                      ? d.name
                      : 'Device ${d.id.substring(0, 8.clamp(0, d.id.length))}',
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      selectedValue: _resolveInputValue(selectedInput),
      onChanged: (deviceId) {
        if (deviceId != null) {
          ref.read(audioInputDeviceProvider.notifier).setDevice(deviceId);
        }
      },
    );
  }

  Widget _buildSpeakerRow(HollowTheme hollow) {
    final selectedOutput = ref.watch(audioOutputDeviceProvider).valueOrNull;
    return _buildDeviceRow(
      hollow: hollow,
      icon: LucideIcons.volume2,
      label: 'Speaker',
      items: _audioOutputs
          .map((d) => DropdownMenuItem<String?>(
                value: d.id,
                child: Text(
                  d.name.isNotEmpty
                      ? d.name
                      : 'Device ${d.id.substring(0, 8.clamp(0, d.id.length))}',
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      selectedValue: _resolveOutputValue(selectedOutput),
      onChanged: (deviceId) {
        if (deviceId != null) {
          ref.read(audioOutputDeviceProvider.notifier).setDevice(deviceId);
          webrtc.Helper.selectAudioOutput(deviceId).catchError((e) {
            debugPrint('[HOLLOW] selectAudioOutput failed: $e');
          });
        }
      },
    );
  }

  Widget _buildCameraRow(HollowTheme hollow) {
    final selectedCamera = ref.watch(cameraDeviceProvider).valueOrNull;
    return _buildDeviceRow(
      hollow: hollow,
      icon: LucideIcons.camera,
      label: 'Camera',
      items: _cameras
          .map((d) => DropdownMenuItem<String?>(
                value: d.deviceId,
                child: Text(
                  d.label.isNotEmpty
                      ? d.label
                      : 'Camera ${d.deviceId.substring(0, d.deviceId.length.clamp(0, 8))}',
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      selectedValue: _resolveCameraValue(selectedCamera),
      onChanged: (deviceId) {
        if (deviceId != null) {
          ref.read(cameraDeviceProvider.notifier).setDevice(deviceId);
        }
      },
    );
  }

  Widget _buildQualityRow(HollowTheme hollow) {
    return _buildDeviceRow(
      hollow: hollow,
      icon: LucideIcons.sliders,
      label: 'Audio Quality',
      items: AudioQualityPreset.values
          .map((p) => DropdownMenuItem<String?>(
                value: p.name,
                child: Text(
                  '${p.label} — ${p.bitrate ~/ 1000} kbps${p.stereo ? ' stereo' : ' mono'}',
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      selectedValue: ref.watch(audioQualityProvider).valueOrNull?.name ??
          AudioQualityPreset.voice.name,
      onChanged: (value) {
        if (value != null) {
          final preset = AudioQualityPreset.values.firstWhere(
            (p) => p.name == value,
            orElse: () => AudioQualityPreset.voice,
          );
          ref.read(audioQualityProvider.notifier).setPreset(preset);
        }
      },
    );
  }

  /// Slim slider theme shared by the gain + strength sliders.
  SliderThemeData _slimSliderTheme(HollowTheme hollow) {
    return SliderThemeData(
      activeTrackColor: hollow.accent,
      inactiveTrackColor: hollow.border,
      thumbColor: hollow.accent,
      overlayColor: hollow.accent.withValues(alpha: 0.08),
      trackHeight: 2,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
    );
  }

  Widget _buildMicGainSlider(HollowTheme hollow) {
    final gain = ref.watch(micGainProvider).valueOrNull ?? kMicGainDefault;
    final enhance = ref.watch(voiceEnhanceProvider).valueOrNull ?? true;
    final dynMode = ref.watch(voiceEnhanceDynamicProvider).valueOrNull ?? true;
    final locked = enhance && dynMode;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: locked ? 0.4 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(left: 30),
        child: Row(
          children: [
            Icon(LucideIcons.volume1, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Gain',
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: SliderTheme(
                data: _slimSliderTheme(hollow),
                child: Slider(
                  value: gain.clamp(kMicGainMin, kMicGainMax),
                  min: kMicGainMin,
                  max: kMicGainMax,
                  divisions: 83,
                  onChanged: locked
                      ? null
                      : (v) => ref.read(micGainProvider.notifier).setGain(v),
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                locked
                    ? 'Auto'
                    : '${(gain / kMicGainDisplayUnit * 100).round()}%',
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEnhanceToggle() {
    final enhance = ref.watch(voiceEnhanceProvider).valueOrNull ?? true;
    return Padding(
      padding: const EdgeInsets.only(left: 30),
      child: SettingsToggleRow(
        icon: LucideIcons.sparkles,
        label: 'Voice enhancement',
        subtitle: 'Studio EQ + compressor for a fuller, louder voice. '
            'Switches live mid-call.',
        value: enhance,
        onChanged: (v) => ref.read(voiceEnhanceProvider.notifier).setEnabled(v),
      ),
    );
  }

  Widget _buildNoiseSuppressAiToggle() {
    final enabled = ref.watch(noiseSuppressAiProvider).valueOrNull ?? false;
    return Padding(
      padding: const EdgeInsets.only(left: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsToggleRow(
            icon: LucideIcons.brainCircuit,
            label: 'AI noise suppression',
            subtitle: 'Removes keyboard, fan and background noise. '
                'Engages instantly; switches live mid-call.',
            value: enabled,
            onChanged: (v) =>
                ref.read(noiseSuppressAiProvider.notifier).setEnabled(v),
          ),
          if (enabled) ...[
            const SizedBox(height: HollowSpacing.xs),
            _buildNoiseSuppressEngineRow(),
          ],
        ],
      ),
    );
  }

  /// Advanced engine picker, shown only while AI NS is on. RNNoise is the
  /// default that runs well everywhere; DeepFilterNet3 stays available for
  /// desktop machines that can afford it (slow first load, ~10x the CPU).
  /// Switching mid-call swaps the engine live — no renegotiation.
  Widget _buildNoiseSuppressEngineRow() {
    final hollow = HollowTheme.of(context);
    final engine = ref.watch(noiseSuppressEngineProvider).valueOrNull ??
        kNoiseSuppressEngineRnnoise;
    return Padding(
      padding: const EdgeInsets.only(left: 26),
      child: Row(
        children: [
          Text(
            'Engine',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(width: HollowSpacing.md),
          _EngineChip(
            label: 'RNNoise',
            hint: 'light, instant',
            isSelected: engine == kNoiseSuppressEngineRnnoise,
            onTap: () => ref
                .read(noiseSuppressEngineProvider.notifier)
                .setEngine(kNoiseSuppressEngineRnnoise),
          ),
          const SizedBox(width: HollowSpacing.xs),
          _EngineChip(
            label: 'DeepFilterNet3',
            hint: 'stronger, heavy',
            isSelected: engine == kNoiseSuppressEngineDfn3,
            onTap: () => ref
                .read(noiseSuppressEngineProvider.notifier)
                .setEngine(kNoiseSuppressEngineDfn3),
          ),
        ],
      ),
    );
  }

  Widget _buildDynamicToggle() {
    final enhance = ref.watch(voiceEnhanceProvider).valueOrNull ?? true;
    final dynMode = ref.watch(voiceEnhanceDynamicProvider).valueOrNull ?? true;
    return Padding(
      padding: const EdgeInsets.only(left: 30),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: enhance ? 1.0 : 0.4,
        child: SettingsToggleRow(
          icon: LucideIcons.audioWaveform,
          label: 'Dynamic mode',
          subtitle: 'Continuously balances your mic level for you — '
              'any microphone lands at the same natural loudness.',
          value: dynMode && enhance,
          onChanged: enhance
              ? (v) =>
                  ref.read(voiceEnhanceDynamicProvider.notifier).setEnabled(v)
              : (_) {},
        ),
      ),
    );
  }

  Widget _buildStrengthSlider(HollowTheme hollow) {
    final enhance = ref.watch(voiceEnhanceProvider).valueOrNull ?? true;
    final dynMode = ref.watch(voiceEnhanceDynamicProvider).valueOrNull ?? true;
    final locked = !enhance || dynMode;
    final strength = ref.watch(voiceEnhanceStrengthProvider).valueOrNull ??
        kEnhanceStrengthDefault;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: locked ? 0.4 : 1.0,
      child: Padding(
        padding: const EdgeInsets.only(left: 30),
        child: Row(
          children: [
            Icon(LucideIcons.gauge, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Strength',
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              ),
            ),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: SliderTheme(
                data: _slimSliderTheme(hollow),
                child: Slider(
                  value:
                      strength.clamp(kEnhanceStrengthMin, kEnhanceStrengthMax),
                  min: kEnhanceStrengthMin,
                  max: kEnhanceStrengthMax,
                  divisions: 30,
                  onChanged: locked
                      ? null
                      : (v) => ref
                          .read(voiceEnhanceStrengthProvider.notifier)
                          .setStrength(v),
                ),
              ),
            ),
            SizedBox(
              width: 40,
              child: Text(
                enhance && dynMode ? 'Auto' : '${strength.round()}%',
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMicTestRow(HollowTheme hollow) {
    // Rendering phase: the take is being run through the offline chain.
    if (_micRendering) {
      return Row(
        children: [
          Icon(LucideIcons.loaderCircle, size: 14, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          Text(
            'Applying voice processing…',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      );
    }
    // Review phase: A/B the processed take against the raw one.
    if (_micTestReviewing) {
      Widget playButton(String label, String? path) {
        final active = path != null && _micPlayingPath == path;
        return HollowButton.ghost(
          onPressed: path == null
              ? null
              : active
                  ? _stopMicTestPlayback
                  : () => _playMicTest(path),
          compact: true,
          child: Text(active ? 'Stop' : label),
        );
      }

      return Row(
        children: [
          Icon(LucideIcons.play, size: 14, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          playButton(
              'Play Processed', _micProcessedOk ? _micTestRecPath : null),
          const SizedBox(width: HollowSpacing.sm),
          playButton('Play Raw', _micTestRawPath),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            onPressed: _startMicTest,
            compact: true,
            child: const Text('Re-record'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            onPressed: () async {
              await _stopMicTestPlayback();
              _discardMicTestRecording();
            },
            compact: true,
            child: const Text('Done'),
          ),
        ],
      );
    }
    return Row(
      children: [
        Icon(
          _micTesting ? LucideIcons.micOff : LucideIcons.mic,
          size: 14,
          color: hollow.textSecondary,
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          onPressed: _micTesting ? _finishMicRecording : _startMicTest,
          compact: true,
          child: Text(_micTesting ? 'Stop & Review' : 'Test Microphone'),
        ),
        if (_micTesting) ...[
          const SizedBox(width: HollowSpacing.md),
          // No level meter here — it didn't track the record-package
          // chunks reliably in the field; the A/B playback afterwards is
          // the real feedback.
          Text(
            'Recording…',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickRingtoneFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'ogg', 'flac', 'm4a'],
      dialogTitle: 'Select Ringtone',
    );
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      ref.read(ringtonePathProvider.notifier).setPath(path);
      // Reset clip range for new file.
      ref.read(ringtoneStartProvider.notifier).setStart(0.0);
      ref.read(ringtoneEndProvider.notifier).setEnd(30.0);
      // Probe and cache duration now so trim dialog opens instantly.
      final probe = AudioPlayer();
      probe.setSource(DeviceFileSource(path)).then((_) async {
        final dur = await probe.getDuration();
        await probe.dispose();
        if (dur != null && dur.inMilliseconds > 0) {
          final secs = dur.inMilliseconds / 1000.0;
          ref.read(ringtoneDurationProvider.notifier).setDuration(secs);
          ref.read(ringtoneEndProvider.notifier).setEnd(secs.clamp(0, 30));
        }
      });
    }
  }

  Widget _buildRingtoneFileRow(HollowTheme hollow) {
    final ringtonePath = ref.watch(ringtonePathProvider).valueOrNull;
    final fileName = ringtonePath?.split(RegExp(r'[\\/]')).last;

    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm,
              vertical: HollowSpacing.xs + 2,
            ),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
            ),
            child: Text(
              fileName ?? 'Default ringtone',
              style: HollowTypography.caption.copyWith(
                color: fileName != null
                    ? hollow.textPrimary
                    : hollow.textSecondary,
                fontSize: 12,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          onPressed: _pickRingtoneFile,
          compact: true,
          child: const Text('Browse'),
        ),
        if (ringtonePath != null) ...[
          const SizedBox(width: HollowSpacing.xs),
          HollowButton.ghost(
            onPressed: () =>
                _showRingtoneClipEditor(context, ref, ringtonePath),
            compact: true,
            child: const Text('Trim'),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowButton.ghost(
            onPressed: () {
              ref.read(ringtonePathProvider.notifier).setPath(null);
            },
            compact: true,
            semanticLabel: 'Remove ringtone',
            child: Icon(LucideIcons.x, size: 14, color: hollow.textSecondary),
          ),
        ],
      ],
    );
  }

  Widget _buildRingtoneVolumeRow(HollowTheme hollow) {
    return Row(
      children: [
        Icon(LucideIcons.volume2, size: 14, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          'Volume',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: hollow.accent,
              inactiveTrackColor: hollow.border,
              thumbColor: hollow.accent,
              overlayColor: hollow.accent.withValues(alpha: 0.1),
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: ref.watch(ringtoneVolumeProvider).valueOrNull ?? 0.5,
              onChangeStart: (v) => _startRingtonePreview(v),
              onChanged: (v) {
                ref.read(ringtoneVolumeProvider.notifier).setVolume(v);
                _ringtonePreview?.setVolume(v);
              },
              onChangeEnd: (_) => _stopRingtonePreview(),
            ),
          ),
        ),
        SizedBox(
          width: 32,
          child: Text(
            '${((ref.watch(ringtoneVolumeProvider).valueOrNull ?? 0.5) * 100).round()}%',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
            ),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  String? _resolveInputValue(String? savedId) {
    if (savedId == null || _audioInputs.isEmpty) return null;
    // If the saved device exists, use it. Otherwise fall back to active device.
    if (_audioInputs.any((d) => d.id == savedId)) return savedId;
    final active = _audioInputs.where((d) => d.isActive);
    return active.isNotEmpty ? active.first.id : _audioInputs.first.id;
  }

  String? _resolveOutputValue(String? savedId) {
    if (savedId == null || _audioOutputs.isEmpty) return null;
    if (_audioOutputs.any((d) => d.id == savedId)) return savedId;
    final active = _audioOutputs.where((d) => d.isActive);
    return active.isNotEmpty ? active.first.id : _audioOutputs.first.id;
  }

  String? _resolveCameraValue(String? savedId) {
    if (savedId == null || _cameras.isEmpty) return null;
    if (_cameras.any((d) => d.deviceId == savedId)) return savedId;
    return _cameras.first.deviceId;
  }

  Widget _buildDeviceRow({
    required HollowTheme hollow,
    required IconData icon,
    required String label,
    required List<DropdownMenuItem<String?>> items,
    required String? selectedValue,
    required void Function(String?) onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: hollow.textPrimary,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Container(
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: selectedValue,
                isExpanded: true,
                dropdownColor: hollow.elevated,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 12,
                ),
                icon: Icon(LucideIcons.chevronDown,
                    size: 14, color: hollow.textSecondary),
                items: items,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Selection chip for the AI-NS engine picker (selection state = chip fill,
/// never a filled button — hover-state rules).
class _EngineChip extends StatelessWidget {
  final String label;
  final String hint;
  final bool isSelected;
  final VoidCallback onTap;

  const _EngineChip({
    required this.label,
    required this.hint,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowFocusRing(
      enabled: true,
      onActivate: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: HollowDurations.fast,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: 3,
          ),
          decoration: BoxDecoration(
            color: isSelected ? hollow.accentMuted : hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(
              color: isSelected ? hollow.accent : hollow.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: HollowTypography.caption.copyWith(
                  color:
                      isSelected ? hollow.accentText : hollow.textSecondary,
                  fontWeight:
                      isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                hint,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
