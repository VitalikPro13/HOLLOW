import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void showMobileArchiveMessageActions({
  required BuildContext context,
  required String messageText,
  required String senderName,
  required String timestamp,
  VoidCallback? onCopy,
  VoidCallback? onDownload,
  VoidCallback? onInfo,
}) {
  showHollowSheet(
    context: context,
    builder: (_) => _ArchiveActionsSheet(
      messageText: messageText,
      senderName: senderName,
      timestamp: timestamp,
      onCopy: onCopy,
      onDownload: onDownload,
      onInfo: onInfo,
    ),
  );
}

class _ArchiveActionsSheet extends StatelessWidget {
  final String messageText;
  final String senderName;
  final String timestamp;
  final VoidCallback? onCopy;
  final VoidCallback? onDownload;
  final VoidCallback? onInfo;

  const _ArchiveActionsSheet({
    required this.messageText,
    required this.senderName,
    required this.timestamp,
    this.onCopy,
    this.onDownload,
    this.onInfo,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final actions = <Widget>[];
    if (onCopy != null) {
      actions.add(_ActionRow(
        icon: LucideIcons.copy,
        label: 'Copy text',
        onTap: () {
          Navigator.pop(context);
          onCopy!();
        },
      ));
    }
    if (onDownload != null) {
      actions.add(_ActionRow(
        icon: LucideIcons.download,
        label: 'Save file',
        onTap: () {
          Navigator.pop(context);
          onDownload!();
        },
      ));
    }
    if (onInfo != null) {
      actions.add(_ActionRow(
        icon: LucideIcons.shieldCheck,
        label: 'Message proof',
        onTap: () {
          Navigator.pop(context);
          onInfo!();
        },
      ));
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(HollowSpacing.sm),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          senderName,
                          style: HollowTypography.caption.copyWith(
                            color: hollow.accent,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        timestamp,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                  if (messageText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      messageText,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.md),

          ...actions,

          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg,
          vertical: HollowSpacing.sm + 2,
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: hollow.textPrimary),
            const SizedBox(width: HollowSpacing.md),
            Text(label,
                style: HollowTypography.body
                    .copyWith(color: hollow.textPrimary)),
          ],
        ),
      ),
    );
  }
}
