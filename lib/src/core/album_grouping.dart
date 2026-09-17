import 'dart:math';

import 'package:hollow/src/core/message_tokens.dart';
import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';

/// Most files one album carries. A longer run with the same id renders as a
/// second group rather than an eleventh tile.
const kMaxAlbumItems = 10;

/// A fresh album id: a random v4 UUID, the shape Rust requires before it
/// signs or accepts one.
String generateAlbumId() {
  final rng = Random.secure();
  final b = List<int>.generate(16, (_) => rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// The album's caption: the first item text that is more than a file token,
/// or empty. Not always the first item's, since a caption must survive an item
/// that sorts ahead of the one it was typed on.
String albumCaption(Iterable<String> texts) {
  for (final t in texts) {
    if (t.replaceAll(fileTokenRegex, '').trim().isNotEmpty) return t;
  }
  return '';
}

/// A message list with every album folded into its first item.
class AlbumCollapse<T> {
  /// What the list renders: plain messages and album anchors, in order.
  final List<T> display;

  /// Every item of a group of two or more, anchor first, keyed by the
  /// anchor's message id.
  final Map<String, List<T>> itemsByAnchorId;

  /// Anchor message id for every grouped item, the anchor included.
  final Map<String, String> anchorIdByItemId;

  const AlbumCollapse._(this.display, this.itemsByAnchorId, this.anchorIdByItemId);

  /// The group [message] anchors, or null when it renders on its own.
  List<T>? itemsFor(String? messageId) =>
      messageId == null ? null : itemsByAnchorId[messageId];
}

/// Folds albums in [messages] (chronological) into their earliest item.
///
/// Items group by sender AND album id, so nobody can graft a file into
/// someone else's album by reusing its id. A group with one loaded item stays
/// a plain message until its siblings arrive. Only live file messages group:
/// a hidden row or one without an id renders as it always has.
AlbumCollapse<T> collapseAlbums<T>(
  List<T> messages, {
  required String? Function(T) albumIdOf,
  required String? Function(T) messageIdOf,
  required String Function(T) senderOf,
  required bool Function(T) isGroupable,
}) {
  final groups = <String, List<List<int>>>{};
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    final album = albumIdOf(m);
    if (album == null || album.isEmpty) continue;
    if (messageIdOf(m) == null || !isGroupable(m)) continue;
    final runs = groups.putIfAbsent('${senderOf(m)}|$album', () => [[]]);
    if (runs.last.length == kMaxAlbumItems) runs.add([]);
    runs.last.add(i);
  }
  if (groups.isEmpty) return AlbumCollapse._(messages, const {}, const {});

  final hidden = <int>{};
  final itemsByAnchor = <String, List<T>>{};
  final anchorByItem = <String, String>{};
  for (final runs in groups.values) {
    for (final run in runs) {
      if (run.length < 2) continue;
      final anchorId = messageIdOf(messages[run.first])!;
      itemsByAnchor[anchorId] = [for (final i in run) messages[i]];
      for (final i in run) {
        anchorByItem[messageIdOf(messages[i])!] = anchorId;
        if (i != run.first) hidden.add(i);
      }
    }
  }
  if (hidden.isEmpty) return AlbumCollapse._(messages, const {}, const {});
  return AlbumCollapse._(
    [
      for (var i = 0; i < messages.length; i++)
        if (!hidden.contains(i)) messages[i],
    ],
    itemsByAnchor,
    anchorByItem,
  );
}

/// [collapseAlbums] for a DM, where the only two senders are us and them.
AlbumCollapse<ChatMessage> collapseDmAlbums(List<ChatMessage> messages) =>
    collapseAlbums<ChatMessage>(
      messages,
      albumIdOf: (m) => m.albumId,
      messageIdOf: (m) => m.messageId,
      senderOf: (m) => m.isMe ? 'me' : 'them',
      isGroupable: (m) => m.fileAttachment != null && m.hiddenAt == null,
    );

/// [collapseAlbums] for a channel. [identityOf] collapses a device id to its
/// master, so one sender's items group whichever id a row carries.
AlbumCollapse<ChannelChatMessage> collapseChannelAlbums(
  List<ChannelChatMessage> messages, {
  required String Function(String) identityOf,
}) =>
    collapseAlbums<ChannelChatMessage>(
      messages,
      albumIdOf: (m) => m.albumId,
      messageIdOf: (m) => m.messageId,
      senderOf: (m) => identityOf(m.senderId),
      isGroupable: (m) => m.fileAttachment != null && m.hiddenAt == null,
    );
