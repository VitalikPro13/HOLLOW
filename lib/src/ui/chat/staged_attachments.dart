import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/album_grouping.dart';
import 'package:hollow/src/core/moderation_format.dart';
import 'package:hollow/src/core/providers/chat_provider.dart' show generateMessageId;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart' show gifAwareImage;
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/large_file_share_dialog.dart';
import 'package:hollow/src/ui/media/media_item.dart';

const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'};

/// A file picked, dropped or pasted into a composer and not sent yet.
@immutable
class StagedAttachment {
  final String path;
  final String name;
  final int sizeBytes;

  const StagedAttachment({
    required this.path,
    required this.name,
    required this.sizeBytes,
  });

  /// Reads the size from disk; 0 when the file cannot be stat'ed.
  factory StagedAttachment.fromPath(String path, {String? name}) {
    var size = 0;
    try {
      size = File(path).lengthSync();
    } catch (_) {}
    return StagedAttachment(
      path: path,
      name: name ?? path.replaceAll('\\', '/').split('/').last,
      sizeBytes: size,
    );
  }

  String get ext =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';
  bool get isImage => _imageExtensions.contains(ext);
  bool get isVideo => kMediaVideoExtensions.contains(ext);
}

/// The part of [incoming] that may join [current]: the media-only filter, the
/// album cap, and ONE large-file question for the whole batch. Toasts what it
/// leaves out. Append with [appendStaged], which re-applies the cap against
/// whatever the list became while the question was open.
Future<List<StagedAttachment>> admitStagedAttachments(
  BuildContext context, {
  required List<StagedAttachment> current,
  required List<StagedAttachment> incoming,
  bool mediaOnly = false,
}) async {
  var accepted = incoming;
  if (mediaOnly) {
    accepted = [
      for (final a in incoming)
        if (kMediaOnlyExtensions.contains(a.ext)) a,
    ];
    if (accepted.length < incoming.length) {
      HollowToast.show(
        context,
        'This is a media-only channel. Only images, GIFs, and videos can be posted',
        type: HollowToastType.info,
      );
    }
  }

  final room = kMaxAlbumItems - current.length;
  if (accepted.length > room) {
    HollowToast.show(
      context,
      'You can attach up to $kMaxAlbumItems files at a time',
      type: HollowToastType.info,
    );
    accepted = accepted.take(room < 0 ? 0 : room).toList();
  }

  final large = [
    for (final a in accepted)
      if (a.sizeBytes > kLargeFileThresholdBytes) a,
  ];
  if (large.isNotEmpty && context.mounted) {
    final ok = await confirmLargeFilesShare(context, files: [
      for (final a in large) (name: a.name, sizeBytes: a.sizeBytes),
    ]);
    if (!ok) accepted = [for (final a in accepted) if (!large.contains(a)) a];
  }
  return accepted;
}

/// [current] plus [accepted], never past the album cap.
List<StagedAttachment> appendStaged(
        List<StagedAttachment> current, List<StagedAttachment> accepted) =>
    [...current, ...accepted].take(kMaxAlbumItems).toList();

/// [list] with the item at [oldIndex] moved to [newIndex], in
/// `onReorderItem` terms (the index after the removal).
List<StagedAttachment> reorderStaged(
    List<StagedAttachment> list, int oldIndex, int newIndex) {
  final out = List<StagedAttachment>.from(list);
  out.insert(newIndex, out.removeAt(oldIndex));
  return out;
}

/// Sends [items] as one album (two or more) or a plain file message.
///
/// Every optimistic row lands first, so the bubble groups at once. The sends
/// then run ONE AT A TIME: the send stamp and relay arrival follow the strip's
/// order only if each file waits for the one before it. The caption rides the
/// first item. Returns how many items failed; the rest still went out.
Future<int> sendStagedAttachments({
  required List<StagedAttachment> items,
  required String caption,
  required void Function(
          StagedAttachment item, String messageId, String text, String? albumId)
      addOptimistic,
  required Future<void> Function(
          StagedAttachment item, String messageId, String text, String? albumId)
      send,
}) async {
  if (items.isEmpty) return 0;
  final albumId = items.length >= 2 ? generateAlbumId() : null;
  final ids = [for (final _ in items) generateMessageId()];
  for (var i = 0; i < items.length; i++) {
    addOptimistic(items[i], ids[i], i == 0 ? caption : '', albumId);
  }
  var failed = 0;
  for (var i = 0; i < items.length; i++) {
    try {
      await send(items[i], ids[i], i == 0 ? caption : '', albumId);
    } catch (e) {
      failed++;
      debugPrint('[HOLLOW] Album item ${i + 1}/${items.length} failed: $e');
    }
  }
  return failed;
}

/// The staged files above a composer: one row for a single file, a
/// reorderable strip of thumbnails for an album.
class StagedAttachmentStrip extends StatelessWidget {
  final List<StagedAttachment> items;
  final ValueChanged<int> onRemove;
  final void Function(int oldIndex, int newIndex) onReorder;

  const StagedAttachmentStrip({
    super.key,
    required this.items,
    required this.onRemove,
    required this.onReorder,
  });

  static bool get _touch => Platform.isAndroid || Platform.isIOS;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.md, HollowSpacing.sm, HollowSpacing.md, 0),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: items.length == 1 ? _single(hollow) : _strip(hollow),
    );
  }

  Widget _single(HollowTheme hollow) {
    final item = items.first;
    return Row(
      children: [
        _thumb(hollow, item, 48),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            item.name,
            style: HollowTypography.caption.copyWith(color: hollow.textPrimary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        HollowPressable(
          semanticLabel: 'Remove attachment',
          onTap: () => onRemove(0),
          padding: const EdgeInsets.all(HollowSpacing.xs),
          child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
        ),
      ],
    );
  }

  Widget _strip(HollowTheme hollow) {
    const cell = 64.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${items.length} of $kMaxAlbumItems',
          style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
        ),
        const SizedBox(height: HollowSpacing.xs),
        SizedBox(
          height: cell,
          child: ReorderableListView.builder(
            scrollDirection: Axis.horizontal,
            buildDefaultDragHandles: false,
            proxyDecorator: (child, _, _) => child,
            itemCount: items.length,
            onReorderItem: onReorder,
            itemBuilder: (context, i) {
              final item = items[i];
              final tile = Padding(
                padding: const EdgeInsets.only(right: HollowSpacing.xs),
                child: Semantics(
                  label: '${item.name}, ${i + 1} of ${items.length}',
                  child: Stack(
                    children: [
                      _thumb(hollow, item, cell),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: HollowPressable(
                          semanticLabel: 'Remove ${item.name}',
                          onTap: () => onRemove(i),
                          backgroundColor: hollow.overlay.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(hollow.radiusMd),
                          padding: const EdgeInsets.all(HollowSpacing.xxs),
                          child: Icon(LucideIcons.x,
                              size: 14, color: hollow.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              );
              final key = ObjectKey(item);
              return _touch
                  ? ReorderableDelayedDragStartListener(
                      key: key, index: i, child: tile)
                  : ReorderableDragStartListener(
                      key: key, index: i, child: tile);
            },
          ),
        ),
      ],
    );
  }

  Widget _thumb(HollowTheme hollow, StagedAttachment item, double size) {
    if (item.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: gifAwareImage(item.path, width: size, height: size),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: Icon(item.isVideo ? LucideIcons.video : LucideIcons.file,
          color: hollow.textSecondary, size: 20),
    );
  }
}
