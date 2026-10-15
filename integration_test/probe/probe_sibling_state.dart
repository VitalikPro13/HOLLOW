import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt;
import 'package:hollow/src/rust/api/storage.dart' as storage;

/// Probe ops for the sibling-sync journey (`scripts/fleet_md_sibling.ps1`).
///
/// | op | fields | does |
/// |---|---|---|
/// | `sibling_state` | `contact`, `texts` (optional) | `extra['state']` = what the database holds (`db`, with `server_ids` by name) and what the providers show (`ui`): servers, friends, own name, blocked, the selected server's name (`selected`); with `contact`, `dm_missing` = the `texts` that DM lacks |
/// | `server_leave` | `name` | leaves a server as the server settings' Leave does |
/// | `select_server` | `name` | selects a held server as the server rail does |
const siblingOps = {'sibling_state', 'server_leave', 'select_server'};

class SiblingOpFailure implements Exception {
  SiblingOpFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<String> siblingOp(String op, WidgetTester tester,
    ProviderContainer container, Map<String, dynamic> step,
    Map<String, dynamic> extra) async {
  switch (op) {
    case 'sibling_state':
      return _state(tester, container, step, extra);
    case 'server_leave':
      final name = '${step['name'] ?? ''}';
      if (name.isEmpty) throw SiblingOpFailure('server_leave needs "name"');
      final id = await tester.runAsync(() => _serverId(name));
      if (id == null) throw SiblingOpFailure('no server named $name');
      await tester.runAsync(() => crdt.leaveServer(serverId: id));
      return 'left $name';
    case 'select_server':
      final name = '${step['name'] ?? ''}';
      final id = await tester.runAsync(() => _serverId(name));
      if (id == null) throw SiblingOpFailure('no server named $name');
      container.read(selectedServerProvider.notifier).state = id;
      await tester.pump();
      return 'selected $name';
  }
  throw SiblingOpFailure('unknown sibling op "$op"');
}

Future<String> _state(WidgetTester tester, ProviderContainer container,
    Map<String, dynamic> step, Map<String, dynamic> extra) async {
  final contact = '${step['contact'] ?? ''}';
  final texts = [for (final t in (step['texts'] as List? ?? const [])) '$t'];
  final master = container.read(identityProvider).peerId ?? '';
  final db = <String, dynamic>{};
  await tester.runAsync(() async {
    final servers = await crdt.getJoinedServers();
    db['servers'] = [for (final s in servers) s.name]..sort();
    db['server_ids'] = {for (final s in servers) s.name: s.serverId};
    db['friends'] = [
      for (final f in await storage.loadFriends())
        {'id': f.peerId, 'status': f.status, 'direction': f.direction}
    ];
    db['name'] = master.isEmpty ? '' : (await storage.getProfile(peerId: master))?.displayName ?? '';
    db['blocked'] = (await storage.loadBlockedPeers())..sort();
    if (contact.isNotEmpty && texts.isNotEmpty) {
      final held = {for (final r in await storage.loadAllDmMessages(peerId: contact)) r.text};
      db['dm_missing'] = [for (final t in texts) if (!held.contains(t)) t];
    }
  });
  final ui = <String, dynamic>{
    'servers': [for (final s in container.read(serverListProvider).values) s.name]..sort(),
    'friends': [
      for (final f in container.read(friendsProvider).values)
        {'id': f.peerId, 'status': f.status, 'direction': f.direction}
    ],
    'name': container.read(profileProvider)[master]?.displayName ?? '',
    'blocked': container.read(blockedUsersProvider).toList()..sort(),
    'selected': container.read(serverListProvider)[container.read(selectedServerProvider)]?.name ?? '',
  };
  extra['state'] = {'master': master, 'db': db, 'ui': ui};
  return 'sibling_state servers=${(db['servers'] as List).length}/${(ui['servers'] as List).length} '
      'friends=${(db['friends'] as List).length}/${(ui['friends'] as List).length} '
      'blocked=${(db['blocked'] as List).length}/${(ui['blocked'] as List).length}';
}

Future<String?> _serverId(String name) async {
  final found = (await crdt.getJoinedServers()).where((s) => s.name == name);
  return found.isEmpty ? null : found.first.serverId;
}
