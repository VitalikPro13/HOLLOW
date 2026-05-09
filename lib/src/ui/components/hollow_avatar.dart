import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';

/// Avatar widget — shows a real image when available, falls back to
/// deterministic color + initials from peer ID.
///
/// Automatically fetches avatar bytes from [avatarProvider] on-demand.
/// Pass [imageBytes] to override with explicit data (e.g. archive data).
///
/// Set [animate] to true for focused profile contexts (profile card,
/// DM panel, settings preview). Defaults to false (static first frame).
class HollowAvatar extends ConsumerWidget {
  final String peerId;
  final double size;
  final Uint8List? imageBytes;
  final bool animate;

  const HollowAvatar({
    super.key,
    required this.peerId,
    this.size = 36,
    this.imageBytes,
    this.animate = false,
  });

  String _initialsFromId(String id) {
    if (id.length < 2) return '??';
    return id.substring(0, 2).toUpperCase();
  }

  Widget _buildFallback(HollowTheme hollow) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorFromId(peerId),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      alignment: Alignment.center,
      child: Text(
        _initialsFromId(peerId),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    Uint8List? bytes = imageBytes;
    if (bytes == null && peerId.isNotEmpty) {
      bytes = ref.watch(avatarProvider.select((c) => c[peerId]));
      if (bytes == null) {
        Future.microtask(
            () => ref.read(avatarProvider.notifier).loadAvatar(peerId));
      }
    }

    if (bytes != null && bytes.isNotEmpty) {
      Widget image;

      if (animate) {
        image = AnimatedGifImage(
          bytes: bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: _buildFallback(hollow),
        );
      } else {
        image = _StaticFirstFrame(
          imageBytes: bytes,
          size: size,
          fallback: _buildFallback(hollow),
        );
      }

      return ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: image,
      );
    }

    return _buildFallback(hollow);
  }
}

/// Renders only the first frame of an image (freezes GIF animation).
class _StaticFirstFrame extends StatefulWidget {
  final Uint8List imageBytes;
  final double size;
  final Widget fallback;

  const _StaticFirstFrame({
    required this.imageBytes,
    required this.size,
    required this.fallback,
  });

  @override
  State<_StaticFirstFrame> createState() => _StaticFirstFrameState();
}

class _StaticFirstFrameState extends State<_StaticFirstFrame> {
  ui.Image? _frame;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _decodeFirstFrame();
  }

  @override
  void didUpdateWidget(_StaticFirstFrame old) {
    super.didUpdateWidget(old);
    if (old.imageBytes.length != widget.imageBytes.length ||
        !listEquals(old.imageBytes, widget.imageBytes)) {
      _frame?.dispose();
      _frame = null;
      _failed = false;
      _decodeFirstFrame();
    }
  }

  Future<void> _decodeFirstFrame() async {
    try {
      final codec = await ui.instantiateImageCodec(widget.imageBytes);
      final frame = await codec.getNextFrame();
      if (mounted) {
        setState(() => _frame = frame.image);
      } else {
        frame.image.dispose();
      }
      codec.dispose();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _frame?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return widget.fallback;
    if (_frame == null) {
      return SizedBox(width: widget.size, height: widget.size);
    }
    return RawImage(
      image: _frame,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
    );
  }
}
