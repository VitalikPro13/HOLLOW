/// status.json v2: signed, stamped, `notices[]` targeted by relay, platform and
/// version, with per-notice expiry and per-id dismissal. The old top-level
/// fields belong to apps up to 0.12.1 and are never read here.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/version_compare.dart';

class _Relay extends RelayDomainNotifier {
  _Relay(this.domain);
  final String domain;
  @override
  String build() => domain;
}

/// Stands in for the network and the settings store.
class _World {
  /// What the host serves; null = the signed fetch fails (unsigned, forged,
  /// offline: Rust reports them all the same way).
  String? served;
  final kv = <String, String>{};
  final fetchedFeeds = <String>[];
  DateTime now = DateTime.utc(2026, 10, 20, 12);
  String platform = 'windows';
  String relay = kDefaultRelayDomain;
  String running = '0.12.1';

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
      signedFeedFetchProvider.overrideWithValue((url, feed) async {
        fetchedFeeds.add(feed);
        final s = served;
        if (s == null) throw Exception('Feed signature does not verify');
        return s;
      }),
      statusFeedEnvProvider.overrideWithValue(StatusFeedEnv(
        load: (k) async => kv[k],
        save: (k, v) async => kv[k] = v,
        now: () => now,
        platform: platform,
      )),
      relayDomainProvider.overrideWith(() => _Relay(relay)),
      runningReleaseProvider.overrideWithValue(ReleaseId.parse(running)!),
    ]);
    addTearDown(c.dispose);
    return c;
  }
}

/// A notice whose every read throws, as no JSON can but a future field might.
class _ThrowingMap extends MapBase<String, dynamic> {
  @override
  dynamic operator [](Object? key) => throw StateError('unreadable');
  @override
  void operator []=(String key, dynamic value) {}
  @override
  void clear() {}
  @override
  Iterable<String> get keys => const ['id', 'level'];
  @override
  dynamic remove(Object? key) => null;
}

Map<String, Object> notice(String id,
        {String level = 'warning', Map<String, Object> extra = const {}}) =>
    {
      'id': id,
      'level': level,
      'title': 'Notice $id',
      'expires': '2026-11-01T00:00:00Z',
      ...extra,
    };

String feed(int issued, List<Map<String, Object>> notices,
        {Map<String, Object> legacy = const {}}) =>
    jsonEncode({...legacy, 'issued': issued, 'notices': notices});

Future<List<String>> _visibleIds(_World w) async {
  final c = w.container();
  await c.read(statusProvider.notifier).loadDismissed();
  await c.read(statusProvider.notifier).refresh();
  return [for (final n in c.read(statusProvider).notices) n.id];
}

void main() {
  group('targeting', () {
    test('the relay tag decides who hears a notice', () async {
      final w = _World()
        ..served = feed(1, [
          notice('default'),
          notice('official', extra: {'relay': 'official'}),
          notice('self', extra: {'relay': 'self_hosted'}),
          notice('all', extra: {'relay': 'all'}),
        ]);
      expect(await _visibleIds(w), ['default', 'official', 'all']);
      w.relay = 'relay.example.org';
      expect(await _visibleIds(w), ['self', 'all']);
    });

    test('a self-hosted install fetches, and an outage notice never reaches it',
        () async {
      final w = _World()
        ..relay = 'relay.example.org'
        ..served = feed(1, [notice('outage', level: 'critical')]);
      expect(await _visibleIds(w), isEmpty);
      expect(w.fetchedFeeds, allOf(isNotEmpty, everyElement('status')));
    });

    test('platforms list the ones that hear it', () async {
      final w = _World()
        ..served = feed(1, [
          notice('desktop', extra: {
            'platforms': ['windows', 'linux']
          }),
          notice('phones', extra: {
            'platforms': ['android', 'ios']
          }),
          notice('everyone'),
        ]);
      expect(await _visibleIds(w), ['desktop', 'everyone']);
      w.platform = 'ios';
      expect(await _visibleIds(w), ['phones', 'everyone']);
    });

    test('below and from gate by version and build', () async {
      final w = _World()
        ..served = feed(1, [
          notice('old', extra: {'below': '0.12.2'}),
          notice('pre-patch', extra: {'below': '0.12.2+1'}),
          notice('new', extra: {'from': '0.12.2'}),
          notice('window', extra: {'from': '0.12.2', 'below': '0.12.3'}),
        ]);
      w.running = '0.12.1';
      expect(await _visibleIds(w), ['old', 'pre-patch']);
      w.running = '0.12.2';
      expect(await _visibleIds(w), ['pre-patch', 'new', 'window']);
      w.running = '0.12.2+1';
      expect(await _visibleIds(w), ['new', 'window']);
      w.running = '0.12.3';
      expect(await _visibleIds(w), ['new']);
    });

    test('an expired notice is gone even while the host still serves it',
        () async {
      final w = _World()..served = feed(1, [notice('a')]);
      expect(await _visibleIds(w), ['a']);
      w.now = DateTime.utc(2026, 11, 1);
      expect(await _visibleIds(w), isEmpty);
    });

    test('a notice this build cannot target safely is skipped, not guessed',
        () async {
      final w = _World()
        ..served = feed(1, [
          {'id': 'no-expiry', 'level': 'warning', 'title': 'x'},
          notice('bad-relay', extra: {'relay': 'selfhosted'}),
          notice('bad-below', extra: {'below': 'soon'}),
          notice('bad-platforms', extra: {'platforms': 'windows'}),
          {'level': 'warning', 'title': 'no id', 'expires': '2026-11-01T00:00:00Z'},
          notice('fine'),
        ]);
      expect(await _visibleIds(w), ['fine']);
    });

    test('the legacy top-level notice is for old apps only', () async {
      final w = _World()
        ..served = feed(1, [], legacy: {
          'id': 'legacy',
          'level': 'warning',
          'title': 'Update to 0.12.2',
          'message': 'Old apps read this',
        });
      final c = w.container();
      await c.read(statusProvider.notifier).refresh();
      expect(c.read(statusProvider).status.isEmpty, isTrue);
      expect(c.read(statusProvider).showBanner, isFalse);
    });
  });

  group('signature and stamp', () {
    test('an unsigned or forged feed shows nothing, never an error', () async {
      final w = _World()..served = null;
      final c = w.container();
      expect(await c.read(statusProvider.notifier).refresh(), isFalse);
      expect(c.read(statusProvider).hasFetched, isTrue);
      expect(c.read(statusProvider).showBanner, isFalse);
      expect(c.read(statusProvider).status.isEmpty, isTrue);
    });

    test('a feed without a stamp is dropped', () async {
      final w = _World()
        ..served = jsonEncode({
          'notices': [notice('a')]
        });
      expect(await _visibleIds(w), isEmpty);
    });

    test('a re-served older copy cannot bring a stale notice back', () async {
      final w = _World()..served = feed(200, []);
      final c = w.container();
      await c.read(statusProvider.notifier).loadDismissed();
      await c.read(statusProvider.notifier).refresh();
      expect(w.kv['status_feed_issued'], '200');

      w.served = feed(100, [notice('stale', level: 'critical')]);
      await c.read(statusProvider.notifier).refresh();
      expect(c.read(statusProvider).notices, isEmpty);

      // The next launch remembers the stamp.
      final again = w.container();
      await again.read(statusProvider.notifier).loadDismissed();
      await again.read(statusProvider.notifier).refresh();
      expect(again.read(statusProvider).notices, isEmpty);

      // The same stamp is the same file, polled again: still shown.
      w.served = feed(200, [notice('current')]);
      await again.read(statusProvider.notifier).refresh();
      expect([for (final n in again.read(statusProvider).notices) n.id],
          ['current']);
    });

    test('a stored stamp read after the first fetch still drops the old copy',
        () async {
      final w = _World()..kv['status_feed_issued'] = '300';
      w.served = feed(100, [notice('stale')]);
      final c = w.container();
      await c.read(statusProvider.notifier).refresh();
      await c.read(statusProvider.notifier).loadDismissed();
      expect(c.read(statusProvider).notices, isEmpty);
      expect(w.kv['status_feed_issued'], '300');
    });
  });

  group('review round 1', () {
    test('one unreadable notice never hides the others', () async {
      final w = _World()
        ..served = jsonEncode({
          'issued': 10,
          'notices': [
            notice('future-shape', extra: {'level': {'base': 'warning'}}),
            notice('relay-number', extra: {'relay': 5}),
            notice('expires-number', extra: {'expires': 7}),
            notice('platforms-map', extra: {'platforms': {'windows': true}}),
            {'id': 3, 'level': 'warning', 'title': 'x', 'expires': '2026-11-01T00:00:00Z'},
            'not a notice',
            notice('update-now', level: 'critical'),
          ],
        });
      expect(await _visibleIds(w), ['update-now']);
    });

    test('a notice whose level is not text is skipped, not read as healthy',
        () {
      for (final level in <Object>[{'base': 'warning'}, 3, true, ['critical']]) {
        expect(SystemStatus.fromNotice(notice('x', extra: {'level': level})),
            isNull,
            reason: '$level');
      }
      expect(SystemStatus.fromNotice(notice('x'))?.level, StatusLevel.warning);
    });

    test('a notice that throws while it is read is skipped', () {
      expect(StatusFeed.readNotice(_ThrowingMap()), isNull);
      expect(StatusFeed.readNotice(notice('ok'))?.id, 'ok');
    });

    // A suffix-less time at DateTime's edge parses as local, then throws when
    // relabelled as UTC: the first east of UTC, the second west of it.
    test('a notice whose time throws while it is read never takes the feed '
        'down', () {
      final parsed = StatusFeed.parse(jsonEncode({
        'issued': 10,
        'notices': [
          notice('edge-east', extra: {'expires': '+275760-09-13T01:00:00'}),
          notice('edge-west', extra: {'expires': '-271821-04-19T23:00:00'}),
          notice('ok'),
        ],
      }));
      expect([for (final n in parsed!.notices) n.id], ['ok']);
    });

    test('a notice with platforms null reaches nobody', () {
      final parsed = StatusFeed.parse(jsonEncode({
        'issued': 10,
        'notices': [
          {...notice('null-platforms'), 'platforms': null},
          notice('ok'),
        ],
      }));
      expect([for (final n in parsed!.notices) n.id], ['ok']);
    });

    test('a copy older than the stored stamp never shows, even before the '
        'store loads', () async {
      final w = _World()
        ..kv['status_feed_issued'] = '500'
        ..served = feed(100, [notice('old-outage', level: 'critical')]);
      final c = w.container();
      await c.read(statusProvider.notifier).refresh();
      expect(c.read(statusProvider).bannerNotice, isNull);
      expect(c.read(statusProvider).notices, isEmpty);
      await c.read(statusProvider.notifier).loadDismissed();
      expect(c.read(statusProvider).notices, isEmpty);
    });

    test('a current copy fetched before the store loads shows once it loads',
        () async {
      final w = _World()
        ..kv['status_feed_issued'] = '500'
        ..served = feed(600, [notice('current', level: 'critical')]);
      final c = w.container();
      await c.read(statusProvider.notifier).refresh();
      expect(c.read(statusProvider).notices, isEmpty);
      await c.read(statusProvider.notifier).loadDismissed();
      expect(c.read(statusProvider).bannerNotice?.id, 'current');
      expect(w.kv['status_feed_issued'], '600');
    });

    test('a store that cannot be read still lets the feed show', () async {
      final w = _World()..served = feed(5, [notice('a')]);
      final c = ProviderContainer(overrides: [
        signedFeedFetchProvider.overrideWithValue((url, f) async => w.served!),
        statusFeedEnvProvider.overrideWithValue(StatusFeedEnv(
          load: (k) async => throw Exception('store closed'),
          save: (k, v) async => throw Exception('store closed'),
          now: () => w.now,
          platform: 'windows',
        )),
        relayDomainProvider.overrideWith(() => _Relay(kDefaultRelayDomain)),
        runningReleaseProvider.overrideWithValue(ReleaseId.parse('0.12.2')!),
      ]);
      addTearDown(c.dispose);
      await c.read(statusProvider.notifier).loadDismissed();
      await c.read(statusProvider.notifier).refresh();
      expect([for (final n in c.read(statusProvider).notices) n.id], ['a']);
    });

    test('a stamp far ahead of this clock shows but is never kept past now plus '
        'an hour', () async {
      final w = _World();
      final nowS = w.now.millisecondsSinceEpoch ~/ 1000;
      final far = nowS + 10 * 365 * 86400;
      w.served = feed(far, [notice('from-the-future')]);
      final c = w.container();
      await c.read(statusProvider.notifier).loadDismissed();
      await c.read(statusProvider.notifier).refresh();
      expect([for (final n in c.read(statusProvider).notices) n.id],
          ['from-the-future']);
      final kept = int.parse(w.kv['status_feed_issued']!);
      expect(kept, lessThanOrEqualTo(nowS + 3600));

      // Two hours on, the next real feed shows, in this session and the next.
      w.now = w.now.add(const Duration(hours: 2));
      w.served = feed(nowS + 7200, [notice('next')]);
      await c.read(statusProvider.notifier).refresh();
      expect([for (final n in c.read(statusProvider).notices) n.id], ['next']);
      final again = w.container();
      await again.read(statusProvider.notifier).loadDismissed();
      await again.read(statusProvider.notifier).refresh();
      expect([for (final n in again.read(statusProvider).notices) n.id], ['next']);
    });

    test('a stored stamp far ahead of this clock is capped when it loads',
        () async {
      final w = _World();
      final nowS = w.now.millisecondsSinceEpoch ~/ 1000;
      w.kv['status_feed_issued'] = '${nowS * 1000}';
      // Capped to this clock plus an hour: hidden at most that long.
      w.served = feed(nowS + 3600, [notice('next')]);
      expect(await _visibleIds(w), ['next']);
      expect(int.parse(w.kv['status_feed_issued']!), nowS + 3600);
      w.served = feed(nowS, [notice('within-the-hour')]);
      expect(await _visibleIds(w), isEmpty);
    });
  });

  group('several notices', () {
    test('the banner shows the most severe one not dismissed', () async {
      final w = _World()
        ..served = feed(1, [
          notice('info', level: 'info'),
          notice('crit', level: 'critical'),
          notice('warn', level: 'warning'),
          notice('ok', level: 'operational'),
        ]);
      final c = w.container();
      await c.read(statusProvider.notifier).loadDismissed();
      await c.read(statusProvider.notifier).refresh();
      expect(c.read(statusProvider).bannerNotice!.id, 'crit');
      expect(c.read(statusProvider).status.id, 'crit');

      await c.read(statusProvider.notifier).dismiss('crit');
      expect(c.read(statusProvider).bannerNotice!.id, 'warn');
      // The calm card keeps the most severe one.
      expect(c.read(statusProvider).status.id, 'crit');
      await c.read(statusProvider.notifier).dismiss('warn');
      await c.read(statusProvider.notifier).dismiss('info');
      expect(c.read(statusProvider).showBanner, isFalse);

      final again = w.container();
      await again.read(statusProvider.notifier).loadDismissed();
      await again.read(statusProvider.notifier).refresh();
      expect(again.read(statusProvider).showBanner, isFalse);
    });

    test('dismissals are remembered per id and bounded', () async {
      final w = _World()..kv['dismissed_status_id'] = 'from-0.12.1';
      final c = w.container();
      await c.read(statusProvider.notifier).loadDismissed();
      for (var i = 0; i < 40; i++) {
        await c.read(statusProvider.notifier).dismiss('n$i');
      }
      final kept = (jsonDecode(w.kv['dismissed_status_ids']!) as List).cast<String>();
      expect(kept.length, 32);
      expect(kept.last, 'n39');
      expect(kept, isNot(contains('from-0.12.1')));
      expect(c.read(statusProvider).dismissedIds.length, 32);
    });

    test('a legacy dismissal still holds for the same id', () async {
      final w = _World()
        ..kv['dismissed_status_id'] = 'same'
        ..served = feed(1, [notice('same')]);
      final c = w.container();
      await c.read(statusProvider.notifier).loadDismissed();
      await c.read(statusProvider.notifier).refresh();
      expect(c.read(statusProvider).showBanner, isFalse);
    });
  });

  group('news', () {
    test('news is fetched as the signed news feed, and a refusal keeps the posts',
        () async {
      final w = _World()
        ..served = jsonEncode([
          {'id': 'p1', 'date': 'x', 'title': 'Hello', 'body': 'b'}
        ]);
      final c = w.container();
      final n = c.read(newsProvider.notifier);
      expect(await n.refresh(), isTrue);
      expect(w.fetchedFeeds, contains('news'));
      expect(c.read(newsProvider).posts.single.id, 'p1');
      w.served = null;
      expect(await n.refresh(), isFalse);
      expect(c.read(newsProvider).posts.single.id, 'p1');
    });
  });

  test('a local time with no UTC twin reads as no time', () {
    for (final t in ['+275760-09-13T01:00:00', '-271821-04-19T23:00:00']) {
      expect(() => SystemStatus.parseUtc(t), returnsNormally);
    }
  });
}
