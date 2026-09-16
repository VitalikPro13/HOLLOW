import 'package:flutter/widgets.dart';

import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/ui/media/media_item.dart';

/// What the media viewer can ask its host to do. Each is null where the host
/// cannot offer it: an archive can save a file and nothing else.
@immutable
class MediaViewerActions {
  /// Sets the host's reply state. The viewer closes first.
  final void Function(String messageId)? onReply;

  /// Scrolls the host to the message. The viewer closes first.
  final void Function(String messageId)? onJumpTo;

  /// Deletes the message. Confirmed by the viewer, which then advances.
  final Future<void> Function(String messageId)? onDelete;

  final Future<void> Function(String messageId, String emoji)? onReact;

  /// Save as, through the host's own file picker.
  final Future<void> Function(FileAttachment attachment)? onSaveAs;

  const MediaViewerActions({
    this.onReply,
    this.onJumpTo,
    this.onDelete,
    this.onReact,
    this.onSaveAs,
  });

  static const MediaViewerActions none = MediaViewerActions();
}

/// Published by a message surface so an attachment opened from it can walk the
/// rest of the conversation and act on its message.
///
/// Read at OPEN time, not from inside the viewer: the viewer is a route, and a
/// route is built under the Navigator rather than under the surface that
/// pushed it.
class MediaViewerScope extends InheritedWidget {
  /// Null when there is nothing to walk, as in an archive.
  final MediaContext? mediaContext;
  final MediaViewerActions actions;

  const MediaViewerScope({
    super.key,
    this.mediaContext,
    this.actions = MediaViewerActions.none,
    required super.child,
  });

  /// Does not register a dependency: callers read this in a tap handler, and a
  /// dependency would rebuild every bubble whenever the host rebuilds.
  static MediaViewerScope? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<MediaViewerScope>();

  @override
  bool updateShouldNotify(MediaViewerScope old) =>
      old.mediaContext != mediaContext || old.actions != actions;
}
