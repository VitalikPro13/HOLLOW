import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hollow/src/core/providers/member_panel_provider.dart'
    show windowFocusedProvider;
import 'package:hollow/src/core/providers/server_avatar_anim_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'animated_gif_image.dart';

/// A server's icon: the ANIMATED variant off the asset rail when there is one,
/// else the still from the CRDT setting, else [fallback].
///
/// Animation is gated like the server banners, to hovered or selected, focused
/// and not reduce-motion; otherwise the blob holds its first frame.
class ServerIconImage extends ConsumerStatefulWidget {
  final String serverId;
  final double size;

  /// Selection un-gates animation: a selected server is being watched.
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
