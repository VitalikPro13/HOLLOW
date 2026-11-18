import 'package:flutter/material.dart';
import 'package:hollow/src/core/name_initials.dart';
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/archive_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/help_panel_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/providers/sidebar_items_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/ui/components/server_icon_image.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/ui/components/server_folder_popup.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/pending_join_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/pending_join_ui.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/shell/new_server_entry.dart';
import 'package:hollow/src/ui/shell/server_context_menus.dart';
import 'package:hollow/src/ui/shell/sidebar_places.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Width of the server rail at 100% panel zoom; every icon row inside it is
/// laid out for exactly this much.
const double kServerStripWidth = 72.0;

class ServerStrip extends ConsumerStatefulWidget {
  const ServerStrip({super.key});

  @override
  ConsumerState<ServerStrip> createState() => _ServerStripState();
}

class _ServerStripState extends ConsumerState<ServerStrip> {
  /// Servers that existed on first build skip the entrance animation, so the
  /// strip does not bounce on startup.
  Set<String>? _initialServerIds;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final selectedServerId = ref.watch(selectedServerProvider);

    _initialServerIds ??= ref.read(serverStripLayoutProvider.notifier).allServerIds();

    final stripLayout = ref.watch(serverStripLayoutProvider);
    // Panel zoom (issue #54). Unlike the two lists, this rail is a fixed width
    // of icons sized to fill it, so the rail has to widen with them or zooming
    // the content alone pushes every icon row out of a narrower column.
    final panelScale = ref.watch(panelScaleProvider);

    final dmUnreadTotal = ref.watch(dmUnreadBadgeProvider);
    final archiveOpen = ref.watch(archiveTabOpenProvider);
    final shareOpen = ref.watch(shareTabOpenProvider);
    final guestOpen = ref.watch(guestTabOpenProvider);
    final conferencesOpen = ref.watch(conferenceTabOpenProvider);
    final helpOpen = ref.watch(helpPanelOpenProvider);
    final shopOpen = ref.watch(shopTabOpenProvider);
    final shopAvailable = ref.watch(shopAvailableProvider);
    // Home is selected only when nothing covers the chat area; every centre
    // tab counts, including the two this strip has no button for.
    final homeSelected =
        selectedServerId == null && !ref.watch(anyShellTabOpenProvider);

    Widget homeIcon = _ServerIconWithIndicator(
      isSelected: homeSelected,
      unreadCount: selectedServerId != null ? dmUnreadTotal : 0,
      child: _ServerIcon(
        // Right click (a long press on touch) is the Home menu: mark all DMs
        // as read (#61) and the hidden places (#141).
        touchLongPressMenu: true,
        onContextMenu: (position) => showHomeMenu(
          context: context,
          ref: ref,
          anchor: position,
          openPlace: _openPlace,
        ),
        isSelected: homeSelected,
        backgroundColor: hollow.accent,
        semanticLabel: 'Home',
        onTap: () {
          setShellTab(ref.read, null);
          ref.read(selectedServerProvider.notifier).state = null;
          ref.read(channelListProvider.notifier).clear();
          ref.read(selectedChannelProvider.notifier).state = null;
          ref.read(serverSettingsOpenProvider.notifier).state = false;
        },
        child: Text(
          'H',
          style: HollowTypography.heading.copyWith(color: hollow.textOnAccent),
        ),
      ),
    );

    final shownPlaces = sidebarItemsShown(
      ref.watch(hiddenSidebarItemsProvider),
      shopAvailable: shopAvailable,
      open: ref.watch(openShellTabProvider),
    );
    final placeOpen = {
      SidebarItem.publicChannels: guestOpen,
      SidebarItem.share: shareOpen,
      SidebarItem.archive: archiveOpen,
      SidebarItem.conferences: conferencesOpen,
      SidebarItem.shop: shopOpen,
    };
    // The Shop sits at the bottom beside the guides (#141): it is not a place
    // people move between all day, so it no longer pushes the servers down.
    final topPlaces = [
      for (final item in shownPlaces)
        if (item != SidebarItem.shop)
          _placeTile(item, open: placeOpen[item]!, hollow: hollow),
    ];
    final shopIcon = shownPlaces.contains(SidebarItem.shop)
        ? _placeTile(SidebarItem.shop,
            open: placeOpen[SidebarItem.shop]!, hollow: hollow)
        : null;

    Widget helpIcon = Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: _ServerIcon(
        isSelected: helpOpen,
        backgroundColor: hollow.elevated,
        tooltip: 'App guides',
        onTap: () =>
            ref.read(helpPanelOpenProvider.notifier).state = !helpOpen,
        child: Icon(
          LucideIcons.circleHelp,
          color: helpOpen ? hollow.accent : hollow.textSecondary,
          size: 20,
        ),
      ),
    );

    Widget divider = Container(
      width: 32,
      height: 2,
      decoration: BoxDecoration(
        color: hollow.border,
        borderRadius: BorderRadius.circular(hollow.radiusXs),
      ),
    );

    Widget addButton = Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.md),
      child: _ServerIcon(
        backgroundColor: hollow.elevated,
        tooltip: 'Create a server',
        onTap: () => showCreateServerDialog(context),
        child: Icon(
          LucideIcons.plus,
          color: hollow.accent,
          size: 24,
        ),
      ),
    );

    return Container(
      width: kServerStripWidth * panelScale,
      decoration: BoxDecoration(
        color: hollow.opaqueSurface,
        border: Border(
          right: BorderSide(color: hollow.border),
        ),
      ),
      // Panel zoom (issue #54): the strip keeps its slot and its icons grow.
      // The fixed stack of icons top and bottom cannot shrink, so
      // minContentHeight caps the zoom at what the window can show.
      child: PanelScale(
        minContentHeight: 560,
        child: Column(
          children: [
            const SizedBox(height: HollowSpacing.md),
            homeIcon,
            for (final tile in topPlaces) ...[
              const SizedBox(height: HollowSpacing.xs),
              tile,
            ],
            const SizedBox(height: HollowSpacing.sm),
            divider,
            const SizedBox(height: HollowSpacing.sm),

            // No scrollbar gutter: this rail is centred icons, and reserving
            // part of its width would shove every one of them off centre.
            Expanded(
              child: ScrollConfiguration(
                behavior:
                    ScrollConfiguration.of(context).copyWith(scrollbars: false),
                child: ListView.builder(
                  // Items interleaved with reorder gaps, gap first.
                  itemCount: stripLayout.length * 2 + 1,
                  padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                  itemBuilder: (context, rawIndex) {
                    if (rawIndex.isEven) {
                      final gapIndex = rawIndex ~/ 2;
                      return _VerticalReorderGap(
                        index: gapIndex,
                        hollow: hollow,
                        onAccept: (data) {
                          ref.read(serverStripLayoutProvider.notifier)
                              .reorder(data.sourceIndex, gapIndex);
                        },
                      );
                    }

                    final index = rawIndex ~/ 2;
                    final item = stripLayout[index];

                    Widget icon = switch (item) {
                      ServerStripItem(:final serverId) => _buildServerIcon(
                          index: index,
                          serverId: serverId,
                          selectedServerId: selectedServerId,
                          hollow: hollow,
                        ),
                      PendingStripItem(:final serverId) => _buildPendingIcon(
                          serverId: serverId,
                        ),
                      FolderStripItem() => _buildFolderIcon(
                          index: index,
                          folder: item,
                          selectedServerId: selectedServerId,
                          hollow: hollow,
                        ),
                    };

                    final isNew = switch (item) {
                      ServerStripItem(:final serverId) =>
                        !_initialServerIds!.contains(serverId),
                      // A parked join can sit here for days, so it never
                      // bounces.
                      PendingStripItem() => false,
                      FolderStripItem() => false,
                    };
                    if (isNew) {
                      icon = NewServerEntry(
                        key: ValueKey('bounce-${switch (item) {
                          ServerStripItem(:final serverId) => serverId,
                          PendingStripItem(:final serverId) => serverId,
                          FolderStripItem(:final id) => id,
                        }}'),
                        child: icon,
                      );
                    }

                    return Padding(
                      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                      child: icon,
                    );
                  },
                ),
              ),
            ),

            if (shopIcon != null)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
                child: shopIcon,
              ),
            helpIcon,
            addButton,
          ],
        ),
      ),
    );
  }

  /// One optional place: a toggle, like every centre-tab button (#28), with
  /// a right-click Hide (#141).
  Widget _placeTile(
    SidebarItem item, {
    required bool open,
    required HollowTheme hollow,
  }) {
    return _ServerIconWithIndicator(
      key: ValueKey(item),
      isSelected: open,
      child: _ServerIcon(
        isSelected: open,
        backgroundColor: hollow.elevated,
        tooltip: item.label,
        onContextMenu: (position) => showSidebarItemMenu(
          context: context,
          ref: ref,
          anchor: position,
          item: item,
          host: PlacesHost.sidebar,
        ),
        onTap: () => open ? setShellTab(ref.read, null) : _openPlace(item),
        child: Icon(
          item.icon,
          color: open ? hollow.accent : hollow.textSecondary,
          size: 20,
        ),
      ),
    );
  }

  /// Opens [item] the way its rail tile always has; the Home menu uses it
  /// for the places hidden from the rail.
  void _openPlace(SidebarItem item) {
    switch (item) {
      case SidebarItem.conferences:
        ref.read(conferenceProvider.notifier).openTab();
        return;
      case SidebarItem.shop:
        openShopTab(ref.read);
        return;
      case SidebarItem.archive:
        ref.invalidate(archiveDmListProvider);
        ref.invalidate(archiveChannelListProvider);
        selectArchiveConversation(ref.read);
      case SidebarItem.publicChannels || SidebarItem.share:
        break;
    }
    setShellTab(ref.read, item.tab);
    ref.read(selectedServerProvider.notifier).state = null;
    ref.read(channelListProvider.notifier).clear();
    ref.read(selectedChannelProvider.notifier).state = null;
    if (item == SidebarItem.publicChannels) {
      ref.read(selectedPeerProvider.notifier).state = null;
    }
    ref.read(serverSettingsOpenProvider.notifier).state = false;
  }

  Widget _buildServerIcon({
    required int index,
    required String serverId,
    required String? selectedServerId,
    required HollowTheme hollow,
  }) {
    final server = ref.watch(serverListProvider)[serverId];
    final isSelected = serverId == selectedServerId;
    final isServerMuted = ref.watch(notificationSettingsProvider
        .select((s) => s.isServerMuted(serverId)));
    final serverUnreads = isServerMuted
        ? 0
        : ref.watch(unreadProvider
            .select((s) => s.serverUnreadCount(serverId)));
    final serverMentions = isServerMuted
        ? 0
        : ref.watch(unreadProvider
            .select((s) => s.serverMentionCount(serverId)));
    // Admitted, but no member has been online long enough to add our MLS leaf.
    // The server is real and browsable; the flair says why it is not fully
    // wired up.
    final awaitingSetup = ref.watch(
        awaitingSetupProvider.select((s) => s.contains(serverId)));
    final name = server?.name ?? '';

    Widget serverIconChild = ServerIconImage(
      serverId: serverId,
      size: 44,
      isSelected: isSelected,
      fallback: Text(
        initialsFromName(name.isNotEmpty ? name : serverId),
        style: HollowTypography.subheading.copyWith(
          color: Colors.white, // design-ignore: initials on an identity colour, as HollowAvatar
        ),
      ),
    );

    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        return details.data.serverId != null && details.data.serverId != serverId;
      },
      onAcceptWithDetails: (details) {
        if (details.data.serverId != null) {
          ref.read(serverStripLayoutProvider.notifier)
              .createFolder(details.data.serverId!, serverId);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isMergeTarget = candidateData.isNotEmpty;
        return LongPressDraggable<_StripDragData>(
          data: _StripDragData(serverId: serverId, sourceIndex: index),
          delay: const Duration(milliseconds: 300),
          // The drag feedback lives in the root Overlay, outside any route's
          // text style.
          feedback: DefaultTextStyle(
            style: HollowTypography.label,
            child: AnimatedOpacity(
              opacity: 0.8,
              duration: Duration.zero,
              child: _ServerIcon(
                backgroundColor: colorFromId(serverId),
                child: serverIconChild,
              ),
            ),
          ),
          childWhenDragging: AnimatedOpacity(
            opacity: 0.3,
            duration: HollowDurations.fast,
            child: _ServerIconWithIndicator(
              isSelected: false,
              child: _ServerIcon(
                backgroundColor: colorFromId(serverId),
                child: serverIconChild,
              ),
            ),
          ),
          child: AnimatedScale(
            scale: isMergeTarget ? 1.08 : 1.0,
            duration: HollowDurations.fast,
            // Right click opens the server menu (issue #61).
            child: ContextMenuTarget(
              semanticLabel: 'Server actions',
              onOpen: (anchor) => showServerIconMenu(
                context: context,
                ref: ref,
                serverId: serverId,
                anchor: anchor,
                onOpenSettings: () => _openServerSettings(serverId),
              ),
              child: _ServerIconWithIndicator(
                isSelected: isSelected,
                unreadCount: serverUnreads,
                mentionCount: serverMentions,
                awaitingSetup: awaitingSetup,
                child: _ServerIcon(
                  isSelected: isSelected,
                  backgroundColor: colorFromId(serverId),
                  tooltip: name,
                  onTap: () => _selectServer(serverId),
                  child: serverIconChild,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// A parked join: we asked, everybody was offline, and Rust holds the request
  /// until somebody answers.
  ///
  /// Deliberately unlike every other tile here. It is NOT selectable, since
  /// there is no server behind it, and it carries a glyph rather than a letter,
  /// because an invite link gives us an id and nothing else to draw. A click
  /// opens the same menu the right click does, so the tile never reads as dead.
  Widget _buildPendingIcon({required String serverId}) {
    final info = ref.watch(pendingJoinsProvider)[serverId];
    final rejected = info?.isRejected ?? false;
    final title = pendingJoinTitle(
        rejected: rejected,
        denied: ref.watch(serverRelayDeniedProvider(serverId)));

    return Builder(builder: (iconContext) {
      void open(Offset anchor) => showPendingJoinMenu(
            context: iconContext,
            ref: ref,
            serverId: serverId,
            anchor: anchor,
          );

      return ContextMenuTarget(
        semanticLabel: '$title, show actions',
        onOpen: open,
        child: _ServerIconWithIndicator(
          isSelected: false,
          // AnimatedOpacity, never the Opacity widget: this one is composited
          // on the GPU.
          child: AnimatedOpacity(
            opacity: rejected ? 0.4 : 0.55,
            duration: HollowDurations.fast,
            child: _ServerIcon(
              backgroundColor: colorFromId(serverId),
              tooltip: title,
              semanticLabel: '$title, show actions',
              onTap: () {
                final box = iconContext.findRenderObject() as RenderBox?;
                final width =
                    (box?.hasSize ?? false) ? box!.size.width : kServerStripWidth;
                open(overlayAnchorOf(iconContext,
                    localOffset: Offset(width, 0)));
              },
              child: Icon(
                rejected ? LucideIcons.ban : LucideIcons.clock,
                size: 20,
                color: Colors.white, // design-ignore: glyph on an identity colour, as HollowAvatar
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildFolderIcon({
    required int index,
    required FolderStripItem folder,
    required String? selectedServerId,
    required HollowTheme hollow,
  }) {
    final isSelected = folder.serverIds.contains(selectedServerId);
    int folderUnreads = 0;
    final notifS = ref.watch(notificationSettingsProvider);
    for (final sid in folder.serverIds) {
      if (!notifS.isServerMuted(sid)) {
        folderUnreads +=
            ref.watch(unreadProvider.select((s) => s.serverUnreadCount(sid)));
      }
    }

    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        return details.data.serverId != null &&
            !folder.serverIds.contains(details.data.serverId);
      },
      onAcceptWithDetails: (details) {
        if (details.data.serverId != null) {
          ref.read(serverStripLayoutProvider.notifier)
              .addToFolder(folder.id, details.data.serverId!);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTarget = candidateData.isNotEmpty;
        return LongPressDraggable<_StripDragData>(
          data: _StripDragData(folderId: folder.id, sourceIndex: index),
          delay: const Duration(milliseconds: 300),
          // The drag feedback lives in the root Overlay, outside any route's
          // text style.
          feedback: DefaultTextStyle(
            style: HollowTypography.label,
            child: AnimatedOpacity(
              opacity: 0.8,
              duration: Duration.zero,
              child: _ServerIcon(
                backgroundColor: hollow.elevated,
                child: ServerFolderIcon(folder: folder, size: 48),
              ),
            ),
          ),
          childWhenDragging: AnimatedOpacity(
            opacity: 0.3,
            duration: HollowDurations.fast,
            child: _ServerIconWithIndicator(
              isSelected: false,
              child: _ServerIcon(
                backgroundColor: hollow.elevated,
                child: ServerFolderIcon(folder: folder, size: 48),
              ),
            ),
          ),
          child: AnimatedScale(
            scale: isDropTarget ? 1.08 : 1.0,
            duration: HollowDurations.fast,
            child: _ServerIconWithIndicator(
              isSelected: isSelected,
              unreadCount: isSelected ? 0 : folderUnreads,
              child: ContextMenuTarget(
                semanticLabel: 'Folder actions',
                onOpen: (anchor) => showFolderIconMenu(
                  context: context,
                  ref: ref,
                  folder: folder,
                  anchor: anchor,
                ),
                child: _ServerIcon(
                  isSelected: isSelected,
                  showBorder: false,
                  backgroundColor: hollow.elevated,
                  tooltip: folder.name,
                  onTap: () {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final pos = overlayAnchorOf(context);
                    showServerFolderPopup(
                      context: context,
                      ref: ref,
                      folder: folder,
                      anchor: Offset(pos.dx + 72, pos.dy + box.size.height / 2),
                      isDock: false,
                      onServerSelected: (serverId) => _selectServer(serverId),
                      onRenameRequested: () {
                        showFolderRenameDialog(
                          context: context,
                          ref: ref,
                          folder: folder,
                        );
                      },
                    );
                  },
                  child: ServerFolderIcon(folder: folder, size: 48),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Selects [serverId] then opens its settings, so closing them lands in
  /// that server.
  Future<void> _openServerSettings(String serverId) async {
    if (ref.read(selectedServerProvider) != serverId) {
      await _selectServer(serverId);
    }
    openServerSettings(ref.read, serverId);
  }

  Future<void> _selectServer(String serverId) async {
    // Read the DB first, with no provider writes yet, so nothing rebuilds.
    final channels = await ChannelListNotifier.fetchChannels(serverId);
    final layout = await ChannelLayoutNotifier.fetchLayout(serverId);

    final lastChannels = ref.read(lastChannelPerServerProvider);
    final lastChannel = lastChannels[serverId];

    String? channelToSelect;
    if (lastChannel != null && channels.containsKey(lastChannel)) {
      channelToSelect = lastChannel;
    } else if (channels.isNotEmpty) {
      channelToSelect = firstTextChannelInLayout(channels, layout)
          ?? channels.keys.first;
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
      final map = Map<String, String>.from(
          ref.read(lastChannelPerServerProvider));
      map[serverId] = channelToSelect;
      ref.read(lastChannelPerServerProvider.notifier).state = map;
    }
  }
}

/// Thin vertical drop zone between items, for reordering.
class _VerticalReorderGap extends StatelessWidget {
  final int index;
  final HollowTheme hollow;
  final void Function(_StripDragData data) onAccept;

  const _VerticalReorderGap({
    required this.index,
    required this.hollow,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<_StripDragData>(
      onWillAcceptWithDetails: (details) {
        final src = details.data.sourceIndex;
        return src != index && src != index - 1;
      },
      onAcceptWithDetails: (details) => onAccept(details.data),
      builder: (context, candidateData, rejectedData) {
        final isActive = candidateData.isNotEmpty;
        return Center(
          child: AnimatedContainer(
            duration: HollowDurations.fast,
            width: 36,
            height: isActive ? 4 : HollowSpacing.xs,
            margin: isActive
                ? const EdgeInsets.symmetric(vertical: HollowSpacing.xxs)
                : EdgeInsets.zero,
            decoration: BoxDecoration(
              color: hollow.accent.withValues(alpha: isActive ? 1 : 0),
              borderRadius: BorderRadius.circular(hollow.radiusXs),
            ),
          ),
        );
      },
    );
  }
}

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


/// Wraps a server icon with a left-edge selection indicator and an optional
/// unread count badge.
class _ServerIconWithIndicator extends StatefulWidget {
  final bool isSelected;
  final int unreadCount;
  final int mentionCount;

  /// Admitted, but waiting for a member to finish the MLS setup.
  final bool awaitingSetup;

  final Widget child;

  const _ServerIconWithIndicator({
    super.key,
    required this.isSelected,
    required this.child,
    this.unreadCount = 0,
    this.mentionCount = 0,
    this.awaitingSetup = false,
  });

  @override
  State<_ServerIconWithIndicator> createState() =>
      _ServerIconWithIndicatorState();
}

class _ServerIconWithIndicatorState
    extends State<_ServerIconWithIndicator> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final indicatorHeight =
        widget.isSelected ? 36.0 : (_hovering ? 20.0 : 0.0);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: SizedBox(
        width: 72,
        height: 48,
        child: Row(
          children: [
            AnimatedContainer(
              duration: HollowDurations.fast,
              curve: HollowCurves.enter,
              width: 3,
              height: indicatorHeight,
              decoration: BoxDecoration(
                color: hollow.textPrimary,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(4),
                  bottomRight: Radius.circular(4),
                ),
              ),
            ),
            const Spacer(),
            // Clip.none is load bearing: an avatar frame paints OUTSIDE the
            // icon box, and a clipping badge stack cuts it off
            // (feedback_badge_stack_clips_avatar_frame).
            Stack(
              clipBehavior: Clip.none,
              children: [
                widget.child,
                if (widget.awaitingSetup)
                  const Positioned(
                    right: -4,
                    top: -4,
                    child: HollowTooltip(
                      message: kAwaitingSetupTooltip,
                      child: AwaitingSetupBadge(),
                    ),
                  ),
                if (widget.unreadCount > 0)
                  Positioned(
                    right: -6,
                    bottom: -4,
                    child: HollowCountBadge(
                      count: widget.mentionCount > 0
                          ? widget.mentionCount
                          : widget.unreadCount,
                      mention: widget.mentionCount > 0,
                      ring: hollow.surface,
                    ),
                  ),
              ],
            ),
            const SizedBox(width: HollowSpacing.md),
          ],
        ),
      ),
    );
  }
}

/// A single icon in the server strip, animating to a pill on hover or select.
class _ServerIcon extends StatefulWidget {
  final Widget child;
  final Color backgroundColor;
  final VoidCallback? onTap;

  /// Right click, with the position already resolved to OVERLAY space: Home
  /// and the optional places. Server and folder icons carry their own
  /// detector, because they also sit inside the drag machinery.
  final void Function(Offset overlayPosition)? onContextMenu;

  /// A touch long press opens the context menu too (Home only).
  final bool touchLongPressMenu;

  final String? tooltip;
  final String? semanticLabel;
  final bool isSelected;
  final bool showBorder;

  const _ServerIcon({
    required this.child,
    required this.backgroundColor,
    this.onTap,
    this.onContextMenu,
    this.touchLongPressMenu = false,
    this.tooltip,
    this.semanticLabel,
    this.isSelected = false,
    this.showBorder = true,
  });

  @override
  State<_ServerIcon> createState() => _ServerIconState();
}

class _ServerIconState extends State<_ServerIcon> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final radius =
        (_hovering || widget.isSelected) ? 16.0 : hollow.radiusLg;

    final effectiveBg = _hovering && !widget.isSelected
        ? Color.lerp(widget.backgroundColor, hollow.accent, 0.15)!
        : widget.backgroundColor;

    Widget icon = MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: HollowFocusRing(
        enabled: widget.onTap != null,
        onActivate: widget.onTap,
        borderRadius: BorderRadius.circular(radius),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: HollowDurations.fast,
            curve: Curves.easeOutCubic,
            width: 48,
            height: 48,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: effectiveBg,
              borderRadius: BorderRadius.circular(radius),
              border: (widget.isSelected && widget.showBorder)
                  ? Border.all(
                      color: hollow.accent.withValues(alpha: 0.6),
                      width: 2,
                    )
                  : null,
            ),
            alignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      icon = HollowTooltip(message: widget.tooltip!, child: icon);
    }

    // Tooltips do not surface to screen readers, so a tappable icon needs a
    // name of its own.
    final label = widget.semanticLabel ?? widget.tooltip;
    if (label != null && widget.onTap != null) {
      icon = Semantics(button: true, label: label, child: icon);
    }

    // ABOVE the focus ring, so Menu and Shift+F10 reach it while the icon is
    // keyboard-focused (issue #61).
    final onContextMenu = widget.onContextMenu;
    if (onContextMenu != null) {
      icon = ContextMenuTarget(
        semanticLabel: '${label ?? 'Icon'} actions',
        onOpen: onContextMenu,
        longPressOnTouch: widget.touchLongPressMenu,
        child: icon,
      );
    }

    return icon;
  }
}
