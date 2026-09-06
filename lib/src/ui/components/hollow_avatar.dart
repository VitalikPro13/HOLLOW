import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/avatar_frame.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';

/// Avatar widget: a real image when available, else deterministic colour and
/// initials from the peer ID. Bytes come from [avatarProvider] on demand, so
/// [imageBytes] is only for explicit data such as an archive row.
///
/// [animate] un-gates the avatar's own animation AND its frame's. Elsewhere
/// both hold frame 0 and play while the enclosing ROW is hovered
/// ([HoverScope]), because aiming at 32px of artwork is a pixel hunt; outside a
/// row the avatar IS the target and hovers itself.
///
/// The person's avatar FRAME (issue #54) is painted here too, so every surface
/// inherits it at once and none of them pay layout for it. [frameId] overrides
/// the stored value, and `''` renders none.
///
/// [semanticLabel] is the display name. Null EXCLUDES the avatar from the
/// semantics tree, which is right both for a decorative avatar (its only
/// fallback is raw peer-id initials) and beside a visible name.
class HollowAvatar extends ConsumerWidget {
  final String peerId;
  final double size;
  final Uint8List? imageBytes;
  final bool animate;

  /// Overrides the frame from the peer's profile. `''` = draw none.
  final String? frameId;

  /// The person's display name; null excludes the avatar from semantics.
  final String? semanticLabel;

  const HollowAvatar({
    super.key,
    required this.peerId,
    this.size = 36,
    this.imageBytes,
    this.animate = false,
    this.frameId,
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
      // The profile blob carries only the still and the animation rides the
      // asset rail, so the still below keeps rendering until a pull lands.
      bytes = watchAnimatedAvatar(ref, peerId);
    }
    if (bytes == null && peerId.isNotEmpty) {
      bytes = ref.watch(avatarProvider.select((c) => c[peerId]));
      if (bytes == null) {
        // Capture the notifier NOW, while build is valid: the notifier
        // outlives this widget and `ref` does not, so a deferred load that
        // touched `ref` would throw on a tile torn down mid-frame.
        final avatars = ref.read(avatarProvider.notifier);
        final id = peerId;
        Future.microtask(() => avatars.loadAvatar(id));
      }
    }

    // The enclosing row's hover, where there is one.
    final rowHovered = HoverScope.maybeOf(context);

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
        final still = _StaticFirstFrame(
          imageBytes: bytes,
          size: size,
          fallback: _buildFallback(hollow),
        );
        // AnimatedGifImage decodes EVERY frame up front, so it is mounted only
        // while hovered, and it sits OVER the still rather than replacing it:
        // no blank while it decodes, no re-decode when the pointer leaves.
        image = (rowHovered != null && isAnimatedImageBytes(bytes))
            ? Stack(
                children: [
                  still,
                  if (rowHovered)
                    AnimatedGifImage(
                      bytes: bytes,
                      width: size,
                      height: size,
                      fit: BoxFit.cover,
                    ),
                ],
              )
            : still;
      }

      visual = ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: image,
      );
    } else {
      visual = _buildFallback(hollow);
    }

    // Frames (issue #54) sit IN FRONT of the avatar and take no layout space.
    // Below ~24px the art is mush, so it is skipped.
    if (size >= kFrameMinAvatarSize) {
      final id = frameId ??
          ref.watch(profileProvider.select((p) => p[peerId]?.avatarFrame)) ??
          '';
      if (isRenderableFrame(id)) {
        visual = AvatarFrame(
          id: id,
          size: size,
          radius: hollow.radiusMd,
          peerHint: peerId,
          animate: animate,
          child: visual,
        );
      }
    }

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
      // Pinned: this still and the animation that sits over it on hover must
      // resample identically, or sharpness changes as the pointer arrives.
      filterQuality: FilterQuality.medium,
    );
  }
}
