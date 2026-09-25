import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/share/share_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum _DialogState { input, loading, confirm }

class PasteLinkDialog extends ConsumerStatefulWidget {
  final String? initialLink;
  const PasteLinkDialog({super.key, this.initialLink});

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
  int _loadingStartMs = 0;
  Timer? _countdownTimer;
  bool _decoding = false;
  bool _downloading = false;
  String? _downloadError;

  @override
  void initState() {
    super.initState();
    if (widget.initialLink != null) {
      _controller.text = widget.initialLink!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _onOpen();
      });
    }
  }

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
            final (name, size, _) = manifest;
            setState(() {
              _state = _DialogState.confirm;
              _fileName = name;
              _totalSize = size;
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
                _errorText = 'Nobody sharing this file is online. Try again later.';
              });
            }
          });
        }
      }
    }

    return HollowDialog(
      title: 'Open a share link',
      width: 420,
      busy: _downloading,
      error: _state == _DialogState.confirm ? _downloadError : null,
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
              onChanged: (_) {
                if (_errorText != null) setState(() => _errorText = null);
              },
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
              const HollowSpinner.medium(),
              const SizedBox(height: HollowSpacing.md),
              Text(
                'Looking for someone who has the file (${remaining}s)',
                style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: HollowSpacing.lg),
            ],
          ),
        );
      case _DialogState.confirm:
        final downloadPath = ref.watch(shareDownloadPathProvider).valueOrNull ?? '';
        final displayPath = downloadPath.isEmpty
            ? 'Default Shares folder'
            : downloadPath;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _fileName ?? '',
              style: HollowTypography.label.copyWith(color: hollow.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              ShareCard.formatSize(_totalSize),
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
            loading: _decoding,
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
            onPressed: _downloading ? null : _onCancel,
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: _onDownload,
            loading: _downloading,
            child: const Text('Download'),
          ),
        ];
    }
  }

  Future<void> _onOpen() async {
    if (_decoding || _state != _DialogState.input) return;
    final link = _controller.text.trim();
    if (link.isEmpty) {
      setState(() => _errorText = 'Paste a share link first');
      return;
    }

    setState(() => _decoding = true);
    final share_api.ShareLinkInfo info;
    try {
      info = await share_api.shareDecodeLink(link: link);
    } catch (_) {
      // Decoding is local, so a failure here means the text is not a link.
      if (mounted) {
        setState(() {
          _decoding = false;
          _errorText = "That isn't a share link";
        });
      }
      return;
    }
    if (!mounted) return;
    final existing = ref.read(shareTabProvider);
    if (existing.any((s) => s.rootHash == info.rootHash)) {
      setState(() {
        _decoding = false;
        _errorText = 'You already have this file';
      });
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
      _decoding = false;
      _state = _DialogState.loading;
      _errorText = null;
    });
    try {
      await share_api.shareOpenLink(link: link);
    } catch (e) {
      // The link was fine; asking for the file failed. Say that, and never
      // let the countdown run on to blame the people sharing it.
      if (!mounted || _state != _DialogState.loading) return;
      _countdownTimer?.cancel();
      _cleanup();
      setState(() {
        _state = _DialogState.input;
        _rootHash = null;
        _errorText = friendlyError(e,
            fallback: "Couldn't ask for this file. Check your connection "
                'and try again.');
      });
    }
  }

  Future<void> _onDownload() async {
    final rootHash = _rootHash;
    if (rootHash == null || _downloading) return;
    final saveDir = ref.read(shareDownloadPathProvider).valueOrNull ?? '';
    final notifier = ref.read(shareTabProvider.notifier);
    final manifest = notifier.pendingManifests[rootHash];
    setState(() {
      _downloading = true;
      _downloadError = null;
    });
    notifier.startDownload(rootHash, _shareLink ?? '');
    try {
      await share_api.shareStartDownload(
          rootHash: rootHash,
          saveDir: saveDir,
          link: _shareLink ?? '',
          sequential: false);
    } catch (e) {
      // Undo the optimistic row so the list never shows a download that
      // never started, and keep the manifest for a retry.
      notifier.removeShare(rootHash);
      if (manifest != null) {
        final (name, size, chunks) = manifest;
        notifier.handleShareManifestReady(rootHash, name, size, chunks);
      }
      if (mounted) {
        setState(() {
          _downloading = false;
          _downloadError = friendlyError(e,
              fallback: "Couldn't start the download. Try again.");
        });
      }
      return;
    }
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
      share_api.shareCancel(rootHash: _rootHash!).catchError((_) {});
    }
  }
}
