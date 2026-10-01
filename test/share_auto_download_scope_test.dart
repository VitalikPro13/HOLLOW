import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/event_provider.dart';

void main() {
  test('a DM file is judged by the DM setting, never held for a server sync', () {
    expect(
      shareAutoDownloadScope(serverId: '', senderIdentity: 'friend', serverSyncDone: false),
      'dm:friend',
    );
  });

  test('a server file waits for that server catch-up, then uses its setting', () {
    expect(
      shareAutoDownloadScope(serverId: 'srv', senderIdentity: 'friend', serverSyncDone: false),
      isNull,
    );
    expect(
      shareAutoDownloadScope(serverId: 'srv', senderIdentity: 'friend', serverSyncDone: true),
      'server:srv',
    );
  });
}
