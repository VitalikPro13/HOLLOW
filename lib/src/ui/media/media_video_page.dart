import 'dart:async';
import 'dart:convert' show base64Decode;
import 'dart:io' show File;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

import 'package:hollow/src/core/services/video_thumbnail_service.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/media/fullscreen_media_chrome.dart';
import 'package:hollow/src/ui/media/media_item.dart';
import 'package:hollow/src/ui/media/media_playback_session.dart';

/// The poster's play button: its icon plus its padding on both sides, so the
/// spinner that stands in for it keeps the same footprint.
const double _kPlayButtonSize = 28 + HollowSpacing.md * 2;

/// One video page of the media viewer.
///
/// A page opened from a bubble arrives with that bubble's live session, so
/// position survives the push; a page reached by walking the conversation opens
/// its own and drops it again when the user moves on.
class MediaVideoPage extends StatefulWidget {
  final MediaItem item;
  final bool isCurrent;
  final bool isFullscreen;
  final VoidCallback? onFullscreen;

  /// Hands the live controller to the route, so the viewer's keys reach it.
  final void Function(VideoPlayerController? controller)? onController;

  const MediaVideoPage({
    super.key,
    required this.item,
    required this.isCurrent,
    this.isFullscreen = false,
    this.onFullscreen,
    this.onController,
  });

  @override
  State<MediaVideoPage> createState() => _MediaVideoPageState();
}

class _MediaVideoPageState extends State<MediaVideoPage> {
  MediaPlaybackSession? _session;

  /// Whether this page opened the session and so must close it.
  bool _owns = false;
  bool _opening = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final handed = widget.item.session;
    if (handed != null && !handed.isReleased) {
      _session = handed;
      _publishController();
    } else if (widget.isCurrent) {
      unawaited(_open());
    }
  }

  @override
  void didUpdateWidget(MediaVideoPage old) {
    super.didUpdateWidget(old);
    if (old.isCurrent == widget.isCurrent) return;
    if (widget.isCurrent) {
      if (_session == null) unawaited(_open());
      _publishController();
      return;
    }
    // Off the current page: a handed-over session stays attached (the bubble
    // behind us would otherwise take the texture back and play on), one of our
    // own goes away entirely.
    unawaited(_session?.controller.pause());
    widget.onController?.call(null);
    if (_owns) _close();
  }

  @override
  void dispose() {
    if (_owns) _close();
    super.dispose();
  }

  void _close() {
    final session = _session;
    _session = null;
    _owns = false;
    session?.releaseViewer();
  }

  Future<void> _open() async {
    final path = _videoPath();
    if (path == null || _opening) return;
    // The at-rest decrypt can take a moment on a large file.
    setState(() => _opening = true);
    try {
      final session = await MediaPlaybackSession.open(path);
      if (!mounted) {
        session.attachViewer();
        session.releaseViewer();
        return;
      }
      session.attachViewer();
      setState(() {
        _session = session;
        _owns = true;
        _error = null;
      });
      _publishController();
      await session.controller.play();
    } catch (e) {
      if (mounted) setState(() => _error = 'This video could not be opened');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _togglePlay() {
    final controller = _session?.controller;
    if (controller == null) return;
    if (controller.value.isPlaying) {
      controller.pause();
    } else {
      controller.play();
    }
  }

  void _publishController() {
    if (!widget.isCurrent) return;
    widget.onController?.call(_session?.controller);
  }

  /// The video itself, which for a vault video is NOT the attachment's path:
  /// that one points at the poster, and the bytes are rebuilt by the bubble.
  String? _videoPath() {
    if (widget.item.attachment.videoThumb != null) return null;
    final path = widget.item.diskPath;
    if (path == null || !File(path).existsSync()) return null;
    return path;
  }

  String? _posterPath() {
    final attachment = widget.item.attachment;
    if (attachment.videoThumb != null) return attachment.diskPath;
    final path = widget.item.diskPath;
    if (path == null) return null;
    return VideoThumbnailService.cachedThumbFor(path);
  }

  Uint8List? _posterBytes() {
    final b64 = widget.item.attachment.thumbB64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      return base64Decode(b64);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final session = _session;
    if (session == null || session.isReleased) return _poster(hollow);

    // The texture alone: the transport lives in the viewer's bottom chrome,
    // above the strip, because the strip is drawn over this page.
    final video = ColoredBox(
      color: HollowColors.mediaBlack,
      child: Center(
        child: AspectRatio(
          aspectRatio: session.controller.value.aspectRatio,
          child: VideoPlayer(session.controller),
        ),
      ),
    );
    final fullscreen = widget.onFullscreen;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _togglePlay,
      child: fullscreen == null
          ? video
          : DoubleClickListener(onDoubleClick: fullscreen, child: video),
    );
  }

  Widget _poster(HollowTheme hollow) {
    final path = _posterPath();
    final bytes = _posterBytes();
    final playable = _videoPath() != null;
    final caption = _error ??
        (playable ? null : 'Play this video from its message');

    return Stack(
      fit: StackFit.expand,
      children: [
        if (path != null)
          AttachmentImage(path: path, fit: BoxFit.contain)
        else if (bytes != null)
          Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true),
        Container(color: HollowColors.mediaBlack.withValues(alpha: 0.35)),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (playable && _opening)
                const SizedBox.square(
                  dimension: _kPlayButtonSize,
                  child: Center(
                    child: HollowSpinner.large(
                        delayed: true, color: HollowColors.onMedia),
                  ),
                )
              else if (playable)
                HollowPressable(
                  onTap: () => unawaited(_open()),
                  semanticLabel: 'Play video',
                  borderRadius: BorderRadius.circular(HollowRadius.pill),
                  backgroundColor: hollow.overlay.withValues(alpha: 0.85),
                  padding: const EdgeInsets.all(HollowSpacing.md),
                  child: Icon(LucideIcons.play,
                      color: hollow.textPrimary, size: 28),
                )
              else
                Icon(LucideIcons.fileVideo,
                    size: 32, color: hollow.textSecondary),
              if (caption != null) ...[
                const SizedBox(height: HollowSpacing.md),
                Text(
                  caption,
                  style: HollowTypography.body.copyWith(
                    color: HollowColors.onMedia,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
