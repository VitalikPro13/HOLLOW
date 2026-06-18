import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/peer_info.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/peers_provider.dart';

/// Test stub for the device→master resolver provider: builds with a fixed link
/// map so we don't need the Rust node / FFI. Mirrors `DeviceLinkNotifier` but
/// seeds `build()` from a provided map.
class _StubDeviceLinkNotifier extends DeviceLinkNotifier {
  _StubDeviceLinkNotifier(this._links);
  final Map<String, String> _links;
  @override
  DeviceLinkState build() => DeviceLinkState(links: _links);
}

ProviderContainer _container(Map<String, String> links) {
  return ProviderContainer(
    overrides: [
      deviceLinkProvider.overrideWith(() => _StubDeviceLinkNotifier(links)),
    ],
  );
}

void main() {
  group('multi-device presence collapse (onlineIdentitiesProvider)', () {
    test('a member is online when only their DEVICE id is in peers', () {
      // master "M" has device "D"; only the device is in the relay-reported peers.
      final c = _container({'D': 'M'});
      addTearDown(c.dispose);
      c.read(peersProvider.notifier).addPeer('D', const []);

      final online = c.read(onlineIdentitiesProvider);
      expect(online.contains('M'), isTrue,
          reason: 'member master must show online via its device');
      // The bare device id is NOT what the member panel keys on, but the
      // collapsed set is master-keyed, so D itself should not appear.
      expect(online.contains('D'), isFalse);
    });

    test('two devices of one person collapse to a single online identity', () {
      final c = _container({'D1': 'M', 'D2': 'M'});
      addTearDown(c.dispose);
      c.read(peersProvider.notifier).addPeer('D1', const []);
      c.read(peersProvider.notifier).addPeer('D2', const []);

      final online = c.read(onlineIdentitiesProvider);
      expect(online, equals({'M'}), reason: 'one person = one online identity');
    });

    test('single-device (no links) is a no-op passthrough', () {
      final c = _container({});
      addTearDown(c.dispose);
      c.read(peersProvider.notifier).addPeer('plain_friend', const []);

      final online = c.read(onlineIdentitiesProvider);
      expect(online, equals({'plain_friend'}),
          reason: 'unknown peer resolves to itself (backward compatible)');
    });

    test('invisible device does not make its identity appear online', () {
      final c = _container({'D': 'M'});
      addTearDown(c.dispose);
      c.read(peersProvider.notifier).addPeer('D', const []);
      c.read(invisiblePeersProvider.notifier).setInvisible('D');

      final online = c.read(onlineIdentitiesProvider);
      expect(online.contains('M'), isFalse,
          reason: 'an invisible-only device must not show the identity online');
    });

    test('identityOf resolves device→master and sameIdentity groups siblings', () {
      const s = DeviceLinkState(links: {'D1': 'M', 'D2': 'M'});
      expect(s.identityOf('D1'), 'M');
      expect(s.identityOf('D2'), 'M');
      expect(s.identityOf('unknown'), 'unknown');
      expect(s.sameIdentity('D1', 'D2'), isTrue);
      expect(s.sameIdentity('D1', 'other'), isFalse);
    });
  });
}
