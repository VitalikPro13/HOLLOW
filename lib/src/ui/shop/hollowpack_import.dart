import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Importing a `.hollowpack`: the pickers, the drop handler's back end, and
/// the "here is what you got, want to wear it" dialog.
///
/// The pack is what makes a support mark light up later: its bytes are the
/// shop-PROCESSED bytes, and the credential names the hash of exactly those.
/// Rust verifies caps, hashes, dimensions and centre on the way in and never
/// re-encodes, so nothing here touches the art itself.

/// Whether [path] names a pack. Case-insensitive: Windows hands back whatever
/// case the file was saved with.
bool looksLikeHollowpack(String path) =>
    path.toLowerCase().endsWith('.hollowpack');

/// Ask for a pack, then import it.
Future<void> pickAndImportHollowpack(
    BuildContext context, WidgetRef ref) async {
  final mobile = Platform.isAndroid || Platform.isIOS;
  final result = await FilePicker.platform.pickFiles(
    // Custom extensions are unreliable on Android and iOS (the system picker
    // maps them through MIME types it does not know), so mobile asks for any
    // file and the name check below is the gate.
    type: mobile ? FileType.any : FileType.custom,
    allowedExtensions: mobile ? null : ['hollowpack'],
    dialogTitle: 'Import a .hollowpack',
  );
  if (result == null || result.files.isEmpty) return;
  final path = result.files.first.path;
  if (path == null || path.isEmpty) return;
  if (!context.mounted) return;
  await importHollowpackAt(context, ref, path);
}

/// Import the pack at [path], then show what it landed.
Future<void> importHollowpackAt(
  BuildContext context,
  WidgetRef ref,
  String path,
) async {
  if (!looksLikeHollowpack(path)) {
    HollowToast.show(context, 'That is not a .hollowpack file',
        type: HollowToastType.error);
    return;
  }

  network_api.HollowpackImport imported;
  try {
    imported = await network_api.importHollowpack(path: path);
  } catch (e) {
    if (!context.mounted) return;
    // The Rust errors are the user's business: a bad signature, a file over
    // the cap, a hash that does not match its bytes.
    final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
    await showHollowDialog<void>(
      context: context,
      builder: (dialogContext) => HollowDialog(
        title: 'That pack could not be imported',
        content: Text(
          message,
          style: HollowTypography.body
              .copyWith(color: HollowTheme.of(dialogContext).textSecondary),
        ),
        actions: [
          HollowButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }

  await ref.read(ownedArtProvider.notifier).reload();
  if (!context.mounted) return;
  await showImportedPackDialog(context, ref, imported);
}

/// What the pack contained, and one button per wearable kind.
Future<void> showImportedPackDialog(
  BuildContext context,
  WidgetRef ref,
  network_api.HollowpackImport result,
) {
  return showHollowDialog<void>(
    context: context,
    builder: (_) => _ImportedPackDialog(result: result),
  );
}

class _ImportedPackDialog extends ConsumerStatefulWidget {
  final network_api.HollowpackImport result;

  const _ImportedPackDialog({required this.result});

  @override
  ConsumerState<_ImportedPackDialog> createState() =>
      _ImportedPackDialogState();
}

class _ImportedPackDialogState extends ConsumerState<_ImportedPackDialog> {
  /// Which button is mid-save, so only that one shows a spinner.
  String? _busyKey;

  Future<void> _wear(String key, Set<String> kinds) async {
    final item = ref
        .read(ownedArtProvider)
        .where((i) => i.itemId == widget.result.itemId)
        .firstOrNull;
    if (item == null) {
      HollowToast.show(context, 'That item is no longer in your library',
          type: HollowToastType.error);
      return;
    }
    setState(() => _busyKey = key);
    try {
      await ref.read(ownedArtProvider.notifier).wear(item, kinds);
      if (!mounted) return;
      HollowToast.show(context, 'Wearing ${item.title}',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
      HollowToast.show(context, message, type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Widget _wearButton({
    required String key,
    required String label,
    required Set<String> kinds,
    required bool filled,
    required HollowTheme hollow,
  }) {
    final busy = _busyKey == key;
    final icon = busy
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: hollow.textSecondary,
            ),
          )
        : null;
    final onPressed = _busyKey == null ? () => _wear(key, kinds) : null;
    final child = Text(label);
    return filled
        ? HollowButton.filled(onPressed: onPressed, icon: icon, child: child)
        : HollowButton.outline(onPressed: onPressed, icon: icon, child: child);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final result = widget.result;

    final item = ref
        .watch(ownedArtProvider)
        .where((i) => i.itemId == result.itemId)
        .firstOrNull;
    final kinds = item?.kinds ?? const <String>[];

    return HollowDialog(
      title: 'Imported',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            result.title,
            style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'by ${result.artistName}',
            style:
                HollowTypography.caption.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.md),
          for (final file in result.files)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
              child: Row(
                children: [
                  _ImportedFilePreview(file: file),
                  const SizedBox(width: HollowSpacing.md),
                  Expanded(
                    child: Text(
                      '${ownedRoleLabel(file.role)}  ${file.w}x${file.h}'
                      '${file.animated ? '  animated' : ''}',
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          if (result.license.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.md),
            Text(
              result.license,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary, fontSize: 11),
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed:
              _busyKey == null ? () => Navigator.of(context).pop() : null,
          child: const Text('Done'),
        ),
        for (final kind in kinds)
          _wearButton(
            key: kind,
            label: wearKindLabel(kind),
            kinds: {kind},
            // With more than one kind, "Wear all" is the primary action and
            // the per-kind buttons step back to outline.
            filled: kinds.length == 1,
            hollow: hollow,
          ),
        if (kinds.length >= 2)
          _wearButton(
            key: 'all',
            label: 'Wear all',
            kinds: kinds.toSet(),
            filled: true,
            hollow: hollow,
          ),
      ],
    );
  }
}

/// What one imported file looks like, read back off the rail it just landed
/// on: a frame in front of your own face, an avatar as your face, a banner
/// as its strip. Animated files play here; this is the one place the buyer
/// is looking at exactly what they bought.
class _ImportedFilePreview extends ConsumerWidget {
  final network_api.HollowpackFile file;

  const _ImportedFilePreview({required this.file});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';
    const height = 48.0;
    final isBanner = file.role.startsWith('banner');
    final width = isBanner ? height * 2.5 : height;

    Widget box(Widget? child) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
          ),
          alignment: Alignment.center,
          child: child,
        );

    if (file.role == 'frame') {
      // The frame provider reads the rail itself; the bytes are already
      // there because the import just stored them.
      return box(HollowAvatar(
        peerId: me,
        size: height * 0.72,
        frameId: file.hash,
        animate: true,
      ));
    }

    final bytes = ref.watch(railBytesProvider(file.hash)).valueOrNull;
    if (bytes == null || bytes.isEmpty) return box(null);
    if (isBanner) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        child: SizedBox(
          width: width,
          height: height,
          child: AnimatedGifImage(
            bytes: bytes,
            fit: BoxFit.cover,
            animate: file.animated,
          ),
        ),
      );
    }
    return box(HollowAvatar(
      peerId: me,
      size: height,
      imageBytes: bytes,
      frameId: '',
      animate: file.animated,
    ));
  }
}
