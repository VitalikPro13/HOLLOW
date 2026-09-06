import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';

/// Open the DM conversation with [peerId] (MASTER identity) in the desktop
/// shell: honors a focused right split pane, closes any exclusive centre tab,
/// and batches the selection providers in one synchronous block.
void openDmConversation(WidgetRef ref, String peerId) {
  final split = ref.read(splitViewProvider);
  if (split.isSplit && split.focusedPane == 1) {
    ref.read(splitViewProvider.notifier).navigateRightToPeer(peerId);
  } else {
    setShellTab(ref.read, null);
    ref.read(selectedPeerProvider.notifier).state = peerId;
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    ref.read(selectedChannelProvider.notifier).state = null;
    ref.read(serverSettingsOpenProvider.notifier).state = false;
  }
  ref.read(unreadProvider.notifier).markDmSeen(peerId, null);
}
