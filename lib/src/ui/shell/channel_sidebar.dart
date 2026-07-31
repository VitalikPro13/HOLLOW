import 'dart:convert';
import 'dart:math' as math;

import 'package:hollow/src/ui/chat/hollow_link_utils.dart';

import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/speaking_border.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
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
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/member_panel_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
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
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/shell/user_bar.dart';
import 'package:hollow/src/ui/shell/voice_channel_panel.dart';
import 'package:hollow/src/ui/sidebar/peer_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;

/// Full height of the server banner header (issue #25) when the sidebar has
/// room for it. Below [kBannerHeaderMinHeight] worth of pressure it yields —
/// see [bannerHeaderHeight].
const double kBannerHeaderHeight = 120;

/// The banner never shrinks past this: the server name + action icons still
/// have to read, and the borderless fallback header is already 48.
const double kBannerHeaderMinHeight = 72;

/// Share of the sidebar column the banner may occupy once space is tight.
/// 120/0.22 ≈ 545, so this is inert at any normal desktop height and only
/// engages when the column is genuinely short.
const double _kBannerHeaderMaxFraction = 0.22;

/// How tall the banner header should be in a sidebar column of [available]
/// logical pixels.
///
/// **Why this is not a constant.** The interface zoom lays the whole app out
/// at `viewport / scale` (`ui_scale.dart`), so raising the zoom does not just
/// magnify the sidebar — it *shortens* it. On 1080p the sidebar column is
/// ~905 logical px at 100% but only ~401 at 200%, and a flat 120px banner
/// goes from 13% of the column to 30% of it. Stack the voice panel on top of
/// that and over half the sidebar is chrome, which is why issue #37's 200%
/// screenshot fits three channels. A fixed slice of a viewport that shrinks
/// with zoom is not a fixed slice — it grows.
///
/// Returns the full [kBannerHeaderHeight] whenever the column can afford it,
/// so nothing changes at ordinary window sizes.
double bannerHeaderHeight(double available) {
  if (!available.isFinite || available <= 0) return kBannerHeaderHeight;
  return math.min(
    kBannerHeaderHeight,
    math.max(kBannerHeaderMinHeight, available * _kBannerHeaderMaxFraction),
  );
}

/// Avatar edge for a voice-channel participant row.
///
/// **Why this is not 18.** Issue #37: "the channel list on the left icons and
/// names are ever so tiny". These rows were the smallest thing in the app —
/// an 18px avatar under a 28px one everywhere else, and `caption` (11px) text
/// directly beneath a `body` (14px) channel name. The interface zoom cannot
/// fix that, because zoom multiplies every size by the same factor: 11-next-
/// to-14 stays 11-next-to-14 at 200%. It was a RATIO problem inside the
/// panel, not a scaling one. 22/13 keeps the rows subordinate to the channel
/// name above them while landing in the same range as every other person row
/// (member panel and chat both use 28px avatars with 13px names).
const double kVoiceParticipantAvatarSize = 22;

/// Status glyphs (screen share / camera / mute / deafen) on a participant
/// row. Sized with the avatar above, not left at 12 — they carry state a user
/// scans for at a glance, and they were the first thing to disappear.
const double kVoiceParticipantIconSize = 14;

/// Channel / DM sidebar (240px). Supports two modes:
///
/// **Home mode** (`selectedServer == null`): room controls + peer list.
/// **Server mode** (`selectedServer != null`): server name header + channel list.
class ChannelSidebar extends StatelessWidget {
  // -- Home mode props --
  final Map<String, PeerInfo> peers;
  final Map<String, ChatMessage> lastMessages;
  final String? selectedPeerId;
  final NodeStatus nodeStatus;
  final ValueChanged<String> onPeerSelected;
  final ChatMessage? Function(String) lastMessage;
  final String Function(DateTime) formatTime;

  // -- Server mode props --
  final ServerInfo? selectedServer;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
  final VoidCallback onOpenSettings;
  final bool canManageChannels;
  final String channelLayoutJson;

  /// Fixed width for desktop/tablet. Pass null on mobile to fill available space.
  final double? width;

  /// When true, sidebar hides entirely when no server selected (Dock layout).
  final bool dockMode;

  /// Whether to show the UserBar at the bottom. False in Dock layout.
  final bool showUserBar;

  const ChannelSidebar({
    super.key,
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

    // In dock mode, hide sidebar entirely when no server is selected.
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
        border: Border(
          right: BorderSide(color: hollow.border),
        ),
      ),
      // The banner header is the only fixed-height slice of this column, and
      // the column itself SHRINKS with the interface zoom (everything below
      // `UiScale` lays out at `viewport / scale`). Measure what we actually
      // got so the header can yield instead of eating the channel list —
      // see `bannerHeaderHeight`.
      child: LayoutBuilder(
        builder: (context, constraints) {
          final bannerHeight = bannerHeaderHeight(constraints.maxHeight);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header — crossfade between server name and "Direct Messages"
              AnimatedSwitcher(
                duration: HollowDurations.fast,
                child: _buildHeader(context, hollow, bannerHeight),
              ),

              // Content — crossfade between server channels and home/DM view
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

              // Voice channel controls (visible when in a voice channel)
              const VoiceChannelPanel(),

              // User bar at bottom (hidden in dock mode)
              ?userBar,
            ],
          );
        },
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

        // No banner (and always in home/DM mode): the classic 48px header.
        if (banner == null) {
          return Container(
            key: ValueKey('header-$label'),
            height: 48,
            // Right = sm so the action icons line up with the channel
            // header's "+" below (its row is LTRB lg/sm).
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

        // Banner header (issue #25): the banner fills a taller header with
        // the name + actions overlaid on a bottom-up scrim. Animated
        // banners only play while actually watched: window focused and not
        // reduce-motion (AnimatedGifImage enforces the latter itself);
        // selected + mounted are implied — the sidebar renders only the
        // selected server.
        final focused = ref.watch(windowFocusedProvider);
        return SizedBox(
          // Hash in the key so a banner re-upload crossfades even though
          // the server label (the old key) is unchanged. No bottom border
          // here — the scrim fades fully into the surface, and a border on
          // top of that fade reads as a stray line.
          key: ValueKey('header-$label-${banner.hash}'),
          height: bannerHeight,
          child: Stack(
            // The sidebar Container insets its children by its 1px right
            // border (BoxDecoration.padding), so an in-bounds banner stops
            // 1px short and the border color shows as a line against the
            // image. Banner + scrim bleed 1px right over that column;
            // Clip.none lets them paint there.
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
              // Bottom-up scrim toward the sidebar surface so the header
              // text keeps its normal theme contrast. Eased multi-stop
              // falloff (a coarse 3-stop ramp BANDS on dark themes) that
              // reaches FULLY opaque surface at the bottom — anything
              // less leaves a sliver of banner against the solid sidebar
              // below, which reads as a line across the edge. Stops use
              // the surface color at alpha 0 — NEVER Colors.transparent
              // (it lerps through black in light theme).
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
                  // Right = sm so the action icons line up with the
                  // channel header's "+" below (its row is LTRB lg/sm).
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
            // a11y Phase 3: fixed-height (48px) sidebar header chrome — cap the
            // title scale so it stays in the bar at high OS text size.
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
                  // Web form: clickable anywhere (browser bounces into the
                  // app); new clients still render it as a Join card.
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

/// Server mode content — channel list with create button.
class _ServerContent extends StatefulWidget {
  final HollowTheme hollow;
  final String serverId;
  final Map<String, ChannelInfo> channels;
  final String? selectedChannelId;
  final ValueChanged<String> onChannelSelected;
  final VoidCallback onCreateChannel;
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
    this.canManageChannels = false,
    this.channelLayoutJson = '[]',
  });

  @override
  State<_ServerContent> createState() => _ServerContentState();
}

class _ServerContentState extends State<_ServerContent> {
  /// Cached parsed layout — only re-parsed when the JSON string changes.
  List<dynamic> _parsedLayout = [];
  String _lastLayoutJson = '';

  List<dynamic> _getParsedLayout() {
    if (widget.channelLayoutJson != _lastLayoutJson) {
      _lastLayoutJson = widget.channelLayoutJson;
      try {
        _parsedLayout = jsonDecode(widget.channelLayoutJson) as List<dynamic>;
      } catch (_) {
        _parsedLayout = [];
      }
    }
    return _parsedLayout;
  }

  List<Widget> _buildLayoutItems() {
    final w = widget;
    final widgets = <Widget>[];
    final placedChannels = <String>{};

    try {
      final List<dynamic> layout = _getParsedLayout();
      String? currentCategory;
      for (final item in layout) {
        if (item['type'] == 'category') {
          currentCategory = item['name'] as String;
          widgets.add(_CategoryHeader(
            hollow: w.hollow,
            name: currentCategory,
            onToggle: () => setState(() {}),
          ));
        } else if (item['type'] == 'separator') {
          currentCategory = null;
          // Add a small visual divider in the sidebar.
          widgets.add(Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg,
              vertical: HollowSpacing.sm,
            ),
            child: Divider(height: 1, color: w.hollow.border),
          ));
        } else if (item['type'] == 'channel') {
          final channelId = item['channel_id'] as String;
          final channel = w.channels[channelId];
          if (channel != null) {
            placedChannels.add(channelId);
            final collapsed = currentCategory != null &&
                (_categoryCollapsedState[currentCategory] ?? false);
            final Widget tile;
            if (channel.channelType == ChannelType.voice) {
              tile = _VoiceChannelTile(
                channel: channel,
                serverId: w.serverId,
                onChannelSelected: w.onChannelSelected,
              );
            } else {
              tile = _ChannelTile(
                channel: channel,
                serverId: w.serverId,
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
      }
    } catch (_) {}

    // Always show channels not yet placed in the layout.
    // This ensures newly created channels appear immediately.
    final unplaced = w.channels.values
        .where((ch) => !placedChannels.contains(ch.channelId))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final channel in unplaced) {
      if (channel.channelType == ChannelType.voice) {
        widgets.add(_VoiceChannelTile(
          key: ValueKey('uch-${channel.channelId}'),
          channel: channel,
          serverId: w.serverId,
          onChannelSelected: w.onChannelSelected,
        ));
      } else {
        widgets.add(_ChannelTile(
          key: ValueKey('uch-${channel.channelId}'),
          channel: channel,
          serverId: w.serverId,
          isSelected: channel.channelId == w.selectedChannelId,
          onTap: () => w.onChannelSelected(channel.channelId),
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
          child: items.isEmpty
              ? Center(
                  child: Text('No channels',
                      style: HollowTypography.bodySmall
                          .copyWith(color: w.hollow.textSecondary)),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                  itemCount: items.length,
                  itemBuilder: (_, i) => items[i],
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

/// Tracks collapsed state of categories in the sidebar (persists across rebuilds).
final Map<String, bool> _categoryCollapsedState = {};

/// Category header in the sidebar — collapsible folder label.
class _CategoryHeader extends StatefulWidget {
  final HollowTheme hollow;
  final String name;
  final VoidCallback? onToggle;

  const _CategoryHeader({
    required this.hollow,
    required this.name,
    this.onToggle,
  });

  @override
  State<_CategoryHeader> createState() => _CategoryHeaderState();
}

class _CategoryHeaderState extends State<_CategoryHeader> {
  bool get _collapsed => _categoryCollapsedState[widget.name] ?? false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.sm + 2,
        HollowSpacing.md,
        HollowSpacing.sm,
        HollowSpacing.xs,
      ),
      child: HollowPressable(
        subtle: true,
        onTap: () {
          setState(() =>
              _categoryCollapsedState[widget.name] = !_collapsed);
          widget.onToggle?.call();
        },
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

/// Home / DM mode content — friends list.
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
    // Multi-device: a friend is online if ANY of their devices is online,
    // collapsed to the master identity. Single-device resolves to itself.
    final online = ref.watch(onlineIdentitiesProvider);
    final dividerTextStyle = HollowTypography.caption.copyWith(
      color: hollow.textSecondary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.8,
      fontSize: 11,
    );

    // Split friends into accepted and pending.
    final accepted = friends.values
        .where((f) => f.status == 'accepted')
        .toList();
    final pendingIncoming = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'incoming')
        .toList();
    final pendingOutgoing = friends.values
        .where((f) => f.status == 'pending' && f.direction == 'outgoing')
        .toList();

    // Sort accepted: online first, then by peer ID.
    accepted.sort((a, b) {
      final aOnline = online.contains(a.peerId) ? 0 : 1;
      final bOnline = online.contains(b.peerId) ? 0 : 1;
      if (aOnline != bOnline) return aOnline.compareTo(bOnline);
      return a.peerId.compareTo(b.peerId);
    });

    final hasPending = pendingIncoming.isNotEmpty || pendingOutgoing.isNotEmpty;

    // Device→master mirror for the encrypted-lock lookup below (peers is
    // DEVICE-keyed, friend.peerId is the MASTER).
    final links = ref.watch(deviceLinkProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Add friend button
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

        // Saved messages — pinned above the friend conversations. A DM with
        // your own master identity; opens through the same flow as a friend.
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

        // Pending requests section
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

        // Friends section header
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

        // Friends list
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
                    // `peers` is DEVICE-keyed but `friend.peerId` is the MASTER —
                    // a direct lookup silently never matches a multi-device
                    // friend, so the encrypted lock never showed here. Collapse
                    // each device through the resolver mirror (same pattern as
                    // home_dashboard's Friends column).
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

/// Pinned "Saved messages" row — mirrors [PeerCard] styling but with a
/// bookmark avatar and no presence dot (it's a conversation with yourself).
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

/// Sidebar add-friend dialog — unified peer ID / nickname input.
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
    // Await the send so a failure (e.g. node not running) surfaces here —
    // the dialog stays open for a retry instead of toasting a false success.
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

  const _ChannelTile({
    super.key,
    required this.channel,
    required this.serverId,
    required this.isSelected,
    required this.onTap,
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

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      child: tile,
    );
  }
}

/// Voice channel tile — shows speaker icon, channel name, and participant list.
/// Clicking joins the voice channel instead of selecting it for text.
/// Tracks leaving peers to animate them out before removal.
class _VoiceChannelTile extends ConsumerStatefulWidget {
  final ChannelInfo channel;
  final String serverId;
  final ValueChanged<String> onChannelSelected;

  const _VoiceChannelTile({
    super.key,
    required this.channel,
    required this.serverId,
    required this.onChannelSelected,
  });

  @override
  ConsumerState<_VoiceChannelTile> createState() => _VoiceChannelTileState();
}

class _VoiceChannelTileState extends ConsumerState<_VoiceChannelTile> {
  /// Peers currently animating out (kept in tree until animation finishes).
  final Set<String> _leavingPeers = {};

  /// Previous frame's participant set for diffing.
  Set<String> _prevParticipants = {};

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final isConnected = vcState.currentServerId == widget.serverId &&
        vcState.currentChannelId == widget.channel.channelId;
    final participants =
        vcState.getParticipants(widget.serverId, widget.channel.channelId);

    // Detect who just left.
    final departed = _prevParticipants.difference(participants);
    for (final peerId in departed) {
      if (!_leavingPeers.contains(peerId)) {
        _leavingPeers.add(peerId);
      }
    }
    _prevParticipants = Set.of(participants);

    // Visible = current participants + still-animating leavers.
    final visible = [...participants, ..._leavingPeers];

    final radius = BorderRadius.circular(hollow.radiusMd);

    Widget channelRow = HollowPressable(
      onTap: () {
        if (isConnected) {
          // Already in this channel — select it for the main pane.
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
    // VC participants are keyed by the ROUTABLE WS sender — a DEVICE peer id
    // for multi-device peers (including our own row). Collapse to the MASTER
    // identity for everything display-related (avatar, local nickname,
    // profile name); audio/speaking/volume state stays keyed by the routable
    // id. Single-device → identityOf is a no-op.
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final peerProfile =
        ref.watch(profileProvider.select((p) => p[master]));
    final name = displayNameForPeer(peerProfile, master);
    final hollow = HollowTheme.of(context);
    final vcState = ref.watch(voiceChannelProvider);
    final localPeerId = ref.watch(identityProvider).peerId ?? '';
    // Self = this row is THIS device (or the bare master id) — a sibling
    // device of ours in the same channel is deliberately NOT self (it has
    // its own mute/camera state).
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

    // Our own row reads the dedicated local flag; remote rows membership-
    // select so a row only rebuilds when ITS peer's bit flips. Testing the
    // set for OURSELVES is what silently failed before: the set is keyed by
    // routable device ids, this row can hold either form.
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

    return GestureDetector(
      onSecondaryTapUp: isRemote
          ? (details) =>
              _showVolumePopup(context, ref, details.globalPosition)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xxs),
        child: Row(
          children: [
            // Speaking cue = an outline hugging the avatar, replacing the
            // teal dot that used to sit at the far end of the row: the cue
            // sits on the thing it identifies, and a long name can't push it
            // out of view. SpeakingAvatarOutline, not SpeakingBorder — this
            // row is dense, so the outline must not take layout space or
            // stand a gap off the avatar (see its doc comment).
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
            // Screen sharing indicator — green monitor icon.
            if (isScreenSharing)
              const Padding(
                padding: EdgeInsets.only(left: HollowSpacing.xxs),
                child: Icon(LucideIcons.monitor,
                    size: kVoiceParticipantIconSize, color: Colors.green),
              ),
            // Camera indicator — accent video icon.
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

  void _showVolumePopup(
      BuildContext context, WidgetRef ref, Offset globalPosition) {
    final position = overlayPositionOf(context, globalPosition);
    final hollow = HollowTheme.of(context);
    final overlay = Overlay.of(context);
    final vcState = ref.read(voiceChannelProvider);
    var volume = vcState.getPeerVolume(peerId);
    OverlayEntry? entry;

    void remove() {
      entry?.remove();
      entry = null;
    }

    entry = OverlayEntry(
      builder: (ctx) {
        return Stack(
          children: [
            // Tap-away barrier.
            Positioned.fill(
              child: GestureDetector(
                onTap: remove,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
              ),
            ),
            Positioned(
              left: position.dx,
              top: position.dy,
              child: Material(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                elevation: 4,
                child: StatefulBuilder(
                  builder: (ctx, setPopupState) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.volume2,
                              size: 12, color: hollow.textSecondary),
                          SizedBox(
                            width: 110,
                            height: 24,
                            child: SliderTheme(
                              data: SliderThemeData(
                                activeTrackColor: hollow.accent,
                                inactiveTrackColor: hollow.border,
                                thumbColor: hollow.accent,
                                overlayColor:
                                    hollow.accent.withValues(alpha: 0.08),
                                trackHeight: 2,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 4),
                                overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 8),
                              ),
                              child: Slider(
                                value: volume,
                                min: 0.0,
                                max: 2.0,
                                onChanged: (v) {
                                  setPopupState(() => volume = v);
                                  ref
                                      .read(voiceChannelProvider.notifier)
                                      .setPeerVolume(peerId, v);
                                },
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 28,
                            child: Text(
                              '${(volume * 100).round()}%',
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary,
                                fontSize: 10,
                              ),
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );

    overlay.insert(entry!);
  }
}

// The speaking cue for a participant row is an outline AROUND the avatar
// (SpeakingBorder), not a separate dot — see _VoiceParticipantRow.
