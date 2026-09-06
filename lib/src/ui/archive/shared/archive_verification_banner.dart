import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Two-row signature status banner for imported archives: the archive-level
/// signature and the per-message ones. Strings come from
/// `prepareImportedArchive`, and [dense] is the mobile sizing.
class ArchiveVerificationBanner extends StatelessWidget {
  final bool archiveSigValid;
  final String archiveSigText;
  final bool msgSigWarning;
  final String msgSigText;
  final bool dense;

  const ArchiveVerificationBanner({
    super.key,
    required this.archiveSigValid,
    required this.archiveSigText,
    required this.msgSigWarning,
    required this.msgSigText,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final archiveColor = archiveSigValid ? hollow.accent : hollow.error;
    final archiveIcon =
        archiveSigValid ? LucideIcons.shieldCheck : LucideIcons.shieldOff;
    final msgColor = msgSigWarning ? Colors.amber.shade700 : hollow.accent;
    final msgIcon =
        msgSigWarning ? LucideIcons.alertTriangle : LucideIcons.shieldCheck;
    final iconSize = dense ? 13.0 : 14.0;

    return Container(
      padding: dense
          ? const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md, vertical: 8)
          : const EdgeInsets.symmetric(
              horizontal: HollowSpacing.lg, vertical: 10),
      decoration: BoxDecoration(
        color: archiveColor.withValues(alpha: 0.08),
        border: Border(
            bottom: BorderSide(color: hollow.border.withValues(alpha: 0.3))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(archiveIcon, size: iconSize, color: archiveColor),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  archiveSigText,
                  style: HollowTypography.caption.copyWith(
                    color: archiveColor,
                    fontWeight: FontWeight.w600,
                    fontSize: dense ? 11 : 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: dense ? 3 : 4),
          Row(
            children: [
              Icon(msgIcon, size: iconSize, color: msgColor),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  msgSigText,
                  style: HollowTypography.caption.copyWith(
                    color: msgColor,
                    fontSize: dense ? 10 : 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Horizontal chip row for switching channels in a server archive. Callers
/// reset the filter and search providers in [onChannelSelected].
class ArchiveChannelSelector extends StatelessWidget {
  final List<archive_api.ArchiveChannelInfoFfi> channels;
  final String? activeChannelId;
  final ValueChanged<String> onChannelSelected;

  const ArchiveChannelSelector({
    super.key,
    required this.channels,
    required this.activeChannelId,
    required this.onChannelSelected,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      // Past a handful of channels the strip overflows with no way to reach
      // the rest on a wheel mouse.
      child: EdgeScrollRow(
        semanticLabel: 'channels',
        children: channels.map((ch) {
          final isActive = ch.channelId == activeChannelId;
          return Padding(
            padding: const EdgeInsets.only(right: HollowSpacing.xs),
            child: Center(
              child: HollowPressable(
                onTap: () => onChannelSelected(ch.channelId),
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Container(
                  decoration: BoxDecoration(
                    color: isActive
                        ? hollow.accent.withValues(alpha: 0.15)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    border: Border.all(
                      color: isActive
                          ? hollow.accent.withValues(alpha: 0.3)
                          : hollow.border,
                    ),
                  ),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    '# ${ch.channelName}',
                    style: HollowTypography.caption.copyWith(
                      color:
                          isActive ? hollow.accent : hollow.textSecondary,
                      fontWeight:
                          isActive ? FontWeight.w600 : FontWeight.normal,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
