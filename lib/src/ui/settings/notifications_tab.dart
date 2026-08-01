import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Notifications settings tab in Server Settings.
///
/// Shows server-wide default (All / Mentions / Nothing) and
/// per-channel overrides (Default / All / Mentions / Nothing).
class NotificationsTab extends ConsumerWidget {
  final String serverId;

  const NotificationsTab({super.key, required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final notifState = ref.watch(notificationSettingsProvider);
    final notifNotifier = ref.read(notificationSettingsProvider.notifier);
    // Only channels the local user can see — listing restricted channel
    // names to a non-privileged member would leak their existence.
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
          // Server-wide setting
          Text(
            'SERVER NOTIFICATIONS',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),

          Text(
            'Default notification level for all channels in this server.',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),

          _NotificationLevelSelector(
            value: serverLevel,
            onChanged: (level) =>
                notifNotifier.setServerLevel(serverId, level),
          ),

          const SizedBox(height: HollowSpacing.xxl),

          // Per-channel overrides
          Text(
            'CHANNEL OVERRIDES',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Override notification settings for specific channels.',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),

          if (channels.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: HollowSpacing.xl),
              child: Center(
                child: Text(
                  'No channels',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ),
            )
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
                    _ChannelOverrideDropdown(
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

/// Server-level notification picker: All / Mentions / Nothing.
class _NotificationLevelSelector extends StatelessWidget {
  final NotificationLevel value;
  final ValueChanged<NotificationLevel> onChanged;

  const _NotificationLevelSelector({
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Row(
      children: [
        _LevelChip(
          label: 'All Messages',
          icon: LucideIcons.bell,
          isSelected: value == NotificationLevel.all,
          onTap: () => onChanged(NotificationLevel.all),
        ),
        const SizedBox(width: HollowSpacing.sm),
        _LevelChip(
          label: 'Mentions Only',
          icon: LucideIcons.atSign,
          isSelected: value == NotificationLevel.mentions,
          onTap: () => onChanged(NotificationLevel.mentions),
          activeColor: hollow.warning,
        ),
        const SizedBox(width: HollowSpacing.sm),
        _LevelChip(
          label: 'Nothing',
          icon: LucideIcons.bellOff,
          isSelected: value == NotificationLevel.nothing,
          onTap: () => onChanged(NotificationLevel.nothing),
          activeColor: hollow.error,
        ),
      ],
    );
  }
}

/// A single level chip (selectable pill).
class _LevelChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  final Color? activeColor;

  const _LevelChip({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = activeColor ?? hollow.accent;

    return HollowFocusRing(
      enabled: true,
      onActivate: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: isSelected
                  ? color.withValues(alpha: 0.15)
                  : hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(
                color: isSelected ? color : hollow.border,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: isSelected ? color : hollow.textSecondary,
                ),
                const SizedBox(width: HollowSpacing.xs),
                Text(
                  label,
                  style: HollowTypography.body.copyWith(
                    color: isSelected ? color : hollow.textSecondary,
                    fontSize: 12,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Per-channel override selector — Hollow-styled PopupMenuButton.
class _ChannelOverrideDropdown extends StatelessWidget {
  final ChannelNotificationLevel value;
  final ValueChanged<ChannelNotificationLevel> onChanged;

  const _ChannelOverrideDropdown({
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
    final hollow = HollowTheme.of(context);
    final currentLabel =
        _options.firstWhere((o) => o.$1 == value).$2;

    return PopupMenuButton<ChannelNotificationLevel>(
      onSelected: onChanged,
      color: hollow.elevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        side: BorderSide(color: hollow.border),
      ),
      offset: const Offset(0, 32),
      itemBuilder: (context) => _options.map((option) {
        final isActive = option.$1 == value;
        return PopupMenuItem(
          value: option.$1,
          child: Row(
            children: [
              Icon(
                option.$3,
                size: 14,
                color: isActive ? hollow.accent : hollow.textSecondary,
              ),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                option.$2,
                style: HollowTypography.body.copyWith(
                  color: isActive ? hollow.accent : hollow.textPrimary,
                  fontWeight:
                      isActive ? FontWeight.w600 : FontWeight.w400,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm + 2,
          vertical: HollowSpacing.xs + 2,
        ),
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: hollow.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              currentLabel,
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Icon(
              LucideIcons.chevronDown,
              size: 12,
              color: hollow.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
