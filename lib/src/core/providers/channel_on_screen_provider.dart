import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// One server channel, as the node's on-screen gate names it.
typedef ScreenChannel = ({String serverId, String channelId});

/// True while the phone shell is the one drawn (phones, tablets, and a desktop
/// window narrower than the tablet breakpoint).
final mobileShellActiveProvider = StateProvider<bool>((ref) => false);

/// True while a desktop window is minimized.
final windowMinimizedProvider = StateProvider<bool>((ref) => false);

/// The phone chat routes showing a server channel, oldest first: the last one
/// is the one on screen. Each route adds itself under its own token.
final mobileChannelRoutesProvider =
    NotifierProvider<MobileChannelRoutes, List<(Object, ScreenChannel)>>(
        MobileChannelRoutes.new);

class MobileChannelRoutes extends Notifier<List<(Object, ScreenChannel)>> {
  @override
  List<(Object, ScreenChannel)> build() => const [];

  void open(Object token, ScreenChannel channel) {
    state = [...state.where((e) => e.$1 != token), (token, channel)];
  }

  void close(Object token) {
    if (state.every((e) => e.$1 != token)) return;
    state = state.where((e) => e.$1 != token).toList();
  }
}

/// Whether the app shows anything at all: a visible window that is not
/// minimized, an app in the foreground, not locked.
@visibleForTesting
bool appOnScreenOf({
  required bool windowVisible,
  required bool windowMinimized,
  required bool appBackground,
  required bool appLocked,
}) =>
    windowVisible && !windowMinimized && !appBackground && !appLocked;

/// The window and lifecycle half of the on-screen rule, for a pane that is not
/// a member's channel (the guest view).
final appOnScreenProvider = Provider<bool>((ref) => appOnScreenOf(
      windowVisible: ref.watch(windowVisibleProvider),
      windowMinimized: ref.watch(windowMinimizedProvider),
      // Only phones feed the lifecycle; a desktop's stays at its first value.
      appBackground: (Platform.isAndroid || Platform.isIOS) &&
          ref.watch(appLifecycleProvider).isBackground,
      appLocked: ref.watch(appLockedProvider),
    ));

/// The server channels on screen, from the parts that decide it. A hidden or
/// minimized window, a backgrounded or locked app, a meeting and any centre tab
/// (Settings, the guest view, Archive...) show none: only a member's own server
/// channel counts.
@visibleForTesting
Set<ScreenChannel> channelsOnScreenOf({
  required bool windowVisible,
  required bool windowMinimized,
  required bool appBackground,
  required bool appLocked,
  required bool mobileShell,
  required List<ScreenChannel> mobileRoutes,
  required String? selectedServer,
  required String? selectedChannel,
  required bool serverSettingsOpen,
  required bool shellTabOpen,
  required PaneContext? rightPane,
}) {
  if (!appOnScreenOf(
    windowVisible: windowVisible,
    windowMinimized: windowMinimized,
    appBackground: appBackground,
    appLocked: appLocked,
  )) {
    return const {};
  }
  bool isServerChannel(String? server, String? channel) =>
      server != null &&
      server.isNotEmpty &&
      channel != null &&
      channel.isNotEmpty &&
      !server.startsWith('conf:');
  if (mobileShell) {
    if (mobileRoutes.isEmpty) return const {};
    final top = mobileRoutes.last;
    return isServerChannel(top.serverId, top.channelId) ? {top} : const {};
  }
  // A centre tab covers the split pane too, and Settings keeps the selection
  // underneath it.
  if (shellTabOpen) return const {};
  final shown = <ScreenChannel>{};
  if (!serverSettingsOpen && isServerChannel(selectedServer, selectedChannel)) {
    shown.add((serverId: selectedServer!, channelId: selectedChannel!));
  }
  final right = rightPane;
  if (right != null &&
      !right.settingsOpen &&
      isServerChannel(right.serverId, right.channelId)) {
    shown.add((serverId: right.serverId!, channelId: right.channelId!));
  }
  return shown;
}

/// The server channels on screen on this device now. Only these take a pushed
/// file's bytes without a tap (Rust `channel_push_allows`).
final channelsOnScreenProvider = Provider<Set<ScreenChannel>>((ref) {
  return channelsOnScreenOf(
    windowVisible: ref.watch(windowVisibleProvider),
    windowMinimized: ref.watch(windowMinimizedProvider),
    // Only phones feed the lifecycle; a desktop's stays at its first value.
    appBackground: (Platform.isAndroid || Platform.isIOS) &&
        ref.watch(appLifecycleProvider).isBackground,
    appLocked: ref.watch(appLockedProvider),
    mobileShell: ref.watch(mobileShellActiveProvider),
    mobileRoutes: [for (final e in ref.watch(mobileChannelRoutesProvider)) e.$2],
    selectedServer: ref.watch(selectedServerProvider),
    selectedChannel: ref.watch(selectedChannelProvider),
    serverSettingsOpen: ref.watch(serverSettingsOpenProvider),
    shellTabOpen: ref.watch(anyShellTabOpenProvider),
    rightPane: ref.watch(splitViewProvider).rightPane,
  );
});

/// Hands the node the channels on screen. Synchronous (in call order) and
/// node-free on the Rust side, so it holds before `start_node()` and across
/// node restarts.
void pushChannelsOnScreen(Set<ScreenChannel> channels) {
  final list = channels.toList();
  try {
    network_api.setChannelsOnScreen(
      serverIds: [for (final c in list) c.serverId],
      channelIds: [for (final c in list) c.channelId],
    );
  } catch (_) {
    // Rust clears the set on a bad call: nothing counts as on screen.
  }
}
