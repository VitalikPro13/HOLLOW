import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hollow/src/core/providers/member_panel_provider.dart'
    show windowFocusedProvider;
import 'package:hollow/src/core/providers/server_avatar_anim_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'animated_gif_image.dart';

/// A server's icon image: renders the ANIMATED variant when the server has
/// one (asset-rail blob, `settings["server_avatar_anim"]`), otherwise the
/// still from the CRDT setting, otherwise [fallback].
///
/// Animation is gated the same way as server banners — only while actually
/// watched: hovered or [isSelected], window focused, and not reduce-motion
/// (enforced inside [AnimatedGifImage]). Otherwise the animated blob holds
/// its first frame, which matches the still.
class ServerIconImage extends ConsumerStatefulWidget {
  final String serverId;
  final double size;

  /// Selection un-gates animation too (a selected server is being watched).
  final bool isSelected;

  /// Shown when neither icon variant is loaded (usually initials).
  final Widget fallback;

  final BorderRadius borderRadius;

  const ServerIconImage({
    super.key,
    required this.serverId,
    required this.size,
    required this.fallback,
    this.isSelected = false,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  @override
  ConsumerState<ServerIconImage> createState() => _ServerIconImageState();
}

class _ServerIconImageState extends ConsumerState<ServerIconImage> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final anim = ref
        .watch(serverAvatarAnimProvider.select((m) => m[widget.serverId]));
    if (anim != null) {
      final focused = ref.watch(windowFocusedProvider);
      return MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: ClipRRect(
          borderRadius: widget.borderRadius,
          child: AnimatedGifImage(
            bytes: anim.bytes,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            animate: (_hovering || widget.isSelected) && focused,
          ),
        ),
      );
    }
    final still = ref
        .watch(serverAvatarProvider.select((m) => m[widget.serverId]));
    if (still != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius,
        child: Image.memory(
          still,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    return widget.fallback;
  }
}
