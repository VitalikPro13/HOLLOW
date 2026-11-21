import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/components/server_name_text.dart';
import 'package:hollow/src/ui/mobile/leave_with_server.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart'
    show MobileChannelPagePreview;
import 'package:hollow/src/ui/mobile/mobile_minimised_call.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_channels.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_navigation.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_sheet.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_switcher.dart';
import 'package:hollow/src/ui/shell/clock_skew_banner.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Height of the plain header bar under the status bar, at text scale 1.
const double kMobileServerBarHeight = 56;

/// How far the banner reaches below the status bar while unfolded.
const double kMobileServerBannerHeight = 156;

/// The header, whose height says how far the banner has folded.
const Key kMobileServerHeaderKey = ValueKey('mobile-server-header');

/// A server opened on the phone: its banner (folding into the plain bar as the
/// list scrolls) and its channel list. Opened through [openMobileServer].
class MobileServerRoute extends ConsumerStatefulWidget {
  final String serverId;

  const MobileServerRoute({super.key, required this.serverId});

  @override
  ConsumerState<MobileServerRoute> createState() => _MobileServerRouteState();
}

class _MobileServerRouteState extends ConsumerState<MobileServerRoute> {
  @override
  void initState() {
    super.initState();
    final serverId = widget.serverId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Loaded on demand: the phone never drew the desktop sidebar that would
      // have read it.
      if (ref.read(serverBannerProvider)[serverId] == null) {
        ref.read(serverBannerProvider.notifier).loadBanner(serverId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final serverId = widget.serverId;
    final hasBanner = ref.watch(
        serverBannerProvider.select((m) => m[serverId] != null));
    final lastChannel =
        ref.watch(mobileLastChannelProvider.select((m) => m[serverId]));
    final swipeIn = lastMobileChannelSwipeIn(
      context,
      serverId: serverId,
      channelId: lastChannel,
      channels: ref.watch(serverChannelsProvider(serverId)).valueOrNull,
      preview: (name) => (_) => MobileChannelPagePreview(
          serverId: serverId, channelId: lastChannel!, channelName: name),
    );
    final media = MediaQuery.of(context);
    // The header grows with large text instead of clipping its two lines.
    final grow = math.max(0.0, media.textScaler.scale(36) - 36);

    return LeaveWithServer(
      serverId: serverId,
      child: HollowPageSwipe(
        swipeIn: swipeIn,
        child: Scaffold(
          backgroundColor: hollow.opaqueBackground,
          body: Column(
            children: [
              Expanded(
                child: CustomScrollView(
                  slivers: [
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _HeaderDelegate(
                        serverId: serverId,
                        hasBanner: hasBanner,
                        top: media.padding.top,
                        grow: grow,
                      ),
                    ),
                    MobileServerChannelList(serverId: serverId),
                  ],
                ),
              ),
              // The call or room you are in, where the thumb rests.
              const MobileMinimisedCall(),
              // Self-hiding, as on the shell and the channel page.
              const SystemStatusBanner(anchor: StatusBannerAnchor.bottom),
              const ClockSkewBanner(anchor: StatusBannerAnchor.bottom),
              SizedBox(height: media.viewPadding.bottom),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  final String serverId;
  final bool hasBanner;
  final double top;
  final double grow;

  _HeaderDelegate({
    required this.serverId,
    required this.hasBanner,
    required this.top,
    required this.grow,
  });

  @override
  double get minExtent => top + kMobileServerBarHeight + grow;

  @override
  double get maxExtent => hasBanner
      ? top + kMobileServerBannerHeight + grow * 2
      : minExtent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final range = maxExtent - minExtent;
    final folded = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    return _ServerHeader(
      key: kMobileServerHeaderKey,
      serverId: serverId,
      hasBanner: hasBanner,
      folded: folded,
      top: top,
      barHeight: kMobileServerBarHeight + grow,
    );
  }

  @override
  bool shouldRebuild(_HeaderDelegate old) =>
      old.serverId != serverId ||
      old.hasBanner != hasBanner ||
      old.top != top ||
      old.grow != grow;
}

/// The page's header. [folded] runs from 0 (the banner open) to 1 (the plain
/// bar); a server with no banner is always folded.
class _ServerHeader extends ConsumerWidget {
  final String serverId;
  final bool hasBanner;
  final double folded;
  final double top;
  final double barHeight;

  const _ServerHeader({
    super.key,
    required this.serverId,
    required this.hasBanner,
    required this.folded,
    required this.top,
    required this.barHeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final banner = ref.watch(serverBannerProvider.select((m) => m[serverId]));
    final server = ref.watch(keptServersProvider.select((s) => s[serverId]));
    final name = server?.name ?? '';
    final nsfw = server?.isNsfw ?? false;
    final online = ref.watch(onlineMemberCountProvider(serverId));
    final members = server?.memberCount ?? 0;
    final caption = '$online online · $members '
        '${members == 1 ? 'member' : 'members'}';

    final art = banner != null && hasBanner;
    // Over the art the controls wear their own scrim; the bar's title takes
    // over once the banner has mostly folded away.
    final overArt = art && folded < 0.6;
    final barTitle = !art ? 1.0 : ((folded - 0.6) / 0.4).clamp(0.0, 1.0);
    final bigTitle = !art ? 0.0 : (1 - folded * 1.6).clamp(0.0, 1.0);
    final light = Theme.of(context).brightness == Brightness.light;

    void back() => Navigator.of(context).maybePop();
    void switcher() => showMobileServerSwitcher(context, serverId);

    final children = <Widget>[
      if (art) ...[
        Positioned.fill(
          child: AnimatedGifImage(
            key: ValueKey(banner.hash),
            bytes: banner.bytes,
            fit: BoxFit.cover,
            animate: !ReduceMotionController.instance.isReduced,
            errorWidget: const SizedBox.expand(),
          ),
        ),
        // Darkens under the status bar and the controls, as the desktop's
        // window chrome does over a banner.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: top + barHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient( // design-ignore: legibility scrim under the status bar over the server banner
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.45), // design-ignore: scrim over art
                  Colors.black.withValues(alpha: 0), // design-ignore: scrim over art
                ],
              ),
            ),
          ),
        ),
        // Bottom-up scrim into the canvas below, as on the desktop sidebar.
        // Stops use the canvas at alpha 0, never Colors.transparent, which
        // lerps through black in the light theme.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient( // design-ignore: legibility scrim over the server banner, fading to the canvas
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  hollow.opaqueBackground.withValues(alpha: 0.0),
                  hollow.opaqueBackground.withValues(alpha: 0.30),
                  hollow.opaqueBackground.withValues(alpha: 0.75),
                  hollow.opaqueBackground.withValues(alpha: 1.0),
                ],
                stops: const [0.35, 0.55, 0.75, 1.0],
              ),
            ),
          ),
        ),
        // Folding hands the art over to the bar's chrome.
        Positioned.fill(
          child: ColoredBox(
              color: hollow.opaqueSurface.withValues(alpha: folded)),
        ),
      ],
      Positioned(
        left: 0,
        right: 0,
        top: top,
        height: barHeight,
        child: _BarRow(
          serverId: serverId,
          name: name,
          nsfw: nsfw,
          caption: caption,
          overArt: overArt,
          titleShown: barTitle,
          onBack: back,
          onSwitch: switcher,
        ),
      ),
      if (art && bigTitle > 0)
        Positioned(
          left: HollowSpacing.lg,
          right: HollowSpacing.lg,
          bottom: HollowSpacing.sm,
          child: FadeTransition(
            opacity: AlwaysStoppedAnimation(bigTitle),
            child: _BigTitle(
              serverId: serverId,
              name: name,
              nsfw: nsfw,
              caption: caption,
              onSwitch: switcher,
            ),
          ),
        ),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overArt || !light
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: art ? hollow.opaqueBackground : hollow.opaqueSurface,
          border: folded >= 1
              ? Border(bottom: BorderSide(color: hollow.border))
              : null,
        ),
        child: Stack(fit: StackFit.expand, children: children),
      ),
    );
  }
}

/// Back, the server's name (once folded) and its two actions.
class _BarRow extends ConsumerWidget {
  final String serverId;
  final String name;
  final bool nsfw;
  final String caption;
  final bool overArt;
  final double titleShown;
  final VoidCallback onBack;
  final VoidCallback onSwitch;

  const _BarRow({
    required this.serverId,
    required this.name,
    required this.nsfw,
    required this.caption,
    required this.overArt,
    required this.titleShown,
    required this.onBack,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final title = HollowPressable(
      onTap: onSwitch,
      semanticLabel: '$name, switch server',
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(
          children: [
            ServerAvatar(serverId: serverId, name: name, size: 32),
            const SizedBox(width: HollowSpacing.md),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: ServerNameText(name,
                            isNsfw: nsfw,
                            style: HollowTypography.subheading
                                .copyWith(color: hollow.textPrimary)),
                      ),
                      const SizedBox(width: HollowSpacing.xs),
                      Icon(LucideIcons.chevronDown,
                          size: 16, color: hollow.textSecondary),
                    ],
                  ),
                  _Caption(caption, style: HollowTypography.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    return Padding(
      // Over the art the round scrims keep the screen edge's 8 px.
      padding: EdgeInsets.symmetric(
          horizontal: overArt ? HollowSpacing.sm : HollowSpacing.xs),
      child: Row(
        children: [
          HollowIconButton(
            icon: LucideIcons.arrowLeft,
            label: 'Back to servers',
            size: 44,
            onMedia: overArt,
            onPressed: onBack,
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: titleShown <= 0
                ? const SizedBox.shrink()
                : FadeTransition(
                    opacity: AlwaysStoppedAnimation(titleShown),
                    child: title,
                  ),
          ),
          HollowIconButton(
            icon: LucideIcons.userPlus,
            label: 'Invite people',
            size: 44,
            onMedia: overArt,
            onPressed: () => showMobileServerInvite(context, ref, serverId),
          ),
          SizedBox(width: overArt ? HollowSpacing.sm : HollowSpacing.xs),
          HollowIconButton(
            icon: LucideIcons.ellipsis,
            label: 'Server options',
            size: 44,
            onMedia: overArt,
            onPressed: () => showMobileServerSheet(context, ref, serverId),
          ),
        ],
      ),
    );
  }
}

/// The name over the open banner, which opens the switcher.
class _BigTitle extends StatelessWidget {
  final String serverId;
  final String name;
  final bool nsfw;
  final String caption;
  final VoidCallback onSwitch;

  const _BigTitle({
    required this.serverId,
    required this.name,
    required this.nsfw,
    required this.caption,
    required this.onSwitch,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onSwitch,
      semanticLabel: '$name, switch server',
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: Row(
        children: [
          DecoratedBox(
            // The canvas ring lifts the icon off the art.
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(hollow.radiusLg),
              border: Border.all(
                  color: hollow.opaqueBackground, width: HollowSpacing.xxs),
            ),
            child: ServerAvatar(serverId: serverId, name: name, size: 44),
          ),
          const SizedBox(width: HollowSpacing.md),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: ServerNameText(name,
                          isNsfw: nsfw,
                          style: HollowTypography.heading
                              .copyWith(color: hollow.textPrimary)),
                    ),
                    const SizedBox(width: HollowSpacing.xs),
                    Icon(LucideIcons.chevronDown,
                        size: 20, color: hollow.textSecondary),
                  ],
                ),
                _Caption(caption, style: HollowTypography.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  final String text;
  final TextStyle style;

  const _Caption(this.text, {required this.style});

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style.copyWith(
          color: HollowTheme.of(context).textSecondary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
}
