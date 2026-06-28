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
///
/// Accessibility: pass [semanticLabel] (the person's display name) so a screen
/// reader announces "`name`, image". When null the avatar is excluded from the
/// semantics tree — a bare avatar with no name is decorative noise to a screen
/// reader (its only fallback content is raw peer-id initials), so silence is
/// better than reading those. Where the avatar sits next to a visible name that
/// already names the row, leaving it null (excluded) is also correct.
class HollowAvatar extends ConsumerWidget {
  final String peerId;
  final double size;
  final Uint8List? imageBytes;
  final bool animate;

  /// Screen-reader label — the person's display name. Null = excluded from
  /// semantics (decorative).
  final String? semanticLabel;

  const HollowAvatar({
    super.key,
    required this.peerId,
    this.size = 36,
    this.imageBytes,
    this.animate = false,
    this.semanticLabel,
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
        // Capture the notifier NOW (valid during build) so the deferred load
        // doesn't touch `ref` after this widget is disposed — that threw
        // "Cannot use ref after the widget was disposed" when an avatar tile
        // (e.g. a screen-share participant) was torn down mid-frame. The
        // notifier outlives the widget; the `ref` does not.
        final avatars = ref.read(avatarProvider.notifier);
        final id = peerId;
        Future.microtask(() => avatars.loadAvatar(id));
      }
    }

    Widget visual;
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

      visual = ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: image,
      );
    } else {
      visual = _buildFallback(hollow);
    }

    // A named avatar announces "<name>, image"; an unnamed one is decorative
    // (its only fallback is raw peer-id initials) and is excluded from the tree.
    if (semanticLabel != null && semanticLabel!.isNotEmpty) {
      return Semantics(label: semanticLabel, image: true, child: visual);
    }
    return ExcludeSemantics(child: visual);
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
