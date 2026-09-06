import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers/sticker_provider.dart';
import '../../rust/api/stickers.dart' as stickers_api;
import '../../theme/hollow_spacing.dart';
import '../../theme/hollow_theme.dart';
import '../../theme/hollow_typography.dart';
import '../components/hollow_button.dart';
import '../components/hollow_toast.dart';
import 'file_card_status.dart';

/// The file extension a shared sticker pack carries (issue #36).
const String kStickerPackExtension = 'hollow-pack';

/// Whether [fileName] names a shared sticker pack.
bool isStickerPackFile(String fileName) =>
    fileName.toLowerCase().endsWith('.$kStickerPackExtension');

/// A received `.hollow-pack`, rendered as an "add this pack" card instead of a
/// generic file row. Only a nicer face on an ordinary attachment: transfer,
/// encryption and storage are the plain file path, untouched.
///
/// NOTHING HERE TRUSTS THE FILE. Name and count label the button only, the
/// byline appears only for a signature that verifies against the author it
/// names, and no image is previewed before import, because a thumbnail means
/// pointing a decoder at un-validated bytes. Every real check lives in
/// `import_sticker_pack`, which re-hashes and re-decodes each blob.
class StickerPackCard extends ConsumerStatefulWidget {
  /// Local path of the pack file, null until the bytes are here.
  final String? diskPath;

  /// Name as it arrived, the label until the manifest is read.
  final String fileName;

  /// True only while bytes are actually moving. A pack the auto-download gate
  /// declined (issue #41) is NOT downloading, and saying so under it forever is
  /// what this separates out (issue #54).
  final bool isDownloading;

  /// 0..1 while [isDownloading].
  final double progress;

  /// Null in a context that cannot fetch, such as an archive viewer.
  final VoidCallback? onDownload;

  /// Why the bytes are not here yet: the subtitle shown instead of "Sticker
  /// pack", and whether the Download button is offered at all.
  final FileCardStatus status;

  const StickerPackCard({
    super.key,
    required this.diskPath,
    required this.fileName,
    this.isDownloading = false,
    this.progress = 0,
    this.onDownload,
    this.status = const FileCardStatus(control: FileCardControl.download),
  });

  @override
  ConsumerState<StickerPackCard> createState() => _StickerPackCardState();
}

class _StickerPackCardState extends ConsumerState<StickerPackCard> {
  stickers_api.StickerPackPreview? _preview;
  bool _busy = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  @override
  void didUpdateWidget(StickerPackCard old) {
    super.didUpdateWidget(old);
    if (old.diskPath != widget.diskPath) _loadPreview();
  }

  Future<void> _loadPreview() async {
    final path = widget.diskPath;
    if (path == null) return;
    try {
      final preview = await stickers_api.previewStickerPack(path: path);
      if (mounted) setState(() => _preview = preview);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  Future<void> _add() async {
    final path = widget.diskPath;
    if (path == null || _busy) return;
    setState(() => _busy = true);
    try {
      final result =
          await stickers_api.importStickerPack(path: path, intoPack: '');
      ref.invalidate(personalStickersProvider);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = result.added > 0 || result.skipped > 0;
      });
      HollowToast.show(context, _summary(result),
          type: result.added > 0
              ? HollowToastType.success
              : HollowToastType.info);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      HollowToast.show(context, e.toString().replaceFirst('Exception: ', ''),
          type: HollowToastType.error);
    }
  }

  /// Partial imports are normal (the vault caps), so this reports what landed
  /// rather than claiming success.
  String _summary(stickers_api.StickerPackImportResult r) {
    final where = r.pack.isEmpty ? 'your stickers' : '“${r.pack}”';
    if (r.added == 0 && r.skipped > 0 && r.rejected == 0) {
      return 'Already in $where';
    }
    if (r.added == 0) return 'Nothing could be added from that pack';
    final parts = <String>['Added ${r.added} to $where'];
    if (r.skipped > 0) parts.add('${r.skipped} already there');
    if (r.rejected > 0) parts.add('${r.rejected} skipped');
    return parts.join(' · ');
  }

  /// Falls back to the file's own name until the manifest is readable.
  String get _title {
    final pack = _preview?.pack.trim() ?? '';
    if (pack.isNotEmpty) return pack;
    return widget.fileName
        .replaceAll(RegExp('\\.$kStickerPackExtension\$', caseSensitive: false),
            '');
  }

  /// True when the bytes are absent and nothing is fetching them.
  bool get _needsDownload => widget.diskPath == null && !widget.isDownloading;

  String get _subtitle {
    if (_error != null) return _error!;
    final preview = _preview;
    if (preview == null) {
      if (widget.diskPath != null) return 'Reading pack…';
      if (widget.isDownloading) {
        final pct = (widget.progress.clamp(0.0, 1.0) * 100).round();
        return pct > 0 ? 'Downloading… $pct%' : 'Downloading…';
      }
      // Why the bytes are missing beats the generic label.
      return widget.status.caption ?? 'Sticker pack';
    }
    final count = preview.count;
    final label = '$count sticker${count == 1 ? '' : 's'}';
    // The byline shows ONLY for a signature that verifies against the author it
    // claims. Anyone may author a pack, so an unsigned one is anonymous rather
    // than suspicious.
    if (preview.authorVerified && preview.author.isNotEmpty) {
      final short = preview.author.length > 10
          ? preview.author.substring(preview.author.length - 6)
          : preview.author;
      return '$label · by …$short';
    }
    return label;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final ready = widget.diskPath != null && _error == null;

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.md),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.package, size: 28, color: hollow.accent),
                const SizedBox(width: HollowSpacing.md),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _title,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: HollowSpacing.xxs),
                      Text(
                        _subtitle,
                        style: HollowTypography.caption.copyWith(
                          color: _error != null
                              ? hollow.error
                              : hollow.textSecondary,
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_needsDownload &&
                widget.onDownload != null &&
                (widget.status.control == FileCardControl.download ||
                    widget.status.control == FileCardControl.retry)) ...[
              const SizedBox(height: HollowSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: HollowButton.ghost(
                  icon: const Icon(LucideIcons.download, size: 14),
                  onPressed: widget.onDownload,
                  semanticLabel: 'Download this sticker pack',
                  child: const Text('Download pack'),
                ),
              ),
            ] else if (_needsDownload &&
                widget.status.control == FileCardControl.busy) ...[
              // Slow FFI behind a button is a busy state, never a second tap.
              const SizedBox(height: HollowSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: HollowButton.ghost(
                  icon: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(hollow.textSecondary),
                    ),
                  ),
                  onPressed: null,
                  semanticLabel: 'Requesting this sticker pack',
                  child: const Text('Requesting...'),
                ),
              ),
            ],
            if (ready) ...[
              const SizedBox(height: HollowSpacing.sm),
              SizedBox(
                width: double.infinity,
                child: HollowButton.ghost(
                  icon: Icon(
                    _done ? LucideIcons.check : LucideIcons.packagePlus,
                    size: 14,
                  ),
                  // A second tap would silently queue another import.
                  onPressed: _busy || _done ? null : _add,
                  semanticLabel: 'Add this sticker pack to your stickers',
                  child: Text(_done
                      ? 'Added'
                      : _busy
                          ? 'Adding…'
                          : 'Add to my stickers'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
