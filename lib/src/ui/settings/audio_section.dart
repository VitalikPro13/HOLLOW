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
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/linux_pulse_capture.dart';
import 'package:hollow/src/core/services/sound_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/dialogs/ringtone_clip_editor_dialog.dart';
import 'package:hollow/src/ui/settings/keybind_capture_field.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:record/record.dart' as rec;
import 'package:win32audio/win32audio.dart' as win32audio;

/// Settings > Audio & Video: devices, the voice chain, the microphone test,
/// push to talk and sounds.
class AudioVideoSettingsView extends ConsumerStatefulWidget {
  const AudioVideoSettingsView({super.key});

  @override
  ConsumerState<AudioVideoSettingsView> createState() =>
      _AudioVideoSettingsViewState();
}

/// Uniform shape for audio device listings, wrapping either a
/// `win32audio.AudioDevice` or a `webrtc.MediaDeviceInfo`.
typedef _AudioDeviceInfo = ({String id, String name, bool isActive});

const double _kDeviceFieldWidth = 260;
const double _kCompactSliderWidth = 120;
const double _kCompactReadoutWidth = 40;

/// Hotkeys need a keyboard, so push to talk is desktop only; mobile transmits
/// on voice activity (issue #38).
bool get _isDesktop => !Platform.isAndroid && !Platform.isIOS;

class _AudioVideoSettingsViewState
    extends ConsumerState<AudioVideoSettingsView> {
  List<_AudioDeviceInfo> _audioInputs = [];
  List<_AudioDeviceInfo> _audioOutputs = [];
  List<webrtc.MediaDeviceInfo> _cameras = [];
  bool _loading = true;
  bool _micTesting = false;
  AudioPlayer? _ringtonePreview;
  rec.AudioRecorder? _micRecorder;
  LinuxPulseCapture? _micPulse;
  StreamSubscription<Uint8List>? _micChunkSub;
  BytesBuilder? _micPcmBuf;
  static const int _micRecRate = 48000;
  String? _micTestRawPath;
  String? _micTestRecPath;
  bool _micRendering = false;
  bool _micTestReviewing = false;
  bool _micProcessedOk = false;
  AudioPlayer? _micTestPlayer;
  String? _micPlayingPath;
  Timer? _micTestCapTimer;
  // Highest capture level seen while recording (dBFS; -100 = never), the one
  // number that separates "the mic delivered nothing" from a recorder bug.
  double _micTestPeakDb = -100.0;

  /// Mic-test diagnostics MUST reach hollow_debug.log: debugPrint alone is
  /// invisible in installed and release builds.
  void _micLog(String msg) {
    debugPrint('[MIC-TEST] $msg');
    network_api.logFromDart(message: '[MIC-TEST] $msg').catchError((_) {});
  }

  @override
  void initState() {
    super.initState();
    // A phone routes audio itself (earpiece, speaker, headset) and picks its
    // camera in the call, so it lists no devices here.
    if (!_isDesktop) {
      _loading = false;
      return;
    }
    _loadDevices();
    // These providers may have cached defaults from before storage was ready,
    // so re-read from disk whenever the page opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(voiceInputModeProvider);
      ref.invalidate(pttKeybindProvider);
      ref.invalidate(muteKeybindProvider);
      ref.invalidate(deafenKeybindProvider);
      ref.invalidate(pttReleaseDelayProvider);
    });
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

  /// Parses the `{input: [...], output: [...]}` map the fork's native audio
  /// enumeration handlers return into the uniform record shape.
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

  /// Invokes one of the fork's native audio enumeration handlers (CoreAudio on
  /// macOS, libpulse on Linux) and parses the shared result shape.
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

  /// macOS: the pinned WebRTC SDK returns empty input/output device lists, so
  /// enumeration goes through CoreAudio via the fork's `hollowMacAudioDevices`.
  /// A short getUserMedia first triggers the system microphone prompt.
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

      // Camera always comes from flutter_webrtc; only AUDIO needs the
      // per-platform enumerators below.
      try {
        final devices = await webrtc.navigator.mediaDevices.enumerateDevices();
        cameras = devices.where((d) => d.kind == 'videoinput').toList();
      } catch (e) {
        debugPrint('[HOLLOW] Device enumeration (webrtc) failed: $e');
      }

      // Linux: the prebuilt libwebrtc AudioDeviceModule reports 0 audio devices
      // on pipewire-pulse (it falls back to AudioDeviceDummy) even though the
      // camera enumerates fine, so audio comes from libpulse via our fork.
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

  /// Record-raw / render-offline / A-B review mic test (issue #40).
  ///
  /// Deliberately NO WebRTC session: a loopback peer connection ran the APM at
  /// session-dependent shapes that never matched a real call. The raw 48 kHz
  /// mono take is rendered through a fresh instance of the same native chain
  /// calls use (`hollowRenderVoiceWav`).
  Future<void> _startMicTest() async {
    if (_micTesting || _micRendering || !mounted) return;

    await _stopMicTestPlayback();
    _discardMicTestRecording();
    if (!mounted) return;

    // The test claims the mic and the process-global capture chain, so it
    // refuses while a call or voice channel is live rather than fight for both.
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
          // The stored id may come from a different enumerator than `record`'s,
          // so fall back to the system default and log it.
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
        // Peak feeds the log line only; there is no on-screen meter, because it
        // never tracked the record-package chunks reliably.
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

      // The dynamic servo needs a few seconds of speech to settle, and the cap
      // stops an abandoned test recording forever.
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

  /// RMS of a PCM16LE chunk as (dBFS, 0..1 bar) over a -60..0 mapping.
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

  /// Stops capture, writes the raw WAV and renders it, then surfaces both takes
  /// for A/B playback.
  Future<void> _finishMicRecording() async {
    if (!_micTesting) return;
    await _stopMicCapture();
    if (!mounted) return;

    final pcm = _micPcmBuf?.takeBytes() ?? Uint8List(0);
    _micPcmBuf = null;
    _micLog('finish: rawBytes=${pcm.length} '
        'peakDb=${_micTestPeakDb.toStringAsFixed(1)}');

    // Name the device we actually recorded from: a stale Settings pick is the
    // failure a user cannot see otherwise.
    final inputId = ref.read(audioInputDeviceProvider).valueOrNull;
    final matches = _audioInputs.where((d) => d.id == inputId).toList();
    final deviceLabel = matches.isEmpty
        ? 'the selected microphone'
        : '"${matches.first.name}"';
    if (pcm.length < _micRecRate ~/ 5) {
      // Under ~100 ms of audio: the capture never really ran.
      HollowToast.show(
          context,
          'No audio arrived from $deviceLabel. Check the microphone '
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
          'Voice processing failed. Only the raw recording is available.',
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

  void _reloadDevices() {
    setState(() => _loading = true);
    _loadDevices();
  }

  @override
  Widget build(BuildContext context) {
    final touch = SettingsDensity.touchOf(context);

    final aiNs = ref.watch(noiseSuppressAiProvider).valueOrNull ?? false;
    final enhance = ref.watch(voiceEnhanceProvider).valueOrNull ?? true;
    final dynMode = ref.watch(voiceEnhanceDynamicProvider).valueOrNull ?? true;
    final autoLevel = enhance && dynMode;
    final gain = ref.watch(micGainProvider).valueOrNull ?? kMicGainDefault;

    final engineState = ref.watch(noiseSuppressEngineProvider);
    final engine = engineState.valueOrNull ?? kNoiseSuppressEngineRnnoise;
    final strengthState = ref.watch(voiceEnhanceStrengthProvider);
    final strength = strengthState.valueOrNull ?? kEnhanceStrengthDefault;
    final releaseState = _isDesktop ? ref.watch(pttReleaseDelayProvider) : null;
    final releaseMs = releaseState?.valueOrNull ?? kPttReleaseDefaultMs;
    final isPtt = _isDesktop &&
        (ref.watch(voiceInputModeProvider).valueOrNull ??
                kVoiceInputActivity) ==
            kVoiceInputPtt;

    // Keyed on the load so a fold built from the placeholder defaults is
    // rebuilt once the stored values arrive.
    final advancedLoaded = engineState.hasValue &&
        strengthState.hasValue &&
        (releaseState?.hasValue ?? true);
    final advancedChanged = (_isDesktop && engine != kNoiseSuppressEngineRnnoise) ||
        strength != kEnhanceStrengthDefault ||
        releaseMs != kPttReleaseDefaultMs;

    return SettingsPage(
      title: 'Audio & Video',
      children: [
        if (_isDesktop)
          SettingsSection(
            title: 'Microphone',
            children: [
              _buildMicrophoneRow(touch),
              _buildMicTestRow(),
              if (_micTesting || _micRendering || _micTestReviewing)
                _buildMicTestPanel(),
            ],
          ),
        SettingsSection(
          title: 'Voice',
          children: [
            SettingsSwitchRow(
              title: 'Noise suppression',
              subtitle: 'Removes keyboard, fan and background noise from your '
                  'mic. Switches on instantly, even mid-call.',
              value: aiNs,
              onChanged: (v) =>
                  ref.read(noiseSuppressAiProvider.notifier).setEnabled(v),
            ),
            SettingsSwitchRow(
              title: 'Voice enhancement',
              subtitle: 'Studio EQ and a compressor for a fuller, louder '
                  'voice. Switches live mid-call.',
              value: enhance,
              onChanged: (v) =>
                  ref.read(voiceEnhanceProvider.notifier).setEnabled(v),
            ),
            SettingsSwitchRow(
              title: 'Automatic level',
              subtitle: 'Keeps balancing your mic level, so any microphone '
                  'lands at the same natural loudness.',
              value: autoLevel,
              onChanged: enhance
                  ? (v) => ref
                      .read(voiceEnhanceDynamicProvider.notifier)
                      .setEnabled(v)
                  : null,
            ),
            SettingsSliderRow(
              title: 'Gain',
              subtitle: autoLevel
                  ? 'Set by Automatic level'
                  : 'Boosts your voice. A limiter stops clipping.',
              value: gain,
              min: kMicGainMin,
              max: kMicGainMax,
              divisions: 83,
              valueLabel: autoLevel
                  ? 'Auto'
                  : '${(gain / kMicGainDisplayUnit * 100).round()}%',
              onChanged: autoLevel
                  ? null
                  : (v) => ref.read(micGainProvider.notifier).setGain(v),
            ),
          ],
        ),
        SettingsSection(
          title: _isDesktop ? 'Speaker and camera' : 'Calls',
          children: [
            if (_isDesktop) _buildSpeakerRow(touch),
            if (_cameras.isNotEmpty) _buildCameraRow(touch),
            SettingsChoiceRow<AudioQualityPreset>(
              title: 'Call quality',
              subtitle: _qualityLine(ref.watch(audioQualityProvider).valueOrNull ??
                  AudioQualityPreset.voice),
              value: ref.watch(audioQualityProvider).valueOrNull ??
                  AudioQualityPreset.voice,
              options: [
                for (final p in AudioQualityPreset.values) (p, p.label),
              ],
              onChanged: (p) =>
                  ref.read(audioQualityProvider.notifier).setPreset(p),
            ),
          ],
        ),
        if (_isDesktop) _buildTalkingSection(isPtt),
        SettingsSection(
          title: 'Sounds',
          children: [
            _buildRingtoneRow(touch),
            _buildSoundEffectsRow(touch),
          ],
        ),
        SettingsAdvanced(
          key: ValueKey('audio-advanced-$advancedLoaded'),
          initiallyOpen: advancedChanged,
          children: [
            // RNNoise runs everywhere; DeepFilterNet3 costs a slow first load
            // and roughly 10x the CPU. Switching mid-call needs no
            // renegotiation.
            if (aiNs && _isDesktop)
              SettingsChoiceRow<String>(
                title: 'Noise suppression engine',
                subtitle: 'DeepFilterNet3 is stronger and heavier',
                value: engine,
                options: const [
                  (kNoiseSuppressEngineRnnoise, 'RNNoise'),
                  (kNoiseSuppressEngineDfn3, 'DeepFilterNet3'),
                ],
                onChanged: (v) =>
                    ref.read(noiseSuppressEngineProvider.notifier).setEngine(v),
              ),
            SettingsSliderRow(
              title: 'Enhancement strength',
              subtitle: !enhance
                  ? 'Needs voice enhancement'
                  : dynMode
                      ? 'Set by Automatic level'
                      : 'How much the enhancement lifts your voice',
              value: strength,
              min: kEnhanceStrengthMin,
              max: kEnhanceStrengthMax,
              divisions: 30,
              valueLabel: autoLevel ? 'Auto' : '${strength.round()}%',
              onChanged: (!enhance || dynMode)
                  ? null
                  : (v) => ref
                      .read(voiceEnhanceStrengthProvider.notifier)
                      .setStrength(v),
            ),
            if (_isDesktop)
              SettingsSliderRow(
                title: 'Push-to-talk release',
                subtitle: isPtt
                    ? 'How long the mic stays open after you let go'
                    : 'Only used with push to talk',
                value: releaseMs.toDouble(),
                min: 0,
                max: 1000,
                divisions: 20,
                valueLabel: '$releaseMs ms',
                onChanged: isPtt
                    ? (v) => ref
                        .read(pttReleaseDelayProvider.notifier)
                        .setDelay(v.round())
                    : null,
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTalkingSection(bool isPtt) {
    final pttBind = ref.watch(pttKeybindProvider).valueOrNull ?? 'ctrl+space';
    return SettingsSection(
      title: 'Talking',
      children: [
        SettingsChoiceRow<String>(
          title: 'Send my voice',
          subtitle: isPtt
              ? 'Only while you hold the key'
              : 'Whenever the mic hears you speak',
          value: isPtt ? kVoiceInputPtt : kVoiceInputActivity,
          options: const [
            (kVoiceInputActivity, 'When I talk'),
            (kVoiceInputPtt, 'While I hold a key'),
          ],
          onChanged: (m) =>
              ref.read(voiceInputModeProvider.notifier).setMode(m),
        ),
        if (isPtt)
          SettingsRow(
            title: 'Push-to-talk key',
            subtitleWidget: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('Mute and deafen keys live in '),
                HollowTextLink(
                  'Shortcuts',
                  onTap: () => ref
                      .read(settingsCategoryProvider.notifier)
                      .state = SettingsCategory.shortcuts,
                ),
              ],
            ),
            trailing: KeybindCaptureField(
              serialized: pttBind,
              onChanged: (v) =>
                  ref.read(pttKeybindProvider.notifier).setBinding(v),
              semanticLabel: 'Set push-to-talk key',
            ),
          ),
      ],
    );
  }

  /// A device picker on the trailing edge; full width under the title on a
  /// phone.
  Widget _deviceControl(bool touch, Widget field, {Widget? before}) {
    if (touch) {
      return Row(
        children: [
          if (before != null) ...[
            before,
            const SizedBox(width: HollowSpacing.xs),
          ],
          Expanded(child: field),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (before != null) ...[
          before,
          const SizedBox(width: HollowSpacing.xs),
        ],
        SizedBox(width: _kDeviceFieldWidth, child: field),
      ],
    );
  }

  static String _deviceName(String name, String id, String fallback) =>
      name.isNotEmpty
          ? name
          : '$fallback ${id.substring(0, id.length.clamp(0, 8))}';

  Widget _buildMicrophoneRow(bool touch) {
    final selectedInput = ref.watch(audioInputDeviceProvider).valueOrNull;
    return SettingsRow(
      title: 'Microphone',
      subtitle: _loading
          ? 'Looking for devices'
          : _audioInputs.isEmpty
              ? 'No microphone found'
              : null,
      wideTrailing: true,
      trailing: _deviceControl(
        touch,
        _buildDropdown(
          items: [
            for (final d in _audioInputs)
              DropdownMenuItem<String?>(
                value: d.id,
                child: Text(
                  _deviceName(d.name, d.id, 'Device'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          selectedValue: _resolveInputValue(selectedInput),
          onChanged: (deviceId) {
            if (deviceId != null) {
              ref.read(audioInputDeviceProvider.notifier).setDevice(deviceId);
            }
          },
        ),
        before: HollowIconButton(
          icon: LucideIcons.refreshCw,
          label: 'Look for devices again',
          size: touch ? 44 : 32,
          onPressed: _loading ? null : _reloadDevices,
        ),
      ),
    );
  }

  Widget _buildSpeakerRow(bool touch) {
    final selectedOutput = ref.watch(audioOutputDeviceProvider).valueOrNull;
    return SettingsRow(
      title: 'Speaker',
      subtitle:
          !_loading && _audioOutputs.isEmpty ? 'No speaker found' : null,
      wideTrailing: true,
      trailing: _deviceControl(
        touch,
        _buildDropdown(
          items: [
            for (final d in _audioOutputs)
              DropdownMenuItem<String?>(
                value: d.id,
                child: Text(
                  _deviceName(d.name, d.id, 'Device'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          selectedValue: _resolveOutputValue(selectedOutput),
          onChanged: (deviceId) {
            if (deviceId != null) {
              ref.read(audioOutputDeviceProvider.notifier).setDevice(deviceId);
              webrtc.Helper.selectAudioOutput(deviceId).catchError((e) {
                debugPrint('[HOLLOW] selectAudioOutput failed: $e');
              });
            }
          },
        ),
      ),
    );
  }

  Widget _buildCameraRow(bool touch) {
    final selectedCamera = ref.watch(cameraDeviceProvider).valueOrNull;
    return SettingsRow(
      title: 'Camera',
      wideTrailing: true,
      trailing: _deviceControl(
        touch,
        _buildDropdown(
          items: [
            for (final d in _cameras)
              DropdownMenuItem<String?>(
                value: d.deviceId,
                child: Text(
                  _deviceName(d.label, d.deviceId, 'Camera'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          selectedValue: _resolveCameraValue(selectedCamera),
          onChanged: (deviceId) {
            if (deviceId != null) {
              ref.read(cameraDeviceProvider.notifier).setDevice(deviceId);
            }
          },
        ),
      ),
    );
  }

  /// The row stays put; the later steps of the test open under it.
  Widget _buildMicTestRow() {
    final idle = !_micTesting && !_micRendering && !_micTestReviewing;
    return SettingsRow(
      title: 'Hear yourself',
      subtitle: 'Record a sentence and play back exactly what others hear',
      trailing: idle
          ? HollowButton.outline(
              onPressed: _startMicTest,
              compact: true,
              child: const Text('Test microphone'),
            )
          : null,
    );
  }

  Widget _buildMicTestPanel() {
    final hollow = HollowTheme.of(context);
    final lineStyle =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);

    if (_micRendering) {
      return Padding(
        padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
        child: Row(
          children: [
            const HollowSpinner(),
            const SizedBox(width: HollowSpacing.sm),
            Text('Applying voice processing', style: lineStyle),
          ],
        ),
      );
    }

    final String line;
    final List<Widget> actions;
    if (_micTesting) {
      line = 'Recording. Speak a sentence, then stop (10 seconds at most).';
      actions = [
        HollowButton.outline(
          onPressed: _finishMicRecording,
          compact: true,
          child: const Text('Stop and review'),
        ),
      ];
    } else {
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

      line = 'Processed is what others hear in a call.';
      actions = [
        playButton('Play processed', _micProcessedOk ? _micTestRecPath : null),
        playButton('Play raw', _micTestRawPath),
        HollowButton.ghost(
          onPressed: _startMicTest,
          compact: true,
          child: const Text('Re-record'),
        ),
        HollowButton.ghost(
          onPressed: () async {
            await _stopMicTestPlayback();
            _discardMicTestRecording();
          },
          compact: true,
          child: const Text('Done'),
        ),
      ];
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(line, style: lineStyle),
          const SizedBox(height: HollowSpacing.sm),
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: actions,
          ),
        ],
      ),
    );
  }

  /// A small volume slider and its readout, for a row whose main control is
  /// something else.
  Widget _compactVolume({
    required bool touch,
    required String semanticLabel,
    required double value,
    required ValueChanged<double>? onChanged,
    ValueChanged<double>? onChangeStart,
    ValueChanged<double>? onChangeEnd,
  }) {
    final hollow = HollowTheme.of(context);
    final slider = Semantics(
      label: semanticLabel,
      child: HollowSlider(
        value: value.clamp(0.0, 1.0),
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
      ),
    );
    final readout = SizedBox(
      width: _kCompactReadoutWidth,
      child: Text(
        '${(value * 100).round()}%',
        textAlign: TextAlign.right,
        style: HollowTypography.monoSmall.copyWith(
          color: hollow.textSecondary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    if (touch) {
      return Row(children: [Expanded(child: slider), readout]);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(width: _kCompactSliderWidth, child: slider),
        readout,
      ],
    );
  }

  Widget _buildRingtoneRow(bool touch) {
    final ringtonePath = ref.watch(ringtonePathProvider).valueOrNull;
    final fileName = ringtonePath?.split(RegExp(r'[\\/]')).last;
    final volume = ref.watch(ringtoneVolumeProvider).valueOrNull ?? 0.5;

    final buttons = <Widget>[
      HollowButton.ghost(
        onPressed: _pickRingtoneFile,
        compact: true,
        child: const Text('Change'),
      ),
      if (ringtonePath != null) ...[
        HollowButton.ghost(
          onPressed: () => _showRingtoneClipEditor(context, ref, ringtonePath),
          compact: true,
          child: const Text('Trim'),
        ),
        HollowIconButton(
          icon: LucideIcons.x,
          label: 'Remove ringtone',
          size: touch ? 44 : 32,
          onPressed: () =>
              ref.read(ringtonePathProvider.notifier).setPath(null),
        ),
      ],
    ];
    final volumeControl = _compactVolume(
      touch: touch,
      semanticLabel: 'Ringtone volume',
      value: volume,
      onChangeStart: (v) => _startRingtonePreview(v),
      onChanged: (v) {
        ref.read(ringtoneVolumeProvider.notifier).setVolume(v);
        _ringtonePreview?.setVolume(v);
      },
      onChangeEnd: (_) => _stopRingtonePreview(),
    );

    return SettingsRow(
      title: 'Ringtone',
      subtitle: fileName ?? 'Default ringtone',
      wideTrailing: true,
      trailing: touch
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: HollowSpacing.sm,
                  runSpacing: HollowSpacing.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: buttons,
                ),
                const SizedBox(height: HollowSpacing.sm),
                volumeControl,
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i > 0) const SizedBox(width: HollowSpacing.sm),
                  buttons[i],
                ],
                const SizedBox(width: HollowSpacing.lg),
                volumeControl,
              ],
            ),
    );
  }

  Widget _buildSoundEffectsRow(bool touch) {
    final enabled = ref.watch(soundEffectsEnabledProvider);
    final volume = ref.watch(soundEffectsVolumeProvider);
    final volumeControl = _compactVolume(
      touch: touch,
      semanticLabel: 'Sound effects volume',
      value: volume,
      onChanged: enabled
          ? (v) => ref.read(soundEffectsVolumeProvider.notifier).setVolume(v)
          : null,
      // Preview on release only; a sound per drag frame is a machine-gun.
      onChangeEnd: enabled
          ? (_) => SoundService.instance.play(HollowSound.joinVoice)
          : null,
    );
    final toggle = HollowToggle(
      value: enabled,
      semanticLabel: 'Sound effects',
      onChanged: (v) {
        ref.read(soundEffectsEnabledProvider.notifier).setEnabled(v);
        // Confirm the new setting with the sound it just enabled.
        if (v) SoundService.instance.play(HollowSound.notification);
      },
    );
    return SettingsRow(
      title: 'Sound effects',
      subtitle: 'Joins, leaves, mute and notifications',
      wideTrailing: true,
      trailing: Row(
        mainAxisSize: touch ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (touch) Expanded(child: volumeControl) else volumeControl,
          const SizedBox(width: HollowSpacing.lg),
          toggle,
        ],
      ),
    );
  }

  Future<void> _pickRingtoneFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'ogg', 'flac', 'm4a'],
      dialogTitle: 'Select ringtone',
    );
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      ref.read(ringtonePathProvider.notifier).setPath(path);
      ref.read(ringtoneStartProvider.notifier).setStart(0.0);
      ref.read(ringtoneEndProvider.notifier).setEnd(30.0);
      // Cached now so the trim dialog opens instantly.
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

  String? _resolveInputValue(String? savedId) {
    if (savedId == null || _audioInputs.isEmpty) return null;
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

  Widget _buildDropdown({
    required List<DropdownMenuItem<String?>> items,
    required String? selectedValue,
    required void Function(String?) onChanged,
  }) {
    final hollow = HollowTheme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: selectedValue,
          isExpanded: true,
          dropdownColor: hollow.overlay,
          style: HollowTypography.bodySmall.copyWith(
            color: hollow.textPrimary,
          ),
          icon: Icon(LucideIcons.chevronDown,
              size: 14, color: hollow.textSecondary),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// What each call quality sends, so the choice is more than a name.
String _qualityLine(AudioQualityPreset p) => switch (p) {
      AudioQualityPreset.voice => '96 kbps mono. Clear speech, light on data.',
      AudioQualityPreset.music =>
        '128 kbps stereo. For playing music or instruments into a call.',
      AudioQualityPreset.hifi =>
        '256 kbps stereo. Close to lossless, uses the most data.',
    };
