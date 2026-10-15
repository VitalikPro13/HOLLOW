import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/api/storage.dart' as storage;

import 'probe_env.dart';

/// What a device holds after a link, read from the DATABASE and the roster
/// rather than from widgets, so a linking matrix judges what landed and not
/// what happens to be built on screen.
///
/// Args: `dm` (a contact's master id), `server` (a server NAME), `channel`
/// (default `general`), `tag` (only bodies containing it are listed).
/// The answer's `state` carries identity, own profile, roster, own devices,
/// friends, servers, and the DM and channel rows with their files.
Future<String> linkStateOp(WidgetTester tester, ProviderContainer container,
    Map<String, dynamic> step, Map<String, dynamic> extra) async {
  final dm = '${step['dm'] ?? ''}';
  final serverName = '${step['server'] ?? ''}';
  final channelName = '${step['channel'] ?? 'general'}';
  final tag = '${step['tag'] ?? ''}';
  final state = <String, dynamic>{};

  final identity = container.read(identityProvider);
  final master = identity.peerId ?? '';
  state['master'] = master;

  await tester.runAsync(() async {
    // What the app's provider says this device is, and what the key on disk
    // says: they must agree once an identity runs.
    state['device'] = await container.read(localDevicePeerIdProvider.future);
    state['device_disk'] = await network_api.getLocalDevicePeerId();

    final profile = master.isEmpty ? null : await storage.getProfile(peerId: master);
    state['profile'] = {
      'name': profile?.displayName ?? '',
      'avatar_bytes': profile?.avatarBytes?.length ?? 0,
    };

    try {
      final roster = await roster_api.rosterStatus();
      state['roster'] = [
        for (final d in roster.devices)
          {'device': d.devicePeerId, 'state': d.state, 'this': d.thisDevice}
      ];
    } catch (e) {
      state['roster_error'] = '$e';
    }

    state['my_devices'] = [
      for (final d in container.read(myDevicesProvider))
        {'device': d.peerId, 'online': d.online, 'this': d.isThisDevice, 'kind': d.kind}
    ];

    state['friends'] = [
      for (final f in await storage.loadFriends())
        {'id': f.peerId, 'status': f.status}
    ];

    final servers = await crdt.getJoinedServers();
    state['servers'] = [for (final s in servers) s.name];

    if (dm.isNotEmpty) {
      final rows = await storage.loadAllDmMessages(peerId: dm);
      state['dm'] = await _rows(
        rows.map((r) => _Row(r.messageId, r.text, r.isMine)).toList(),
        tag,
      );
    }

    if (serverName.isNotEmpty) {
      final server = servers.where((s) => s.name == serverName).firstOrNull;
      if (server == null) {
        state['channel'] = {'error': 'no server named $serverName'};
      } else {
        final channels = await crdt.getServerChannels(serverId: server.serverId);
        final channel = channels.where((c) => c.name == channelName).firstOrNull;
        if (channel == null) {
          state['channel'] = {'error': 'no channel named $channelName'};
        } else {
          final rows = await storage.loadAllChannelMessages(
            serverId: server.serverId,
            channelId: channel.channelId,
          );
          state['channel'] = await _rows(
            rows.map((r) => _Row(r.messageId, r.text, r.isMine)).toList(),
            tag,
          );
          state['channel']['server_id'] = server.serverId;
          state['channel']['channel_id'] = channel.channelId;
        }
      }
    }
  });

  extra['state'] = state;
  final roster = (state['roster'] as List?)?.length ?? -1;
  return 'link_state master=$master device=${state['device']} '
      'roster=$roster friends=${(state['friends'] as List).length} '
      'servers=${(state['servers'] as List).length}'
      '${state['dm'] == null ? '' : ' dm=${state['dm']['count']}'}'
      '${state['channel'] == null ? '' : ' channel=${state['channel']['count']}'}';
}

String _norm(String path) => path.replaceAll('\\', '/').toLowerCase();

class _Row {
  _Row(this.mid, this.text, this.mine);
  final String? mid;
  final String text;
  final bool mine;
}

/// Bodies (filtered by `tag`) and every file row behind the messages, with
/// whether its bytes are complete and on disk.
Future<Map<String, dynamic>> _rows(List<_Row> rows, String tag) async {
  final texts = <String>[];
  final files = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (tag.isEmpty || row.text.contains(tag)) texts.add(row.text);
    final mid = row.mid;
    if (mid == null) continue;
    for (final f in await storage.getFilesForMessage(messageId: mid)) {
      final path = f.diskPath;
      final root = probeEnv['HOLLOW_DATA_DIR'] ?? '';
      files.add({
        'name': f.fileName,
        'image': f.isImage,
        'size': f.sizeBytes.toInt(),
        'mine': f.isMine,
        'completed': f.completedAt != null,
        'on_disk': path != null && File(path).existsSync(),
        // A row imported from another device can still name THAT device's path.
        'own_path': path != null &&
            root.isNotEmpty &&
            _norm(path).startsWith(_norm(root)),
        'path': path ?? '',
      });
    }
  }
  return {'count': rows.length, 'texts': texts, 'files': files};
}
