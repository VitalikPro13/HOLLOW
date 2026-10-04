// C-RP-06: the relay keeps a phone's push filters, so it gets only what
// differs from its own default of "all": never the full list of servers.
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';

void main() {
  test('servers and channels left at the default never reach the relay', () {
    final prefs = pushPrefsForRelay(
      serverLevels: const {
        'quiet': NotificationLevel.all,
        'busy': NotificationLevel.mentions,
        'muted': NotificationLevel.nothing,
      },
      channelOverrides: const {
        // Same as its server: no override at all.
        'quiet:lobby': ChannelNotificationLevel.all,
        'busy:alerts': ChannelNotificationLevel.mentions,
        'busy:inherited': ChannelNotificationLevel.inherit,
        // These differ, so the relay needs them.
        'quiet:noise': ChannelNotificationLevel.nothing,
        'muted:urgent': ChannelNotificationLevel.all,
      },
      mutedDmDevices: const {},
    );

    expect(prefs.keys.toSet(), {'quiet', 'busy', 'muted'});
    expect(prefs['quiet'], {
      'level': 'all',
      'channels': {'noise': 'nothing'},
    });
    expect(prefs['busy'], {'level': 'mentions', 'channels': <String, String>{}});
    expect(prefs['muted'], {
      'level': 'nothing',
      'channels': {'urgent': 'all'},
    });
  });

  test('a phone with every default sends an empty filter set', () {
    final prefs = pushPrefsForRelay(
      serverLevels: const {
        'a': NotificationLevel.all,
        'b': NotificationLevel.all,
      },
      channelOverrides: const {'a:x': ChannelNotificationLevel.all},
      mutedDmDevices: const {},
    );
    expect(prefs, isEmpty,
        reason: 'the relay replaces the set wholesale, so {} clears it');
  });

  test('muted DM senders ride the reserved entry by device id', () {
    final prefs = pushPrefsForRelay(
      serverLevels: const {},
      channelOverrides: const {},
      mutedDmDevices: const {'device1', 'device2'},
    );
    expect(prefs, {
      NotificationSettingsNotifier.dmMutePrefKey: {
        'level': 'all',
        'channels': {'device1': 'nothing', 'device2': 'nothing'},
      },
    });
  });
}
