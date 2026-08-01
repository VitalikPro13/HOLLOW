import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';

/// The Dart access filters must consume the Rust-computed `meCanSee` /
/// `meCanPost` verbatim — never a re-implemented role ladder. These pin the
/// provider contract after the issue-#32 migration.
class _StaticChannels extends ChannelListNotifier {
  final Map<String, ChannelInfo> channels;
  _StaticChannels(this.channels);
  @override
  Map<String, ChannelInfo> build() => channels;
}

void main() {
  const visible = ChannelInfo(
    channelId: 'c-visible',
    name: 'general',
  );
  const hidden = ChannelInfo(
    channelId: 'c-hidden',
    name: 'vip-lounge',
    visibility: 'admin',
    visibilityLabels: ['vip'],
    meCanSee: false,
    meCanPost: false,
  );
  const readOnly = ChannelInfo(
    channelId: 'c-readonly',
    name: 'announcements',
    posting: 'admin',
    meCanPost: false,
  );

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
      channelListProvider.overrideWith(() => _StaticChannels({
            visible.channelId: visible,
            hidden.channelId: hidden,
            readOnly.channelId: readOnly,
          })),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('visibleChannelsProvider filters on meCanSee', () {
    final c = container();
    c.read(selectedServerProvider.notifier).state = 'srv-1';
    final visibleMap = c.read(visibleChannelsProvider);
    expect(visibleMap.keys, containsAll(['c-visible', 'c-readonly']));
    expect(visibleMap.containsKey('c-hidden'), isFalse,
        reason: 'meCanSee=false must hide the channel regardless of any '
            'Dart-side role knowledge');
  });

  test('visibleChannelsProvider is unfiltered with no selected server', () {
    final c = container();
    expect(c.read(visibleChannelsProvider).length, 3);
  });

  test('canPostInChannelProvider reads meCanPost', () {
    final c = container();
    bool canPost(String id) => c.read(
        canPostInChannelProvider((serverId: 'srv-1', channelId: id)));
    expect(canPost('c-visible'), isTrue);
    expect(canPost('c-readonly'), isFalse);
    expect(canPost('c-hidden'), isFalse);
    expect(canPost('c-unknown'), isTrue,
        reason: 'unknown channel keeps the historical fail-open (the send '
            'path re-checks in Rust)');
  });
}
