import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'package:hollow/src/core/services/at_rest.dart';

/// One [VideoPlayerController] shared by the inline bubble and the fullscreen
/// view, so opening fullscreen never restarts playback from zero.
///
/// Ownership is a holder SET, not a parent: the bubble can scroll out of the
/// message list and die while the view is still up, so whoever releases last
/// disposes. Only one [VideoPlayer] widget may be attached to the controller at
/// a time ([viewerHolds] says which side draws), because two of them on one
/// controller double-render through fvp on Windows.
class MediaPlaybackSession extends ChangeNotifier {
  MediaPlaybackSession._(this._controller, this.diskPath);

  /// Holder token for the fullscreen view. Canonicalised across sessions, which
  /// is harmless: holder sets are per session.
  static const Object _viewerToken = #hollowFullscreenMediaViewer;

  final VideoPlayerController _controller;

  /// The at-rest path the controller was opened from, so the fullscreen handoff
  /// never has to turn the loopback URL back into a path.
  final String diskPath;

  final Set<Object> _holders = <Object>{};
  bool _released = false;

  /// Opens a controller on an at-rest file. Throws when the source cannot be
  /// opened, leaving no controller behind.
  static Future<MediaPlaybackSession> open(String diskPath) async {
    // Loopback URL, not a file: an attachment on disk is ciphertext and no
    // player can open it directly.
    final controller = VideoPlayerController.networkUrl(
        Uri.parse(await AtRest.mediaUrlFor(diskPath)));
    try {
      await controller.initialize();
    } catch (_) {
      await controller.dispose();
      rethrow;
    }
    await controller.setLooping(false);
    return MediaPlaybackSession._(controller, diskPath);
  }

  /// Wraps a controller a test made itself, since [open] needs the at-rest
  /// loopback and a widget test has no FFI.
  @visibleForTesting
  static MediaPlaybackSession debugWrap(
    VideoPlayerController controller,
    String diskPath,
  ) =>
      MediaPlaybackSession._(controller, diskPath);

  VideoPlayerController get controller => _controller;

  /// True while the fullscreen view draws the texture, which is when the inline
  /// bubble must draw its poster instead.
  bool get viewerHolds => _holders.contains(_viewerToken);

  bool get isReleased => _released;

  void retain(Object holder) {
    if (_released) return;
    _holders.add(holder);
  }

  /// Drops one holder. The last one out pauses and disposes, exactly once.
  Future<void> release(Object holder) async {
    if (!_holders.remove(holder)) return;
    if (_holders.isNotEmpty || _released) return;
    _released = true;
    await _controller.pause();
    await _controller.dispose();
  }

  void attachViewer() {
    retain(_viewerToken);
    notifyListeners();
  }

  void releaseViewer() {
    if (!viewerHolds) return;
    // The holder leaves the set synchronously, so listeners already see
    // `viewerHolds == false` and the bubble re-attaches its player.
    unawaited(release(_viewerToken).catchError((Object _) {}));
    notifyListeners();
  }
}
