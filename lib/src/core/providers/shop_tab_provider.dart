import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';

/// Whether the Hollow Shop centre tab is covering the chat area. Written ONLY
/// by [setShellTab] (issue #28's rule): everything else calls [openShopTab] or
/// `setShellTab(read, null)`.
final shopTabOpenProvider = StateProvider<bool>((_) => false);

/// Open the Hollow Shop centre tab: close a split, set our flag through the one
/// switch that knows every sibling tab, and clear the selection providers so
/// closing the tab lands on Home rather than a half-selected server.
void openShopTab(ProviderRead read) {
  final split = read(splitViewProvider);
  if (split.isSplit) {
    read(splitViewProvider.notifier).closeSplit();
  }
  setShellTab(read, ShellTab.shop);
  read(selectedServerProvider.notifier).state = null;
  read(channelListProvider.notifier).clear();
  read(selectedChannelProvider.notifier).state = null;
  read(selectedPeerProvider.notifier).state = null;
  read(serverSettingsOpenProvider.notifier).state = false;
}
