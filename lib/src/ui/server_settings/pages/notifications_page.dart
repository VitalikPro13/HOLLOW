import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/settings/channel_override_dropdown.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// What one server may notify you about, and per channel where a channel
/// should differ. Everything applies at once.
class ServerNotificationsPage extends ConsumerWidget {
  final String serverId;
  const ServerNotificationsPage({super.key, required this.serverId});

  static String _describe(NotificationLevel level) => switch (level) {
        NotificationLevel.all => 'Every message in the channels you can see',
        NotificationLevel.mentions =>
          'Only when someone mentions you, or @everyone',
        NotificationLevel.nothing => 'Nothing, not even a mention',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final state = ref.watch(notificationSettingsProvider);
    final notifier = ref.read(notificationSettingsProvider.notifier);
    final level = state.serverLevels[serverId] ?? NotificationLevel.all;
    final serverName = ref.watch(serverListProvider)[serverId]?.name ?? 'This server';
    // Only channels you can see: naming a restricted one would leak it.
    final all = ref.watch(serverChannelsProvider(serverId)).valueOrNull ?? {};
    final channels = [
      for (final c in all.values)
        if (c.meCanSee) c,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return SettingsPage(
      title: 'Notifications',
      children: [
        SettingsChoiceRow<NotificationLevel>(
          title: serverName,
          subtitle: _describe(level),
          value: level,
          options: const [
            (NotificationLevel.all, 'All messages'),
            (NotificationLevel.mentions, 'Mentions only'),
            (NotificationLevel.nothing, 'Nothing'),
          ],
          onChanged: (l) => notifier.setServerLevel(serverId, l),
        ),
        SettingsSection(
          title: 'Channels',
          subtitle: "A channel set here ignores the server's choice",
          children: [
            if (channels.isEmpty)
              const HollowEmptyState(dense: true, title: 'No channels yet')
            else
              for (final c in channels)
                SettingsRow(
                  key: ValueKey(c.channelId),
                  title: c.name,
                  leading: Icon(
                    c.channelType == ChannelType.voice
                        ? LucideIcons.volume2
                        : LucideIcons.hash,
                    size: 16,
                    color: hollow.textSecondary,
                  ),
                  trailing: ChannelOverrideDropdown(
                    value: notifier.channelOverride(serverId, c.channelId),
                    onChanged: (l) =>
                        notifier.setChannelOverride(serverId, c.channelId, l),
                  ),
                ),
            if (!touch) ...[
              const SizedBox(height: HollowSpacing.md),
              Text.rich(
                TextSpan(
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                  children: [
                    const TextSpan(text: 'Every server at once lives in '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: HollowTextLink(
                        'Settings, Notifications',
                        onTap: () => openSettings(ref.read,
                            category: SettingsCategory.notifications),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
