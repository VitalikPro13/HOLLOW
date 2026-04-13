import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/settings/channels_tab.dart';
import 'package:hollow/src/ui/settings/danger_zone_tab.dart';
import 'package:hollow/src/ui/settings/members_tab.dart';
import 'package:hollow/src/ui/settings/notifications_tab.dart';
import 'package:hollow/src/ui/settings/overview_tab.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Full server settings panel — replaces the chat pane.
/// Tabs are gated by the local user's permissions.
class ServerSettingsPanel extends ConsumerStatefulWidget {
  final ServerInfo server;
  final VoidCallback? onClose;

  const ServerSettingsPanel({super.key, required this.server, this.onClose});

  @override
  ConsumerState<ServerSettingsPanel> createState() =>
      _ServerSettingsPanelState();
}

class _ServerSettingsPanelState extends ConsumerState<ServerSettingsPanel> {
  int _selectedTab = 0;

  List<({IconData icon, String label, bool isDanger})> _visibleTabs(
      int permissions) {
    final tabs = <({IconData icon, String label, bool isDanger})>[];

    // Overview — always visible (nickname for all, server settings for admins)
    tabs.add((
      icon: LucideIcons.info,
      label: 'Overview',
      isDanger: false,
    ));

    // Channels — only for channel managers
    if (permissions & Permission.manageChannels != 0) {
      tabs.add((
        icon: LucideIcons.hash,
        label: 'Channels',
        isDanger: false,
      ));
    }

    // Members — always visible (viewing is OK, actions gated inside)
    tabs.add((
      icon: LucideIcons.users,
      label: 'Members',
      isDanger: false,
    ));

    // Notifications — always visible
    tabs.add((
      icon: LucideIcons.bell,
      label: 'Notifications',
      isDanger: false,
    ));

    // Danger Zone — only for server owner
    if (permissions & Permission.manageServer != 0) {
      tabs.add((
        icon: LucideIcons.alertTriangle,
        label: 'Danger',
        isDanger: true,
      ));
    }

    return tabs;
  }

  Widget _buildTabContent(
    ServerInfo server,
    List<({IconData icon, String label, bool isDanger})> tabs,
    int permissions,
  ) {
    if (_selectedTab >= tabs.length) return const SizedBox.shrink();
    final tab = tabs[_selectedTab];
    return switch (tab.label) {
      'Overview' => OverviewTab(
          key: const ValueKey('overview'),
          server: server,
          canManageServer: permissions & Permission.manageServer != 0),
      'Channels' => ChannelsTab(
          key: const ValueKey('channels'), serverId: server.serverId),
      'Members' => MembersTab(
          key: const ValueKey('members'), serverId: server.serverId),
      'Notifications' => NotificationsTab(
          key: const ValueKey('notifications'), serverId: server.serverId),
      'Danger' => DangerZoneTab(
          key: const ValueKey('danger'), server: server),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Re-read the server from provider so it updates when renamed
    final currentServer =
        ref.watch(serverListProvider)[widget.server.serverId] ?? widget.server;

    final permissionsAsync =
        ref.watch(myPermissionsProvider(widget.server.serverId));

    // Don't render until permissions are loaded — prevents flash of wrong tabs.
    if (!permissionsAsync.hasValue) {
      return Column(
        children: [
          Container(
            height: 48,
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: hollow.border)),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.settings, size: 18, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(
                    'Server Settings — ${currentServer.name}',
                    style: HollowTypography.subheading.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                HollowPressable(
                  onTap: () {
                    if (widget.onClose != null) {
                      widget.onClose!();
                    } else {
                      ref.read(serverSettingsOpenProvider.notifier).state = false;
                    }
                  },
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xs),
                  child: Icon(LucideIcons.x, size: 18, color: hollow.textSecondary),
                ),
              ],
            ),
          ),
          const Expanded(child: SizedBox.shrink()),
        ],
      );
    }

    final permissions = permissionsAsync.value!;
    final tabs = _visibleTabs(permissions);

    // Clamp selected tab if permissions changed
    if (_selectedTab >= tabs.length) {
      _selectedTab = 0;
    }

    return Column(
      children: [
        // Header bar
        Container(
          height: 48,
          padding:
              const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.settings,
                  size: 18, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  'Server Settings — ${currentServer.name}',
                  style: HollowTypography.subheading.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HollowPressable(
                onTap: () {
                  if (widget.onClose != null) {
                    widget.onClose!();
                  } else {
                    ref.read(serverSettingsOpenProvider.notifier).state =
                        false;
                  }
                },
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.x,
                    size: 18, color: hollow.textSecondary),
              ),
            ],
          ),
        ),

        // Tab bar
        Container(
          height: 40,
          padding:
              const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(bottom: BorderSide(color: hollow.border)),
          ),
          child: Row(
            children: List.generate(tabs.length, (i) {
              final tab = tabs[i];
              final isSelected = i == _selectedTab;
              return _TabButton(
                icon: tab.icon,
                label: tab.label,
                isSelected: isSelected,
                isDanger: tab.isDanger,
                onTap: () => setState(() => _selectedTab = i),
              );
            }),
          ),
        ),

        // Tab content
        Expanded(
          child: AnimatedSwitcher(
            duration: HollowDurations.normal,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                alignment: Alignment.topCenter,
                children: [
                  ...previousChildren,
                  ?currentChild,
                ],
              );
            },
            child: _buildTabContent(currentServer, tabs, permissions),
          ),
        ),
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isDanger;
  final VoidCallback onTap;

  const _TabButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    this.isDanger = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final activeColor = isDanger ? hollow.error : hollow.accent;
    final color = isSelected ? activeColor : hollow.textSecondary;

    return HollowPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            label,
            style: HollowTypography.label.copyWith(
              color: color,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
