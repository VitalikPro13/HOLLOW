import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';

/// Open [channelId] of [serverId] in the desktop shell from anywhere (a
/// notification, Home's inbox): loads that server's channels and layout, then
/// batches the selection providers in one synchronous block.
///
/// Takes the container, not a `WidgetRef`: the caller is often torn down by the
/// very selection this makes, and the batch runs after the awaits.
Future<void> openServerChannel(
    ProviderContainer container, String serverId, String channelId) async {
  final channels = await ChannelListNotifier.fetchChannels(serverId);
  final layout = await ChannelLayoutNotifier.fetchLayout(serverId);
  final read = container.read;
  setShellTab(read, null);
  read(selectedPeerProvider.notifier).state = null;
  read(serverSettingsOpenProvider.notifier).state = false;
  read(channelListProvider.notifier).setChannels(channels);
  read(channelLayoutProvider.notifier).setLayout(layout, serverId: serverId);
  read(selectedChannelProvider.notifier).state = channelId;
  read(selectedServerProvider.notifier).state = serverId;
  read(lastChannelPerServerProvider.notifier).state = {
    ...read(lastChannelPerServerProvider),
    serverId: channelId,
  };
}
