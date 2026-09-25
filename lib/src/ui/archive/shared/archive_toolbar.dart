import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/shared/archive_sender_filter.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart' show ChatHeaderBar;
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// "3 messages", or "3 of 12 messages" while a sender filter narrows the list.
String archiveCountLabel(int shown, {int? total}) {
  final noun = (total ?? shown) == 1 ? 'message' : 'messages';
  return total != null ? '$shown of $total $noun' : '$shown $noun';
}

/// Desktop archive header, shared by the My Data viewer and the imported-archive
/// viewer, which has no export button. The chat header, so a read-back
/// conversation looks like the live one.
class ArchiveToolbar extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final int? messageCount;
  final int? totalMessageCount;
  final VoidCallback? onExport;
  final VoidCallback? onJumpToDate;
  final VoidCallback? onToggleSearch;
  final bool searchOpen;

  /// Beside "Read only", such as an imported archive's signature verdict.
  final List<Widget> badges;

  /// Filter controls (channel only).
  final List<String>? senderIds;
  final String? selectedSender;
  final ValueChanged<String?>? onSenderFilterChanged;
  final Map<String, String>? senderDisplayNames;

  const ArchiveToolbar({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.messageCount,
    this.totalMessageCount,
    this.onExport,
    this.onJumpToDate,
    this.onToggleSearch,
    this.searchOpen = false,
    this.badges = const [],
    this.senderIds,
    this.selectedSender,
    this.onSenderFilterChanged,
    this.senderDisplayNames,
  });

  @override
  Widget build(BuildContext context) {
    final count = messageCount == null
        ? null
        : archiveCountLabel(messageCount!,
            total: selectedSender != null ? totalMessageCount : null);
    return ChatHeaderBar(
      leading: leading,
      title: title,
      subtitle: [?subtitle, ?count].join(' · '),
      badges: [const HollowBadge('Read only'), ...badges],
      actions: [
        if (senderIds != null && senderIds!.length > 1)
          ArchiveFilterButton(
            senderIds: senderIds!,
            selectedSender: selectedSender,
            senderDisplayNames: senderDisplayNames ?? const {},
            onSenderFilterChanged: onSenderFilterChanged,
          ),
        if (onJumpToDate != null)
          HollowIconButton(
            icon: LucideIcons.calendar,
            label: 'Jump to date',
            onPressed: onJumpToDate,
          ),
        if (onToggleSearch != null)
          HollowIconButton(
            icon: LucideIcons.search,
            label: 'Search messages',
            selected: searchOpen,
            onPressed: onToggleSearch,
          ),
        if (onExport != null)
          HollowIconButton(
            icon: LucideIcons.fileOutput,
            label: 'Export conversation',
            onPressed: onExport,
          ),
      ],
    );
  }
}

/// Mobile archive header, shared by the My Data viewer route and the
/// imported-archive viewer route.
class ArchiveMobileToolbar extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final bool searchOpen;
  final VoidCallback onBack;
  final VoidCallback? onToggleSearch;
  final VoidCallback? onFilter;
  final bool filterActive;
  final VoidCallback? onJumpToDate;
  final VoidCallback? onExport;

  const ArchiveMobileToolbar({
    super.key,
    required this.leading,
    required this.title,
    required this.onBack,
    this.subtitle,
    this.searchOpen = false,
    this.onToggleSearch,
    this.onFilter,
    this.filterActive = false,
    this.onJumpToDate,
    this.onExport,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    const touch = 44.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          HollowIconButton(
            icon: LucideIcons.chevronLeft,
            label: 'Back',
            size: touch,
            onPressed: onBack,
          ),
          leading,
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle == null ? 'Read only' : '$subtitle · Read only',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onFilter != null)
            HollowIconButton(
              icon: LucideIcons.filter,
              label: 'Filter by sender',
              size: touch,
              selected: filterActive,
              onPressed: onFilter,
            ),
          if (onJumpToDate != null)
            HollowIconButton(
              icon: LucideIcons.calendar,
              label: 'Jump to date',
              size: touch,
              onPressed: onJumpToDate,
            ),
          if (onToggleSearch != null)
            HollowIconButton(
              icon: LucideIcons.search,
              label: 'Search messages',
              size: touch,
              selected: searchOpen,
              onPressed: onToggleSearch,
            ),
          if (onExport != null)
            HollowIconButton(
              icon: LucideIcons.fileOutput,
              label: 'Export conversation',
              size: touch,
              onPressed: onExport,
            ),
        ],
      ),
    );
  }
}
