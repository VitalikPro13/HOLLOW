import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/share/share_card.dart';
import 'package:lucide_icons/lucide_icons.dart';

enum _DialogState { input, loading, confirm }

class PasteLinkDialog extends ConsumerStatefulWidget {
  const PasteLinkDialog({super.key});

  @override
  ConsumerState<PasteLinkDialog> createState() => _PasteLinkDialogState();
}

class _PasteLinkDialogState extends ConsumerState<PasteLinkDialog> {
  final _controller = TextEditingController();
  _DialogState _state = _DialogState.input;
  String? _errorText;
  String? _rootHash;
  String? _shareLink;
  String? _fileName;
  int _totalSize = 0;
  int _chunkCount = 0;
  int _loadingStartMs = 0;
  Timer? _countdownTimer;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (_state == _DialogState.loading && _rootHash != null) {
      ref.watch(shareTabProvider);
      final notifier = ref.read(shareTabProvider.notifier);
      final manifest = notifier.pendingManifests[_rootHash];

      if (manifest != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _state == _DialogState.loading) {
            _countdownTimer?.cancel();
            final (name, size, count) = manifest;
            setState(() {
              _state = _DialogState.confirm;
              _fileName = name;
              _totalSize = size;
              _chunkCount = count;
            });
          }
        });
      } else {
        final elapsed = DateTime.now().millisecondsSinceEpoch - _loadingStartMs;
        if (elapsed > 10000) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _state == _DialogState.loading) {
              _countdownTimer?.cancel();
              _cleanup();
              setState(() {
                _state = _DialogState.input;
                _errorText = 'No seeders found — try again later';
              });
            }
          });
        }
      }
    }

    return HollowDialog(
      title: 'Open Share Link',
      content: _buildContent(hollow),
      actions: _buildActions(),
    );
  }

  Widget _buildContent(HollowTheme hollow) {
    switch (_state) {
      case _DialogState.input:
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HollowTextField(
              controller: _controller,
              hintText: 'hollow://share/...',
              autofocus: true,
              errorText: _errorText,
              onSubmitted: (_) => _onOpen(),
            ),
          ],
        );
      case _DialogState.loading:
        final elapsed = DateTime.now().millisecondsSinceEpoch - _loadingStartMs;
        final remaining = ((10000 - elapsed) / 1000).ceil().clamp(0, 10);
        return SizedBox(
          width: double.infinity,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: HollowSpacing.lg),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: hollow.accent,
              ),
            ),
            const SizedBox(height: HollowSpacing.md),
            Text(
              'Looking for seeders... ${remaining}s',
              style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.lg),
          ],
        ));
      case _DialogState.confirm:
        final downloadPath = ref.watch(shareDownloadPathProvider).valueOrNull ?? '';
        final displayPath = downloadPath.isEmpty
            ? 'Default Shares folder'
            : downloadPath;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _fileName ?? '',
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text(
              '${ShareCard.formatSize(_totalSize)}  ·  $_chunkCount chunks',
              style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.md),
            Row(
              children: [
                Icon(LucideIcons.folderOpen, size: 14, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.xs),
                Expanded(
                  child: Text(
                    displayPath,
                    style: HollowTypography.bodySmall.copyWith(
                      color: hollow.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.ghost(
                  compact: true,
                  onPressed: _pickSaveDir,
                  child: const Text('Change'),
                ),
              ],
            ),
          ],
        );
    }
  }

  List<Widget> _buildActions() {
    switch (_state) {
      case _DialogState.input:
        return [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: _onOpen,
            child: const Text('Open'),
          ),
        ];
      case _DialogState.loading:
        return [
          HollowButton.ghost(
            onPressed: _onCancel,
            child: const Text('Cancel'),
          ),
        ];
      case _DialogState.confirm:
        return [
          HollowButton.ghost(
            onPressed: _onCancel,
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: _onDownload,
            child: const Text('Download'),
          ),
        ];
    }
  }

  Future<void> _onOpen() async {
    final link = _controller.text.trim();
    if (link.isEmpty) {
      setState(() => _errorText = 'Please paste a share link');
      return;
    }

    try {
      final info = await share_api.shareDecodeLink(link: link);
      final existing = ref.read(shareTabProvider);
      if (existing.any((s) => s.rootHash == info.rootHash)) {
        setState(() => _errorText = 'You already have this file');
        return;
      }
      _rootHash = info.rootHash;
      _shareLink = link;
      _loadingStartMs = DateTime.now().millisecondsSinceEpoch;
      _countdownTimer?.cancel();
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && _state == _DialogState.loading) setState(() {});
      });
      setState(() {
        _state = _DialogState.loading;
        _errorText = null;
      });
      await share_api.shareOpenLink(link: link);
    } catch (e) {
      setState(() => _errorText = 'Invalid share link');
    }
  }

  Future<void> _onDownload() async {
    if (_rootHash == null) return;
    final saveDir = ref.read(shareDownloadPathProvider).valueOrNull ?? '';
    ref.read(shareTabProvider.notifier).startDownload(_rootHash!, _shareLink ?? '');
    await share_api.shareStartDownload(rootHash: _rootHash!, saveDir: saveDir, link: _shareLink ?? '');
    if (mounted) Navigator.pop(context);
  }

  Future<void> _pickSaveDir() async {
    final result = await FilePicker.platform.getDirectoryPath();
    if (result != null) {
      await ref.read(shareDownloadPathProvider.notifier).setPath(result);
    }
  }

  void _onCancel() {
    _cleanup();
    Navigator.pop(context);
  }

  void _cleanup() {
    if (_rootHash != null) {
      ref.read(shareTabProvider.notifier).clearPendingManifest(_rootHash!);
      share_api.shareCancel(rootHash: _rootHash!);
    }
  }
}
