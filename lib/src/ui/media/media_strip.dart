import 'dart:convert' show base64Decode;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/services/video_thumbnail_service.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/media/media_item.dart';

const double _kThumbSize = 56;
const double _kThumbGap = HollowSpacing.xs;
const double _kStride = _kThumbSize + _kThumbGap;

/// Where the user is in the conversation's media, and a way to jump.
class MediaStrip extends StatefulWidget {
  final List<MediaItem> items;
  final int index;
  final void Function(int index) onSelect;

  const MediaStrip({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
  });

  @override
  State<MediaStrip> createState() => _MediaStripState();
}

class _MediaStripState extends State<MediaStrip> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(MediaStrip old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _reveal();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final viewport = _scroll.position.viewportDimension;
      final target = (widget.index * _kStride + _kThumbSize / 2 - viewport / 2)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      if (ReduceMotionController.instance.isReduced) {
        _scroll.jumpTo(target);
        return;
      }
      _scroll.animateTo(target,
          duration: const Duration(milliseconds: 180), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _kThumbSize + HollowSpacing.sm * 2,
      child: ListView.separated(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        itemCount: widget.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: _kThumbGap),
        itemBuilder: (context, i) => _MediaThumb(
          key: ValueKey(widget.items[i].fileId),
          item: widget.items[i],
          selected: i == widget.index,
          onTap: () => widget.onSelect(i),
        ),
      ),
    );
  }
}

class _MediaThumb extends StatelessWidget {
  final MediaItem item;
  final bool selected;
  final VoidCallback onTap;

  const _MediaThumb({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  String? _thumbPath() {
    final path = item.diskPath;
    if (path == null) return null;
    if (item.kind != MediaKind.video) return path;
    if (item.attachment.videoThumb != null) return path;
    return VideoThumbnailService.cachedThumbFor(path);
  }

  Uint8List? _thumbBytes() {
    final b64 = item.attachment.thumbB64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final path = _thumbPath();
    final bytes = path == null ? _thumbBytes() : null;
    final decodeWidth =
        (_kThumbSize * MediaQuery.devicePixelRatioOf(context)).ceil();

    Widget content;
    if (path != null) {
      content = AttachmentImage(
        path: path,
        fit: BoxFit.cover,
        cacheWidth: item.kind == MediaKind.gif ? null : decodeWidth,
        animated: item.kind == MediaKind.gif,
      );
    } else if (bytes != null) {
      content = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    } else {
      content = Icon(
        item.kind == MediaKind.video ? LucideIcons.fileVideo : LucideIcons.image,
        size: 18,
        color: hollow.textSecondary,
      );
    }

    return HollowPressable(
      onTap: onTap,
      semanticLabel: item.attachment.fileName,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: Container(
        width: _kThumbSize,
        height: _kThumbSize,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(
            color: selected ? hollow.accent : Colors.white.withValues(alpha: 0.1),
            width: selected ? 2 : 1,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(child: content),
            if (item.kind == MediaKind.video)
              const Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(LucideIcons.play, size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
