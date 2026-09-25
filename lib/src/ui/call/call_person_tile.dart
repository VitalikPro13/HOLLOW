import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/call/speaking_ring.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Below this a tile's weak-link mark drops its words.
const double _kWordedMarkHeight = 150;

/// How big a person tile is drawn.
enum CallTileSize {
  /// The stage grid or the focused camera: fills the 16:9 box it is given.
  large,

  /// The people strip above a focused source.
  strip,

  /// The DM call row: the avatar alone.
  compact,
}

/// One person in a call, at any size: their camera when it is on, else their
/// avatar, with their name and only the marks that are true (muted, deafened,
/// a weak link). The speaking ring sits outside the tile.
class CallPersonTile extends ConsumerWidget {
  final CallPerson person;
  final CallTileSize size;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;

  const CallPersonTile({
    super.key,
    required this.person,
    required this.size,
    this.onTap,
    this.onDoubleTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final speaking = ref.watch(person.speaking) && !person.muted;
    final linkSource = person.link;
    final link = linkSource == null ? null : ref.watch(linkSource);
    final weak = link != null && link.health != LinkHealth.healthy;

    final radius =
        size == CallTileSize.compact ? hollow.radiusMd : hollow.radiusLg;
    final face = switch (size) {
      CallTileSize.compact => _compact(hollow),
      _ => _framed(context, hollow, weak ? link : null, radius),
    };

    Widget tile = SpeakingRing(
      speaking: speaking,
      color: callRingColor(hollow,
          isSelf: person.isSelf, master: person.master),
      radius: radius,
      child: face,
    );

    final marks = [
      if (person.muted) 'muted',
      if (person.deafened) 'deafened',
      if (weak) 'weak connection',
    ];
    tile = Semantics(
      label: [person.name, ...marks].join(', '),
      button: onTap != null,
      onTap: onTap,
      excludeSemantics: size == CallTileSize.compact,
      child: tile,
    );

    if (onTap != null || onDoubleTap != null) {
      tile = MouseRegion(
        cursor: onTap != null
            ? SystemMouseCursors.click
            : MouseCursor.defer,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          onDoubleTap: onDoubleTap,
          child: tile,
        ),
      );
    }

    final onMenu = person.onMenu;
    if (onMenu != null) {
      tile = ContextMenuTarget(
        semanticLabel: 'Actions for ${person.name}',
        onOpen: (anchor) => onMenu(context, anchor),
        child: tile,
      );
    }
    return tile;
  }

  Widget _compact(HollowTheme hollow) {
    return SizedBox.square(
      dimension: CallMetrics.compactAvatar,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          HollowAvatar(
            peerId: person.master,
            size: CallMetrics.compactAvatar,
            frameId: '',
          ),
          if (person.muted || person.deafened)
            Positioned(
              right: -HollowSpacing.xs,
              bottom: -HollowSpacing.xs,
              child: Container(
                width: HollowSpacing.lg,
                height: HollowSpacing.lg,
                decoration: BoxDecoration(
                  color: hollow.surface,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  person.deafened ? LucideIcons.headphoneOff : LucideIcons.micOff,
                  size: 10,
                  color: hollow.error,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _framed(BuildContext context, HollowTheme hollow,
      LinkHealthSnapshot? weakLink, double radius) {
    final camera = person.cameraOn ? person.camera : null;
    final large = size == CallTileSize.large;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: ColoredBox(
        color: person.cameraOn ? HollowColors.mediaBlack : hollow.elevated,
        child: LayoutBuilder(builder: (context, box) {
          final children = <Widget>[];
          if (person.cameraOn) {
            children.add(camera == null
                ? const SizedBox.expand()
                : RepaintBoundary(
                    child: RTCVideoView(
                      camera,
                      mirror: person.mirror,
                      objectFit:
                          RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                    ),
                  ));
            children.add(Positioned(
              left: HollowSpacing.sm,
              bottom: HollowSpacing.sm,
              right: HollowSpacing.sm,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: _mediaName(hollow, large),
              ),
            ));
          } else if (large) {
            // 48 to 72 by the tile's width, less when a crowded grid makes
            // the tile short, so the name always fits under it.
            final byHeight = box.maxHeight - HollowSpacing.xxl - HollowSpacing.lg;
            final avatar = (box.maxWidth * 0.18)
                .clamp(48.0, 72.0)
                .clamp(24.0, byHeight < 24 ? 24.0 : byHeight)
                .roundToDouble();
            children.add(Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  HollowAvatar(
                      peerId: person.master, size: avatar, frameId: ''),
                  const SizedBox(height: HollowSpacing.sm),
                  _nameRow(HollowTypography.label, hollow),
                ],
              ),
            ));
          } else {
            children.add(Center(
              child: HollowAvatar(
                peerId: person.master,
                size: CallMetrics.stripAvatar,
                frameId: '',
              ),
            ));
            children.add(Positioned(
              left: HollowSpacing.sm,
              right: HollowSpacing.sm,
              bottom: HollowSpacing.xs,
              child: _nameRow(
                  HollowTypography.caption
                      .copyWith(fontWeight: FontWeight.w500),
                  hollow),
            ));
          }
          if (weakLink != null) {
            // A short tile keeps the icon alone, clear of the avatar.
            children.add(Positioned(
              left: HollowSpacing.sm,
              top: HollowSpacing.sm,
              child: _weakMark(
                  hollow, weakLink, large && box.maxHeight >= _kWordedMarkHeight),
            ));
          }
          return Stack(fit: StackFit.expand, children: children);
        }),
      ),
    );
  }

  /// Name plus the mute and deafen marks, in the person's colour.
  Widget _nameRow(TextStyle style, HollowTheme palette) {
    final color =
        callNameColor(palette, isSelf: person.isSelf, master: person.master);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: Text(
            person.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style.copyWith(color: color),
          ),
        ),
        if (person.muted) ...[
          const SizedBox(width: HollowSpacing.xs),
          Icon(LucideIcons.micOff, size: 14, color: palette.error),
        ],
        if (person.deafened) ...[
          const SizedBox(width: HollowSpacing.xs),
          Icon(LucideIcons.headphoneOff, size: 14, color: palette.error),
        ],
      ],
    );
  }

  Widget _mediaName(HollowTheme hollow, bool large) {
    final media = callMediaTheme(hollow);
    return CallMediaLabel(
      padding: EdgeInsets.symmetric(
        horizontal: large ? HollowSpacing.sm : HollowSpacing.xs,
        vertical: HollowSpacing.xxs,
      ),
      child: _nameRow(
        (large ? HollowTypography.label : HollowTypography.caption)
            .copyWith(fontWeight: FontWeight.w500),
        media,
      ),
    );
  }

  Widget _weakMark(
      HollowTheme hollow, LinkHealthSnapshot link, bool large) {
    final tip = [link.label, link.detail].whereType<String>().join('. ');
    final Widget mark;
    if (person.cameraOn) {
      final media = callMediaTheme(hollow);
      mark = CallMediaLabel(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.xs,
          vertical: HollowSpacing.xxs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.wifiLow, size: 14, color: media.warning),
            if (large) ...[
              const SizedBox(width: HollowSpacing.xs),
              Text('Weak connection',
                  style: HollowTypography.caption
                      .copyWith(color: media.warning)),
            ],
          ],
        ),
      );
    } else if (large) {
      mark = const HollowBadge('Weak connection',
          kind: HollowBadgeKind.warning, icon: LucideIcons.wifiLow);
    } else {
      mark = Icon(LucideIcons.wifiLow, size: 14, color: hollow.warning);
    }
    return HollowTooltip(message: tip.isEmpty ? 'Weak connection' : tip, child: mark);
  }
}
