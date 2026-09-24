import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A channel's own notification level, overriding its server's. Shared by a
/// server's Notifications page and Settings > Notifications.
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
