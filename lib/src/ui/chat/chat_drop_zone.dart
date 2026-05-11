import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// A drop zone wrapper for chat panes.
///
/// Wraps [child] in a [DropTarget] that accepts file drops. When a file
/// is dragged over, an accent-bordered overlay appears with "Drop file
/// to attach" text. On drop, the first file is staged via [onFileDropped].
///
/// File size validation and image detection are the caller's responsibility
/// — see `_pickAndStageFile` in chat_pane / channel_chat_pane for the
/// existing pattern. This widget is purely a visual + drop event wrapper.
class ChatDropZone extends StatefulWidget {
  final Widget child;

  /// Called when a file is dropped. Receives the file path, name, and size
  /// in bytes. The callback is responsible for size validation and staging.
  /// May be sync or async — return value is ignored.
  final dynamic Function(String path, String name, int sizeBytes) onFileDropped;

  const ChatDropZone({
    super.key,
    required this.child,
    required this.onFileDropped,
  });

  @override
  State<ChatDropZone> createState() => _ChatDropZoneState();
}

class _ChatDropZoneState extends State<ChatDropZone> {
  bool _dragging = false;

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (details.files.isEmpty) return;

    // Take only the first file (multi-file support is a separate todo).
    final file = details.files.first;
    final path = file.path;
    if (path.isEmpty) return;

    // Get file size from disk (XFile.length is async).
    int sizeBytes;
    try {
      sizeBytes = await File(path).length();
    } catch (_) {
      sizeBytes = 0;
    }

    // Use XFile.name when available, fallback to basename of path.
    final name = file.name.isNotEmpty
        ? file.name
        : path.split(Platform.pathSeparator).last;

    widget.onFileDropped(path, name, sizeBytes);
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
                            'Drop file to attach',
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
