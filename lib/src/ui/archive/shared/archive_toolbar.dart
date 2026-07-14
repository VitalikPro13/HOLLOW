import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/archive/shared/archive_sender_filter.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// ── Desktop toolbar ─────────────────────────────────────────────

/// Desktop archive header: leading + title/subtitle, message count,
/// sender filter, jump-to-date, search, optional export, read-only badge.
/// Used by both the My Data viewer and the imported-archive viewer
/// (imported = no export button).
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
  /// Filter controls (channel only).
  final List<String>? senderIds;
  final String? selectedSender;
  final ValueChanged<String?>? onSenderFilterChanged;
  final Map<String, String>? senderDisplayNames;
  final Map<String, dynamic>? senderAvatars;

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
    this.senderIds,
    this.selectedSender,
    this.onSenderFilterChanged,
    this.senderDisplayNames,
    this.senderAvatars,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final countText = selectedSender != null && totalMessageCount != null
        ? '$messageCount of $totalMessageCount'
        : '${messageCount ?? 0}';

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: subtitle != null
                ? Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: title,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      TextSpan(
                        text: '  $subtitle',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : Text(
                    title,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if (messageCount != null)
            // NOT Flexible: a second flex child would split the row's free
            // space with the title's Expanded and leave a dead gap on the
            // right. The title Expanded owns all slack; the count + trailing
            // controls hug the right edge. Counts are short/bounded.
            Text(
              '$countText messages',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
          // Peer filter (channel archives only).
          if (senderIds != null && senderIds!.length > 1) ...[
            const SizedBox(width: HollowSpacing.xs),
            ArchiveFilterButton(
              senderIds: senderIds!,
              selectedSender: selectedSender,
              senderDisplayNames: senderDisplayNames ?? {},
              senderAvatars: senderAvatars ?? {},
              onSenderFilterChanged: onSenderFilterChanged,
            ),
          ],
          if (onJumpToDate != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onJumpToDate,
              semanticLabel: 'Jump to date',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.calendar,
                  size: 16, color: hollow.textSecondary),
            ),
          ],
          if (onToggleSearch != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onToggleSearch,
              semanticLabel: 'Search messages',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.search,
                  size: 16,
                  color: searchOpen
                      ? hollow.accent
                      : hollow.textSecondary),
            ),
          ],
          if (onExport != null) ...[
            const SizedBox(width: HollowSpacing.xs),
            HollowPressable(
              onTap: onExport,
              semanticLabel: 'Export conversation',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.fileOutput,
                  size: 16, color: hollow.accent),
            ),
          ],
          const SizedBox(width: HollowSpacing.sm),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: Text(
              'read-only',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Mobile toolbar ──────────────────────────────────────────────

/// Mobile archive header: back button, leading + two-line title, filter,
/// jump-to-date, search, optional export, read-only badge. Used by both
/// the My Data viewer route and the imported-archive viewer route.
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

    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.xs, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        children: [
          HollowPressable(
            onTap: onBack,
            semanticLabel: 'Back',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(8),
            child: Icon(LucideIcons.chevronLeft,
                size: 20, color: hollow.textPrimary),
          ),
          leading,
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: subtitle != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        subtitle!,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  )
                : Text(
                    title,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
          if (onFilter != null)
            HollowPressable(
              onTap: onFilter,
              semanticLabel: 'Filter by sender',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.filter,
                  size: 16,
                  color: filterActive
                      ? hollow.accent
                      : hollow.textSecondary),
            ),
          if (onJumpToDate != null)
            HollowPressable(
              onTap: onJumpToDate,
              semanticLabel: 'Jump to date',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.calendar,
                  size: 16, color: hollow.textSecondary),
            ),
          if (onToggleSearch != null)
            HollowPressable(
              onTap: onToggleSearch,
              semanticLabel: 'Search messages',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.search,
                  size: 16,
                  color: searchOpen
                      ? hollow.accent
                      : hollow.textSecondary),
            ),
          if (onExport != null)
            HollowPressable(
              onTap: onExport,
              semanticLabel: 'Export conversation',
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(6),
              child: Icon(LucideIcons.fileOutput,
                  size: 16, color: hollow.accent),
            ),
          Container(
            margin: const EdgeInsets.only(left: 4, right: 4),
            padding:
                const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: Text(
              'read-only',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 9,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
