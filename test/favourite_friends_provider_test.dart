/// Favourites are stored by MASTER id: a device id collapses to its master on
/// load, when the device map arrives, and on every read or write, so one
/// friend is never both favourite and not, or stored twice.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';

const _master = 'master_aaa';
const _device = 'device_aaa';
const _other = 'master_bbb';

class _Links extends DeviceLinkNotifier {
  _Links(this.initial);
  final Map<String, String> initial;
  @override
  DeviceLinkState build() => DeviceLinkState(links: initial);
  void set(Map<String, String> links) => state = DeviceLinkState(links: links);
}

class _Stored extends FavouriteFriendsNotifier {
  _Stored(this.raw);
  String? raw;
  final writes = <String>[];
  @override
  Future<String?> readStored() async => raw;
  @override
  Future<void> writeStored(String value) async {
    writes.add(value);
    raw = value;
  }
}

void main() {
  late _Stored store;

  ProviderContainer container(List<String> stored,
      {Map<String, String> links = const {_device: _master}}) {
    store = _Stored(json.encode(stored));
    final c = ProviderContainer(overrides: [
      deviceLinkProvider.overrideWith(() => _Links(links)),
      favouriteFriendsProvider.overrideWith(() => store),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('collapseFavourites maps devices to masters and keeps first place', () {
    String identityOf(String id) => id == _device ? _master : id;
    expect(collapseFavourites([_other, _device, _master], identityOf),
        [_other, _master]);
    expect(collapseFavourites([_master, _master], identityOf), [_master]);
  });

  test('a list holding a device and its master heals on load and is saved',
      () async {
    final c = container([_device, _other, _master]);
    await c.read(favouriteFriendsProvider.notifier).load();
    expect(c.read(favouriteFriendsProvider), [_master, _other]);
    expect(json.decode(store.writes.single), [_master, _other]);
  });

  test('a clean list loads without a write', () async {
    final c = container([_master, _other]);
    await c.read(favouriteFriendsProvider.notifier).load();
    expect(c.read(favouriteFriendsProvider), [_master, _other]);
    expect(store.writes, isEmpty);
  });

  test('the list heals when the device map arrives after load', () async {
    final c = container([_device, _master], links: const {});
    await c.read(favouriteFriendsProvider.notifier).load();
    expect(c.read(favouriteFriendsProvider), [_device, _master]);
    (c.read(deviceLinkProvider.notifier) as _Links)
        .set(const {_device: _master});
    expect(c.read(favouriteFriendsProvider), [_master]);
    expect(json.decode(store.writes.last), [_master]);
  });

  test('a favourite stored under a device id reads as favourite by master',
      () async {
    final c = container([_device], links: const {});
    await c.read(favouriteFriendsProvider.notifier).load();
    // The map is learned only now, as on a slow start; before any heal.
    final n = c.read(favouriteFriendsProvider.notifier);
    expect(n.isFavourite(_device), isTrue);
    (c.read(deviceLinkProvider.notifier) as _Links)
        .set(const {_device: _master});
    expect(n.isFavourite(_master), isTrue);
    expect(n.isFavourite(_device), isTrue);
  });

  test('toggle by master of a device-stored favourite removes it, never adds',
      () async {
    final c = container([_device, _other]);
    final n = c.read(favouriteFriendsProvider.notifier);
    await n.load();
    await n.toggle(_master);
    expect(c.read(favouriteFriendsProvider), [_other]);
    await n.toggle(_device);
    expect(c.read(favouriteFriendsProvider), [_other, _master]);
  });

  test('add stores the master and never a duplicate', () async {
    final c = container([]);
    final n = c.read(favouriteFriendsProvider.notifier);
    await n.add(_device);
    await n.add(_master);
    expect(c.read(favouriteFriendsProvider), [_master]);
  });

  test('remove by device id drops the master entry', () async {
    final c = container([_master, _other]);
    final n = c.read(favouriteFriendsProvider.notifier);
    await n.load();
    await n.remove(_device);
    expect(c.read(favouriteFriendsProvider), [_other]);
  });
}
