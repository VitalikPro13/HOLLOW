import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What an attachment that never reached the decoder says: Hollow refused its
/// bytes (they did not decode safely) or could not read them.
const String kCantShowImageCaption = "Can't show this image";

/// The honest box for an image Hollow will not paint, sized like the image it
/// stands in for. The file itself is still there to save.
class CantShowImage extends StatelessWidget {
  final double? width;
  final double? height;

  /// Replaces [kCantShowImageCaption], e.g. with why a photo was not sent.
  final String? caption;

  const CantShowImage({super.key, this.width, this.height, this.caption});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final text = caption ?? kCantShowImageCaption;
    return Semantics(
      label: text,
      child: Container(
        width: width,
        height: height,
        color: hollow.elevated,
        alignment: Alignment.center,
        padding: const EdgeInsets.all(HollowSpacing.sm),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.imageOff, size: 20, color: hollow.textSecondary),
              const SizedBox(height: HollowSpacing.sm),
              ExcludeSemantics(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many decoded attachment payloads the animated path keeps. Stills are not
/// here: they live in Flutter's own [ImageCache], which already evicts by size.
const int _kAnimatedCacheEntries = 16;

final Map<String, Uint8List> _animatedBytes = <String, Uint8List>{};

void _rememberAnimated(String key, Uint8List bytes) {
  _animatedBytes.remove(key);
  _animatedBytes[key] = bytes;
  while (_animatedBytes.length > _kAnimatedCacheEntries) {
    _animatedBytes.remove(_animatedBytes.keys.first);
  }
}

Uint8List? _recallAnimated(String key) {
  final hit = _animatedBytes.remove(key);
  if (hit != null) _animatedBytes[key] = hit;
  return hit;
}

@visibleForTesting
void debugClearAttachmentImageCache() => _animatedBytes.clear();

/// Identity of one decoded attachment in Flutter's [ImageCache].
///
/// Size and modification time ride along so a file replaced under the same name
/// gets its own entry instead of painting the previous bytes.
@immutable
class AtRestImageKey {
  final String path;
  final int modifiedMs;
  final int length;
  final double scale;

  const AtRestImageKey({
    required this.path,
    required this.modifiedMs,
    required this.length,
    required this.scale,
  });

  @override
  bool operator ==(Object other) =>
      other is AtRestImageKey &&
      other.path == path &&
      other.modifiedMs == modifiedMs &&
      other.length == length &&
      other.scale == scale;

  @override
  int get hashCode => Object.hash(path, modifiedMs, length, scale);
}

/// An [ImageProvider] over a file that is encrypted at rest.
///
/// The decrypted bytes are handed straight to the decoder and never kept in a
/// map of our own, so eviction stays Flutter's job. They reach the decoder only
/// after Rust's image check passed them; a refusal fails the load.
@immutable
class AtRestImageProvider extends ImageProvider<AtRestImageKey> {
  final String path;
  final double scale;

  const AtRestImageProvider(this.path, {this.scale = 1.0});

  /// Synchronous on purpose: an async key misses the [ImageCache] for one
  /// frame, so an already-decoded image flashed empty every time its
  /// conversation opened. One stat is microseconds.
  @override
  Future<AtRestImageKey> obtainKey(ImageConfiguration configuration) {
    var modifiedMs = 0;
    var length = 0;
    try {
      final stat = File(path).statSync();
      modifiedMs = stat.modified.millisecondsSinceEpoch;
      length = stat.size;
    } catch (_) {
      // A vanished file still needs a key; the load below reports the failure.
    }
    return SynchronousFuture(AtRestImageKey(
      path: path,
      modifiedMs: modifiedMs,
      length: length,
      scale: scale,
    ));
  }

  @override
  ImageStreamCompleter loadImage(
      AtRestImageKey key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: key.scale,
      debugLabel: key.path,
      informationCollector: () => <DiagnosticsNode>[
        ErrorDescription('Path: ${key.path}'),
      ],
    );
  }

  Future<ui.Codec> _load(AtRestImageKey key, ImageDecoderCallback decode) async {
    final bytes = await AtRest.readImage(key.path);
    if (bytes.isEmpty) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('${key.path} is empty and cannot be decoded.');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is AtRestImageProvider && other.path == path && other.scale == scale;

  @override
  int get hashCode => Object.hash(path, scale);

  @override
  String toString() => 'AtRestImageProvider("$path")';
}

/// Renders an attachment stored on disk, animated or still.
///
/// The one way to paint a file from the data root: dart:io cannot read those
/// bytes any more. [animated] routes to the frame decoder; everything else goes
/// through [AtRestImageProvider].
class AttachmentImage extends StatefulWidget {
  final String path;
  final bool animated;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Decode width in physical pixels, as `Image.file(cacheWidth:)` means it.
  final int? cacheWidth;
  final bool gaplessPlayback;
  final Widget? errorWidget;

  const AttachmentImage({
    super.key,
    required this.path,
    this.animated = false,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.cacheWidth,
    this.gaplessPlayback = false,
    this.errorWidget,
  });

  @override
  State<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<AttachmentImage> {
  Uint8List? _bytes;
  bool _failed = false;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    if (widget.animated) _startAnimated();
  }

  @override
  void didUpdateWidget(AttachmentImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.animated != widget.animated) {
      _bytes = null;
      _failed = false;
      if (widget.animated) _startAnimated();
    }
  }

  /// A cached payload is taken in the same frame, never after a setState.
  /// Keyed by path alone: an attachment's name carries its file id, so the
  /// same path never comes back holding different bytes.
  void _startAnimated() {
    ++_loadGeneration;
    _bytes = _recallAnimated(widget.path);
    if (_bytes == null) _loadBytes();
  }

  Future<void> _loadBytes() async {
    final path = widget.path;
    final generation = _loadGeneration;
    try {
      final bytes = await AtRest.readImage(path);
      _rememberAnimated(path, bytes);
      if (mounted && generation == _loadGeneration) {
        setState(() => _bytes = bytes);
      }
    } catch (_) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _failed = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.animated) {
      if (_failed) {
        return widget.errorWidget ??
            SizedBox(width: widget.width, height: widget.height);
      }
      final bytes = _bytes;
      if (bytes == null) {
        return SizedBox(width: widget.width, height: widget.height);
      }
      return AnimatedGifImage(
        bytes: bytes,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        errorWidget: widget.errorWidget,
      );
    }

    return Image(
      image: ResizeImage.resizeIfNeeded(
          widget.cacheWidth, null, AtRestImageProvider(widget.path)),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: widget.gaplessPlayback,
      errorBuilder: (_, _, _) =>
          widget.errorWidget ??
          SizedBox(width: widget.width, height: widget.height),
    );
  }
}
