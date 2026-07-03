import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/guest_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/selection_shimmer.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class GuestServerSidebar extends ConsumerStatefulWidget {
  const GuestServerSidebar({super.key});

  @override
  ConsumerState<GuestServerSidebar> createState() => _GuestServerSidebarState();
}

class _GuestServerSidebarState extends ConsumerState<GuestServerSidebar> {
  bool _showAddField = false;
  final _addController = TextEditingController();

  @override
  void dispose() {
    _addController.dispose();
    super.dispose();
  }

  void _submitAdd() {
    final input = _addController.text.trim();
    if (input.isEmpty) return;

    String serverId = input;
    final serverParam = Uri.tryParse(input)?.queryParameters['server'];
    if (serverParam != null && serverParam.isNotEmpty) {
      serverId = serverParam;
    } else if (input.contains('/')) {
      serverId = input.split('/').last;
    }

    final notifier = ref.read(savedGuestServersProvider.notifier);
    final realtimeCount = notifier.realtimeCount;
    final mode = realtimeCount >= 7
        ? GuestFetchMode.manual
        : GuestFetchMode.realtime;

    notifier.addServer(serverId, '', mode).then((added) {
      if (!mounted) return;
      if (!added) {
        HollowToast.show(context, 'Server already saved',
            type: HollowToastType.info);
        return;
      }
      if (mode == GuestFetchMode.manual) {
        HollowToast.show(
            context, 'Added as manual — 7 real-time servers reached',
            type: HollowToastType.info);
      }
      // Expand the newly added server and request its channels.
      ref.read(guestExpandedServerProvider.notifier).state = serverId;
      ref.read(guestSelectedServerProvider.notifier).state = serverId;
      final loading = Set<String>.from(ref.read(guestLoadingProvider));
      loading.add(serverId);
      ref.read(guestLoadingProvider.notifier).state = loading;
      crdt_api.requestPublicChannels(serverId: serverId).catchError((_) {});
    });

    _addController.clear();
    setState(() => _showAddField = false);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(savedGuestServersProvider).valueOrNull ?? [];
    final expandedServer = ref.watch(guestExpandedServerProvider);
    final channelMap = ref.watch(guestChannelMapProvider);
    final loadingSet = ref.watch(guestLoadingProvider);
    final selectedChannel = ref.watch(guestSelectedChannelProvider);

    return Container(
      decoration: BoxDecoration(
        color: hollow.opaqueBackground,
        border: Border(right: BorderSide(color: hollow.border)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: hollow.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Public Channels',
                    style: HollowTypography.subheading.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                HollowPressable(
                  onTap: () => setState(() {
                    _showAddField = !_showAddField;
                    if (_showAddField) {
                      _addController.clear();
                    }
                  }),
                  semanticLabel: 'Add channel',
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    _showAddField ? LucideIcons.x : LucideIcons.plus,
                    size: 16,
                    color: hollow.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // Add server field (slide down)
          AnimatedSize(
            duration: HollowDurations.normal,
            curve: HollowCurves.enter,
            child: _showAddField
                ? Padding(
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: HollowTextField(
                      controller: _addController,
                      hintText: 'Server ID or invite link',
                      autofocus: true,
                      onSubmitted: (_) => _submitAdd(),
                      isDense: true,
                    ),
                  )
                : const SizedBox.shrink(),
          ),

          // Server list or empty state
          Expanded(
            child: servers.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(HollowSpacing.xl),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.globe,
                            size: 48,
                            color: hollow.textSecondary.withValues(alpha: 0.3),
                          ),
                          const SizedBox(height: HollowSpacing.md),
                          Text(
                            'Add a server to browse\npublic channels',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: hollow.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: HollowSpacing.md),
                          HollowButton.ghost(
                            compact: true,
                            icon: const Icon(LucideIcons.plus, size: 14),
                            onPressed: () =>
                                setState(() => _showAddField = true),
                            child: const Text('Add Server'),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
                    itemCount: servers.length,
                    itemBuilder: (context, index) {
                      final server = servers[index];
                      final isExpanded =
                          expandedServer == server.serverId;
                      final channels =
                          channelMap[server.serverId] ?? [];
                      final isLoading =
                          loadingSet.contains(server.serverId);

                      return _GuestServerSection(
                        server: server,
                        isExpanded: isExpanded,
                        channels: channels,
                        isLoading: isLoading,
                        selectedChannel: selectedChannel,
                        onToggleExpand: () => _toggleExpand(server.serverId),
                        onChannelTap: (channelId) =>
                            _selectChannel(server.serverId, channelId),
                        onRefresh: () {
                          final loading = Set<String>.from(ref.read(guestLoadingProvider));
                          loading.add(server.serverId);
                          ref.read(guestLoadingProvider.notifier).state = loading;
                          crdt_api.requestPublicChannels(serverId: server.serverId)
                              .catchError((_) {});
                        },
                        onRemove: () => ref
                            .read(savedGuestServersProvider.notifier)
                            .removeServer(server.serverId),
                        onCopyId: () {
                          Clipboard.setData(
                              ClipboardData(text: server.serverId));
                          HollowToast.show(context, 'Server ID copied',
                              type: HollowToastType.success);
                        },
                        onFetchModeChanged: (mode) => _changeFetchMode(
                            server.serverId, mode),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _toggleExpand(String serverId) {
    final current = ref.read(guestExpandedServerProvider);
    if (current == serverId) {
      ref.read(guestExpandedServerProvider.notifier).state = null;
      return;
    }
    ref.read(guestExpandedServerProvider.notifier).state = serverId;
    ref.read(guestSelectedServerProvider.notifier).state = serverId;

    // Fetch channels if not cached.
    final channels = ref.read(guestChannelMapProvider)[serverId];
    if (channels == null || channels.isEmpty) {
      final loading = Set<String>.from(ref.read(guestLoadingProvider));
      loading.add(serverId);
      ref.read(guestLoadingProvider.notifier).state = loading;
      crdt_api.requestPublicChannels(serverId: serverId).catchError((_) {});
    }
  }

  void _selectChannel(String serverId, String channelId) {
    ref.read(guestSelectedServerProvider.notifier).state = serverId;
    ref.read(guestSelectedChannelProvider.notifier).state = channelId;
    // Only fetch if messages aren't already loaded for this channel.
    final key = '$serverId:$channelId';
    final existing = ref.read(channelChatProvider)[key];
    if (existing == null || existing.isEmpty) {
      crdt_api.requestPublicChannelSync(
        serverId: serverId,
        channelId: channelId,
      ).catchError((_) {});
    }
  }

  void _changeFetchMode(String serverId, GuestFetchMode mode) {
    ref
        .read(savedGuestServersProvider.notifier)
        .updateFetchMode(serverId, mode)
        .then((ok) {
      if (!mounted) return;
      if (!ok) {
        HollowToast.show(
            context, 'Maximum 7 real-time servers reached',
            type: HollowToastType.error);
      }
    });
  }
}

// ── Server section (header + expandable channels) ──

class _GuestServerSection extends ConsumerWidget {
  final SavedGuestServer server;
  final bool isExpanded;
  final List<GuestChannelEntry> channels;
  final bool isLoading;
  final String? selectedChannel;
  final VoidCallback onToggleExpand;
  final ValueChanged<String> onChannelTap;
  final VoidCallback onRefresh;
  final VoidCallback onRemove;
  final VoidCallback onCopyId;
  final ValueChanged<GuestFetchMode> onFetchModeChanged;

  const _GuestServerSection({
    required this.server,
    required this.isExpanded,
    required this.channels,
    required this.isLoading,
    required this.selectedChannel,
    required this.onToggleExpand,
    required this.onChannelTap,
    required this.onRefresh,
    required this.onRemove,
    required this.onCopyId,
    required this.onFetchModeChanged,
  });

  IconData _fetchModeIcon(GuestFetchMode mode) => switch (mode) {
        GuestFetchMode.realtime => LucideIcons.radio,
        GuestFetchMode.onLaunch => LucideIcons.refreshCw,
        GuestFetchMode.manual => LucideIcons.hand,
        _ => LucideIcons.clock,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final name = server.serverName.isNotEmpty
        ? server.serverName
        : server.serverId.substring(0, 8);
    final avatarColor = colorFromId(server.serverId);
    // Try guest avatar first (from PublicChannelListResponse), then member avatar.
    final guestAvatar = ref.watch(
        guestServerAvatarProvider.select((m) => m[server.serverId]));
    final memberAvatar = ref.watch(
        serverAvatarProvider.select((m) => m[server.serverId]));
    final avatarBytes = guestAvatar ?? memberAvatar;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Server header
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.xxs,
          ),
          child: GestureDetector(
            onSecondaryTapUp: (details) =>
                _showContextMenu(context, details.globalPosition),
            child: HollowPressable(
              onTap: onToggleExpand,
              subtle: true,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              backgroundColor: isExpanded
                  ? hollow.accent.withValues(alpha: 0.06)
                  : Colors.transparent,
              hoverColor: hollow.elevated,
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.sm,
              ),
              child: Row(
                children: [
                  // Server avatar
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: avatarBytes != null
                        ? Image.memory(
                            avatarBytes is Uint8List
                                ? avatarBytes
                                : Uint8List.fromList(avatarBytes),
                            width: 20,
                            height: 20,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 20,
                            height: 20,
                            color: avatarColor,
                            alignment: Alignment.center,
                            child: Text(
                              name[0].toUpperCase(),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  // Server name
                  Expanded(
                    child: Text(
                      name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isExpanded
                            ? hollow.textPrimary
                            : hollow.textSecondary,
                        fontSize: 13,
                        fontWeight:
                            isExpanded ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                  ),
                  // Fetch mode icon
                  Icon(
                    _fetchModeIcon(server.fetchMode),
                    size: 12,
                    color: hollow.textSecondary.withValues(alpha: 0.5),
                  ),
                  if (isExpanded) ...[
                    const SizedBox(width: 2),
                    HollowPressable(
                      onTap: onRefresh,
                      semanticLabel: 'Refresh',
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        LucideIcons.refreshCw,
                        size: 12,
                        color: hollow.textSecondary.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  // Chevron
                  AnimatedRotation(
                    turns: isExpanded ? 0.25 : 0.0,
                    duration: HollowDurations.fast,
                    child: Icon(
                      LucideIcons.chevronRight,
                      size: 14,
                      color: hollow.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Channel list (animated expand/collapse)
        AnimatedSize(
          duration: HollowDurations.normal,
          curve: HollowCurves.enter,
          alignment: Alignment.topCenter,
          child: isExpanded
              ? _buildChannelList(context, hollow)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildChannelList(BuildContext context, HollowTheme hollow) {
    if (isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.md),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: hollow.accent,
            ),
          ),
        ),
      );
    }

    if (channels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          vertical: HollowSpacing.md,
          horizontal: HollowSpacing.lg,
        ),
        child: Text(
          'No public channels found.\nMembers may be offline.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: hollow.textSecondary,
            fontSize: 12,
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < channels.length; i++)
          _GuestChannelTile(
            name: channels[i].name,
            isSelected: selectedChannel == channels[i].channelId,
            isLast: i == channels.length - 1,
            onTap: () => onChannelTap(channels[i].channelId),
          ),
      ],
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final hollow = HollowTheme.of(context);
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.pop(ctx),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: position.dx,
            top: position.dy,
            child: Material(
              color: Colors.transparent,
              child: Container(
                width: 200,
                decoration: BoxDecoration(
                  color: hollow.surface,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border: Border.all(color: hollow.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Fetch mode submenu header
                    _ContextMenuHeader(
                      label: 'Fetch Mode',
                      hollow: hollow,
                    ),
                    for (final mode in GuestFetchMode.values)
                      _ContextMenuItem(
                        label: mode.label,
                        hollow: hollow,
                        isSelected: server.fetchMode == mode,
                        onTap: () {
                          Navigator.pop(ctx);
                          onFetchModeChanged(mode);
                        },
                      ),
                    Divider(height: 1, color: hollow.border),
                    _ContextMenuItem(
                      label: 'Copy Server ID',
                      hollow: hollow,
                      icon: LucideIcons.copy,
                      onTap: () {
                        Navigator.pop(ctx);
                        onCopyId();
                      },
                    ),
                    _ContextMenuItem(
                      label: 'Remove',
                      hollow: hollow,
                      icon: LucideIcons.trash2,
                      isDestructive: true,
                      onTap: () {
                        Navigator.pop(ctx);
                        onRemove();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Channel tile (matches _ChannelTile from channel_sidebar.dart) ──

class _GuestChannelTile extends StatelessWidget {
  final String name;
  final bool isSelected;
  final bool isLast;
  final VoidCallback onTap;

  const _GuestChannelTile({
    required this.name,
    required this.isSelected,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusMd);

    Widget tile = HollowPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: radius,
      backgroundColor: isSelected ? hollow.accentMuted : Colors.transparent,
      hoverColor: hollow.elevated,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.sm - 2,
      ),
      child: AnimatedDefaultTextStyle(
        duration: HollowDurations.fast,
        curve: HollowCurves.subtle,
        style: HollowTypography.body.copyWith(
          color: isSelected ? hollow.textPrimary : hollow.textSecondary,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          fontSize: 13,
        ),
        child: Row(
          children: [
            Text(
              isLast ? '└' : '├',
              style: TextStyle(
                color: hollow.textSecondary.withValues(alpha: 0.4),
                fontSize: 13,
                fontFamily: 'monospace',
                height: 1,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              LucideIcons.hash,
              size: 14,
              color: isSelected ? hollow.textPrimary : hollow.textSecondary,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(name, overflow: TextOverflow.ellipsis),
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
      padding: const EdgeInsets.only(
        left: HollowSpacing.lg,
        right: HollowSpacing.sm,
        top: HollowSpacing.xxs,
        bottom: HollowSpacing.xxs,
      ),
      child: tile,
    );
  }
}

// ── Context menu helpers ──

class _ContextMenuHeader extends StatelessWidget {
  final String label;
  final HollowTheme hollow;

  const _ContextMenuHeader({required this.label, required this.hollow});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(
        label,
        style: TextStyle(
          color: hollow.textSecondary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ContextMenuItem extends StatelessWidget {
  final String label;
  final HollowTheme hollow;
  final IconData? icon;
  final bool isSelected;
  final bool isDestructive;
  final VoidCallback onTap;

  const _ContextMenuItem({
    required this.label,
    required this.hollow,
    this.icon,
    this.isSelected = false,
    this.isDestructive = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        isDestructive ? hollow.error : hollow.textPrimary;
    return HollowPressable(
      onTap: onTap,
      hoverColor: hollow.elevated,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 13,
              ),
            ),
          ),
          if (isSelected)
            Icon(LucideIcons.check, size: 14, color: hollow.accent),
        ],
      ),
    );
  }
}
