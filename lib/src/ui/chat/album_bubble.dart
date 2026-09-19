import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/models/channel_chat_message.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/file_attachment_widget.dart';
import 'package:hollow/src/ui/chat/sticker_pack_card.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/media/media_item.dart';

/// One file of an album, with the message it belongs to.
@immutable
class AlbumItem {
  final FileAttachment attachment;
  final String? messageId;
  final String? senderId;
  final int timestampMs;
  final bool isMine;

  /// The message's own text: a file token, or the album's caption.
  final String text;

  const AlbumItem({
    required this.attachment,
    this.text = '',
    required this.messageId,
    required this.senderId,
    required this.timestampMs,
    required this.isMine,
  });
}

/// Builds the album items of a group, skipping rows that lost their file.
List<AlbumItem> albumItemsOf<T>(
  List<T> messages, {
  required FileAttachment? Function(T) attachmentOf,
  required String? Function(T) messageIdOf,
  required String? Function(T) senderOf,
  required DateTime Function(T) timestampOf,
  required bool Function(T) isMineOf,
  required String Function(T) textOf,
}) =>
    [
      for (final m in messages)
        if (attachmentOf(m) != null)
          AlbumItem(
            attachment: attachmentOf(m)!,
            messageId: messageIdOf(m),
            senderId: senderOf(m),
            timestampMs: timestampOf(m).millisecondsSinceEpoch,
            isMine: isMineOf(m),
            text: textOf(m),
          ),
    ];

/// The album items of a DM group. Senders are master ids, as the viewer wants.
List<AlbumItem> dmAlbumItems(List<ChatMessage> messages,
        {required String localPeerId, required String peerId}) =>
    albumItemsOf<ChatMessage>(
      messages,
      attachmentOf: (m) => m.fileAttachment,
      messageIdOf: (m) => m.messageId,
      senderOf: (m) => m.isMe ? localPeerId : peerId,
      timestampOf: (m) => m.timestamp,
      isMineOf: (m) => m.isMe,
      textOf: (m) => m.text,
    );

/// The album items of a channel group, senders collapsed to masters.
List<AlbumItem> channelAlbumItems(List<ChannelChatMessage> messages,
        {required String Function(String) identityOf}) =>
    albumItemsOf<ChannelChatMessage>(
      messages,
      attachmentOf: (m) => m.fileAttachment,
      messageIdOf: (m) => m.messageId,
      senderOf: (m) => identityOf(m.senderId),
      timestampOf: (m) => m.timestamp,
      isMineOf: (m) => m.isMe,
      textOf: (m) => m.text,
    );

/// Asks before a delete from the album bubble takes every item with it. The
/// viewer deletes one item at a time.
Future<bool> confirmDeleteAlbum(BuildContext context, int count) async {
  return showHollowConfirm(
    context: context,
    title: 'Delete album',
    message: 'This deletes all $count items for everyone. To delete one item, '
        'open it and delete it from the viewer.',
    confirmLabel: 'Delete all $count',
    destructive: true,
  );
}

/// Most cells a mosaic shows; the last one carries "+N" for the rest.
const _maxCells = 6;
const _maxWidth = 320.0;
const _gap = 2.0;

/// An album: photos and videos as one mosaic, other files stacked under it.
///
/// Every cell is the ordinary attachment widget in tile mode, so each item
/// keeps its own honest download, progress and viewer behaviour.
class AlbumBubble extends StatelessWidget {
  final List<AlbumItem> items;

  const AlbumBubble({super.key, required this.items});

  static bool _isMedia(FileAttachment a) {
    if (isStickerPackFile(a.fileName)) return false;
    if (a.isImage || a.videoThumb != null) return true;
    return kMediaVideoExtensions.contains(a.fileExt.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final media = [for (final i in items) if (_isMedia(i.attachment)) i];
    final files = [for (final i in items) if (!_isMedia(i.attachment)) i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (media.length == 1)
          _cell(media.first, null)
        else if (media.length > 1)
          LayoutBuilder(
            builder: (context, constraints) => _mosaic(
                media, math.min(_maxWidth, constraints.maxWidth)),
          ),
        for (final f in files)
          Padding(
            padding: EdgeInsets.only(
                top: identical(f, files.first) && media.isEmpty
                    ? 0
                    : HollowSpacing.xs),
            child: _cell(f, null),
          ),
        _DownloadAllButton(items: items),
      ],
    );
  }

  Widget _cell(AlbumItem item, Size? tile) => FileAttachmentWidget(
        key: ValueKey('album-cell-${item.messageId ?? item.attachment.fileId}'),
        attachment: item.attachment,
        messageId: item.messageId,
        senderId: item.senderId,
        timestampMs: item.timestampMs,
        isMine: item.isMine,
        tileSize: tile,
      );

  Widget _mosaic(List<AlbumItem> media, double width) {
    final n = media.length;
    final hidden = n - _maxCells;

    Widget tile(int index, double w, double h) {
      final cell = _cell(media[index], Size(w, h));
      if (hidden <= 0 || index != _maxCells - 1) return cell;
      return Stack(
        children: [
          cell,
          Positioned.fill(
            child: IgnorePointer(
              child: _MoreOverlay(count: hidden),
            ),
          ),
        ],
      );
    }

    Widget row(List<int> indices, double height) {
      final w = (width - _gap * (indices.length - 1)) / indices.length;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final i in indices) ...[
            if (i != indices.first) const SizedBox(width: _gap),
            tile(i, w, height),
          ],
        ],
      );
    }

    Widget column(List<Widget> rows) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: _gap),
              rows[i],
            ],
          ],
        );

    final half = (width - _gap) / 2;
    final third = (width - _gap * 2) / 3;
    switch (n) {
      case 2:
        return row([0, 1], half);
      case 3:
        final bigW = (width - _gap) * 0.62;
        final sideW = width - _gap - bigW;
        final h = width * 0.66;
        final smallH = (h - _gap) / 2;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            tile(0, bigW, h),
            const SizedBox(width: _gap),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                tile(1, sideW, smallH),
                const SizedBox(height: _gap),
                tile(2, sideW, smallH),
              ],
            ),
          ],
        );
      case 4:
        return column([row([0, 1], half * 0.75), row([2, 3], half * 0.75)]);
      case 5:
        return column([row([0, 1], half * 0.75), row([2, 3, 4], third)]);
      default:
        return column([row([0, 1, 2], third), row([3, 4, 5], third)]);
    }
  }
}

class _MoreOverlay extends StatelessWidget {
  final int count;

  const _MoreOverlay({required this.count});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: Text(
            '+$count',
            style: HollowTypography.subheading.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// Offers one tap for every item the auto-download gate held back, once two
/// or more are waiting.
class _DownloadAllButton extends ConsumerWidget {
  final List<AlbumItem> items;

  const _DownloadAllButton({required this.items});

  List<FileAttachment> _waiting(Map<String, FileTransferState> transfers) => [
        for (final i in items)
          if (!i.attachment.isComplete &&
              !i.attachment.isExpired &&
              transfers[i.attachment.fileId]?.isComplete != true &&
              transfers[i.attachment.fileId]?.isDownloading != true)
            i.attachment,
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A count, not the list: the transfer map is replaced on every chunk.
    final count =
        ref.watch(fileTransferProvider.select((s) => _waiting(s).length));
    if (count < 2) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xs),
      child: HollowButton.ghost(
        compact: true,
        semanticLabel: 'Download all $count files',
        icon: const Icon(LucideIcons.download),
        onPressed: () {
          for (final a in _waiting(ref.read(fileTransferProvider))) {
            unawaited(startManualAttachmentDownload(context, ref, a));
          }
        },
        child: Text('Download all ($count)'),
      ),
    );
  }
}
