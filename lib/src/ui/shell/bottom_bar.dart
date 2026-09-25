import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/channel_navigation.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/help_panel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/call/call_stage_sources.dart' show dmCallPeerName;
import 'package:hollow/src/ui/components/connection_visual.dart';
import 'package:hollow/src/ui/components/download_icon_button.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_mark.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:hollow/src/ui/components/nav_selection_mark.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/components/profile_card_popup.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/components/server_folder_popup.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/components/voice_here_badge.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/shell/new_server_entry.dart';
import 'package:hollow/src/ui/shell/server_context_menus.dart';
import 'package:hollow/src/ui/shell/voice_quick_controls.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The dock's height below its hairline.
const double kDockHeight = 56;

/// Server, folder, Home and Add tiles.
const double _kTile = 40;

/// Below this the five places fold into one menu, so a few server tiles still
/// fit between Home and the tools.
const double kDockPlacesFoldWidth = 1000;

/// The Dock layout's bottom bar.
///
/// Left, you: identity, connection and the call. Then where you are: Home,
/// your servers and the app's places, with ONE accent mark on the top edge
/// above whichever is active. Right, the tools, which open on top.
class BottomBar extends ConsumerWidget {
  const BottomBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final inCall = watchHasQuickControls(ref);
    final location = ref.watch(dockLocationProvider);
    final atSettings =
        location is _AtPlace && location.tab == ShellTab.settings;

    return Container(
      height: kDockHeight + 1,
      decoration: BoxDecoration(
        color: hollow.opaqueSurface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      // Fixed-height chrome, so the label scale is capped to keep it in the bar.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fold = constraints.maxWidth < kDockPlacesFoldWidth;
            return Row(
              children: [
                const SizedBox(width: HollowSpacing.md),
                const DockIdentity(),
                if (inCall) ...[
                  const SizedBox(width: HollowSpacing.xs),
                  const VoiceQuickControls(),
                ],
                const _DockDivider(),
                _DockSlot(
                  marked: location is _AtHome,
                  child: _DockTile(
                    tooltip: 'Home',
                    fill: hollow.elevated,
                    hoverFill: hollow.hover,
                    onTap: () => _goHome(ref),
                    // Right click is "mark all DMs as read" (#61).
                    onContextMenu: (position) => showHomeMenu(
                      context: context,
                      ref: ref,
                      anchor: position,
                    ),
                    child: HollowMark(size: 22, color: hollow.accentText),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                // Servers anchor left; the space after Add is the gap before
                // the places, so a short list never floats in the middle.
                Expanded(
                  child: Row(
                    children: [
                      Flexible(child: _ServerList(location: location)),
                      _DockTile(
                        tooltip: 'Create a server',
                        fill: hollow.opaqueSurface,
                        hoverFill: hollow.elevated,
                        onTap: () => showCreateServerDialog(context),
                        child: Icon(LucideIcons.plus,
                            size: 20, color: hollow.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                _Places(location: location, fold: fold),
                const _DockDivider(),
                const DownloadIconButton(),
                const SizedBox(width: HollowSpacing.xs),
                const _HelpButton(),
                const SizedBox(width: HollowSpacing.xs),
                _DockSlot(
                  marked: atSettings,
                  child: HollowIconButton(
                    icon: LucideIcons.settings,
                    label: 'Settings',
                    selected: atSettings,
                    onPressed: () => toggleSettings(ref.read),
                  ),
                ),
                const SizedBox(width: HollowSpacing.md),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Where you are: the one thing the selection mark sits over.
// ---------------------------------------------------------------------------

sealed class DockLocation {
  const DockLocation();
}

/// Home, a DM included.
class _AtHome extends DockLocation {
  const _AtHome();
}

class _AtServer extends DockLocation {
  final String serverId;
  const _AtServer(this.serverId);
}

class _AtPlace extends DockLocation {
  final ShellTab tab;
  const _AtPlace(this.tab);
}

/// The dock's single "you are here". In a split the focused pane decides, so
/// the mark never sits over two items.
final dockLocationProvider = Provider<DockLocation>((ref) {
  final tab = ref.watch(openShellTabProvider);
  if (tab != null) return _AtPlace(tab);
  final split = ref.watch(splitViewProvider);
  final serverId = split.isSplit && split.focusedPane == 1
      ? split.rightPane?.serverId
      : ref.watch(selectedServerProvider);
  return serverId == null ? const _AtHome() : _AtServer(serverId);
});

void _clearSelection(WidgetRef ref) {
  ref.read(selectedServerProvider.notifier).state = null;
  ref.read(channelListProvider.notifier).clear();
  ref.read(selectedChannelProvider.notifier).state = null;
  ref.read(selectedPeerProvider.notifier).state = null;
  ref.read(serverSettingsOpenProvider.notifier).state = false;
}

void _closeSplit(WidgetRef ref) {
  if (ref.read(splitViewProvider).isSplit) {
    ref.read(splitViewProvider.notifier).closeSplit();
  }
}

void _goHome(WidgetRef ref) {
  _closeSplit(ref);
  setShellTab(ref.read, null);
  _clearSelection(ref);
}

/// Opens [tab] the way each place always has; the Shop and Conferences keep
/// their own openers.
void _openPlace(WidgetRef ref, ShellTab tab) {
  switch (tab) {
    case ShellTab.conference:
      ref.read(conferenceProvider.notifier).openTab();
    case ShellTab.shop:
      openShopTab(ref.read);
    case ShellTab.archive:
      _closeSplit(ref);
      ref.invalidate(archiveDmListProvider);
      ref.invalidate(archiveChannelListProvider);
      selectArchiveConversation(ref.read);
      setShellTab(ref.read, tab);
      _clearSelection(ref);
    case ShellTab.settings:
      openSettings(ref.read);
    case ShellTab.guest || ShellTab.share:
      _closeSplit(ref);
      setShellTab(ref.read, tab);
      _clearSelection(ref);
  }
}

/// A place toggles: pressing the lit one goes back to what it covered (#28).
void _togglePlace(WidgetRef ref, ShellTab tab) {
  if (ref.read(openShellTabProvider) == tab) {
    setShellTab(ref.read, null);
  } else {
    _openPlace(ref, tab);
  }
}

/// Selects [serverId] then opens its settings, so closing them lands in that
/// server.
Future<void> _openServerSettings(WidgetRef ref, String serverId) async {
  if (ref.read(selectedServerProvider) != serverId) {
    await _selectServer(ref, serverId);
  }
  openServerSettings(ref.read, serverId);
}

Future<void> _selectServer(WidgetRef ref, String serverId) async {
  final split = ref.read(splitViewProvider);
  if (split.isSplit && split.focusedPane == 1) {
    // Channels load straight from FFI so the global channelListProvider is
    // not overwritten. A restricted channel the local user cannot see must
    // never be auto-selected.
    try {
      final channels = (await crdt_api.getServerChannels(serverId: serverId))
          .where((c) => c.meCanSee)
          .toList();
      final lastChannel = ref.read(lastChannelPerServerProvider)[serverId];
      String? channelToSelect;
      if (lastChannel != null &&
          channels.any((c) => c.channelId == lastChannel)) {
        channelToSelect = lastChannel;
      } else if (channels.isNotEmpty) {
        channelToSelect = channels
                .where((c) => c.channelType == 'text')
                .firstOrNull
                ?.channelId ??
            channels.first.channelId;
      }
      ref.read(splitViewProvider.notifier).navigateRightToServer(
            serverId,
            channelId: channelToSelect,
          );
    } catch (_) {
      ref.read(splitViewProvider.notifier).navigateRightToServer(serverId);
    }
    return;
  }

  // Read the DB first, with no provider writes yet, so nothing rebuilds.
  final channels = await ChannelListNotifier.fetchChannels(serverId);
  final layout = await ChannelLayoutNotifier.fetchLayout(serverId);

  final lastChannel = ref.read(lastChannelPerServerProvider)[serverId];
  String? channelToSelect;
  if (lastChannel != null && channels.containsKey(lastChannel)) {
    channelToSelect = lastChannel;
  } else if (channels.isNotEmpty) {
    channelToSelect =
        firstTextChannelInLayout(channels, layout) ?? channels.keys.first;
  }

  // Every provider write batches in ONE synchronous block, so the rebuild
  // sees consistent server, channel and selection state. Closing EVERY centre
  // tab belongs in that block: one left open covers the channel just selected
  // (issue #28).
  setShellTab(ref.read, null);
  ref.read(selectedPeerProvider.notifier).state = null;
  ref.read(serverSettingsOpenProvider.notifier).state = false;
  ref.read(channelListProvider.notifier).setChannels(channels);
  ref.read(channelLayoutProvider.notifier).setLayout(layout, serverId: serverId);
  ref.read(selectedChannelProvider.notifier).state = channelToSelect;
  ref.read(selectedServerProvider.notifier).state = serverId;
  if (channelToSelect != null) {
    ref.read(lastChannelPerServerProvider.notifier).state = {
      ...ref.read(lastChannelPerServerProvider),
      serverId: channelToSelect,
    };
  }
}

// ---------------------------------------------------------------------------
// You: identity, connection, the call.
// ---------------------------------------------------------------------------

/// Your avatar with its connection dot, your name, and one line of status by
/// exception: a problem with the link, the voice room you are in, or your own
/// status line. Silent when all is well.
class DockIdentity extends ConsumerWidget {
  const DockIdentity({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final localPeerId = ref.watch(identityProvider.select((i) => i.peerId));
    final profile = localPeerId == null
        ? null
        : ref.watch(profileProvider.select((p) => p[localPeerId]));
    final name =
        localPeerId == null ? '' : displayNameForPeer(profile, localPeerId);

    // The REAL node and relay state, shared with the Classic user bar so the
    // two layouts cannot disagree.
    final invisible = ref.watch(invisibleModeProvider);
    final overall = ref.watch(overallConnectionProvider);
    final visual = connectionVisual(hollow, overall, invisible: invisible);

    final voice = ref.watch(voiceChannelProvider.select((s) => (
          s.isInVoiceChannel ? s.currentServerId : null,
          s.currentChannelId,
          s.currentChannelName,
        )));
    final voiceServerName = voice.$1 == null
        ? null
        : ref.watch(serverListProvider.select((m) => m[voice.$1]?.name));

    final call = ref.watch(callProvider.select((c) => (
          status: c.status,
          direction: c.direction,
          peerId: c.peerId,
        )));
    final callMaster = call.peerId == null
        ? null
        : ref.watch(deviceLinkProvider).identityOf(call.peerId!);
    final dmCallShown = callMaster != null &&
        call.status != CallStatus.idle &&
        !(call.status == CallStatus.ringing &&
            call.direction == CallDirection.incoming);

    final Widget? line;
    if (!overall.isOnline && !invisible) {
      line = _statusLine(visual.label, hollow.warning);
    } else if (dmCallShown) {
      final who = dmCallPeerName(ref, callMaster);
      final text = call.status == CallStatus.ringing
          ? 'Calling $who'
          : 'In a call with $who';
      line = HollowPressable(
        subtle: true,
        semanticLabel: '$text, open the conversation',
        onTap: () => openDmConversation(ref, callMaster),
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        child: _statusLine(text,
            call.status == CallStatus.ringing
                ? hollow.textSecondary
                : hollow.success),
      );
    } else if (voice.$1 != null && voice.$2 != null) {
      final room = voice.$3 ?? 'Voice';
      final text =
          voiceServerName == null ? room : '$room · $voiceServerName';
      line = HollowPressable(
        subtle: true,
        semanticLabel: 'Open $room',
        onTap: () => openServerChannel(
          ProviderScope.containerOf(context, listen: false),
          voice.$1!,
          voice.$2!,
        ).catchError((_) {}),
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        child: _statusLine(text, hollow.success),
      );
    } else if (profile != null && profile.status.isNotEmpty) {
      line = _statusLine(profile.status, hollow.textTertiary);
    } else {
      line = null;
    }

    return HollowTooltip(
      message: 'Your profile and status',
      child: HollowPressable(
        semanticLabel: '$name, ${visual.label}',
        onTap: localPeerId == null
            ? null
            : () => showProfileCardPopup(
                  context: context,
                  ref: ref,
                  peerId: localPeerId,
                  anchorOf: () {
                    final pos = overlayAnchorOf(context);
                    return Offset(
                        pos.dx + HollowSpacing.sm, pos.dy - HollowSpacing.sm);
                  },
                  anchorBottom: true,
                ),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _IdentityAvatar(peerId: localPeerId, visual: visual),
            const SizedBox(width: HollowSpacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kIdentityTextWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: HollowTypography.label
                        .copyWith(color: hollow.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  ?line,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine(String text, Color color) => Text(
        text,
        style: HollowTypography.caption.copyWith(color: color),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
}

const double _kIdentityTextWidth = 160;

/// Your avatar with the connection dot cut into its corner. The cut-out
/// follows the row's hover fill so it never shows a dark halo.
class _IdentityAvatar extends StatelessWidget {
  final String? peerId;
  final ConnectionVisual visual;

  const _IdentityAvatar({required this.peerId, required this.visual});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hovered = HoverScope.maybeOf(context) ?? false;
    final id = peerId;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (id != null)
          HollowAvatar(peerId: id, size: 28)
        else
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
          ),
        Positioned(
          right: -HollowSpacing.xxs,
          bottom: -HollowSpacing.xxs,
          child: AnimatedContainer(
            duration: HollowDurations.fast,
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: hovered ? hollow.elevated : hollow.opaqueSurface,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: StatusDot(
              color: visual.color,
              size: 7,
              filled: visual.filled,
              semanticLabel: visual.label,
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Tiles and the mark.
// ---------------------------------------------------------------------------

/// The hairline between the dock's three groups.
class _DockDivider extends StatelessWidget {
  const _DockDivider();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(horizontal: HollowSpacing.md),
        child: SizedBox(height: HollowSpacing.xl, child: HollowVerticalDivider()),
      );
}

/// A dock item at the dock's full height, with the selection mark on the top
/// edge when [marked]. Its badges sit inside this box, so a scrolling row
/// never cuts them.
class _DockSlot extends StatelessWidget {
  final bool marked;
  final Widget child;

  const _DockSlot({required this.marked, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kDockHeight,
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          child,
          if (marked) const Positioned(top: 0, child: NavSelectionMark()),
        ],
      ),
    );
  }
}

/// A 40 px square: Home, a server, a folder, Add, a parked join.
///
/// Hover steps the fill up one surface ([hoverFill]) or, on an identity
/// colour or an image, lays a luminance-aware lift over it. Nothing else
/// changes on hover: no bar, no accent, so only the active item looks active.
class _DockTile extends StatelessWidget {
  final Widget child;
  final Color fill;
  final Color? hoverFill;
  final VoidCallback? onTap;
  final void Function(Offset overlayPosition)? onContextMenu;
  final String? tooltip;

  /// Overrides [tooltip] as the screen-reader name, for a tile whose tooltip
  /// states a CONDITION while its purpose is to open a menu.
  final String? semanticLabel;

  /// The context menu's screen-reader name, when "<label> actions" is wrong.
  final String? menuLabel;

  final int unreadCount;
  final int mentionCount;
  final bool awaitingSetup;
  final bool voiceHere;

  const _DockTile({
    required this.child,
    required this.fill,
    this.hoverFill,
    this.onTap,
    this.onContextMenu,
    this.tooltip,
    this.semanticLabel,
    this.menuLabel,
    this.unreadCount = 0,
    this.mentionCount = 0,
    this.awaitingSetup = false,
    this.voiceHere = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final label = semanticLabel ?? tooltip;
    final ring = hollow.opaqueSurface;

    Widget tile = HollowPressable(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(hollow.radiusLg),
      child: _TileFace(fill: fill, hoverFill: hoverFill, child: child),
    );
    if (tooltip != null) tile = HollowTooltip(message: tooltip!, child: tile);

    // ABOVE the focus ring, so Menu and Shift+F10 reach it while the tile is
    // keyboard-focused (issue #61).
    final onContextMenu = this.onContextMenu;
    if (onContextMenu != null) {
      tile = ContextMenuTarget(
        semanticLabel: menuLabel ?? '${label ?? 'Server'} actions',
        onOpen: onContextMenu,
        child: tile,
      );
    }

    // Clip.none is load bearing: the badges sit on the corners.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        tile,
        // Top-LEFT, since the unread count owns the top-right corner.
        if (awaitingSetup)
          const Positioned(
            left: -HollowSpacing.xs,
            top: -HollowSpacing.xs,
            child: HollowTooltip(
              message: kAwaitingSetupTooltip,
              child: AwaitingSetupBadge(size: HollowSpacing.lg),
            ),
          ),
        if (unreadCount > 0 || mentionCount > 0)
          Positioned(
            right: -HollowSpacing.sm,
            top: -HollowSpacing.xs,
            child: IgnorePointer(
              child: HollowCountBadge(
                count: mentionCount > 0 ? mentionCount : unreadCount,
                mention: mentionCount > 0,
                ring: ring,
              ),
            ),
          ),
        if (voiceHere)
          Positioned(
            right: -HollowSpacing.xs,
            bottom: -HollowSpacing.xs,
            child: IgnorePointer(child: VoiceHereBadge(ring: ring)),
          ),
      ],
    );
  }
}

class _TileFace extends StatelessWidget {
  final Color fill;
  final Color? hoverFill;
  final Widget child;

  const _TileFace({required this.fill, required this.child, this.hoverFill});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hovered = HoverScope.maybeOf(context) ?? false;
    final hoverFill = this.hoverFill;
    return AnimatedContainer(
      duration: HollowDurations.fast,
      curve: HollowCurves.subtle,
      width: _kTile,
      height: _kTile,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: hovered && hoverFill != null ? hoverFill : fill,
        borderRadius: BorderRadius.circular(hollow.radiusLg),
      ),
      foregroundDecoration: hoverFill != null
          ? null
          : BoxDecoration(
              // Same colour at both ends, so the fade never lerps via black.
              color: hollow.textPrimary.withValues(alpha: hovered ? 0.1 : 0),
              borderRadius: BorderRadius.circular(hollow.radiusLg),
            ),
      alignment: Alignment.center,
      child: child,
    );
  }
}

// ---------------------------------------------------------------------------
// Servers.
// ---------------------------------------------------------------------------

/// The server strip model as tiles, reorderable by a held drag. Its scroll
/// viewport is the dock's full height, so badges and the mark are never cut.
class _ServerList extends ConsumerStatefulWidget {
  final DockLocation location;
  const _ServerList({required this.location});

  @override
  ConsumerState<_ServerList> createState() => _ServerListState();
}

class _ServerListState extends ConsumerState<_ServerList> {
  bool _isDragging = false;

  /// Servers that existed on first build skip the entrance animation.
  Set<String>? _initialServerIds;

  void _setDragging(bool value) {
    if (mounted) setState(() => _isDragging = value);
  }

  String? get _activeServerId => switch (widget.location) {
        _AtServer(:final serverId) => serverId,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final stripLayout = ref.watch(serverStripLayoutProvider);
    _initialServerIds ??=
        ref.read(serverStripLayoutProvider.notifier).allServerIds();

    void reorder(_StripDragData data, int to) =>
        ref.read(serverStripLayoutProvider.notifier).reorder(data.sourceIndex, to);

    return EdgeScrollRow(
      semanticLabel: 'servers',
      height: kDockHeight,
      fadeColor: hollow.opaqueSurface,
      // Hugs the tiles, so Add follows the last one instead of the far edge.
      shrinkWrap: true,
      children: [
        for (int i = 0; i < stripLayout.length; i++) ...[
          _ReorderGap(index: i, onAccept: (data) => reorder(data, i)),
          switch (stripLayout[i]) {
            ServerStripItem(:final serverId) =>
              _buildServer(index: i, serverId: serverId),
            PendingStripItem(:final serverId) => _buildPending(serverId),
            final FolderStripItem folder =>
              _buildFolder(index: i, folder: folder),
          },
        ],
        _ReorderGap(
          index: stripLayout.length,
          onAccept: (data) => reorder(data, stripLayout.length),
        ),
      ],
    );
  }

  Widget _buildServer({required int index, required String serverId}) {
    final name = ref.watch(serverListProvider.select((m) => m[serverId]?.name)) ??
        '';
    final active = serverId == _activeServerId;
    final muted = ref.watch(notificationSettingsProvider
        .select((n) => n.isServerMuted(serverId)));
    final unread = muted
        ? 0
        : ref.watch(unreadProvider.select((s) => s.serverUnreadCount(serverId)));
    final mentions = muted
        ? 0
        : ref.watch(unreadProvider.select((s) => s.serverMentionCount(serverId)));
    // Admitted after a parked join, still waiting on a member to add our MLS
    // leaf; the same flair the Classic strip shows.
    final awaitingSetup =
        ref.watch(awaitingSetupProvider.select((s) => s.contains(serverId)));
    final voiceHere =
        ref.watch(_voiceServerProvider.select((id) => id == serverId));

    Widget face({bool plain = false}) => _DockTile(
          fill: colorFromId(serverId),
          tooltip: plain || _isDragging ? null : name,
          semanticLabel: plain ? null : name,
          unreadCount: plain ? 0 : unread,
          mentionCount: plain ? 0 : mentions,
          awaitingSetup: !plain && awaitingSetup,
          voiceHere: !plain && voiceHere,
          onTap: plain ? null : () => _selectServer(ref, serverId),
          // The same server menu the Classic strip shows (#61).
          onContextMenu: plain
              ? null
              : (position) => showServerIconMenu(
                    context: context,
                    ref: ref,
                    serverId: serverId,
                    anchor: position,
                    onOpenSettings: () => _openServerSettings(ref, serverId),
                  ),
          child: ServerAvatar(
              serverId: serverId, name: name, size: _kTile, animate: active),
        );

    Widget tile = DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) =>
          details.data.serverId != null && details.data.serverId != serverId,
      onAcceptWithDetails: (details) => ref
          .read(serverStripLayoutProvider.notifier)
          .createFolder(details.data.serverId!, serverId),
      builder: (context, candidateData, _) => LongPressDraggable<_StripDragData>(
        data: _StripDragData(serverId: serverId, sourceIndex: index),
        delay: const Duration(milliseconds: 300),
        onDragStarted: () => _setDragging(true),
        onDragEnd: (_) => _setDragging(false),
        onDraggableCanceled: (_, _) => _setDragging(false),
        feedback: _DragFeedback(child: face(plain: true)),
        childWhenDragging: AnimatedOpacity(
          opacity: 0.3,
          duration: HollowDurations.fast,
          child: face(plain: true),
        ),
        child: AnimatedScale(
          scale: candidateData.isNotEmpty ? 1.08 : 1.0,
          duration: HollowDurations.fast,
          child: face(),
        ),
      ),
    );

    if (!_initialServerIds!.contains(serverId)) {
      tile = NewServerEntry(key: ValueKey('bounce-$serverId'), child: tile);
    }
    return _DockSlot(marked: active, child: tile);
  }

  /// The Dock's twin of the Classic strip's parked-join tile. Both shells
  /// render the same strip model, so a tile in one and not the other is a bug
  /// nobody notices until they switch layouts.
  Widget _buildPending(String serverId) {
    final hollow = HollowTheme.of(context);
    final rejected = ref.watch(
        pendingJoinsProvider.select((m) => m[serverId]?.isRejected ?? false));
    final title = pendingJoinTitle(rejected: rejected);

    return _DockSlot(
      marked: false,
      child: Builder(builder: (tileContext) {
        return AnimatedOpacity(
          opacity: rejected ? 0.4 : 0.55,
          duration: HollowDurations.fast,
          child: _DockTile(
            fill: hollow.elevated,
            hoverFill: hollow.hover,
            tooltip: _isDragging ? null : title,
            semanticLabel: '$title, show actions',
            menuLabel: '$title, show actions',
            // Anchored at the tile's top-left: the menu flips upward when
            // opening downward would leave the window, which a bar pinned to
            // the bottom always does.
            onTap: () => showPendingJoinMenu(
              context: tileContext,
              ref: ref,
              serverId: serverId,
              anchor: overlayAnchorOf(tileContext),
            ),
            onContextMenu: (anchor) => showPendingJoinMenu(
              context: tileContext,
              ref: ref,
              serverId: serverId,
              anchor: anchor,
            ),
            child: Icon(
              rejected ? LucideIcons.ban : LucideIcons.clock,
              size: 20,
              color: hollow.textSecondary,
            ),
          ),
        );
      }),
    );
  }

  Widget _buildFolder({required int index, required FolderStripItem folder}) {
    final hollow = HollowTheme.of(context);
    final activeServerId = _activeServerId;
    final active =
        activeServerId != null && folder.serverIds.contains(activeServerId);

    var unread = 0;
    var mentions = 0;
    for (final sid in folder.serverIds) {
      if (ref.watch(notificationSettingsProvider
          .select((n) => n.isServerMuted(sid)))) {
        continue;
      }
      unread += ref.watch(unreadProvider.select((s) => s.serverUnreadCount(sid)));
      mentions +=
          ref.watch(unreadProvider.select((s) => s.serverMentionCount(sid)));
    }
    final voiceHere = ref.watch(_voiceServerProvider
        .select((id) => id != null && folder.serverIds.contains(id)));

    Widget face({bool plain = false}) => Builder(
          builder: (tileContext) => _DockTile(
            fill: hollow.elevated,
            hoverFill: hollow.hover,
            tooltip: plain || _isDragging ? null : folder.name,
            semanticLabel: plain ? null : folder.name,
            unreadCount: plain ? 0 : unread,
            mentionCount: plain ? 0 : mentions,
            voiceHere: !plain && voiceHere,
            onTap: plain ? null : () => _openFolder(tileContext, folder),
            onContextMenu: plain
                ? null
                : (anchor) => showFolderIconMenu(
                      context: tileContext,
                      ref: ref,
                      folder: folder,
                      anchor: anchor,
                    ),
            child: ServerFolderIcon(
                folder: folder, size: _kTile, filled: false),
          ),
        );

    return _DockSlot(
      marked: active,
      child: DragTarget<_StripDragData>(
        onWillAcceptWithDetails: (details) =>
            details.data.serverId != null &&
            !folder.serverIds.contains(details.data.serverId),
        onAcceptWithDetails: (details) => ref
            .read(serverStripLayoutProvider.notifier)
            .addToFolder(folder.id, details.data.serverId!),
        builder: (context, candidateData, _) =>
            LongPressDraggable<_StripDragData>(
          data: _StripDragData(folderId: folder.id, sourceIndex: index),
          delay: const Duration(milliseconds: 300),
          onDragStarted: () => _setDragging(true),
          onDragEnd: (_) => _setDragging(false),
          onDraggableCanceled: (_, _) => _setDragging(false),
          feedback: _DragFeedback(child: face(plain: true)),
          childWhenDragging: AnimatedOpacity(
            opacity: 0.3,
            duration: HollowDurations.fast,
            child: face(plain: true),
          ),
          child: AnimatedScale(
            scale: candidateData.isNotEmpty ? 1.08 : 1.0,
            duration: HollowDurations.fast,
            child: face(),
          ),
        ),
      ),
    );
  }

  void _openFolder(BuildContext tileContext, FolderStripItem folder) {
    final box = tileContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final pos = overlayAnchorOf(tileContext);
    showServerFolderPopup(
      context: tileContext,
      ref: ref,
      folder: folder,
      anchor: Offset(pos.dx + box.size.width / 2, pos.dy),
      isDock: true,
      onServerSelected: (serverId) => _selectServer(ref, serverId),
      onRenameRequested: () => showFolderRenameDialog(
        context: tileContext,
        ref: ref,
        folder: folder,
      ),
    );
  }
}

/// The server holding the voice room you are in, if any.
final _voiceServerProvider = Provider<String?>((ref) => ref.watch(
    voiceChannelProvider
        .select((s) => s.isInVoiceChannel ? s.currentServerId : null)));

/// Drag data for server strip items.
class _StripDragData {
  final String? serverId;
  final String? folderId;
  final int sourceIndex;

  const _StripDragData({
    this.serverId,
    this.folderId,
    required this.sourceIndex,
  });
}

/// What follows the pointer during a drag. It renders in the Overlay with no
/// text style above it, so it brings its own.
class _DragFeedback extends StatelessWidget {
  final Widget child;
  const _DragFeedback({required this.child});

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
        style: HollowTypography.label,
        child: AnimatedOpacity(
          opacity: 0.8,
          duration: Duration.zero,
          child: child,
        ),
      );
}

/// The gap between two tiles, which is also where a dragged tile drops to
/// reorder. Its width never changes, so a drag never shoves the row.
class _ReorderGap extends StatelessWidget {
  final int index;
  final void Function(_StripDragData data) onAccept;

  const _ReorderGap({required this.index, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        // A drop right next to the source would be a no-op reorder.
        final src = details.data.sourceIndex;
        return src != index && src != index - 1;
      },
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, _) => SizedBox(
        width: HollowSpacing.sm,
        height: _kTile,
        child: Center(
          child: AnimatedContainer(
            duration: HollowDurations.fast,
            width: HollowSpacing.xs,
            decoration: BoxDecoration(
              color: hollow.accent
                  .withValues(alpha: candidateData.isNotEmpty ? 1 : 0),
              borderRadius: BorderRadius.circular(hollow.radiusXs),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Places and tools.
// ---------------------------------------------------------------------------

class _PlaceSpec {
  final ShellTab tab;
  final String label;
  final IconData icon;
  const _PlaceSpec(this.tab, this.label, this.icon);
}

/// The app's other places, which swap the centre pane. Five buttons, or one
/// "Places" menu when the dock is too narrow for them beside the servers.
class _Places extends ConsumerWidget {
  final DockLocation location;
  final bool fold;

  const _Places({required this.location, required this.fold});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final places = [
      const _PlaceSpec(ShellTab.conference, 'Conferences', LucideIcons.video),
      const _PlaceSpec(ShellTab.guest, 'Public channels', LucideIcons.globe),
      const _PlaceSpec(ShellTab.share, 'Share', LucideIcons.share2),
      const _PlaceSpec(ShellTab.archive, 'Archive', LucideIcons.archive),
      // Absent entirely, not disabled, on store builds: Apple 3.1.1 and Play
      // policy want no shop surface at all.
      if (ref.watch(shopAvailableProvider))
        const _PlaceSpec(ShellTab.shop, 'Hollow Shop', LucideIcons.store),
    ];
    // Settings is a place, but its mark sits on the dock's gear.
    final active = switch (location) {
      _AtPlace(:final tab) when tab != ShellTab.settings => tab,
      _ => null,
    };

    if (fold) {
      return _DockSlot(
        marked: active != null,
        child: Builder(
          builder: (buttonContext) => HollowIconButton(
            icon: LucideIcons.layoutGrid,
            label: 'Places',
            selected: active != null,
            onPressed: () {
              final box = buttonContext.findRenderObject() as RenderBox?;
              showHollowMenu(
                context: buttonContext,
                anchor: overlayAnchorOf(buttonContext,
                    localOffset: Offset(box?.size.width ?? 0, 0)),
                alignEnd: true,
                builder: (_, _) => [
                  for (final p in places)
                    HollowMenuItem(
                      icon: p.icon,
                      label: p.label,
                      isChecked: p.tab == active,
                      onTap: () => _togglePlace(ref, p.tab),
                    ),
                ],
              );
            },
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < places.length; i++) ...[
          if (i > 0) const SizedBox(width: HollowSpacing.xs),
          _DockSlot(
            marked: places[i].tab == active,
            child: HollowIconButton(
              icon: places[i].icon,
              label: places[i].label,
              selected: places[i].tab == active,
              onPressed: () => _togglePlace(ref, places[i].tab),
            ),
          ),
        ],
      ],
    );
  }
}

class _HelpButton extends ConsumerWidget {
  const _HelpButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(helpPanelOpenProvider);
    return HollowIconButton(
      icon: LucideIcons.circleHelp,
      label: 'Help',
      selected: open,
      onPressed: () => ref.read(helpPanelOpenProvider.notifier).state = !open,
    );
  }
}
