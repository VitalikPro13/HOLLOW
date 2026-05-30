import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
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
  final hollow = HollowTheme.of(context);
  showModalBottomSheet(
    context: context,
    backgroundColor: hollow.surface,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
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

class _ArchiveActionsSheet extends StatefulWidget {
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
  State<_ArchiveActionsSheet> createState() => _ArchiveActionsSheetState();
}

class _ArchiveActionsSheetState extends State<_ArchiveActionsSheet>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _stagger(int index, {required Widget child}) {
    final start = (index * 0.15).clamp(0.0, 0.6);
    final end = (start + 0.5).clamp(0.0, 1.0);
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(start, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    final actions = <Widget>[];
    int actionIndex = 1;
    if (widget.onCopy != null) {
      actions.add(_stagger(actionIndex++, child: _ActionRow(
        icon: LucideIcons.copy,
        label: 'Copy Text',
        onTap: () {
          Navigator.pop(context);
          widget.onCopy!();
        },
      )));
    }
    if (widget.onDownload != null) {
      actions.add(_stagger(actionIndex++, child: _ActionRow(
        icon: LucideIcons.download,
        label: 'Save File',
        onTap: () {
          Navigator.pop(context);
          widget.onDownload!();
        },
      )));
    }
    if (widget.onInfo != null) {
      actions.add(_stagger(actionIndex, child: _ActionRow(
        icon: LucideIcons.shieldCheck,
        label: 'Message Info',
        onTap: () {
          Navigator.pop(context);
          widget.onInfo!();
        },
      )));
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.sm),
            child: Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: hollow.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),

          _stagger(0, child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(HollowSpacing.sm),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
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
                          widget.senderName,
                          style: HollowTypography.caption.copyWith(
                            color: hollow.accent,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        widget.timestamp,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                  if (widget.messageText.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      widget.messageText,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          )),
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
