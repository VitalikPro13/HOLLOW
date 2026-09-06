import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/settings/channels_tab.dart';
import 'package:hollow/src/ui/settings/danger_zone_tab.dart';
import 'package:hollow/src/ui/settings/members_tab.dart';
import 'package:hollow/src/ui/settings/notifications_tab.dart';
import 'package:hollow/src/ui/settings/emotes_tab.dart';
import 'package:hollow/src/ui/settings/labels_tab.dart';
import 'package:hollow/src/ui/settings/overview_tab.dart';
import 'package:hollow/src/ui/settings/roles_tab.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Full server settings panel, in place of the chat pane. Tabs are gated by the
/// local user's permissions.
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
      int permissions, String myRole) {
    final tabs = <({IconData icon, String label, bool isDanger})>[];

    // Always visible; the server settings inside are admin-gated.
    tabs.add((
      icon: LucideIcons.info,
      label: 'Overview',
      isDanger: false,
    ));

    if (permissions & Permission.manageChannels != 0) {
      tabs.add((
        icon: LucideIcons.hash,
        label: 'Channels',
        isDanger: false,
      ));
    }

    // Role managers can view; only the owner can edit.
    if (permissions & Permission.manageRoles != 0) {
      tabs.add((
        icon: LucideIcons.shield,
        label: 'Roles',
        isDanger: false,
      ));
    }

    // Visible to everyone for self-assign; management needs MANAGE_ROLES.
    tabs.add((
      icon: LucideIcons.tag,
      label: 'Labels',
      isDanger: false,
    ));

    // Visible to everyone for browsing; management needs MANAGE_EMOTES.
    tabs.add((
      icon: LucideIcons.smile,
      label: 'Emotes',
      isDanger: false,
    ));

    // Always visible: viewing is fine, and the actions are gated inside.
    tabs.add((
      icon: LucideIcons.users,
      label: 'Members',
      isDanger: false,
    ));

    tabs.add((
      icon: LucideIcons.bell,
      label: 'Notifications',
      isDanger: false,
    ));

    // The owner sees Delete Server here, everyone else sees Leave Server.
    tabs.add((
      icon: LucideIcons.alertTriangle,
      label: 'Danger',
      isDanger: true,
    ));

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
      'Roles' => RolesTab(
          key: const ValueKey('roles'), serverId: server.serverId),
      'Labels' => LabelsTab(
          key: const ValueKey('labels'), serverId: server.serverId),
      'Emotes' => EmotesTab(
          key: const ValueKey('emotes'), serverId: server.serverId),
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

    // Re-read from the provider so a rename lands here.
    final currentServer =
        ref.watch(serverListProvider)[widget.server.serverId] ?? widget.server;

    final permissionsAsync =
        ref.watch(myPermissionsProvider(widget.server.serverId));
    final roleAsync = ref.watch(myRoleProvider(widget.server.serverId));

    // Rendering before permissions load flashes the wrong tabs.
    if (!permissionsAsync.hasValue || !roleAsync.hasValue) {
      return Column(
        children: [
          Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: hollow.border)),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.settings, size: 18, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Text(
                    'Server Settings: ${currentServer.name}',
                    style: HollowTypography.subheading.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                HollowPressable(
                  semanticLabel: 'Close',
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
    final myRole = roleAsync.value ?? 'member';
    final tabs = _visibleTabs(permissions, myRole);

    // Permissions may have shrunk the tab list.
    if (_selectedTab >= tabs.length) {
      _selectedTab = 0;
    }

    return Column(
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
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
                  'Server Settings: ${currentServer.name}',
                  style: HollowTypography.subheading.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              HollowPressable(
                semanticLabel: 'Close',
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

        // Own traversal group (a11y 2.6): Tab cycles the section selector on
        // its own, separate from the content pane below.
        FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding:
                const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              border: Border(bottom: BorderSide(color: hollow.border)),
            ),
            // At high text scale the tab row outgrows the panel, so it scrolls
            // instead of overflowing. EdgeScrollRow rather than a bare
            // scroller, because overflowing tabs were unreachable with a plain
            // wheel mouse: no drag affordance and no gesture.
            child: EdgeScrollRow(
              semanticLabel: 'settings tabs',
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
        ),

        // Own traversal group (a11y 2.6): Tab stays WITHIN the active section
        // body instead of leaking back into the tab selector.
        Expanded(
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
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
          // Load-bearing chrome, so the label scale is capped where content
          // areas honour the full 2.0x.
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.3,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.label.copyWith(
                color: color,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
