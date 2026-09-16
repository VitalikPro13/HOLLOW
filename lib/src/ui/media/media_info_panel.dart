import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/media/media_item.dart';

/// Everything the app knows about one item, including the content hash that
/// makes it citable.
class MediaInfoPanel extends ConsumerWidget {
  final MediaItem item;
  final VoidCallback? onJumpToMessage;
  final VoidCallback onClose;

  /// Desktop hangs this off the side at a fixed width; mobile puts it at the
  /// bottom over the full width.
  final bool isSidePanel;

  const MediaInfoPanel({
    super.key,
    required this.item,
    required this.onClose,
    this.onJumpToMessage,
    this.isSidePanel = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final attachment = item.attachment;
    final sender = item.senderId;
    final master =
        sender == null ? null : ref.watch(deviceLinkProvider).identityOf(sender);
    final senderName = master == null
        ? null
        : displayNameFor(ref.watch(profileProvider), master);
    final size = item.pixelSize;
    final ts = item.timestampMs;

    return Container(
      width: isSidePanel ? 300 : double.infinity,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          left: isSidePanel
              ? BorderSide(color: hollow.border)
              : BorderSide.none,
          top: isSidePanel ? BorderSide.none : BorderSide(color: hollow.border),
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(HollowSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Details',
                    style: HollowTypography.subheading
                        .copyWith(color: hollow.textPrimary, fontSize: 14),
                  ),
                ),
                HollowPressable(
                  onTap: onClose,
                  semanticLabel: 'Close details',
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xxs),
                  child: Icon(LucideIcons.x,
                      size: 16, color: hollow.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.md),
            _Row(label: 'Name', value: attachment.fileName),
            if (size != null)
              _Row(
                label: 'Dimensions',
                value: '${size.width.round()} x ${size.height.round()}',
              ),
            _Row(label: 'Size', value: attachment.formattedSize),
            if (senderName != null) _Row(label: 'Sent by', value: senderName),
            if (ts != null) _Row(label: 'Time', value: _formatTime(ts)),
            if (item.contentId != null)
              _HashRow(hash: item.contentId!, hollow: hollow),
            if (attachment.diskPath != null &&
                AtRest.isManaged(attachment.diskPath!)) ...[
              const SizedBox(height: HollowSpacing.sm),
              Text(
                'Encrypted on this device',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary),
              ),
            ],
            if (onJumpToMessage != null) ...[
              const SizedBox(height: HollowSpacing.lg),
              HollowButton.outline(
                onPressed: onJumpToMessage,
                expand: true,
                child: const Text('Jump to message'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatTime(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: HollowTypography.caption
                .copyWith(color: hollow.textTertiary, fontSize: 10),
          ),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: HollowTypography.body
                .copyWith(color: hollow.textPrimary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _HashRow extends StatelessWidget {
  final String hash;
  final HollowTheme hollow;

  const _HashRow({required this.hash, required this.hollow});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Content hash',
            style: HollowTypography.caption
                .copyWith(color: hollow.textTertiary, fontSize: 10),
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  hash,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.mono
                      .copyWith(color: hollow.textSecondary, fontSize: 10),
                ),
              ),
              HollowTooltip(
                message: 'Copy hash',
                child: HollowPressable(
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: hash));
                    if (context.mounted) {
                      HollowToast.show(context, 'Hash copied',
                          type: HollowToastType.success);
                    }
                  },
                  semanticLabel: 'Copy content hash',
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  padding: const EdgeInsets.all(HollowSpacing.xxs),
                  child: Icon(LucideIcons.copy,
                      size: 14, color: hollow.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
