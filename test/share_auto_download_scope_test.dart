import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/event_provider.dart';

void main() {
  test('a DM file is judged by the DM setting, never held for a server sync', () {
    expect(
      shareAutoDownloadScope(
          serverId: '', senderIdentity: 'friend', serverSyncDone: false, channelOnScreen: false),
      'dm:friend',
    );
  });

  test('a server file waits for that server catch-up, then uses its setting', () {
    expect(
      shareAutoDownloadScope(
          serverId: 'srv', senderIdentity: 'friend', serverSyncDone: false, channelOnScreen: true),
      isNull,
    );
    expect(
      shareAutoDownloadScope(
          serverId: 'srv', senderIdentity: 'friend', serverSyncDone: true, channelOnScreen: true),
      'server:srv',
    );
  });

  test('a server file in a channel not on screen never starts by itself', () {
    expect(
      shareAutoDownloadScope(
          serverId: 'srv', senderIdentity: 'friend', serverSyncDone: true, channelOnScreen: false),
      isNull,
    );
  });
}
