import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/no_turn_dialog.dart';
import 'package:hollow/src/ui/dialogs/screen_share_dialog.dart';

/// Screen capture exists on the desktops only.
bool get callCanShareScreen =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

bool get _isPhone => Platform.isAndroid || Platform.isIOS;

/// Turns your camera on or off in the DM call ([dm]) or the voice room. A
/// camera that stays off (none, or another app holds it) says so rather than
/// leaving a button that did nothing.
Future<void> toggleCallCamera(BuildContext context, {required bool dm}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  bool on() => dm
      ? container.read(callProvider).isVideoEnabled
      : container.read(voiceChannelProvider).isCameraOn;
  final wasOn = on();
  try {
    if (dm) {
      await container.read(callProvider.notifier).toggleVideo();
    } else {
      await container.read(voiceChannelProvider.notifier).toggleCamera();
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(
          context,
          friendlyError(e,
              fallback: wasOn
                  ? "Couldn't turn off the camera"
                  : "Couldn't turn on the camera"),
          type: HollowToastType.error);
    }
    return;
  }
  if (!wasOn && !on() && context.mounted) {
    HollowToast.show(context, 'No camera found, or another app is using it',
        type: HollowToastType.error);
  }
}

/// THE way to start a DM call, from any surface (the header, a person's menu,
/// the Friends Manager): the TURN check, the leave-the-voice-room confirm
/// (issue #49), then the call, with its DM opened so the call has a home.
/// [beforeCall] runs once the user has committed, for a dialog to close.
Future<void> startDmCallFlow(
  BuildContext context,
  WidgetRef ref,
  String master, {
  bool withVideo = false,
  VoidCallback? beforeCall,
}) async {
  if (!await ensureTurnForCall(context, ref)) return;
  if (!context.mounted) return;
  final vc = ref.read(voiceChannelProvider);
  if (vc.isInVoiceChannel) {
    final channelName = vc.currentChannelName ?? 'voice';
    final confirmed = await showHollowConfirm(
      context: context,
      title: 'Start call?',
      message: 'Starting this call will disconnect you from #$channelName.',
      confirmLabel: 'Start call',
    );
    if (!confirmed || !context.mounted) return;
  }
  // Captured before the navigation, which can unmount whatever opened this.
  final calls = ref.read(callProvider.notifier);
  if (!_isPhone) openDmConversation(ref, master);
  beforeCall?.call();
  try {
    await calls.startCall(master, withVideo: withVideo);
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't start the call",
          type: HollowToastType.error);
    }
  }
}

/// Ends the DM call, or cancels it while it rings.
Future<void> leaveDmCall(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(callProvider.notifier).endCall();
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't leave the call",
          type: HollowToastType.error);
    }
  }
}

/// Starts or stops our share in the DM call. A new share takes focus only when
/// nothing else holds it (D7).
Future<void> toggleDmScreenShare(BuildContext context, WidgetRef ref) async {
  final calls = ref.read(callProvider.notifier);
  if (ref.read(callProvider).isScreenSharing) {
    await calls.stopScreenShare();
    return;
  }
  final focus = ref.read(focusedDmSourceProvider.notifier);
  final me = ref.read(identityProvider).peerId ?? '';
  final selection = await showScreenShareDialog(context);
  if (selection == null) return;
  try {
    await calls.startScreenShare(
      sourceId: selection.sourceId,
      width: selection.width,
      height: selection.height,
      fps: selection.fps,
      shareAudio: selection.shareAudio,
      pid: selection.pid,
      windowHwnd: selection.windowHwnd,
      profile: selection.profile,
    );
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't share your screen",
          type: HollowToastType.error);
    }
    return;
  }
  if (!context.mounted) return;
  if (focus.state.peerId == null && ref.read(callProvider).isScreenSharing) {
    focus.state = DmFocusedSource(peerId: me, type: 'screen');
  }
}

/// Starts or stops our share in the voice room.
Future<void> toggleVcScreenShare(BuildContext context, WidgetRef ref) async {
  final vc = ref.read(voiceChannelProvider.notifier);
  if (ref.read(voiceChannelProvider).isScreenSharing) {
    await vc.stopScreenShare();
    return;
  }
  final selection = await showScreenShareDialog(context);
  if (selection == null) return;
  try {
    await vc.startScreenShare(
      selection.sourceId,
      selection.width,
      selection.height,
      selection.fps,
      shareAudio: selection.shareAudio,
      pid: selection.pid,
      windowHwnd: selection.windowHwnd,
      profile: selection.profile,
    );
  } catch (_) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't share your screen",
          type: HollowToastType.error);
    }
  }
}
