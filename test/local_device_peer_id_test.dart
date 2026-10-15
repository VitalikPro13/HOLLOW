import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// The identity on disk: a throwaway one until a link import replaces it.
class _DiskApi implements RustLibApi {
  String? device;

  @override
  Future<String?> crateApiNetworkGetLocalDevicePeerId() async => device;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Identity extends IdentityNotifier {
  @override
  IdentityState build() => const IdentityState();

  void loaded(String master) =>
      state = IdentityState(peerId: master, isLoaded: true);
}

void main() {
  final api = _DiskApi();
  setUpAll(() => RustLib.initMock(api: api));

  ProviderContainer container() {
    final c = ProviderContainer(overrides: [
      identityProvider.overrideWith(_Identity.new),
    ]);
    addTearDown(c.dispose);
    // Widgets watch it from the first frame, before the shell's bootstrap runs.
    c.listen(localDevicePeerIdProvider, (_, _) {}, fireImmediately: true);
    return c;
  }

  test('the first launch after a link reports the linked device, not the throwaway', () async {
    api.device = 'throwaway-device';
    final c = container();
    await c.read(localDevicePeerIdProvider.future);

    // The pending link import lands, then the identity loads.
    api.device = 'linked-device';
    (c.read(identityProvider.notifier) as _Identity).loaded('presenter-master');

    expect(await c.read(localDevicePeerIdProvider.future), 'linked-device');
  });

  test('nothing is read from disk before an identity has loaded', () async {
    api.device = 'throwaway-device';
    final c = container();
    expect(await c.read(localDevicePeerIdProvider.future), isNull);
  });

  test('an identity swapped in the running app is followed', () async {
    api.device = 'first-device';
    final c = container();
    final identity = c.read(identityProvider.notifier) as _Identity;
    identity.loaded('first-master');
    expect(await c.read(localDevicePeerIdProvider.future), 'first-device');

    api.device = 'second-device';
    identity.loaded('second-master');
    expect(await c.read(localDevicePeerIdProvider.future), 'second-device');
  });
}
