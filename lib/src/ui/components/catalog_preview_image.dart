import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/services/gif_thumb_cache.dart';

/// A still preview from a catalog search (FFZ emotes, IGDB covers), painted only
/// once Rust fetched it from the catalog and its image check passed it.
class CatalogPreviewImage extends StatefulWidget {
  final String url;
  final double width;
  final double height;
  final BoxFit fit;

  /// Shown while the preview loads and when it cannot be shown.
  final Widget fallback;

  const CatalogPreviewImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    required this.fallback,
    this.fit = BoxFit.contain,
  });

  @override
  State<CatalogPreviewImage> createState() => _CatalogPreviewImageState();
}

class _CatalogPreviewImageState extends State<CatalogPreviewImage> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant CatalogPreviewImage old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _bytes = null;
      _load();
    }
  }

  void _load() {
    final url = widget.url;
    GifThumbCache.instance.load(url).then((bytes) {
      if (!mounted || widget.url != url || bytes == null) return;
      setState(() => _bytes = bytes);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(
          width: widget.width, height: widget.height, child: widget.fallback);
    }
    return Image.memory(
      bytes,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => SizedBox(
          width: widget.width, height: widget.height, child: widget.fallback),
    );
  }
}
