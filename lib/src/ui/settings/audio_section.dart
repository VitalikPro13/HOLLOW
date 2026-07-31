import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/ringtone_clip_editor_dialog.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:win32audio/win32audio.dart' as win32audio;

/// Audio & Video category of the desktop Settings dialog: device selection,
/// mic gain + Voice Enhancement chain controls, mic test, and ringtone.
class AudioVideoSettingsView extends StatelessWidget {
  const AudioVideoSettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return settingsCardList(const [
      SettingsCard(
        title: 'Devices',
        children: [_AudioDeviceSettings()],
      ),
    ]);
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
  webrtc.MediaStream? _micTestStream;
  webrtc.RTCPeerConnection? _micTestSend;
  webrtc.RTCPeerConnection? _micTestRecv;
  Timer? _micLevelTimer;
  bool _micLevelPollBusy = false;
  Future<void>? _micTestTeardown;
  bool _micTesting = false;
  double _micLevel = 0.0;
  AudioPlayer? _ringtonePreview;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _stopMicTest();
    _stopRingtonePreview();
    super.dispose();
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

  /// Loopback echo test through the real call pipeline (issue #40). The
  /// `record` package the old test used shells out to `parecord` on Linux,
  /// which PipeWire systems don't ship — and it bypassed the processing
  /// chain entirely. Instead, capture via getUserMedia with the exact call
  /// constraints and feed the track through a local PeerConnection pair:
  /// libwebrtc only starts the audio device module (and thus the capture
  /// meter) once a PC carries the track, and the receiving end plays you
  /// back through the selected output — denoiser, enhance chain and gain
  /// included, so what you hear is what peers hear.
  Future<void> _startMicTest() async {
    // Wait out a previous teardown so a rapid restart can't contend for the
    // mic, and refuse a double-start.
    final teardown = _micTestTeardown;
    if (teardown != null) await teardown;
    if (_micTestStream != null || !mounted) return;

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
    final selectedOutput = ref.read(audioOutputDeviceProvider).valueOrNull;
    final aiNs = ref.read(noiseSuppressAiProvider).valueOrNull ?? false;
    final engine = noiseSuppressEngineToNative(
        ref.read(noiseSuppressEngineProvider).valueOrNull ??
            kNoiseSuppressEngineRnnoise);
    final micGain = ref.read(micGainProvider).valueOrNull ?? kMicGainDefault;
    final enhance = ref.read(voiceEnhanceProvider).valueOrNull ?? true;
    final dynMode = ref.read(voiceEnhanceDynamicProvider).valueOrNull ?? true;
    final strength = ref.read(voiceEnhanceStrengthProvider).valueOrNull ??
        kEnhanceStrengthDefault;

    try {
      // AI NS first — like the call path, its state decides the WebRTC-NS
      // constraint before the capture opens.
      await webrtc.Helper.setNoiseSuppressAi(aiNs, engine: engine)
          .catchError((_) {});

      final audioConstraints = <String, dynamic>{
        'echoCancellation': true,
        'noiseSuppression': !aiNs,
        'googNoiseSuppression': !aiNs,
        'autoGainControl': false,
        'googAutoGainControl': false,
      };
      if (selectedInput != null) {
        audioConstraints['optional'] = [
          {'sourceId': selectedInput}
        ];
      }
      final stream = await webrtc.navigator.mediaDevices
          .getUserMedia({'audio': audioConstraints, 'video': false});
      _micTestStream = stream;

      try {
        await webrtc.Helper.setCaptureGain(micGain);
        await webrtc.Helper.setVoiceEnhance(enhance,
            makeupDb: enhanceStrengthToMakeupDb(strength),
            dynamicMode: dynMode);
      } catch (e) {
        debugPrint('[HOLLOW] mic test: capture chain setup failed: $e');
      }

      final send = await webrtc.createPeerConnection({'iceServers': []});
      final recv = await webrtc.createPeerConnection({'iceServers': []});
      _micTestSend = send;
      _micTestRecv = recv;

      // Trickle ICE between the two local ends; candidates can fire before
      // the counterpart has its remote description, so queue until then.
      var recvHasRemote = false;
      var sendHasRemote = false;
      final queuedForRecv = <webrtc.RTCIceCandidate>[];
      final queuedForSend = <webrtc.RTCIceCandidate>[];
      send.onIceCandidate = (c) {
        if (c.candidate == null) return;
        if (recvHasRemote) {
          recv.addCandidate(c).catchError((_) {});
        } else {
          queuedForRecv.add(c);
        }
      };
      recv.onIceCandidate = (c) {
        if (c.candidate == null) return;
        if (sendHasRemote) {
          send.addCandidate(c).catchError((_) {});
        } else {
          queuedForSend.add(c);
        }
      };

      for (final track in stream.getAudioTracks()) {
        await send.addTrack(track, stream);
      }
      final offer = await send.createOffer({});
      await send.setLocalDescription(offer);
      await recv.setRemoteDescription(offer);
      recvHasRemote = true;
      for (final c in queuedForRecv) {
        await recv.addCandidate(c).catchError((_) {});
      }
      final answer = await recv.createAnswer({});
      await recv.setLocalDescription(answer);
      await send.setRemoteDescription(answer);
      sendHasRemote = true;
      for (final c in queuedForSend) {
        await send.addCandidate(c).catchError((_) {});
      }

      // Route the playback to the chosen speaker (same swallow-on-mismatch
      // as the picker — Linux pulse ids may not match the ADM's).
      if (selectedOutput != null) {
        await webrtc.Helper.selectAudioOutput(selectedOutput).catchError((e) {
          debugPrint('[HOLLOW] selectAudioOutput failed: $e');
        });
      }

      if (!mounted) {
        await _stopMicTest();
        return;
      }
      setState(() => _micTesting = true);

      _micLevelTimer =
          Timer.periodic(const Duration(milliseconds: 100), (_) async {
        if (_micLevelPollBusy) return;
        _micLevelPollBusy = true;
        try {
          final res = await webrtc.Helper.getCaptureLevel();
          if (!mounted || !_micTesting) return;
          // Normalize dBFS (-60..0) to 0.0..1.0 for the level bar.
          final levelDb = (res['levelDb'] as num?)?.toDouble() ?? -100.0;
          const minDb = -60.0;
          final clamped = levelDb.clamp(minDb, 0.0);
          setState(() => _micLevel = (clamped - minDb) / (0.0 - minDb));
        } catch (_) {
          // Keep the last level; the meter self-heals on the next tick.
        } finally {
          _micLevelPollBusy = false;
        }
      });
    } catch (e) {
      await _stopMicTest();
      if (!mounted) return;
      HollowToast.show(context, 'Microphone error: $e',
          type: HollowToastType.error);
    }
  }

  Future<void> _stopMicTest() {
    final future = _teardownMicTest();
    _micTestTeardown = future;
    return future;
  }

  Future<void> _teardownMicTest() async {
    _micLevelTimer?.cancel();
    _micLevelTimer = null;
    _micLevel = 0.0;
    if (mounted) setState(() => _micTesting = false);

    final stream = _micTestStream;
    final send = _micTestSend;
    final recv = _micTestRecv;
    _micTestStream = null;
    _micTestSend = null;
    _micTestRecv = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        try {
          await track.stop();
        } catch (_) {}
      }
    }
    for (final pc in [send, recv]) {
      try {
        await pc?.close();
      } catch (_) {}
      try {
        await pc?.dispose();
      } catch (_) {}
    }
    try {
      await stream?.dispose();
    } catch (_) {}
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
        if (_micTesting)
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 4),
            child: Text(
              'You are hearing your own microphone through the selected '
              'output — exactly what others hear in a call.',
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
    return Row(
      children: [
        Icon(
          _micTesting ? LucideIcons.micOff : LucideIcons.mic,
          size: 14,
          color: hollow.textSecondary,
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          onPressed: _micTesting ? _stopMicTest : _startMicTest,
          compact: true,
          child: Text(_micTesting ? 'Stop Test' : 'Test Microphone'),
        ),
        if (_micTesting) ...[
          const SizedBox(width: HollowSpacing.md),
          // Volume meter bar
          Expanded(
            child: SizedBox(
              height: 8,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Stack(
                  children: [
                    // Background
                    Container(
                      color: hollow.border,
                    ),
                    // Level fill
                    FractionallySizedBox(
                      widthFactor: _micLevel.clamp(0.0, 1.0),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 80),
                        decoration: BoxDecoration(
                          color: _micLevelColor(hollow),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Color _micLevelColor(HollowTheme hollow) {
    if (_micLevel > 0.5) return hollow.success;
    if (_micLevel > 0.02) return hollow.accent;
    return hollow.textSecondary.withValues(alpha: 0.3);
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
