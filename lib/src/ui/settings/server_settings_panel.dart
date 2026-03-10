import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:haven/src/core/models/server_info.dart';
import 'package:haven/src/core/providers/server_provider.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/components/haven_pressable.dart';
import 'package:haven/src/ui/settings/channels_tab.dart';
import 'package:haven/src/ui/settings/danger_zone_tab.dart';
import 'package:haven/src/ui/settings/members_tab.dart';
import 'package:haven/src/ui/settings/overview_tab.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Full server settings panel — replaces the chat pane.
/// Tabs are gated by the local user's permissions.
class ServerSettingsPanel extends ConsumerStatefulWidget {
  final ServerInfo server;

  const ServerSettingsPanel({super.key, required this.server});

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
      'Danger' => DangerZoneTab(
          key: const ValueKey('danger'), server: server),
      _ => const SizedBox.shrink(),
    };
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);

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
            padding: const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: haven.border)),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.settings, size: 18, color: haven.textSecondary),
                const SizedBox(width: HavenSpacing.sm),
                Expanded(
                  child: Text(
                    'Server Settings — ${currentServer.name}',
                    style: HavenTypography.subheading.copyWith(
                      color: haven.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                HavenPressable(
                  onTap: () {
                    ref.read(serverSettingsOpenProvider.notifier).state = false;
                  },
                  borderRadius: BorderRadius.circular(haven.radiusSm),
                  padding: const EdgeInsets.all(HavenSpacing.xs),
                  child: Icon(LucideIcons.x, size: 18, color: haven.textSecondary),
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
              const EdgeInsets.symmetric(horizontal: HavenSpacing.lg),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: haven.border)),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.settings,
                  size: 18, color: haven.textSecondary),
              const SizedBox(width: HavenSpacing.sm),
              Expanded(
                child: Text(
                  'Server Settings — ${currentServer.name}',
                  style: HavenTypography.subheading.copyWith(
                    color: haven.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HavenPressable(
                onTap: () {
                  ref.read(serverSettingsOpenProvider.notifier).state =
                      false;
                },
                borderRadius: BorderRadius.circular(haven.radiusSm),
                padding: const EdgeInsets.all(HavenSpacing.xs),
                child: Icon(LucideIcons.x,
                    size: 18, color: haven.textSecondary),
              ),
            ],
          ),
        ),

        // Tab bar
        Container(
          height: 40,
          padding:
              const EdgeInsets.symmetric(horizontal: HavenSpacing.md),
          decoration: BoxDecoration(
            color: haven.surface,
            border: Border(bottom: BorderSide(color: haven.border)),
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
            duration: const Duration(milliseconds: 200),
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
    final haven = HavenTheme.of(context);
    final activeColor = isDanger ? haven.error : haven.accent;
    final color = isSelected ? activeColor : haven.textSecondary;

    return HavenPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: BorderRadius.circular(haven.radiusSm),
      padding: const EdgeInsets.symmetric(
        horizontal: HavenSpacing.md,
        vertical: HavenSpacing.sm,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: HavenSpacing.xs),
          Text(
            label,
            style: HavenTypography.label.copyWith(
              color: color,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
