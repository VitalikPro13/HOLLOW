import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Notifications tab in Server Settings: the server-wide default and the
/// per-channel overrides.
class NotificationsTab extends ConsumerWidget {
  final String serverId;

  const NotificationsTab({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final notifState = ref.watch(notificationSettingsProvider);
    final notifNotifier = ref.read(notificationSettingsProvider.notifier);
    // Only channels the local user can see: listing a restricted channel's name
    // to a non-privileged member would leak its existence.
    final allChannels =
        ref.watch(serverChannelsProvider(serverId)).valueOrNull ?? {};
    final channels = <String, ChannelInfo>{
      for (final e in allChannels.entries)
        if (e.value.meCanSee) e.key: e.value,
    };
    final serverLevel = notifState.serverLevels[serverId] ??
        NotificationLevel.all;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const HollowSectionHeader('Server Notifications'),

          Text(
            'Default notification level for all channels in this server.',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),

          NotificationLevelSelector(
            value: serverLevel,
            onChanged: (level) =>
                notifNotifier.setServerLevel(serverId, level),
          ),

          const SizedBox(height: HollowSpacing.xxl),

          const HollowSectionHeader('Channel Overrides'),
          Text(
            'Override notification settings for specific channels.',
            style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),

          if (channels.isEmpty)
            const HollowEmptyState(dense: true, title: 'No channels')
          else
            ...channels.values.map((channel) {
              final override = notifNotifier.channelOverride(
                  serverId, channel.channelId);

              return Padding(
                padding: const EdgeInsets.only(
                    bottom: HollowSpacing.sm),
                child: Row(
                  children: [
                    Icon(
                      LucideIcons.hash,
                      size: 16,
                      color: hollow.textSecondary,
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: Text(
                        channel.name,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 13,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.md),
                    ChannelOverrideDropdown(
                      value: override,
                      onChanged: (level) =>
                          notifNotifier.setChannelOverride(
                              serverId, channel.channelId, level),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}

/// Server-level notification picker. Shared with the Notifications category of
/// user settings, which lists every server.
class NotificationLevelSelector extends StatelessWidget {
  final NotificationLevel value;
  final ValueChanged<NotificationLevel> onChanged;

  const NotificationLevelSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        HollowChip(
          label: 'All messages',
          icon: LucideIcons.bell,
          selected: value == NotificationLevel.all,
          onTap: () => onChanged(NotificationLevel.all),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowChip(
          label: 'Mentions only',
          icon: LucideIcons.atSign,
          selected: value == NotificationLevel.mentions,
          onTap: () => onChanged(NotificationLevel.mentions),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowChip(
          label: 'Nothing',
          icon: LucideIcons.bellOff,
          selected: value == NotificationLevel.nothing,
          onTap: () => onChanged(NotificationLevel.nothing),
        ),
      ],
    );
  }
}

/// Per-channel override selector. Shared with the Notifications category of
/// user settings.
class ChannelOverrideDropdown extends StatelessWidget {
  final ChannelNotificationLevel value;
  final ValueChanged<ChannelNotificationLevel> onChanged;

  const ChannelOverrideDropdown({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static const _options = [
    (ChannelNotificationLevel.inherit, 'Default', LucideIcons.settings),
    (ChannelNotificationLevel.all, 'All', LucideIcons.bell),
    (ChannelNotificationLevel.mentions, 'Mentions', LucideIcons.atSign),
    (ChannelNotificationLevel.nothing, 'Nothing', LucideIcons.bellOff),
  ];

  @override
  Widget build(BuildContext context) {
    final current = _options.firstWhere((o) => o.$1 == value);
    return Builder(
      builder: (chipContext) => HollowChip(
        label: current.$2,
        trailingIcon: LucideIcons.chevronDown,
        semanticLabel: 'Notifications for this channel, ${current.$2}',
        onTap: () => showHollowMenu(
          context: chipContext,
          // The chip sits at the row's trailing edge, so the menu opens
          // right-aligned under it rather than over the next panel.
          alignEnd: true,
          anchor: overlayAnchorOf(chipContext,
              localOffset: Offset(chipContext.size?.width ?? 0,
                  (chipContext.size?.height ?? 0) + HollowSpacing.xs)),
          builder: (_, _) => [
            for (final (level, label, icon) in _options)
              HollowMenuItem(
                icon: icon,
                label: label,
                isChecked: level == value,
                onTap: () => onChanged(level),
              ),
          ],
        ),
      ),
    );
  }
}
