import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/download_manager_provider.dart';
import 'package:hollow/src/core/services/attachment_export.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

bool _picking = false;

/// Saves an archived file through the OS save dialog, converting a WebP image
/// when the chosen name asks for another format. One pick at a time: a second
/// click while the native dialog is up would open another.
Future<void> saveArchivedAttachment(
    BuildContext context, WidgetRef ref, FileAttachment attachment) async {
  if (_picking) return;
  _picking = true;
  try {
    final isImage = attachment.isImage;
    final isGif = attachment.fileExt.toLowerCase() == 'gif';
    final baseName = attachment.fileName.contains('.')
        ? attachment.fileName
            .substring(0, attachment.fileName.lastIndexOf('.'))
        : attachment.fileName;
    final savePath = await FilePicker.platform.saveFile(
      dialogTitle: 'Save file',
      fileName: isImage
          ? (isGif ? '$baseName.gif' : '$baseName.png')
          : attachment.fileName,
      type: FileType.custom,
      allowedExtensions:
          isImage ? ['png', 'jpg', 'jpeg', 'webp', 'gif'] : [attachment.fileExt],
    );
    if (savePath == null || attachment.diskPath == null) return;

    final targetExt = savePath.contains('.')
        ? savePath.split('.').last.toLowerCase()
        : attachment.fileExt;
    if (isImage && targetExt != 'webp' && attachment.fileExt == 'webp') {
      final converted = await network_api.convertImageFormat(
        sourcePath: attachment.diskPath!,
        targetFormat: targetExt,
      );
      await File(savePath).writeAsBytes(converted);
    } else {
      await exportAttachmentTo(attachment.diskPath!, savePath);
    }

    ref.read(downloadManagerStateProvider.notifier).recordSavedFile(
          savedPath: savePath,
          isImage: isImage,
          isVideo: attachment.videoThumb != null,
        );
    if (context.mounted) {
      HollowToast.show(context, exportedCopyMessage(savePath),
          type: HollowToastType.success);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, "Couldn't save the file: $e",
          type: HollowToastType.error);
    }
  } finally {
    _picking = false;
  }
}

/// The date picker behind "Jump to date", in the app's current theme.
Future<DateTime?> pickArchiveDate(
  BuildContext context, {
  required DateTime first,
  required DateTime last,
}) {
  final hollow = HollowTheme.of(context);
  final base = Theme.of(context);
  final scheme = base.colorScheme.copyWith(
    primary: hollow.accent,
    onPrimary: hollow.textOnAccent,
    surface: hollow.overlay,
    onSurface: hollow.textPrimary,
  );
  return showDatePicker(
    context: context,
    initialDate: last,
    firstDate: first,
    lastDate: last,
    builder: (context, child) => Theme(
      data: base.copyWith(
        colorScheme: scheme,
        dialogTheme: base.dialogTheme.copyWith(backgroundColor: hollow.overlay),
      ),
      child: child!,
    ),
  );
}

/// The read-only hover bar every desktop archive message gets: save the file,
/// copy the text or the image, and the signature details.
Widget archiveHoverActions({
  required BuildContext context,
  required WidgetRef ref,
  required bool isMe,
  required String? messageId,
  required String text,
  required FileAttachment? attachment,
  required VoidCallback onInfo,
  required Widget child,
}) {
  final onDisk = attachment?.diskPath != null;
  return MessageHoverWrapper(
    isMe: isMe,
    messageId: messageId,
    currentText: text,
    onDownload: onDisk
        ? () => saveArchivedAttachment(context, ref, attachment!)
        : null,
    onCopy: text.isNotEmpty && !text.startsWith('[file:')
        ? () {
            Clipboard.setData(ClipboardData(text: text));
            HollowToast.show(context, 'Copied to clipboard',
                type: HollowToastType.success);
          }
        : null,
    onCopyImage: onDisk && attachment!.isImage
        ? () async {
            final ok = await copyImageToClipboard(attachment.diskPath!);
            if (context.mounted) {
              HollowToast.show(
                context,
                ok ? 'Image copied to clipboard' : "Couldn't copy the image",
                type: ok ? HollowToastType.success : HollowToastType.error,
              );
            }
          }
        : null,
    onInfo: onInfo,
    child: child,
  );
}
