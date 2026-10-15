import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/staged_attachments.dart';
import 'package:path_provider/path_provider.dart';

/// Content a linking journey seeds through the app's own providers, so every
/// platform builds the same populated identity without driving its UI. The
/// link itself is always driven through the UI; only what it carries is
/// seeded here.
///
/// | op | args | does |
/// |---|---|---|
/// | `seed_server` | `name`, `as` | creates a server; captures its invite link |
/// | `seed_join` | `invite` | asks to join from a whole invite link |
/// | `seed_dm` | `contact`, `text` | a DM to a master id |
/// | `seed_channel` | `server`, `channel`, `text` | a post in a channel by name |
/// | `seed_image` | `contact` or `server` + `channel`, `name` | a generated PNG, as the composer sends one |
/// | `seed_avatar` | | a generated avatar on the own profile |
/// | `seed_delete_server` | `name` | the owner deletes a server it created |
const linkSeedOps = {
  'seed_server',
  'seed_join',
  'seed_dm',
  'seed_channel',
  'seed_image',
  'seed_avatar',
  'seed_delete_server',
};

class LinkSeedFailure implements Exception {
  LinkSeedFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

Future<String> linkSeedOp(String op, WidgetTester tester,
    ProviderContainer container, Map<String, dynamic> step,
    Map<String, dynamic> extra) async {
  String arg(String key) {
    final value = '${step[key] ?? ''}';
    if (value.isEmpty) throw LinkSeedFailure('$op needs "$key"');
    return value;
  }

  switch (op) {
    case 'seed_server':
      final name = arg('name');
      final invite = await tester.runAsync(() async {
        await crdt.createServer(name: name);
        final id = await _serverId(name, const Duration(seconds: 30));
        return serverInviteLinkFor(id, relay: container.read(relayDomainProvider));
      });
      final as = '${step['as'] ?? 'INVITE'}';
      extra['captured'] = {as: invite};
      extra['value'] = invite;
      return 'created $name, invite captured as $as';
    case 'seed_join':
      final invite = inviteFromInput(arg('invite'), HollowLinkType.serverInvite);
      if (!isServerIdShape(invite.id) || invite.key == null) {
        throw LinkSeedFailure('not a whole server invite: ${step['invite']}');
      }
      await tester.runAsync(() => crdt.joinServer(
            serverId: invite.id.toLowerCase(),
            nsfwConfirmed: false,
            ownerPin: invite.owner,
            joinKey: invite.key,
          ));
      return 'asked to join ${invite.id}';
    case 'seed_dm':
      final contact = arg('contact');
      final text = arg('text');
      await tester.runAsync(
          () => container.read(chatProvider.notifier).sendMessage(contact, text));
      return 'sent a DM to $contact';
    case 'seed_channel':
      final text = arg('text');
      final where = await tester.runAsync(
          () => _channel(arg('server'), '${step['channel'] ?? 'general'}'));
      await tester.runAsync(() => container
          .read(channelChatProvider.notifier)
          .sendMessage(where!.$1, where.$2, text));
      return 'posted in ${step['server']}';
    case 'seed_image':
      return _seedImage(tester, container, step, arg('name'));
    case 'seed_avatar':
      await tester.runAsync(() async {
        final me = container.read(identityProvider).peerId ?? '';
        final current = container.read(profileProvider)[me];
        final png = await _png('avatar-$me', 256);
        final processed = await network_api.processAvatar(rawBytes: png);
        await container.read(profileProvider.notifier).updateMyProfile(
              displayName: current?.displayName ?? '',
              status: current?.status ?? '',
              aboutMe: current?.aboutMe ?? '',
              avatarBytes: processed,
              twitchUsername: current?.twitchUsername ?? '',
            );
      });
      return 'set a generated avatar';
    case 'seed_delete_server':
      final name = arg('name');
      await tester.runAsync(() async =>
          crdt.deleteServer(serverId: await _serverId(name, const Duration(seconds: 5))));
      return 'deleted $name';
  }
  throw LinkSeedFailure('unknown seed op "$op"');
}

Future<String> _seedImage(WidgetTester tester, ProviderContainer container,
    Map<String, dynamic> step, String name) async {
  final contact = '${step['contact'] ?? ''}';
  final server = '${step['server'] ?? ''}';
  if (contact.isEmpty == server.isEmpty) {
    throw LinkSeedFailure('seed_image takes "contact" or "server", one of them');
  }
  final outcome = await tester.runAsync(() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}$name.png');
    await file.writeAsBytes(await _png(name, 320));
    final item = StagedAttachment.fromPath(file.path);
    final files = container.read(fileTransferProvider.notifier);
    if (contact.isNotEmpty) {
      return sendStagedAttachments(
        items: [item],
        caption: name,
        addOptimistic: (i, mid, text, album) => container
            .read(chatProvider.notifier)
            .addFileMessage(contact, mid, i.name, i.sizeBytes, i.ext, i.isImage,
                i.path, text: text, albumId: album),
        send: (i, mid, text, album) => files.sendFile(
            peerId: contact,
            filePath: i.path,
            messageId: mid,
            messageText: text,
            album: album),
      );
    }
    final where = await _channel(server, '${step['channel'] ?? 'general'}');
    return sendStagedAttachments(
      items: [item],
      caption: name,
      addOptimistic: (i, mid, text, album) => container
          .read(channelChatProvider.notifier)
          .addFileMessage(where.$1, where.$2, mid, i.name, i.sizeBytes, i.ext,
              i.isImage, i.path, text: text, albumId: album),
      send: (i, mid, text, album) => files.sendFile(
          serverId: where.$1,
          channelId: where.$2,
          filePath: i.path,
          messageId: mid,
          messageText: text,
          album: album),
    );
  });
  if (outcome == null || outcome.failed > 0) {
    throw LinkSeedFailure('the image send failed: ${outcome?.firstError}');
  }
  return 'sent image $name';
}

Future<String> _serverId(String name, Duration within) async {
  final deadline = DateTime.now().add(within);
  while (true) {
    final found = (await crdt.getJoinedServers()).where((s) => s.name == name);
    if (found.isNotEmpty) return found.first.serverId;
    if (DateTime.now().isAfter(deadline)) {
      throw LinkSeedFailure('no server named $name appeared');
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
}

Future<(String, String)> _channel(String server, String channel) async {
  final serverId = await _serverId(server, const Duration(seconds: 5));
  final channels = await crdt.getServerChannels(serverId: serverId);
  final found = channels.where((c) => c.name == channel);
  if (found.isEmpty) throw LinkSeedFailure('no channel $channel in $server');
  return (serverId, found.first.channelId);
}

/// A PNG unique to [seed]: content-addressed file ids would fold two
/// identical images into one.
Future<List<int>> _png(String seed, int size) async {
  final hue = (seed.hashCode % 360).abs().toDouble();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final s = size.toDouble();
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, s, s),
      ui.Paint()..color = HSVColor.fromAHSV(1, hue, 0.6, 0.9).toColor());
  canvas.drawCircle(ui.Offset(s / 2, s / 2), s / 3,
      ui.Paint()..color = HSVColor.fromAHSV(1, (hue + 180) % 360, 0.7, 0.6).toColor());
  final image = await recorder.endRecording().toImage(size, size);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
