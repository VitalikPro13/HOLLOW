import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:hollow/src/core/friendly_error.dart';
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
/// shop-PROCESSED bytes and the credential names the hash of exactly those, so
/// Rust verifies on the way in and never re-encodes. Nothing here touches the
/// art itself.

/// Whether [path] names a pack, case-insensitively: Windows hands back whatever
/// case the file was saved with.
bool looksLikeHollowpack(String path) =>
    path.toLowerCase().endsWith('.hollowpack');

/// Ask for a pack, then import it.
Future<void> pickAndImportHollowpack(
    BuildContext context, WidgetRef ref) async {
  final mobile = Platform.isAndroid || Platform.isIOS;
  final result = await FilePicker.platform.pickFiles(
    // Custom extensions are unreliable on mobile, where the system picker maps
    // them through MIME types it does not know, so the name check is the gate.
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
    await showHollowDialog<void>(
      context: context,
      builder: (dialogContext) => HollowDialog(
        title: "Couldn't import that pack",
        content: HollowDialogText(hollowpackFailureSentence(e)),
        actions: [
          HollowButton.filled(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Got it'),
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

/// Why a pack was refused, as a sentence with a next step. Rust names the
/// exact check that failed; a person only needs to know what to do about it.
String hollowpackFailureSentence(Object error) {
  final raw = switch (error) {
    AnyhowException(:final message) => message,
    _ => error.toString(),
  };
  final lower = raw.toLowerCase();
  bool has(List<String> needles) => needles.any(lower.contains);
  if (has(['newer version'])) {
    return 'This pack was made by a newer version of Hollow. Update Hollow, '
        'then import it again.';
  }
  if (has(['to be real', 'claims', 'does not match', 'missing the file',
      'malformed', 'twice', 'animates', 'does not animate', 'has to be',
      'unreadable', 'zero dimensions', 'no frames', 'failed to decode',
      'carries no files', 'lists a file role'])) {
    return 'This pack is damaged or was changed after the shop made it. '
        'Download it again from where you bought it.';
  }
  if (has(['too large', 'over the', 'more than', 'at most'])) {
    return 'This pack is bigger than Hollow accepts. Ask the artist for a '
        'smaller one.';
  }
  if (has(['not a hollow art pack', 'not a valid art pack', 'not a webp',
      'manifest'])) {
    return "This file isn't a Hollow art pack, or it's damaged. Download it "
        'again from where you bought it.';
  }
  if (has(['failed to open the pack', 'failed to read the pack'])) {
    return "Hollow couldn't read that file. Check that it's still there and "
        'try again.';
  }
  return friendlyError(error,
      fallback: "Hollow couldn't import this pack. Download it again from "
          'where you bought it and try once more.');
}

/// What the pack contained, with the art ready to wear.
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

class _ImportedPackDialogState extends ConsumerState<_ImportedPackDialog>
    with HollowDialogAction {
  Future<void> _wear(Set<String> kinds) async {
    final worn = await runDialogAction(() async {
      final item = ref
          .read(ownedArtProvider)
          .where((i) => i.itemId == widget.result.itemId)
          .firstOrNull;
      if (item == null) {
        throw const FriendlyException(
            'That item is no longer in your library.');
      }
      await ref.read(ownedArtProvider.notifier).wear(item, kinds);
    });
    if (!worn || !mounted) return;
    final title = widget.result.title;
    final overlay = Overlay.of(context);
    Navigator.of(context).pop();
    HollowToast.show(context, 'Wearing $title',
        type: HollowToastType.success, overlayState: overlay);
  }

  static String _fileLabel(network_api.HollowpackFile file) {
    final role = ownedRoleLabel(file.role);
    // The animated slots already read "Animated avatar".
    return file.animated && !role.toLowerCase().contains('animated')
        ? '$role, animated'
        : role;
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
      title: '${result.title} is in your library',
      width: 420,
      // With nothing to wear there is nothing to confirm.
      showClose: kinds.isEmpty,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HollowDialogText('By ${result.artistName}.'),
          const SizedBox(height: HollowSpacing.lg),
          for (final file in result.files)
            Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
              child: Row(
                children: [
                  _ImportedFilePreview(file: file),
                  const SizedBox(width: HollowSpacing.md),
                  Expanded(
                    child: Text(
                      _fileLabel(file),
                      style: HollowTypography.label
                          .copyWith(color: hollow.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          if (result.license.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.lg),
            Text(
              result.license,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary),
            ),
          ],
        ],
      ),
      actions: [
        if (kinds.isNotEmpty) ...[
          HollowButton.ghost(
            onPressed:
                actionRunning ? null : () => Navigator.of(context).pop(),
            child: const Text('Not now'),
          ),
          // One kind wears by name; a bundle wears whole, and single pieces
          // of it stay a tap away in Your art.
          HollowButton.filled(
            onPressed: () => _wear(kinds.toSet()),
            loading: actionRunning,
            child: Text(
                kinds.length == 1 ? wearKindLabel(kinds.single) : 'Wear all'),
          ),
        ],
      ],
    );
  }
}

/// What one imported file looks like, read back off the rail it just landed on.
/// Animated files play here: it is the one place the buyer sees exactly what
/// they bought.
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
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          alignment: Alignment.center,
          child: child,
        );

    if (file.role == 'frame') {
      // The frame provider reads the rail, where the import just stored the
      // bytes.
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
        borderRadius: BorderRadius.circular(hollow.radiusMd),
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
