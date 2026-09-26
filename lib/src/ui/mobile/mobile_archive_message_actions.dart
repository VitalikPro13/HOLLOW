import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/services/at_rest.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

bool _picking = false;

/// Saves an archived file on a phone. The platform save sheet takes the BYTES
/// (there is no path to copy to), and a WebP image leaves as a PNG.
Future<void> saveArchivedAttachmentMobile(
    BuildContext context, FileAttachment attachment) async {
  if (_picking || attachment.diskPath == null) return;
  _picking = true;
  try {
    final asPng = attachment.isImage && attachment.fileExt == 'webp';
    final Uint8List bytes = asPng
        ? await network_api.convertImageFormat(
            sourcePath: attachment.diskPath!, targetFormat: 'png')
        : await AtRest.read(attachment.diskPath!);
    final name = attachment.fileName;
    final base =
        name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;

    final saved = await FilePicker.platform.saveFile(
      dialogTitle: 'Save file',
      fileName: asPng ? '$base.png' : name,
      bytes: bytes,
    );
    if (saved != null && context.mounted) {
      HollowToast.show(context, 'File saved', type: HollowToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, friendlyError(e, fallback: "Couldn't save the file. Try again."),
          type: HollowToastType.error);
    }
  } finally {
    _picking = false;
  }
}

/// The long-press sheet on an archived message: who and when, a line of the
/// text, then what can be done with a read-only message.
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

    Widget action(IconData icon, String label, VoidCallback onTap) =>
        HollowListRow(
          touch: true,
          title: label,
          leading: Icon(icon, size: 20, color: hollow.textSecondary),
          onTap: () {
            Navigator.pop(context);
            onTap();
          },
        );

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
                left: HollowSpacing.lg,
                right: HollowSpacing.lg,
                bottom: HollowSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        senderName,
                        style: HollowTypography.label
                            .copyWith(color: hollow.textPrimary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    Text(
                      timestamp,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textTertiary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (messageText.isNotEmpty)
                  Text(
                    messageText,
                    style: HollowTypography.body
                        .copyWith(color: hollow.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (onCopy != null) action(LucideIcons.copy, 'Copy text', onCopy!),
          if (onDownload != null)
            action(LucideIcons.download, 'Save file', onDownload!),
          if (onInfo != null)
            action(LucideIcons.shieldCheck, 'Signature details', onInfo!),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
  }
}
