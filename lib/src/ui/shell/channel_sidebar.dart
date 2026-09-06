import 'dart:math' as math;

import 'package:hollow/src/ui/chat/hollow_link_utils.dart';

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/speaking_border.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/models/peer_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/reveal_widgets.dart';
import 'package:hollow/src/ui/animations/selection_shimmer.dart';
import 'package:hollow/src/ui/dialogs/storage_dashboard_dialog.dart';
import 'package:hollow/src/ui/shell/channel_context_menus.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/providers/speaking_provider.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/recording_indicator.dart';
import 'package:hollow/src/ui/components/saved_messages_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/link_health_chip.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';
import 'package:hollow/src/ui/shell/voice_channel_panel.dart';
import 'package:hollow/src/ui/sidebar/peer_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Full height of the server banner header (issue #25) when the sidebar has
/// room for it; under pressure it yields, see [bannerHeaderHeight].
const double kBannerHeaderHeight = 120;

/// The banner never shrinks past this: the server name + action icons still
/// have to read, and the borderless fallback header is already 48.
const double kBannerHeaderMinHeight = 72;

/// Share of the sidebar column the banner may occupy once space is tight.
/// Inert at any normal desktop height; it engages only on a short column.
const double _kBannerHeaderMaxFraction = 0.22;

/// How tall the banner header should be in a sidebar column of [available]
/// logical pixels.
///
/// Not a constant, because the interface zoom lays the app out at
/// `viewport / scale` and so SHORTENS the sidebar as it magnifies it: a fixed
/// height grows as a share of the column until the chrome crowds out the
/// channel list (issue #37). The full [kBannerHeaderHeight] is returned
/// whenever the column can afford it.
double bannerHeaderHeight(double available) {
  if (!available.isFinite || available <= 0) return kBannerHeaderHeight;
  return math.min(
    kBannerHeaderHeight,
    math.max(kBannerHeaderMinHeight, available * _kBannerHeaderMaxFraction),
  );
}

/// Avatar edge for a voice-channel participant row.
///
/// A RATIO inside the panel, not a scale (issue #37): the zoom multiplies every
/// size by the same factor, so a row that reads as too small next to the
/// channel name above it still does at 200%. This keeps the row subordinate
/// while landing in the same range as every other person row in the app.
const double kVoiceParticipantAvatarSize = 22;

/// Status glyphs (screen share, camera, mute, deafen) on a participant row.
/// Sized with the avatar: they carry state a user scans for at a glance.
const double kVoiceParticipantIconSize = 14;

/// Channel / DM sidebar. A null `selectedServer` draws home mode (room controls
/// and the peer list), otherwise server mode (name header and channel list).
class ChannelSidebar extends StatelessWidget {
  final Map<String, PeerInfo> peers;
  final Map<String, ChatMessage> lastMessages;
  final String? selectedPeerId;
  final NodeStatus nodeStatus;
  final ValueChanged<String> onPeerSelected;
  final ChatMessage? Function(String) lastMessage;
  final String Function(DateTime) formatTime;

  final ServerInfo? selectedServer;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final VoidCallback onOpenSettings;
  final bool canManageChannels;
  final String channelLayoutJson;

  /// Null fills the available space, which is what mobile passes.
  final double? width;

  /// Dock layout: the sidebar hides entirely when no server is selected.
  final bool dockMode;

  /// False in Dock layout, which carries the user bar elsewhere.
  final bool showUserBar;

  /// Whether to draw this panel's own divider on the edge facing the chat.
  ///
  /// False wherever a [PanelResizeHandle] sits against that edge: the seam
  /// paints the divider itself, and two of them put a second line just inside
  /// the first.
  final bool edgeBorder;

  const ChannelSidebar({
    super.key,
    this.edgeBorder = true,
    required this.peers,
    required this.lastMessages,
    required this.selectedPeerId,
    required this.nodeStatus,
    required this.onPeerSelected,
    required this.lastMessage,
    required this.formatTime,
    this.selectedServer,
    this.channels = const {},
    this.selectedChannelId,
    this.onChannelSelected = _noop,
    this.onCreateChannel = _noopVoid,
    this.onOpenSettings = _noopVoid,
    this.canManageChannels = false,
    this.channelLayoutJson = '[]',
    this.width = 240,
    this.dockMode = false,
    this.showUserBar = true,
  });

  static void _noop(String _) {}
  static void _noopVoid() {}

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (dockMode && selectedServer == null) {
      return const SizedBox.shrink();
    }

    final sidebarReveal =
        StartupRevealScope.interval(context, 0.12, 0.30);
    final userBarReveal =
        StartupRevealScope.interval(context, 0.50, 0.60);

    Widget? userBar;
    if (showUserBar) {
      userBar = const UserBar();
      if (userBarReveal != null) {
        userBar = FadeTransition(
          opacity: userBarReveal,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.5),
              end: Offset.zero,
            ).animate(userBarReveal),
            child: userBar,
          ),
        );
      }
    }

    Widget sidebar = Container(
      width: width,
      decoration: BoxDecoration(
        color: hollow.surface,
        // A PanelResizeHandle against this edge paints the divider itself, and
        // a second one lands just inside the first.
        border: Border(
          right: edgeBorder
              ? BorderSide(color: hollow.border)
              : BorderSide.none,
        ),
      ),
      // Measure what the column actually got: it SHRINKS with the interface
      // zoom, so the banner header has to yield rather than eat the channel
      // list (see `bannerHeaderHeight`). Panel zoom (issue #54) keeps the slot
      // and grows the contents.
      child: PanelScale(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bannerHeight = bannerHeaderHeight(constraints.maxHeight);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedSwitcher(
                  duration: HollowDurations.fast,
                  child: _buildHeader(context, hollow, bannerHeight),
                ),

                Expanded(
                  child: AnimatedSwitcher(
                    duration: HollowDurations.normal,
                    switchInCurve: HollowCurves.enter,
                    switchOutCurve: HollowCurves.exit,
                    child: selectedServer != null
                        ? _ServerContent(
                            key: ValueKey('server-${selectedServer!.serverId}'),
                            hollow: hollow,
                            serverId: selectedServer!.serverId,
                            channels: channels,
                            selectedChannelId: selectedChannelId,
                            onChannelSelected: onChannelSelected,
                            onCreateChannel: onCreateChannel,
                            onOpenSettings: onOpenSettings,
                            canManageChannels: canManageChannels,
                            channelLayoutJson: channelLayoutJson,
                          )
                        : _HomeContent(
                            key: const ValueKey('home'),
                            hollow: hollow,
                            peers: peers,
                            selectedPeerId: selectedPeerId,
                            nodeStatus: nodeStatus,
                            onPeerSelected: onPeerSelected,
                            lastMessage: lastMessage,
                            formatTime: formatTime,
                          ),
                  ),
                ),

                const VoiceChannelPanel(),

                ?userBar,
              ],
            );
          },
        ),
      ),
    );

    return RevealClip(
      animation: sidebarReveal,
      axis: Axis.horizontal,
      alignment: Alignment.centerLeft,
      child: sidebar,
    );
  }

  Widget _buildHeader(
      BuildContext context, HollowTheme hollow, double bannerHeight) {
    final label = selectedServer?.name ?? 'Direct Messages';
    final serverId = selectedServer?.serverId;

    return Consumer(
      builder: (context, ref, _) {
        final banner = serverId == null
            ? null
            : ref.watch(serverBannerProvider.select((m) => m[serverId]));

        if (banner == null) {
          return Container(
            key: ValueKey('header-$label'),
            height: 48,
            // Right = sm so the action icons line up with the channel header's
            // "+" below.
            padding: const EdgeInsets.only(
              left: HollowSpacing.lg,
              right: HollowSpacing.sm,
            ),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: hollow.border)),
            ),
            child: _buildHeaderRow(context, hollow),
          );
        }

        // Banner header (issue #25). An animated banner plays only while it is
        // actually watched: the window is focused and motion is not reduced.
        final focused = ref.watch(windowFocusedProvider);
        return SizedBox(
          // The hash is in the key so a re-upload crossfades even though the
          // server label has not changed. No bottom border: the scrim fades
          // fully into the surface, and a border over that reads as a stray
          // line.
          key: ValueKey('header-$label-${banner.hash}'),
          height: bannerHeight,
          child: Stack(
            // The sidebar Container insets its children by its right border,
            // so an in-bounds banner stops short of it and the border colour
            // reads as a line against the image; the banner and scrim bleed
            // over that column instead.
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                right: -1,
                child: AnimatedGifImage(
                  bytes: banner.bytes,
                  fit: BoxFit.cover,
                  animate: focused,
                  errorWidget: const SizedBox.expand(),
                ),
              ),
              // Bottom-up scrim toward the sidebar surface, so header text
              // keeps its normal contrast. Many stops because a coarse ramp
              // BANDS on dark themes, and it must reach a FULLY opaque surface
              // or a sliver of banner reads as a line across the edge. Stops
              // use the surface colour at alpha 0, NEVER Colors.transparent,
              // which lerps through black in the light theme.
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                right: -1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        hollow.surface.withValues(alpha: 0.0),
                        hollow.surface.withValues(alpha: 0.08),
                        hollow.surface.withValues(alpha: 0.28),
                        hollow.surface.withValues(alpha: 0.60),
                        hollow.surface.withValues(alpha: 0.88),
                        hollow.surface.withValues(alpha: 1.0),
                      ],
                      stops: const [0.28, 0.46, 0.62, 0.78, 0.90, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Padding(
                  // Right = sm so the action icons line up with the channel
                  // header's "+" below.
                  padding: const EdgeInsets.fromLTRB(
                    HollowSpacing.lg,
                    HollowSpacing.sm,
                    HollowSpacing.sm,
                    HollowSpacing.sm,
                  ),
                  child: _buildHeaderRow(context, hollow),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeaderRow(BuildContext context, HollowTheme hollow) {
    final label = selectedServer?.name ?? 'Direct Messages';
    final headerTextReveal =
        StartupRevealScope.interval(context, 0.25, 0.40);

    return Row(
        children: [
          Expanded(
            // The header chrome is fixed-height, so the title scale is capped
            // to keep it in the bar at high OS text size.
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: TypewriterText(
                text: label,
                animation: headerTextReveal,
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (selectedServer != null) ...[
            HollowTooltip(
              message: 'Invite people',
              child: HollowPressable(
                semanticLabel: 'Invite people',
                onTap: () {
                  // Web form: clickable anywhere, since the browser bounces
                  // into the app, and new clients still render a Join card.
                  final link =
                      webServerInviteLink(selectedServer!.serverId);
                  showInviteDialog(
                      context, link, selectedServer!.serverId);
                },
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.userPlus,
                  size: 16,
                  color: hollow.textSecondary,
                ),
              ),
            ),
            HollowTooltip(
              message: 'Storage',
              child: HollowPressable(
                semanticLabel: 'Storage',
                onTap: () => showStorageDashboardDialog(
                    context, selectedServer!.serverId),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.hardDrive,
                  size: 16,
                  color: hollow.textSecondary,
                ),
              ),
            ),
            HollowTooltip(
              message: 'Server settings',
              child: HollowPressable(
                semanticLabel: 'Server settings',
                onTap: onOpenSettings,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(
                  LucideIcons.settings,
                  size: 16,
                  color: hollow.textSecondary,
                ),
              ),
            ),
          ],
        ],
      );
  }
}

/// Server mode content: the channel list.
class _ServerContent extends StatefulWidget {
  final HollowTheme hollow;
  final String serverId;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final VoidCallback onOpenSettings;
  final bool canManageChannels;
  final String channelLayoutJson;

  const _ServerContent({
    super.key,
    required this.hollow,
    required this.serverId,
    required this.channels,
    required this.selectedChannelId,
    required this.onChannelSelected,
    required this.onCreateChannel,
    required this.onOpenSettings,
    this.canManageChannels = false,
    this.channelLayoutJson = '[]',
  });

  @override
  State<_ServerContent> createState() => _ServerContentState();
}

class _ServerContentState extends State<_ServerContent> {
  /// Re-parsed only when the JSON string changes.
  List<LayoutItem> _parsedLayout = const [];
  String _lastLayoutJson = '';

  List<LayoutItem> _getParsedLayout() {
    if (widget.channelLayoutJson != _lastLayoutJson) {
      _lastLayoutJson = widget.channelLayoutJson;
      _parsedLayout = parseLayoutJson(widget.channelLayoutJson);
    }
    return _parsedLayout;
  }

  /// The rows to draw, from the EFFECTIVE layout.
  ///
  /// Effective, never stored: [effectiveLayoutFrom] is the same normalisation
  /// the context menus and the Channels editor use, so all three agree on what
  /// a category contains AND on what index it has. Rendering the stored layout
  /// strands appended channels outside the category they are drawn under, and
  /// shifts every index past a dropped channel id, which the category menu
  /// edits by (feedback_one_mutation_path_per_state).
  List<Widget> _buildLayoutItems() {
    final w = widget;
    final widgets = <Widget>[];
    final layout = effectiveLayoutFrom(_getParsedLayout(), w.channels);

    String? currentCategory;
    for (var index = 0; index < layout.length; index++) {
      final item = layout[index];
      switch (item) {
        case CategoryItem(:final name):
          currentCategory = name;
          widgets.add(_CategoryHeader(
            hollow: w.hollow,
            name: name,
            // Categories are addressed by POSITION, never by name: two of them
            // may legally share one.
            layoutIndex: index,
            serverId: w.serverId,
            layoutJson: w.channelLayoutJson,
            canManage: w.canManageChannels,
            onToggle: () => setState(() {}),
          ));
        case SeparatorItem():
          currentCategory = null;
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
            child: Divider(height: 1, color: w.hollow.border),
          ));
        case ChannelItem(:final channelId):
          // Normalisation already dropped ids with no channel, so a miss means
          // the channel list changed under us this frame.
          final channel = w.channels[channelId];
          if (channel == null) break;
          final collapsed = currentCategory != null &&
              (_categoryCollapsedState[currentCategory] ?? false);
          final Widget tile;
          if (channel.channelType == ChannelType.voice) {
            tile = _VoiceChannelTile(
              channel: channel,
              serverId: w.serverId,
              canManage: w.canManageChannels,
              onChannelSelected: w.onChannelSelected,
            );
          } else {
            tile = _ChannelTile(
              channel: channel,
              serverId: w.serverId,
              canManage: w.canManageChannels,
              isSelected: channel.channelId == w.selectedChannelId,
              onTap: () => w.onChannelSelected(channel.channelId),
            );
          }
          widgets.add(_AnimatedChannelTile(
            key: ValueKey('ach-$channelId'),
            visible: !collapsed,
            child: tile,
          ));
      }
    }

    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final items = _buildLayoutItems();
    final hasCategories = items.any((i) => i is _CategoryHeader);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!hasCategories)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.lg, HollowSpacing.sm, HollowSpacing.sm, HollowSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'TEXT CHANNELS',
                    style: HollowTypography.caption.copyWith(
                      color: w.hollow.textSecondary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                if (w.canManageChannels)
                  HollowPressable(
                    semanticLabel: 'Create channel',
                    onTap: w.onCreateChannel,
                    borderRadius: BorderRadius.circular(w.hollow.radiusSm),
                    padding: const EdgeInsets.all(HollowSpacing.xs),
                    child: Icon(LucideIcons.plus,
                        size: 14, color: w.hollow.textSecondary),
                  ),
              ],
            ),
          ),
        if (!hasCategories) Divider(height: 1, color: w.hollow.border),
        Expanded(
          // Right-click on empty sidebar space opens the server-level menu
          // (issue #61). Opaque so the area below the last channel is a hit
          // target; a tile or category header wins its own right-click,
          // because the inner recognizer takes the arena.
          child: Consumer(
            builder: (context, ref, child) => ContextMenuTarget(
              behavior: HitTestBehavior.opaque,
              semanticLabel: 'Server actions',
              onOpen: (anchor) => showChannelSidebarMenu(
                context: context,
                ref: ref,
                serverId: w.serverId,
                canManage: w.canManageChannels,
                onOpenSettings: w.onOpenSettings,
                onInvite: () {
                  // The same web-form link the header's invite button copies.
                  final link = webServerInviteLink(w.serverId);
                  showInviteDialog(context, link, w.serverId);
                },
                anchor: anchor,
              ),
              child: child!,
            ),
            child: items.isEmpty
                ? Center(
                    child: Text('No channels',
                        style: HollowTypography.bodySmall
                            .copyWith(color: w.hollow.textSecondary)),
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                    itemCount: items.length,
                    itemBuilder: (_, i) => items[i],
                  ),
          ),
        ),
      ],
    );
  }
}

/// Animates a channel tile in/out when its category is collapsed/expanded.
class _AnimatedChannelTile extends StatelessWidget {
  final bool visible;
  final Widget child;

  const _AnimatedChannelTile({
    super.key,
    required this.visible,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: HollowDurations.fast,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: visible ? null : 0,
        child: visible
            ? child
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// Top-level so a collapsed category survives a sidebar rebuild.
final Map<String, bool> _categoryCollapsedState = {};

/// Collapsible category header in the sidebar.
class _CategoryHeader extends StatefulWidget {
  final HollowTheme hollow;
  final String name;
  final VoidCallback? onToggle;

  /// Position in the parsed layout, which is the identity the context menu
  /// edits by, because names are not unique.
  final int layoutIndex;
  final String serverId;
  final String layoutJson;
  final bool canManage;

  const _CategoryHeader({
    required this.hollow,
    required this.name,
    required this.layoutIndex,
    required this.serverId,
    required this.layoutJson,
    this.canManage = false,
    this.onToggle,
  });

  @override
  State<_CategoryHeader> createState() => _CategoryHeaderState();
}

class _CategoryHeaderState extends State<_CategoryHeader> {
  bool get _collapsed => _categoryCollapsedState[widget.name] ?? false;

  void _toggle() {
    setState(() => _categoryCollapsedState[widget.name] = !_collapsed);
    widget.onToggle?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref, _) => ContextMenuTarget(
        semanticLabel: 'Category actions',
        onOpen: (anchor) => showCategoryMenu(
          context: context,
          ref: ref,
          serverId: widget.serverId,
          layoutJson: widget.layoutJson,
          categoryIndex: widget.layoutIndex,
          categoryName: widget.name,
          canManage: widget.canManage,
          isCollapsed: _collapsed,
          onToggleCollapse: _toggle,
          anchor: anchor,
        ),
        child: _buildHeader(),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.sm + 2,
        HollowSpacing.md,
        HollowSpacing.sm,
        HollowSpacing.xs,
      ),
      child: HollowPressable(
        subtle: true,
        onTap: _toggle,
        child: Row(
          children: [
            AnimatedRotation(
              turns: _collapsed ? -0.25 : 0,
              duration: HollowDurations.fast,
              child: Icon(LucideIcons.chevronDown,
                  size: 10, color: widget.hollow.textSecondary),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: Text(
                widget.name.toUpperCase(),
                style: HollowTypography.caption.copyWith(
                  color: widget.hollow.textSecondary,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Home mode content: the friends list.
class _HomeContent extends ConsumerWidget {
  final HollowTheme hollow;
  final Map<String, PeerInfo> peers;
  final String? selectedPeerId;
  final NodeStatus nodeStatus;
  final ValueChanged<String> onPeerSelected;
  final ChatMessage? Function(String) lastMessage;
  final String Function(DateTime) formatTime;

  const _HomeContent({
    super.key,
    required this.hollow,
    required this.peers,
    required this.selectedPeerId,
    required this.nodeStatus,
    required this.onPeerSelected,
    required this.lastMessage,
    required this.formatTime,
  });

  @override
  Widget build(BuildContext innerContext, WidgetRef ref) {
    final friends = ref.watch(friendsProvider);
    // A friend is online if ANY of their devices is, collapsed to the master
    // identity.
    final online = ref.watch(onlineIdentitiesProvider);
    final dividerTextStyle = HollowTypography.caption.copyWith(
      color: hollow.textSecondary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      fontSize: 11,
    );

    final accepted = friends.values
        .where((f) => f.status == 'accepted')
        .toList();
    final pendingIncoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList();
    final pendingOutgoing = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'outgoing')
        .toList();

    accepted.sort((a, b) {
      final aOnline = online.contains(a.peerId) ? 0 : 1;
      final bOnline = online.contains(b.peerId) ? 0 : 1;
      if (aOnline != bOnline) return aOnline.compareTo(bOnline);
      return a.peerId.compareTo(b.peerId);
    });

    final hasPending = pendingIncoming.isNotEmpty || pendingOutgoing.isNotEmpty;

    // Device to master mirror for the encrypted-lock lookup below: `peers` is
    // DEVICE-keyed and `friend.peerId` is the MASTER.
    final links = ref.watch(deviceLinkProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(HollowSpacing.sm + 2),
          child: HollowButton.outline(
            onPressed: () => _showAddFriendDialog(innerContext, ref),
            expand: true,
            icon: const Icon(LucideIcons.userPlus, size: 14),
            child: const Text('Add Friend'),
          ),
        ),

        Divider(height: 1, color: hollow.border),

        // Saved messages is a DM with your own master identity, opened through
        // the same flow as a friend.
        Builder(builder: (context) {
          final savedId = ref.watch(savedMessagesPeerIdProvider);
          if (savedId == null) return const SizedBox.shrink();
          return _SavedMessagesCard(
            isSelected: savedId == selectedPeerId,
            lastMessage: lastMessage(savedId),
            formatTime: formatTime,
            onTap: () => onPeerSelected(savedId),
          );
        }),

        if (hasPending) ...[
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm + 2,
              vertical: HollowSpacing.sm,
            ),
            child: Row(
              children: [
                Text('PENDING', style: dividerTextStyle),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(child: Divider(height: 1, color: hollow.border)),
                const SizedBox(width: HollowSpacing.sm),
                Text('${pendingIncoming.length + pendingOutgoing.length}',
                    style: dividerTextStyle),
              ],
            ),
          ),
          for (final req in pendingIncoming)
            _PendingRequestTile(
              hollow: hollow,
              peerId: req.peerId,
              direction: 'incoming',
              onAccept: () async {
                try {
                  await ref
                      .read(friendsProvider.notifier)
                      .acceptRequest(req.peerId);
                } catch (_) {
                  if (innerContext.mounted) {
                    HollowToast.show(innerContext, 'Could not accept request',
                        type: HollowToastType.error);
                  }
                }
              },
              onReject: () async {
                try {
                  await ref
                      .read(friendsProvider.notifier)
                      .rejectRequest(req.peerId);
                } catch (_) {
                  if (innerContext.mounted) {
                    HollowToast.show(innerContext, 'Could not decline request',
                        type: HollowToastType.error);
                  }
                }
              },
            ),
          for (final req in pendingOutgoing)
            _PendingRequestTile(
              hollow: hollow,
              peerId: req.peerId,
              direction: 'outgoing',
            ),
          Divider(height: 1, color: hollow.border),
        ],

        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm + 2,
            vertical: HollowSpacing.sm,
          ),
          child: Row(
            children: [
              Text('FRIENDS', style: dividerTextStyle),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(child: Divider(height: 1, color: hollow.border)),
              const SizedBox(width: HollowSpacing.sm),
              Text('${accepted.length}', style: dividerTextStyle),
            ],
          ),
        ),

        Expanded(
          child: accepted.isEmpty && !hasPending
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.users, size: 48,
                          color: hollow.textSecondary.withValues(alpha: 0.3)),
                      const SizedBox(height: HollowSpacing.md),
                      Text('No friends yet',
                          style: HollowTypography.body
                              .copyWith(color: hollow.textSecondary)),
                      const SizedBox(height: HollowSpacing.xs),
                      Text('Add a friend by their peer ID',
                          style: HollowTypography.caption
                              .copyWith(color: hollow.textSecondary)),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: accepted.length,
                  padding: const EdgeInsets.symmetric(
                      vertical: HollowSpacing.xs),
                  itemBuilder: (context, index) {
                    final friend = accepted[index];
                    final isOnline = online.contains(friend.peerId);
                    // `peers` is DEVICE-keyed while `friend.peerId` is the
                    // MASTER, so a direct lookup silently never matches a
                    // multi-device friend and the encrypted lock never shows.
                    final isEncrypted = peers.entries.any((e) =>
                        links.identityOf(e.key) == friend.peerId &&
                        e.value.isEncrypted);
                    final isSelected = friend.peerId == selectedPeerId;
                    final last = lastMessage(friend.peerId);

                    return PeerCard(
                      peerId: friend.peerId,
                      isSelected: isSelected,
                      isEncrypted: isEncrypted,
                      isOnline: isOnline,
                      lastMessage: last,
                      formatTime: formatTime,
                      onTap: () => onPeerSelected(friend.peerId),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _showAddFriendDialog(BuildContext context, WidgetRef ref) {
    showHollowDialog(
      context: context,
      builder: (ctx) => _SidebarAddFriendDialog(parentContext: context),
    );
  }
}

/// Pinned "Saved messages" row: [PeerCard] styling with a bookmark avatar and
/// no presence dot, since it is a conversation with yourself.
class _SavedMessagesCard extends StatelessWidget {
  final bool isSelected;
  final ChatMessage? lastMessage;
  final String Function(DateTime) formatTime;
  final VoidCallback onTap;

  const _SavedMessagesCard({
    required this.isSelected,
    required this.lastMessage,
    required this.formatTime,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusMd);

    Widget card = HollowPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: radius,
      backgroundColor: isSelected ? hollow.accentMuted : null,
      hoverColor: hollow.elevated,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm + 2,
      ),
      child: Row(
        children: [
          const SavedMessagesAvatar(size: 36),
          const SizedBox(width: HollowSpacing.sm + 2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Saved messages',
                  style: HollowTypography.body.copyWith(
                    fontSize: 13,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w400,
                    color: hollow.textPrimary,
                  ),
                ),
                if (lastMessage != null) ...[
                  const SizedBox(height: HollowSpacing.xxs),
                  Text(
                    lastMessage!.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.bodySmall.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (lastMessage != null)
            Padding(
              padding: const EdgeInsets.only(left: HollowSpacing.sm),
              child: Text(
                formatTime(lastMessage!.timestamp),
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                ),
              ),
            ),
        ],
      ),
    );

    if (isSelected) {
      card = SelectionShimmer(
        highlightColor: hollow.accent.withValues(alpha: 0.12),
        borderRadius: radius,
        child: card,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: card,
    );
  }
}

/// Pending friend request tile with accept/reject buttons.
class _PendingRequestTile extends ConsumerWidget {
  final HollowTheme hollow;
  final String peerId;
  final String direction;
  final VoidCallback? onAccept;
  final VoidCallback? onReject;

  const _PendingRequestTile({
    required this.hollow,
    required this.peerId,
    required this.direction,
    this.onAccept,
    this.onReject,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[peerId]));
    final name = displayNameForPeer(peerProfile, peerId);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm + 2,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
        ),
        child: Row(
          children: [
            HollowAvatar(peerId: peerId, size: 28),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    direction == 'incoming'
                        ? 'Wants to be friends'
                        : 'Request sent',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            if (direction == 'incoming') ...[
              HollowPressable(
                semanticLabel: 'Accept friend request',
                onTap: onAccept,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.check, size: 16, color: hollow.success),
              ),
              HollowPressable(
                semanticLabel: 'Reject friend request',
                onTap: onReject,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.x, size: 16, color: hollow.error),
              ),
            ] else
              Icon(LucideIcons.clock, size: 14, color: hollow.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// Sidebar add-friend dialog, taking a peer id or a nickname.
class _SidebarAddFriendDialog extends ConsumerStatefulWidget {
  final BuildContext parentContext;
  const _SidebarAddFriendDialog({required this.parentContext});

  @override
  ConsumerState<_SidebarAddFriendDialog> createState() =>
      _SidebarAddFriendDialogState();
}

class _SidebarAddFriendDialogState
    extends ConsumerState<_SidebarAddFriendDialog> {
  final _controller = TextEditingController();

  static bool _isPeerId(String input) => input.startsWith('12D3KooW');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final input = _controller.text.trim();
    if (input.isEmpty) return;
    // Awaited so a failure surfaces here and the dialog stays open for a
    // retry, instead of toasting a false success.
    try {
      if (_isPeerId(input)) {
        await ref.read(friendsProvider.notifier).sendRequest(input);
      } else {
        await network_api.sendFriendRequestByNickname(nickname: input);
      }
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not send request',
            type: HollowToastType.error);
      }
      return;
    }
    if (!mounted) return;
    Navigator.pop(context);
    final parentContext = widget.parentContext;
    if (!parentContext.mounted) return;
    HollowToast.show(
      parentContext,
      _isPeerId(input) ? 'Friend request sent' : 'Looking up nickname...',
      type: HollowToastType.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowDialog(
      title: 'Add Friend',
      content: HollowTextField(
        controller: _controller,
        hintText: 'Peer ID or nickname...',
        autofocus: true,
        style: HollowTypography.mono.copyWith(
          color: hollow.textPrimary,
          fontSize: 12,
        ),
        onSubmitted: (_) => _send(),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _send,
          child: const Text('Send Request'),
        ),
      ],
    );
  }
}

/// A single channel tile in the channel list.
class _ChannelTile extends ConsumerWidget {
  final ChannelInfo channel;
  final String serverId;
  final bool isSelected;
  final VoidCallback onTap;

  /// Advisory only: it picks which rows the context menu offers, and Rust
  /// re-checks every op.
  final bool canManage;

  // No `key`: the keyed list element is the _AnimatedChannelTile wrapping this
  // one, and Flutter reparents on that.
  const _ChannelTile({
    required this.channel,
    required this.serverId,
    required this.isSelected,
    required this.onTap,
    this.canManage = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusMd);
    final isMuted = ref.watch(notificationSettingsProvider
        .select((s) => s.isChannelMuted(serverId, channel.channelId)));
    final unreadCount = isSelected ? 0 :
        (isMuted ? 0 : ref.watch(unreadProvider
            .select((s) => s.channelUnreadCount(serverId, channel.channelId))));
    final hasUnread = unreadCount > 0;
    final mentionCount = isSelected ? 0 :
        ref.watch(unreadProvider
            .select((s) => s.channelMentions(serverId, channel.channelId)));

    Widget tile = HollowPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: radius,
      backgroundColor: isSelected ? hollow.accentMuted : null,
      hoverColor: hollow.elevated,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      child: AnimatedDefaultTextStyle(
        duration: HollowDurations.fast,
        curve: HollowCurves.subtle,
        style: HollowTypography.body.copyWith(
          color: isSelected || hasUnread
              ? hollow.textPrimary
              : hollow.textSecondary,
          fontWeight:
              isSelected || hasUnread ? FontWeight.w600 : FontWeight.w400,
        ),
        child: Row(
          children: [
            Icon(
              channel.channelType == ChannelType.voice
                  ? LucideIcons.volume2
                  : LucideIcons.hash,
              size: 18,
              color: isSelected || hasUnread
                  ? hollow.textPrimary
                  : hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                channel.name,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Public indicator (#44): otherwise nothing tells a member which
            // channels the public browser can read.
            if (channel.isPublic) ...[
              HollowTooltip(
                message: 'Public: anyone can read this channel without joining',
                child: Icon(
                  LucideIcons.globe,
                  size: 12,
                  color: hollow.textTertiary,
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
            ],
            if (mentionCount > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: hollow.error,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  '@$mentionCount',
                  style: HollowTypography.caption.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10),
                ),
              )
            else if (hasUnread)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: hollow.error,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  unreadCount > 99 ? '99+' : '$unreadCount',
                  style: HollowTypography.caption.copyWith(
                    color: Colors.white, fontWeight: FontWeight.w700, fontSize: 10),
                ),
              ),
          ],
        ),
      ),
    );

    if (isSelected) {
      tile = SelectionShimmer(
        highlightColor: hollow.accent.withValues(alpha: 0.12),
        borderRadius: radius,
        child: tile,
      );
    }

    return ContextMenuTarget(
      semanticLabel: 'Channel actions',
      onOpen: (anchor) => showChannelTileMenu(
        context: context,
        ref: ref,
        serverId: serverId,
        channel: channel,
        canManage: canManage,
        anchor: anchor,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xxs,
        ),
        child: tile,
      ),
    );
  }
}

/// Voice channel tile. A click JOINS the channel rather than selecting it for
/// text, and leaving peers are held until their exit animation finishes.
class _VoiceChannelTile extends ConsumerStatefulWidget {
  final ChannelInfo channel;
  final String serverId;
  final ValueChanged<String> onChannelSelected;

  /// See [_ChannelTile.canManage].
  final bool canManage;

  /// See [_ChannelTile]'s note on keys.
  const _VoiceChannelTile({
    required this.channel,
    required this.serverId,
    required this.onChannelSelected,
    this.canManage = false,
  });

  @override
  ConsumerState<_VoiceChannelTile> createState() => _VoiceChannelTileState();
}

class _VoiceChannelTileState extends ConsumerState<_VoiceChannelTile> {
  /// Held in the tree until their exit animation finishes.
  final Set<String> _leavingPeers = {};

  Set<String> _prevParticipants = {};

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final isConnected = vcState.currentServerId == widget.serverId &&
        vcState.currentChannelId == widget.channel.channelId;
    final participants =
        vcState.getParticipants(widget.serverId, widget.channel.channelId);

    final departed = _prevParticipants.difference(participants);
    for (final peerId in departed) {
      if (!_leavingPeers.contains(peerId)) {
        _leavingPeers.add(peerId);
      }
    }
    _prevParticipants = Set.of(participants);

    final visible = [...participants, ..._leavingPeers];

    final radius = BorderRadius.circular(hollow.radiusMd);

    Widget channelRow = HollowPressable(
      onTap: () {
        if (isConnected) {
          widget.onChannelSelected(widget.channel.channelId);
          return;
        }
        ref.read(voiceChannelProvider.notifier)
            .joinChannel(widget.serverId, widget.channel.channelId);
      },
      subtle: true,
      borderRadius: radius,
      backgroundColor: isConnected ? hollow.accentMuted : null,
      hoverColor: hollow.elevated,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            LucideIcons.volume2,
            size: 18,
            color: isConnected ? hollow.accent : hollow.textSecondary,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              widget.channel.name,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.body.copyWith(
                color: isConnected
                    ? hollow.textPrimary
                    : hollow.textSecondary,
                fontWeight: isConnected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );

    if (isConnected) {
      channelRow = SelectionShimmer(
        highlightColor: hollow.accent.withValues(alpha: 0.12),
        borderRadius: radius,
        vertical: true,
        child: channelRow,
      );
    }

    // The channel row only: participant rows below keep their own secondary-tap
    // volume popup.
    channelRow = ContextMenuTarget(
      semanticLabel: 'Channel actions',
      onOpen: (anchor) => showChannelTileMenu(
        context: context,
        ref: ref,
        serverId: widget.serverId,
        channel: widget.channel,
        canManage: widget.canManage,
        anchor: anchor,
      ),
      child: channelRow,
    );

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          channelRow,
          AnimatedSize(
            duration: HollowDurations.normal,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(
                  left: HollowSpacing.sm + 2 + 18 + HollowSpacing.sm),
              child: Column(
                children: visible
                    .map((peerId) => _AnimatedParticipantRow(
                          key: ValueKey('vp-$peerId'),
                          leaving: _leavingPeers.contains(peerId),
                          onLeaveComplete: () {
                            if (mounted) {
                              setState(() => _leavingPeers.remove(peerId));
                            }
                          },
                          child: _VoiceParticipantRow(
                            peerId: peerId,
                            serverId: widget.serverId,
                            channelId: widget.channel.channelId,
                          ),
                        ))
                    .toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Animates a participant row in/out with a simple fade.
class _AnimatedParticipantRow extends StatefulWidget {
  final Widget child;
  final bool leaving;
  final VoidCallback? onLeaveComplete;

  const _AnimatedParticipantRow({
    super.key,
    required this.child,
    this.leaving = false,
    this.onLeaveComplete,
  });

  @override
  State<_AnimatedParticipantRow> createState() =>
      _AnimatedParticipantRowState();
}

class _AnimatedParticipantRowState extends State<_AnimatedParticipantRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 180),
    );
    if (widget.leaving) {
      _controller.value = 1.0;
      _controller.reverse().then((_) => widget.onLeaveComplete?.call());
    } else {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_AnimatedParticipantRow old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      _controller.reverse().then((_) => widget.onLeaveComplete?.call());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: widget.child,
    );
  }
}

/// A single participant row in a voice channel tile.
class _VoiceParticipantRow extends ConsumerWidget {
  final String peerId;
  final String serverId;
  final String channelId;

  const _VoiceParticipantRow({
    required this.peerId,
    required this.serverId,
    required this.channelId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // VC participants are keyed by the ROUTABLE WS sender, a DEVICE peer id.
    // Display (avatar, nickname, profile name) collapses to the MASTER, while
    // audio, speaking and volume state stay keyed by the routable id.
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[master]));
    final name = displayNameForPeer(peerProfile, master);
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    // Self is THIS device or the bare master id. A sibling of ours in the same
    // channel is deliberately NOT self: it has its own mute and camera state.
    final myDevice = ref.watch(localDevicePeerIdProvider).valueOrNull;
    final isSelf = peerId == localPeerId || peerId == myDevice;

    final bool isMuted;
    final bool isDeafened;
    if (isSelf) {
      isMuted = vcState.isMuted;
      isDeafened = vcState.isDeafened;
    } else {
      final peerState = vcState.getPeerAudioState(peerId);
      isMuted = peerState.isMuted;
      isDeafened = peerState.isDeafened;
    }

    // Our own row reads the dedicated local flag; remote rows
    // membership-select so a row rebuilds only when ITS peer's bit flips.
    // Testing the set for OURSELVES fails silently, because the set is keyed
    // by routable device ids and this row may hold either form.
    final speaking = isSelf
        ? ref.watch(vcLocalSpeakingProvider)
        : ref.watch(vcSpeakingProvider.select((s) => s.contains(peerId)));
    final isRemote = !isSelf;
    final isScreenSharing = isSelf
        ? vcState.isScreenSharing
        : (vcState.peerScreenSharing[peerId] ?? false);
    final isCameraOn = isSelf
        ? vcState.isCameraOn
        : (vcState.peerCameraOn[peerId] ?? false);
    final recState = ref.watch(recordingProvider);
    final isRecording = isSelf
        ? recState.isMyRecording
        : recState.remoteRecorders.contains(peerId);

    // The user menu, with the per-peer volume slider as its first row (#61).
    return ContextMenuTarget(
      enabled: isRemote,
      semanticLabel: 'Participant actions',
      onOpen: (anchor) => showUserContextMenu(
        context: context,
        ref: ref,
        peerId: master,
        routablePeerId: peerId,
        serverId: serverId,
        surface: UserMenuSurface.voice,
        anchor: anchor,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xxs),
        child: Row(
          children: [
            // The speaking cue hugs the avatar so a long name cannot push it
            // out of view. SpeakingAvatarOutline, not SpeakingBorder: this row
            // is dense, so the outline must take no layout space and stand no
            // gap off the avatar.
            SpeakingAvatarOutline(
              isSpeaking: speaking,
              size: kVoiceParticipantAvatarSize,
              radius: hollow.radiusMd,
              child: HollowAvatar(
                  peerId: master, size: kVoiceParticipantAvatarSize),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                name,
                style: HollowTypography.label.copyWith(
                  color: hollow.textSecondary,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // In a mesh, one member on bad Wi-Fi is that member's leg, so the
            // flair sits on THEIR row and never reads as a channel-wide alarm.
            if (isRemote)
              Consumer(builder: (context, ref, _) {
                final health =
                    ref.watch(vcLinkHealthProvider.select((m) => m[peerId]));
                if (health == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(left: HollowSpacing.xxs),
                  child: LinkHealthChip(snapshot: health, compact: true),
                );
              }),
            if (isScreenSharing)
              const Padding(
                padding: EdgeInsets.only(left: HollowSpacing.xxs),
                child: Icon(LucideIcons.monitor,
                    size: kVoiceParticipantIconSize, color: Colors.green),
              ),
            if (isCameraOn)
              Padding(
                padding: const EdgeInsets.only(left: HollowSpacing.xxs),
                child: Icon(LucideIcons.video,
                    size: kVoiceParticipantIconSize, color: hollow.accent),
              ),
            if (isMuted)
              Padding(
                padding: const EdgeInsets.only(left: HollowSpacing.xxs),
                child: Icon(LucideIcons.micOff,
                    size: kVoiceParticipantIconSize, color: hollow.error),
              ),
            if (isDeafened)
              Padding(
                padding: const EdgeInsets.only(left: HollowSpacing.xxs),
                child: Icon(LucideIcons.headphones,
                    size: kVoiceParticipantIconSize, color: hollow.error),
              ),
            if (isRecording)
              const Padding(
                padding: EdgeInsets.only(left: 4),
                child: RecordingIndicator.compact(),
              ),
          ],
        ),
      ),
    );
  }

}
