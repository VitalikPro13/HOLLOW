import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/avatar_frame.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A frame picked but not yet committed. [bytes] is set only for a fresh
/// upload, so the preview renders before the profile save lands.
class AvatarFramePick {
  final String id;
  final Uint8List? bytes;

  const AvatarFramePick(this.id, [this.bytes]);
}

/// The built-in palette (issue #54). Procedural colours rather than bundled
/// art: zero bytes on the wire, and something the widget tests can render with
/// no network.
const List<({int hue, String name})> kBuiltinFrames = [
  (hue: 0, name: 'Red'),
  (hue: 20, name: 'Orange'),
  (hue: 45, name: 'Amber'),
  (hue: 90, name: 'Lime'),
  (hue: 140, name: 'Green'),
  (hue: 168, name: 'Teal'),
  (hue: 190, name: 'Cyan'),
  (hue: 215, name: 'Blue'),
  (hue: 250, name: 'Indigo'),
  (hue: 280, name: 'Violet'),
  (hue: 320, name: 'Magenta'),
  (hue: 340, name: 'Rose'),
];

/// Picks an avatar frame. Null is a cancel and an empty id is a clear.
Future<AvatarFramePick?> showAvatarFramePicker({
  required BuildContext context,
  required String peerId,
  required String currentId,
}) {
  return showHollowDialog<AvatarFramePick>(
    context: context,
    builder: (_) => _AvatarFramePickerDialog(peerId: peerId, initial: currentId),
  );
}

class _AvatarFramePickerDialog extends ConsumerStatefulWidget {
  final String peerId;
  final String initial;

  const _AvatarFramePickerDialog({required this.peerId, required this.initial});

  @override
  ConsumerState<_AvatarFramePickerDialog> createState() =>
      _AvatarFramePickerDialogState();
}

class _AvatarFramePickerDialogState
    extends ConsumerState<_AvatarFramePickerDialog> {
  late String _selected = widget.initial;

  /// Kept so switching to a built-in and back does not lose the upload.
  String? _uploadedId;
  Uint8List? _uploadedBytes;
  bool _busy = false;

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final raw = await File(path).readAsBytes();
      final processed = await network_api.processAndStoreAvatarFrame(
        rawBytes: raw,
      );
      if (!mounted) return;
      // Seeded so the preview paints immediately, with no round trip back out
      // through the blob store.
      ref
          .read(avatarFrameProvider.notifier)
          .seed(processed.hash, processed.bytes);
      setState(() {
        _uploadedId = processed.hash;
        _uploadedBytes = processed.bytes;
        _selected = processed.hash;
      });
    } catch (e) {
      if (!mounted) return;
      // The processing errors are the user's business: over the cap, or the
      // gate that a frame's middle has to be see-through.
      setState(() => _busy = false);
      final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
      showHollowDialog<void>(
        context: context,
        builder: (_) => HollowDialog(
          title: 'That image cannot be a frame',
          content: Text(
            message,
            style: HollowTypography.body
                .copyWith(color: HollowTheme.of(context).textSecondary),
          ),
          actions: [
            HollowButton.filled(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final accentHue = ref.watch(accentHueProvider).round() % 360;

    return HollowDialog(
      title: 'Avatar frame',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(bottom: HollowSpacing.lg),
              child: HollowAvatar(
                peerId: widget.peerId,
                size: 72,
                frameId: _selected,
                animate: true,
              ),
            ),
          ),
          Text(
            'A frame is painted in front of your avatar, so its middle has to '
            'be see-through. Uploads are cropped square and shared with the '
            'people who can already see your profile.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              _FrameChoice(
                id: '',
                peerId: widget.peerId,
                label: 'No frame',
                isSelected: _selected.isEmpty,
                onTap: () => setState(() => _selected = ''),
              ),
              if (_uploadedId != null)
                _FrameChoice(
                  id: _uploadedId!,
                  peerId: widget.peerId,
                  label: 'Your upload',
                  isSelected: _selected == _uploadedId,
                  onTap: () => setState(() => _selected = _uploadedId!),
                )
              else if (isFrameHash(widget.initial))
                _FrameChoice(
                  id: widget.initial,
                  peerId: widget.peerId,
                  label: 'Your frame',
                  isSelected: _selected == widget.initial,
                  onTap: () => setState(() => _selected = widget.initial),
                ),
              // Your own accent first when it is not already a built-in, so
              // the frame can match the app you are looking at.
              if (!kBuiltinFrames.any((f) => f.hue == accentHue))
                _FrameChoice(
                  id: 'b:$accentHue',
                  peerId: widget.peerId,
                  label: 'Your accent color',
                  isSelected: _selected == 'b:$accentHue',
                  onTap: () => setState(() => _selected = 'b:$accentHue'),
                ),
              for (final builtin in kBuiltinFrames)
                _FrameChoice(
                  id: 'b:${builtin.hue}',
                  peerId: widget.peerId,
                  label: builtin.name,
                  isSelected: _selected == 'b:${builtin.hue}',
                  onTap: () =>
                      setState(() => _selected = 'b:${builtin.hue}'),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),
          HollowButton.outline(
            onPressed: _busy ? null : _upload,
            icon: _busy
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: hollow.textSecondary,
                    ),
                  )
                : const Icon(LucideIcons.upload, size: 14),
            child: Text(_busy ? 'Processing...' : 'Upload an image or GIF'),
          ),
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).pop(
                    AvatarFramePick(
                      _selected,
                      _selected == _uploadedId ? _uploadedBytes : null,
                    ),
                  ),
          child: const Text('Use frame'),
        ),
      ],
    );
  }
}

/// One choice in the picker, drawn around a real avatar because a frame is only
/// legible against the thing it decorates.
class _FrameChoice extends StatelessWidget {
  final String id;
  final String peerId;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _FrameChoice({
    required this.id,
    required this.peerId,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // The frame's own box plus breathing room, so neighbouring choices never
    // overlap each other's art.
    final box = 40 * kFrameScale + 8;
    return HollowFocusRing(
      onActivate: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: HollowTooltip(
        message: label,
        child: Semantics(
          button: true,
          selected: isSelected,
          label: label,
          child: HollowPressable(
            onTap: onTap,
            // Selection is a chip, never a filled button, and deliberately does
            // NOT tint the BORDER: a coloured ring is the frame's own language,
            // and against the accent-hued frame it would vanish.
            backgroundColor: isSelected ? hollow.accentMuted : null,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: EdgeInsets.zero,
            child: Container(
              width: box,
              height: box,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // "No frame" still shows the avatar, so the comparison is
                  // like for like.
                  Center(
                    child: HollowAvatar(peerId: peerId, size: 40, frameId: id),
                  ),
                  if (isSelected)
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: hollow.accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: hollow.surface, width: 1.5),
                        ),
                        child: Icon(
                          LucideIcons.check,
                          size: 9,
                          color: hollow.textOnAccent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
