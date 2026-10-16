import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';

void main() {
  // #107: the split view overrides the selection in a child scope around BOTH
  // panes, so a provider that watched it without declaring it threw there and
  // the pane rendered an error instead of the chat.
  test('a voice room chat flag reads inside a scope that overrides the selection',
      () {
    final root = ProviderContainer();
    addTearDown(root.dispose);
    root.read(channelListProvider.notifier).setChannels({
      'vc': const ChannelInfo(
          channelId: 'vc',
          name: 'vc',
          channelType: ChannelType.voice,
          chatOpen: false),
      'tx': const ChannelInfo(channelId: 'tx', name: 'tx'),
    });
    final pane = ProviderContainer(
      parent: root,
      overrides: [selectedServerProvider.overrideWith((ref) => 'srv')],
    );
    addTearDown(pane.dispose);
    expect(pane.read(channelChatOpenProvider((serverId: 'srv', channelId: 'vc'))),
        isFalse);
    expect(pane.read(channelChatOpenProvider((serverId: 'srv', channelId: 'tx'))),
        isTrue);
  });
}
