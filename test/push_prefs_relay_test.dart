// C-RP-06: the relay keeps a phone's push filters, so it gets only what
// differs from the default it is told (`~default`): never the list of servers.
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';

const _default = {
  NotificationSettingsNotifier.defaultPrefKey: {
    'level': 'mentions',
    'channels': <String, String>{},
  },
};

void main() {
  test('servers and channels left at the default never reach the relay', () {
    final prefs = pushPrefsForRelay(
      // Only levels someone chose; a server never set has no entry.
      serverLevels: const {
        'loud': NotificationLevel.all,
        'busy': NotificationLevel.mentions,
        'muted': NotificationLevel.nothing,
      },
      channelOverrides: const {
        // Same as its server: no override at all.
        'loud:lobby': ChannelNotificationLevel.all,
        'busy:alerts': ChannelNotificationLevel.mentions,
        'busy:inherited': ChannelNotificationLevel.inherit,
        'unset:inherited': ChannelNotificationLevel.inherit,
        // These differ, so the relay needs them.
        'loud:noise': ChannelNotificationLevel.nothing,
        'muted:urgent': ChannelNotificationLevel.all,
        'unset:feed': ChannelNotificationLevel.all,
        // A choice in a server never set, though it matches the default.
        'unset:quiet': ChannelNotificationLevel.mentions,
      },
      mutedDmDevices: const {},
    );

    expect(prefs.keys.toSet(),
        {NotificationSettingsNotifier.defaultPrefKey, 'loud', 'busy', 'muted', 'unset'});
    expect(prefs['loud'], {
      'level': 'all',
      'channels': {'noise': 'nothing'},
    }, reason: 'an explicit "All messages" differs from the default, so it is sent');
    expect(prefs['busy'], {'level': 'mentions', 'channels': <String, String>{}});
    expect(prefs['muted'], {
      'level': 'nothing',
      'channels': {'urgent': 'all'},
    });
    expect(prefs['unset'], {
      'level': 'mentions',
      'channels': {'feed': 'all', 'quiet': 'mentions'},
    }, reason: 'a never-set server is named only for its channel choices, all of '
        'them, so a relay older than ~default honours each');
  });

  test('a phone that never set a level sends only the default', () {
    final prefs = pushPrefsForRelay(
      serverLevels: const {},
      channelOverrides: const {'a:x': ChannelNotificationLevel.inherit},
      mutedDmDevices: const {},
    );
    expect(prefs, _default,
        reason: 'the relay replaces the set wholesale; no server is named');
  });

  test("a channel's choice in a never-set server is sent even at the default",
      () {
    final prefs = pushPrefsForRelay(
      serverLevels: const {},
      channelOverrides: const {'quiet:alerts': ChannelNotificationLevel.mentions},
      mutedDmDevices: const {},
    );
    expect(prefs, {
      ..._default,
      'quiet': {
        'level': 'mentions',
        'channels': {'alerts': 'mentions'},
      },
    }, reason: 'a relay older than ~default would wake every post there');
  });

  test('muted DM senders ride the reserved entry by device id', () {
    final prefs = pushPrefsForRelay(
      serverLevels: const {},
      channelOverrides: const {},
      mutedDmDevices: const {'device1', 'device2'},
    );
    expect(prefs, {
      ..._default,
      NotificationSettingsNotifier.dmMutePrefKey: {
        'level': 'all',
        'channels': {'device1': 'nothing', 'device2': 'nothing'},
      },
    });
  });

  group('the never-set default', () {
    const state = NotificationSettingsState(
      serverLevels: {
        'all': NotificationLevel.all,
        'mentions': NotificationLevel.mentions,
      },
      channelOverrides: {'unset:loud': ChannelNotificationLevel.all},
    );

    test('a server never set notifies on mentions but counts every post', () {
      expect(state.serverLevelOf('unset'), NotificationLevel.mentions,
          reason: 'what its settings show');
      expect(state.notifyLevel('unset', 'c'), NotificationLevel.mentions);
      expect(state.unreadLevel('unset', 'c'), NotificationLevel.all);
      expect(state.isServerMuted('unset'), isFalse);
    });

    test('an explicit "All messages" stays all for both', () {
      expect(state.serverLevelOf('all'), NotificationLevel.all);
      expect(state.notifyLevel('all', 'c'), NotificationLevel.all);
      expect(state.unreadLevel('all', 'c'), NotificationLevel.all);
    });

    test('an explicit "Mentions only" keeps mentions-only badges', () {
      expect(state.notifyLevel('mentions', 'c'), NotificationLevel.mentions);
      expect(state.unreadLevel('mentions', 'c'), NotificationLevel.mentions);
    });

    test("a channel's own level wins over the default for both", () {
      expect(state.notifyLevel('unset', 'loud'), NotificationLevel.all);
      expect(state.unreadLevel('unset', 'loud'), NotificationLevel.all);
    });
  });
}
