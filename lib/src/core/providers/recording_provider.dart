import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/recording_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// What kind of session this recording is announced to.
enum RecordingScope { none, dmCall, voiceChannel }

class RecordingState {
  final bool isMyRecording;
  final DateTime? myStartedAt;
  final String? myFilePath;
  final RecordingScope scope;

  /// Peer IDs currently broadcasting that they are recording.
  final Set<String> remoteRecorders;

  /// Last finished local recording — used to show a "Saved to ..." toast.
  final RecordingResult? lastFinished;

  /// Last error from start/stop — UI may show as toast.
  final String? lastError;

  const RecordingState({
    this.isMyRecording = false,
    this.myStartedAt,
    this.myFilePath,
    this.scope = RecordingScope.none,
    this.remoteRecorders = const {},
    this.lastFinished,
    this.lastError,
  });

  RecordingState copyWith({
    bool? isMyRecording,
    DateTime? myStartedAt,
    String? myFilePath,
    RecordingScope? scope,
    Set<String>? remoteRecorders,
    RecordingResult? lastFinished,
    String? lastError,
    bool clearStartedAt = false,
    bool clearFilePath = false,
    bool clearLastFinished = false,
    bool clearLastError = false,
  }) {
    return RecordingState(
      isMyRecording: isMyRecording ?? this.isMyRecording,
      myStartedAt: clearStartedAt ? null : (myStartedAt ?? this.myStartedAt),
      myFilePath: clearFilePath ? null : (myFilePath ?? this.myFilePath),
      scope: scope ?? this.scope,
      remoteRecorders: remoteRecorders ?? this.remoteRecorders,
      lastFinished:
          clearLastFinished ? null : (lastFinished ?? this.lastFinished),
      lastError: clearLastError ? null : (lastError ?? this.lastError),
    );
  }

  /// Convenience: is any peer (including me) recording right now?
  bool get anyoneRecording => isMyRecording || remoteRecorders.isNotEmpty;
}

class RecordingNotifier extends Notifier<RecordingState> {
  @override
  RecordingState build() => const RecordingState();

  /// Start a local recording. If a DM call or voice channel is currently
  /// active, also broadcasts a `recording_start` signal to all participants.
  Future<void> startRecording() async {
    if (state.isMyRecording) return;

    // Optimistic: flip the UI to "recording" immediately so the Stop button
    // is active and the indicator pulses while native setup completes
    // (ScreenCaptureKit can take ~1-2s).
    final scope = _detectActiveScope();
    state = state.copyWith(
      isMyRecording: true,
      myStartedAt: DateTime.now(),
      scope: scope,
      clearLastError: true,
      clearLastFinished: true,
    );

    try {
      await RecordingService.instance.start();
    } catch (e) {
      // Roll back the optimistic flip on failure.
      state = state.copyWith(
        isMyRecording: false,
        clearStartedAt: true,
        clearFilePath: true,
        scope: RecordingScope.none,
        lastError: e.toString(),
      );
      debugPrint('[REC] start failed: $e');
      return;
    }

    // Intentionally do NOT update myStartedAt here — that would jump the
    // timer to the native-start moment (~3-5s after click) and the elapsed
    // counter would visibly snap backwards. Keep the click-time anchor.
    state = state.copyWith(
      myFilePath: RecordingService.instance.currentFilePath,
    );

    _broadcastRecordingState(true);
  }

  /// Stop the local recording and finalize the MP4. Broadcasts a stop
  /// signal to other participants and stores the resulting file in
  /// [state.lastFinished] so the UI can show a "Saved to ..." toast.
  Future<void> stopRecording() async {
    if (!state.isMyRecording) return;

    // Broadcast first so peers' REC indicators clear promptly even if
    // ffmpeg finalize takes a moment.
    _broadcastRecordingState(false);

    RecordingResult? result;
    try {
      result = await RecordingService.instance.stop();
    } catch (e) {
      state = state.copyWith(lastError: e.toString());
      debugPrint('[REC] stop failed: $e');
    }

    state = state.copyWith(
      isMyRecording: false,
      clearStartedAt: true,
      clearFilePath: true,
      scope: RecordingScope.none,
      lastFinished: result,
    );
  }

  /// Called by call_provider / voice_channel_provider when a remote peer
  /// sends a `recording_start` signal.
  void onRemoteRecordingStart(String peerId) {
    if (state.remoteRecorders.contains(peerId)) return;
    state = state.copyWith(
      remoteRecorders: {...state.remoteRecorders, peerId},
    );
  }

  void onRemoteRecordingStop(String peerId) {
    if (!state.remoteRecorders.contains(peerId)) return;
    final next = {...state.remoteRecorders}..remove(peerId);
    state = state.copyWith(remoteRecorders: next);
  }

  /// Drop all remote-recording state for a peer that disconnected.
  void onPeerDisconnected(String peerId) => onRemoteRecordingStop(peerId);

  /// Clear the "saved" toast trigger after the UI shows it.
  void acknowledgeLastFinished() {
    if (state.lastFinished == null) return;
    state = state.copyWith(clearLastFinished: true);
  }

  void acknowledgeLastError() {
    if (state.lastError == null) return;
    state = state.copyWith(clearLastError: true);
  }

  // ---------------------------------------------------------------------------

  RecordingScope _detectActiveScope() {
    final call = ref.read(callProvider);
    if (call.status == CallStatus.active || call.status == CallStatus.connecting) {
      return RecordingScope.dmCall;
    }
    final vc = ref.read(voiceChannelProvider);
    if (vc.isInVoiceChannel) return RecordingScope.voiceChannel;
    return RecordingScope.none;
  }

  void _broadcastRecordingState(bool recording) {
    final scope = state.scope == RecordingScope.none
        ? _detectActiveScope()
        : state.scope;

    final type = recording ? 'recording_start' : 'recording_stop';
    final payload = jsonEncode({
      'recording': recording,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });

    if (scope == RecordingScope.dmCall) {
      final peerId = ref.read(callProvider).peerId;
      if (peerId == null) return;
      _send(() => network_api.callSendSignal(
            peerId: peerId,
            signalType: type,
            payload: payload,
          ));
      return;
    }

    if (scope == RecordingScope.voiceChannel) {
      final vc = ref.read(voiceChannelProvider);
      final serverId = vc.currentServerId;
      final channelId = vc.currentChannelId;
      if (serverId == null || channelId == null) return;
      final peerIds = ref
              .read(voiceChannelProvider.notifier)
              .service
              ?.connectedPeerIds ??
          const <String>{};
      for (final p in peerIds) {
        _send(() => network_api.voiceChannelSendSignal(
              serverId: serverId,
              channelId: channelId,
              peerId: p,
              signalType: type,
              payload: payload,
            ));
      }
    }
  }

  void _send(Future<void> Function() action) {
    // Fire-and-forget; signaling errors are logged but don't block the UI.
    action().catchError((e) {
      debugPrint('[REC] signal send failed: $e');
    });
  }
}

final recordingProvider =
    NotifierProvider<RecordingNotifier, RecordingState>(RecordingNotifier.new);
