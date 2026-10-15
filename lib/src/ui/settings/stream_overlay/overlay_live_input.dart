import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/overlay_mic_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/voice_level_provider.dart';

/// Where our own voice comes from right now, for the look editor's preview.
enum OverlayLiveSource { voiceRoom, call, listening }

/// Our own overlay state and level while something measures the mic: a voice
/// room, a DM call, or "Listen to my mic now". Null when nothing does, and the
/// preview falls back to the editor's own buttons. Muted and deafened win over
/// talking, as on the page.
typedef OverlaySelfLive = ({
  OverlayLiveSource source,
  String state,
  double level,
});

/// Watched only by the look editor's preview: it follows level ticks.
final overlaySelfLiveProvider = Provider.autoDispose<OverlaySelfLive?>((ref) {
  String stateOf({required bool deafened, required bool muted, required bool speaking}) =>
      deafened ? 'deafened' : (muted ? 'muted' : (speaking ? 'talking' : 'idle'));

  final vc = ref.watch(voiceChannelProvider
      .select((s) => (s.currentChannelId, s.isMuted, s.isDeafened)));
  if (vc.$1 != null) {
    final muted = vc.$2 || vc.$3;
    return (
      source: OverlayLiveSource.voiceRoom,
      state: stateOf(
          deafened: vc.$3,
          muted: vc.$2,
          speaking: ref.watch(vcLocalSpeakingProvider)),
      level: muted ? 0.0 : ref.watch(vcLocalLevelProvider),
    );
  }

  final call = ref.watch(
      callProvider.select((c) => (c.status, c.isMuted, c.isDeafened)));
  if (call.$1 == CallStatus.active) {
    final muted = call.$2 || call.$3;
    return (
      source: OverlayLiveSource.call,
      state: stateOf(
          deafened: call.$3,
          muted: call.$2,
          speaking: ref.watch(callSpeakingProvider.select((s) => s.local))),
      level: muted ? 0.0 : ref.watch(callLevelProvider.select((l) => l.local)),
    );
  }

  if (ref.watch(overlayMicProvider.select((s) => s.listening))) {
    return (
      source: OverlayLiveSource.listening,
      state: stateOf(
          deafened: false,
          muted: false,
          speaking: ref.watch(overlayMicSpeakingProvider)),
      level: ref.watch(listenLevelProvider),
    );
  }
  return null;
});
