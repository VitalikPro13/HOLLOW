import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/archive.dart' as archive_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// An imported archive's signature verdict as one badge for the viewer's
/// header. The banner under it spells out who signed it and what checked out.
Widget archiveVerdictBadge({
  required bool archiveSigValid,
  required String archiveSigText,
  required bool msgSigWarning,
  required String msgSigText,
}) {
  final (label, kind, icon) = !archiveSigValid
      ? ('Signature invalid', HollowBadgeKind.error, LucideIcons.shieldOff)
      : msgSigWarning
          ? ('Partly verified', HollowBadgeKind.warning, LucideIcons.shieldAlert)
          : ('Verified', HollowBadgeKind.success, LucideIcons.shieldCheck);
  return HollowBadge(label, kind: kind, icon: icon);
}

/// The signature verdict spelled out above an imported archive. A problem gets
/// a warning strip; a clean archive gets one quiet line naming who signed it.
class ArchiveVerificationBanner extends StatelessWidget {
  final bool archiveSigValid;
  final String archiveSigText;
  final bool msgSigWarning;
  final String msgSigText;

  const ArchiveVerificationBanner({
    super.key,
    required this.archiveSigValid,
    required this.archiveSigText,
    required this.msgSigWarning,
    required this.msgSigText,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final problem = !archiveSigValid || msgSigWarning;

    final tone = !archiveSigValid
        ? hollow.error
        : (msgSigWarning ? hollow.warning : hollow.success);
    final icon = !archiveSigValid
        ? LucideIcons.shieldOff
        : (msgSigWarning ? LucideIcons.shieldAlert : LucideIcons.shieldCheck);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        color: problem ? hollow.noticeSurface(tone) : null,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              '$archiveSigText. $msgSigText.',
              style: HollowTypography.bodySmall.copyWith(
                  color: problem ? hollow.textPrimary : hollow.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Switches channels in an imported server archive. Callers reset the filter
/// and search providers in [onChannelSelected].
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
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      // Past a handful of channels the strip overflows with no way to reach
      // the rest on a wheel mouse.
      child: EdgeScrollRow(
        semanticLabel: 'channels',
        fadeColor: hollow.surface,
        children: [
          for (final ch in channels)
            Padding(
              padding: const EdgeInsets.only(right: HollowSpacing.sm),
              child: HollowChip(
                label: '# ${ch.channelName}',
                selected: ch.channelId == activeChannelId,
                onTap: () => onChannelSelected(ch.channelId),
              ),
            ),
        ],
      ),
    );
  }
}
