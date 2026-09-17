import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/staged_attachments.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A drop zone wrapper for chat panes: purely the overlay and the drop event.
/// Size validation, the album cap and image detection belong to [onFilesDropped].
class ChatDropZone extends StatefulWidget {
  final Widget child;

  /// Called with every dropped file, and owns the size validation and
  /// staging. May be sync or async.
  final dynamic Function(List<StagedAttachment> files) onFilesDropped;

  const ChatDropZone({
    super.key,
    required this.child,
    required this.onFilesDropped,
  });

  @override
  State<ChatDropZone> createState() => _ChatDropZoneState();
}

class _ChatDropZoneState extends State<ChatDropZone> {
  bool _dragging = false;

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (details.files.isEmpty) return;

    final files = <StagedAttachment>[];
    for (final file in details.files) {
      final path = file.path;
      // A dropped folder is not a file to send.
      if (path.isEmpty || !await File(path).exists()) continue;
      files.add(StagedAttachment.fromPath(path,
          name: file.name.isNotEmpty ? file.name : null));
    }
    if (files.isNotEmpty) widget.onFilesDropped(files);
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS) {
      return widget.child;
    }

    final hollow = HollowTheme.of(context);

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _handleDrop,
      child: Stack(
        children: [
          widget.child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: hollow.background.withValues(alpha: 0.85),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.xl,
                        vertical: HollowSpacing.lg,
                      ),
                      decoration: BoxDecoration(
                        color: hollow.surface,
                        borderRadius:
                            BorderRadius.circular(hollow.radiusLg),
                        border: Border.all(
                          color: hollow.accent,
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: hollow.accent.withValues(alpha: 0.3),
                            blurRadius: 24,
                            spreadRadius: 4,
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.upload,
                            size: 48,
                            color: hollow.accent,
                          ),
                          const SizedBox(height: HollowSpacing.md),
                          Text(
                            'Drop files to attach',
                            style: HollowTypography.subheading.copyWith(
                              color: hollow.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
