import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

import 'package:hollow/src/core/perf_sentinel.dart';
import 'package:hollow/src/core/providers/app_shortcuts_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/chat_input_shortcuts.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/components/attachment_image.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/media/fullscreen_media_chrome.dart';
import 'package:hollow/src/ui/media/media_info_panel.dart';
import 'package:hollow/src/ui/media/media_item.dart';
import 'package:hollow/src/ui/media/media_strip.dart';
import 'package:hollow/src/ui/media/media_video_page.dart';
import 'package:hollow/src/ui/media/media_viewer_controls.dart';
import 'package:hollow/src/ui/media/media_viewer_scope.dart';
import 'package:hollow/src/ui/media/media_zoom_math.dart';
import 'package:hollow/src/ui/media/media_zoom_view.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';

/// How many items each page of the conversation's media brings in.
const int _kPageSize = 40;

/// Distance from either end of the loaded list that triggers the next page.
const int _kPrefetchMargin = 3;

/// Drag distance past which a swipe down dismisses the viewer.
const double _kDismissDrag = 120;

/// Crisp pixels past twice actual size. A viewing preference rather than a
/// setting, so it lives for the process and never reaches the disk.
@visibleForTesting
bool mediaViewerCrispPixels = true;

/// Opens the media viewer for [item], picking up the host's
/// [MediaViewerScope].
///
/// The scope is read HERE rather than inside the viewer, because the viewer is
/// a route and a route is built under the Navigator, not under the surface that
/// pushed it.
Future<void> openMediaViewer(
  BuildContext context,
  MediaItem item, {
  bool enterFullscreen = false,
}) {
  final scope = MediaViewerScope.maybeOf(context);
  return Navigator.of(context).push(mediaViewerRoute(
    item: item,
    mediaContext: scope?.mediaContext,
    actions: scope?.actions ?? MediaViewerActions.none,
    enterFullscreen: enterFullscreen,
  ));
}

/// The route the viewer lives on: opaque and full bleed, because a dialog's
/// blur barrier and inset box are the opposite of a viewer.
Route<void> mediaViewerRoute({
  required MediaItem item,
  MediaContext? mediaContext,
  MediaViewerActions actions = MediaViewerActions.none,
  bool enterFullscreen = false,
}) {
  const fade = Duration(milliseconds: 150);
  Widget page(BuildContext _) => MediaViewerView(
        item: item,
        mediaContext: mediaContext,
        actions: actions,
        enterFullscreen: enterFullscreen,
      );
  if (isMobileMediaPlatform) {
    return hollowMobileRoute<void>(
      builder: page,
      transition: HollowRouteTransition.fade,
      duration: fade,
    );
  }
  final reduce = ReduceMotionController.instance.isReduced;
  return PageRouteBuilder<void>(
    opaque: true,
    fullscreenDialog: true,
    transitionDuration: reduce ? Duration.zero : fade,
    reverseTransitionDuration: reduce ? Duration.zero : fade,
    pageBuilder: (context, _, _) => page(context),
    transitionsBuilder: (_, anim, _, child) =>
        reduce ? child : FadeTransition(opacity: anim, child: child),
  );
}

/// One viewer for images, GIFs and video.
class MediaViewerView extends ConsumerStatefulWidget {
  final MediaItem item;
  final MediaContext? mediaContext;
  final MediaViewerActions actions;

  /// Opened from a video bubble, which took the window fullscreen on the way
  /// in. Leaving the fullscreen by any path then leaves the viewer too.
  final bool enterFullscreen;

  const MediaViewerView({
    super.key,
    required this.item,
    this.mediaContext,
    this.actions = MediaViewerActions.none,
    this.enterFullscreen = false,
  });

  @override
  ConsumerState<MediaViewerView> createState() => _MediaViewerViewState();
}

class _MediaViewerViewState extends ConsumerState<MediaViewerView>
    with TickerProviderStateMixin, FullscreenMediaChrome<MediaViewerView> {
  late List<MediaItem> _items;
  late final PageController _pages;
  final TransformationController _transform = TransformationController();
  final GlobalKey _reactAnchor = GlobalKey();

  int _index = 0;
  int _rotation = 0;
  Size _viewport = Size.zero;
  Size? _imageSize;
  double _actualScale = 1.0;
  double _maxScale = 8.0;
  double _minScale = 1.0;
  FilterQuality _quality = FilterQuality.high;

  late final AnimationController _zoomAnim;
  Animation<Matrix4>? _zoomTween;

  bool _controlsVisible = true;
  Timer? _hideTimer;
  bool _infoOpen = false;
  bool _saving = false;
  bool _deleting = false;
  bool _dismissed = false;
  bool _loadingOlder = false;
  bool _loadingNewer = false;
  bool _endOlder = false;
  bool _endNewer = false;
  double _dragDy = 0;
  int? _dragPointer;
  Offset _dragStart = Offset.zero;
  VideoPlayerController? _video;
  late final DateTime _openedAt;

  MediaItem get _current => _items[_index];
  bool get _reduced => ReduceMotionController.instance.isReduced;
  bool get _walkable => widget.mediaContext != null && _items.length > 1;

  @override
  void initState() {
    super.initState();
    _openedAt = DateTime.now();
    _items = [widget.item];
    _pages = PageController();
    _zoomAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(_onZoomTick);
    _transform.addListener(_onTransform);
    beginFullscreenMedia(widget.item.pixelSize);
    if (widget.enterFullscreen) unawaited(enterWindowFullscreen());
    // On HardwareKeyboard, not a Shortcuts binding: an opaque page route has no
    // barrier, and focus may sit on a control.
    HardwareKeyboard.instance.addHandler(_onKey);
    OverlayHosts.register(this, _dismiss);
    _scheduleHide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      PerfSentinel.emit('[SENTINEL] media viewer open '
          '${DateTime.now().difference(_openedAt).inMilliseconds}ms');
      unawaited(_loadAround());
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    OverlayHosts.unregister(this);
    _hideTimer?.cancel();
    _zoomAnim.dispose();
    _transform.dispose();
    _pages.dispose();
    endFullscreenMedia();
    super.dispose();
  }

  // --- the conversation's media ------------------------------------------

  /// Fills the list in both directions around the item the viewer opened at.
  Future<void> _loadAround() async {
    final context = widget.mediaContext;
    final ts = widget.item.timestampMs;
    if (context == null || ts == null) return;
    _loadingOlder = true;
    _loadingNewer = true;
    try {
      final results = await Future.wait([
        MediaLibrary.page(
          contextType: context.contextType,
          contextId: context.contextId,
          beforeMs: ts + 1,
          limit: _kPageSize,
        ),
        MediaLibrary.page(
          contextType: context.contextType,
          contextId: context.contextId,
          afterMs: ts,
          limit: _kPageSize,
        ),
      ]);
      if (!mounted) return;
      // Both pages arrive newest first; the viewer reads left to right in time.
      final older = results[0].reversed.toList();
      final newer = results[1].reversed.toList();
      _endOlder = results[0].length < _kPageSize;
      _endNewer = results[1].length < _kPageSize;
      final merged = <MediaItem>[...older, ...newer];
      var at = merged.indexWhere((m) => m.fileId == widget.item.fileId);
      if (at == -1) {
        at = older.length;
        merged.insert(at, widget.item);
      } else {
        // Keep the item we were handed: it carries the live player. Its hash
        // only exists on the stored row.
        merged[at] = widget.item.withContentId(merged[at].contentId);
      }
      setState(() {
        _items = merged;
        _index = at;
      });
      _pages.jumpToPage(at);
      _precacheNeighbours();
    } catch (_) {
      // A conversation whose media cannot be listed still views this one item.
    } finally {
      _loadingOlder = false;
      _loadingNewer = false;
    }
  }

  Future<void> _loadMore({required bool older}) async {
    final context = widget.mediaContext;
    if (context == null) return;
    if (older ? (_loadingOlder || _endOlder) : (_loadingNewer || _endNewer)) {
      return;
    }
    final edge = older ? _items.first.timestampMs : _items.last.timestampMs;
    if (edge == null) return;
    if (older) {
      _loadingOlder = true;
    } else {
      _loadingNewer = true;
    }
    try {
      final rows = await MediaLibrary.page(
        contextType: context.contextType,
        contextId: context.contextId,
        beforeMs: older ? edge : null,
        afterMs: older ? null : edge,
        limit: _kPageSize,
      );
      if (!mounted) return;
      final known = {for (final m in _items) m.fileId};
      final fresh =
          rows.reversed.where((m) => !known.contains(m.fileId)).toList();
      if (older) {
        _endOlder = rows.length < _kPageSize;
      } else {
        _endNewer = rows.length < _kPageSize;
      }
      if (fresh.isEmpty) return;
      setState(() {
        if (older) {
          _items = [...fresh, ..._items];
          _index += fresh.length;
        } else {
          _items = [..._items, ...fresh];
        }
      });
      // Prepending moves every index, so the controller is put back on the
      // page the user is actually looking at.
      if (older) _pages.jumpToPage(_index);
    } catch (_) {
      // Leave the list as it is; the user can still walk what loaded.
    } finally {
      if (older) {
        _loadingOlder = false;
      } else {
        _loadingNewer = false;
      }
    }
  }

  void _precacheNeighbours() {
    if (!mounted) return;
    final started = DateTime.now();
    var count = 0;
    for (final offset in const [-1, 1]) {
      final i = _index + offset;
      if (i < 0 || i >= _items.length) continue;
      final item = _items[i];
      final path = item.diskPath;
      if (path == null || item.kind == MediaKind.video) continue;
      if (!File(path).existsSync()) continue;
      count++;
      unawaited(precacheImage(AtRestImageProvider(path), context)
          .catchError((Object _) {}));
    }
    if (count == 0) return;
    PerfSentinel.emit('[SENTINEL] media viewer preload n=$count '
        '${DateTime.now().difference(started).inMilliseconds}ms');
  }

  // --- zoom ---------------------------------------------------------------

  void _onTransform() {
    final quality = MediaZoomMath.filterQualityFor(
      currentScale: _transform.value.getMaxScaleOnAxis(),
      actualScale: _actualScale,
      crisp: mediaViewerCrispPixels,
    );
    // Only the BUCKET rebuilds the image; the readout listens to the
    // controller on its own.
    if (quality != _quality) setState(() => _quality = quality);
  }

  void _onGeometry(Size viewport, Size imageSize) {
    final fit = MediaZoomMath.fitSize(imageSize, viewport);
    // MediaQuery under UiScale already multiplies the display ratio by the
    // interface zoom, so passing both again would count it twice.
    final actual = MediaZoomMath.actualScale(
      imagePixelWidth: imageSize.width,
      fitLogicalWidth: fit.width,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      uiScale: 1.0,
    );
    if (viewport == _viewport &&
        imageSize == _imageSize &&
        (actual - _actualScale).abs() < 0.0001) {
      return;
    }
    setState(() {
      _viewport = viewport;
      _imageSize = imageSize;
      _actualScale = actual;
      _maxScale = MediaZoomMath.maxScaleFor(actual);
      _minScale = MediaZoomMath.minScaleFor(actual);
    });
  }

  void _onZoomTick() {
    final tween = _zoomTween;
    if (tween == null) return;
    _transform.value = tween.value;
    if (_zoomAnim.isCompleted) _zoomTween = null;
  }

  /// The image's rectangle on screen right now, in viewport coordinates.
  Rect? _imageRect() {
    final image = _imageSize;
    if (image == null || _viewport.isEmpty) return null;
    final fit = MediaZoomMath.fitSize(image, _viewport);
    final rect = Rect.fromCenter(
      center: _viewport.center(Offset.zero),
      width: fit.width,
      height: fit.height,
    );
    return MatrixUtils.transformRect(_transform.value, rect);
  }

  /// Z scales with X and Y: `getMaxScaleOnAxis` takes the LARGEST of the
  /// three, so a Z left at 1 hides every zoom below fit from the readout.
  Matrix4 _matrixFor(double scale, Offset translation) => Matrix4.identity()
    ..setEntry(0, 0, scale)
    ..setEntry(1, 1, scale)
    ..setEntry(2, 2, scale)
    ..setEntry(0, 3, translation.dx)
    ..setEntry(1, 3, translation.dy);

  void _zoomTo(double target, {Offset? focal}) {
    if (_viewport.isEmpty) return;
    final scale = target.clamp(_minScale, _maxScale);
    final matrix = _transform.value;
    final current = matrix.getMaxScaleOnAxis();
    final anchor = focal ?? _viewport.center(Offset.zero);
    final translation = Offset(matrix.storage[12], matrix.storage[13]);
    // The scene point under the anchor must stay under it.
    final scene = (anchor - translation) / current;
    final wanted = anchor - scene * scale;
    final next = Offset(
      _boundedTranslation(wanted.dx, _viewport.width, scale),
      _boundedTranslation(wanted.dy, _viewport.height, scale),
    );
    final destination = _matrixFor(scale, next);
    if (_reduced) {
      _zoomTween = null;
      _zoomAnim.stop();
      _transform.value = destination;
      return;
    }
    _zoomTween = Matrix4Tween(begin: matrix, end: destination)
        .animate(CurvedAnimation(parent: _zoomAnim, curve: Curves.easeOut));
    _zoomAnim.forward(from: 0);
  }

  /// Keeps the content inside the viewport, and centres it once it is smaller
  /// than one: below fit the slack is positive, which is not a clamp range.
  double _boundedTranslation(double value, double extent, double scale) {
    final slack = extent - extent * scale;
    if (slack >= 0) return slack / 2;
    return value.clamp(slack, 0.0);
  }

  void _resetZoom() {
    _zoomTween = null;
    _zoomAnim.stop();
    _transform.value = Matrix4.identity();
  }

  void _nudgeZoom(double factor) =>
      _zoomTo(_transform.value.getMaxScaleOnAxis() * factor);

  void _onDoubleTapAt(Offset local) {
    final next = MediaZoomMath.nextDoubleTapScale(
      _transform.value.getMaxScaleOnAxis(),
      _actualScale,
      _maxScale,
    );
    _zoomTo(next, focal: local);
  }

  // --- navigation ---------------------------------------------------------

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= _items.length) return;
    _resetZoom();
    if (_reduced) {
      _pages.jumpToPage(next);
      return;
    }
    _pages.animateToPage(next,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  void _onPageChanged(int index) {
    // Leaving zoom swaps the page physics, and that rebuild re-reports the
    // page we are already on; acting on it would throw away the zoom that
    // caused it.
    if (index == _index) return;
    setState(() {
      _index = index;
      _rotation = 0;
      _imageSize = null;
      _actualScale = 1.0;
      _maxScale = 8.0;
      _minScale = 1.0;
    });
    _resetZoom();
    updateFullscreenMediaSize(_current.pixelSize);
    _precacheNeighbours();
    if (index <= _kPrefetchMargin) unawaited(_loadMore(older: true));
    if (index >= _items.length - 1 - _kPrefetchMargin) {
      unawaited(_loadMore(older: false));
    }
  }

  // --- chrome -------------------------------------------------------------

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_reduced || _infoOpen) return;
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _showControls() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _onTapAt(Offset local) {
    if (isMobileMediaPlatform) {
      _toggleControls();
      return;
    }
    // Clicking the black around the image is how a desktop viewer closes,
    // but only at fit: past it the black is somewhere to pan to.
    final rect = _imageRect();
    final atFit = _transform.value.getMaxScaleOnAxis() <= 1.001;
    if (atFit && rect != null && !rect.contains(local)) {
      _dismiss();
      return;
    }
    _showControls();
  }

  void _dismiss() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    final route = ModalRoute.of(context);
    if (route == null) return;
    // A plain pop takes the TOP route, which on app lock is the cover pushed
    // above this one.
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  // --- keyboard -----------------------------------------------------------

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    if (ref.read(keybindCaptureActiveProvider)) return false;
    final hk = HardwareKeyboard.instance;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      // Walked into fullscreen from inside the viewer: the first Escape hands
      // the window back and stays, the second closes. A viewer opened from a
      // video bubble leaves both at once (Part A), and a fullscreen the user
      // was already in stays theirs.
      if (!widget.enterFullscreen &&
          enteredFullscreen &&
          ref.read(fullscreenProvider)) {
        unawaited(exitWindowFullscreen());
        return true;
      }
      _dismiss();
      return true;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _go(-1);
      return true;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _go(1);
      return true;
    }
    // AltGr reports as Ctrl+Alt on Windows, so a held Alt is the user typing a
    // layout character, never this shortcut.
    if (hk.isControlPressed &&
        !hk.isAltPressed &&
        key == LogicalKeyboardKey.keyC) {
      unawaited(_copyImage());
      return true;
    }

    final binds =
        ref.read(appShortcutsProvider).valueOrNull ?? kAppShortcutDefaults;
    bool match(AppShortcut s) => binds[s]!.matchesEvent(event, hk);

    if (match(AppShortcut.mediaZoomIn)) {
      _nudgeZoom(1.25);
      return true;
    }
    if (match(AppShortcut.mediaZoomOut)) {
      _nudgeZoom(1 / 1.25);
      return true;
    }
    if (match(AppShortcut.mediaZoomFit)) {
      _zoomTo(1.0);
      return true;
    }
    if (match(AppShortcut.mediaActualSize)) {
      _zoomTo(_actualScale);
      return true;
    }
    if (match(AppShortcut.mediaRotate)) {
      _rotate();
      return true;
    }
    if (match(AppShortcut.mediaInfo)) {
      _toggleInfo();
      return true;
    }
    if (match(AppShortcut.mediaSaveAs)) {
      unawaited(_saveAs());
      return true;
    }

    final video = _video;
    if (video == null) return false;
    if (match(AppShortcut.mediaPlayPause)) {
      video.value.isPlaying ? video.pause() : video.play();
      return true;
    }
    if (match(AppShortcut.mediaMute)) {
      video.setVolume(video.value.volume == 0 ? 1 : 0);
      return true;
    }
    if (match(AppShortcut.mediaLoop)) {
      video.setLooping(!video.value.isLooping);
      return true;
    }
    return false;
  }

  // --- actions ------------------------------------------------------------

  void _rotate() {
    setState(() => _rotation = (_rotation + 1) % 4);
    _resetZoom();
  }

  void _toggleInfo() {
    setState(() => _infoOpen = !_infoOpen);
    _showControls();
  }

  void _toggleCrisp() {
    setState(() => mediaViewerCrispPixels = !mediaViewerCrispPixels);
    _onTransform();
  }

  Future<void> _saveAs() async {
    final save = widget.actions.onSaveAs;
    if (save == null || _saving) return;
    setState(() => _saving = true);
    try {
      await save(_current.attachment);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Save failed', type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyImage() async {
    final path = _current.diskPath;
    if (path == null || _current.kind == MediaKind.video) return;
    try {
      final ok = await copyImageToClipboard(path);
      if (!mounted) return;
      HollowToast.show(
        context,
        ok ? 'Image copied' : 'Could not copy this image',
        type: ok ? HollowToastType.success : HollowToastType.error,
      );
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not copy this image',
            type: HollowToastType.error);
      }
    }
  }

  void _reply() {
    final messageId = _current.messageId;
    final reply = widget.actions.onReply;
    if (messageId == null || reply == null) return;
    _dismiss();
    reply(messageId);
  }

  void _jumpToMessage() {
    final messageId = _current.messageId;
    final jump = widget.actions.onJumpTo;
    if (messageId == null || jump == null) return;
    _dismiss();
    jump(messageId);
  }

  void _react() {
    final messageId = _current.messageId;
    final react = widget.actions.onReact;
    if (messageId == null || react == null) return;
    final anchorContext = _reactAnchor.currentContext;
    showEmojiPicker(
      context: context,
      anchorPosition: anchorContext == null
          ? overlayPositionOf(context, Offset.zero)
          : overlayAnchorOf(anchorContext),
      onSelect: (emoji) {
        unawaited(react(messageId, emoji).catchError((Object _) {
          if (mounted) {
            HollowToast.show(context, 'Could not add the reaction',
                type: HollowToastType.error);
          }
        }));
      },
    );
    _showControls();
  }

  Future<void> _delete() async {
    final messageId = _current.messageId;
    final delete = widget.actions.onDelete;
    if (messageId == null || delete == null || _deleting) return;
    final hollow = HollowTheme.of(context);
    // None of the three panes confirm a delete of their own, so the viewer is
    // the only place this question gets asked.
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Delete this message?',
        content: Text(
          'The message and its file go away for everyone in this conversation.',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _deleting = true);
    try {
      await delete(messageId);
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Failed to delete message',
            type: HollowToastType.error);
      }
      if (mounted) setState(() => _deleting = false);
      return;
    }
    if (!mounted) return;
    setState(() => _deleting = false);
    if (_items.length <= 1) {
      _dismiss();
      return;
    }
    final removed = _index;
    setState(() {
      _items = [..._items]..removeAt(removed);
      _index = removed >= _items.length - 1 ? _items.length - 1 : removed;
    });
    _pages.jumpToPage(_index);
  }

  void _openOverflow(Offset globalPosition) {
    final specs = _actionSpecs(includeNavigation: false);
    showHollowMenu(
      context: context,
      anchor: overlayPositionOf(context, globalPosition),
      builder: (menuContext, menuRef) => [
        for (final spec in specs)
          HollowMenuItem(
            label: spec.label,
            icon: spec.icon,
            isDanger: spec.danger,
            enabled: spec.onTap != null,
            onTap: spec.onTap,
          ),
      ],
    );
  }

  // --- build --------------------------------------------------------------

  /// Every action of the current item, shared by the bars and the menu.
  List<MediaControlSpec> _actionSpecs({bool includeNavigation = true}) {
    final item = _current;
    final isImage = item.kind != MediaKind.video;
    final canCopy = isImage && canCopyImageToClipboard && item.diskPath != null;
    return [
      if (includeNavigation && isImage)
        MediaControlSpec(
          icon: LucideIcons.scanSearch,
          label: 'Actual size',
          onTap: () => _zoomTo(_actualScale),
        ),
      if (includeNavigation && isImage)
        MediaControlSpec(
          icon: LucideIcons.grid2x2,
          label: 'Crisp pixels',
          active: mediaViewerCrispPixels,
          onTap: _toggleCrisp,
        ),
      if (isImage)
        MediaControlSpec(
          icon: LucideIcons.rotateCw,
          label: 'Rotate',
          onTap: _rotate,
        ),
      MediaControlSpec(
        icon: LucideIcons.info,
        label: 'Details',
        active: _infoOpen,
        onTap: _toggleInfo,
      ),
      if (widget.actions.onSaveAs != null)
        MediaControlSpec(
          icon: LucideIcons.download,
          label: 'Save as',
          busy: _saving,
          onTap: _saveAs,
        ),
      if (canCopy)
        MediaControlSpec(
          icon: LucideIcons.copy,
          label: 'Copy image',
          onTap: () => unawaited(_copyImage()),
        ),
      if (widget.actions.onReply != null && item.messageId != null)
        MediaControlSpec(
          icon: LucideIcons.reply,
          label: 'Reply',
          onTap: _reply,
        ),
      if (widget.actions.onReact != null && item.messageId != null)
        MediaControlSpec(
          icon: LucideIcons.smilePlus,
          label: 'React',
          onTap: _react,
        ),
      if (item.isMine && widget.actions.onDelete != null)
        MediaControlSpec(
          icon: LucideIcons.trash2,
          label: 'Delete',
          danger: true,
          busy: _deleting,
          onTap: _delete,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // Leaving the OS fullscreen leaves a viewer that entered it, so F11, the
    // control bar and the app lock all close it. A viewer opened in-window is
    // unaffected, which is what keeps F11 a window toggle for an image.
    if (widget.enterFullscreen) {
      ref.listen<bool>(fullscreenProvider, (previous, next) {
        if (previous == true && next == false) _dismiss();
      });
    } else {
      // Left by some other route (F11, the app lock): the window is the
      // user's again, so closing the viewer must not touch it.
      ref.listen<bool>(fullscreenProvider, (previous, next) {
        if (previous == true && next == false && enteredFullscreen) {
          unawaited(exitWindowFullscreen());
        }
      });
    }
    final isFullscreen = ref.watch(fullscreenProvider);
    final fade = _reduced ? 1.0 : (_controlsVisible ? 1.0 : 0.0);
    final specs = _actionSpecs();

    return Material(
      color: Colors.black.withValues(
          alpha: 1.0 - (_dragDy.abs() / (_kDismissDrag * 3)).clamp(0.0, 0.6)),
      child: MouseRegion(
        onHover: (_) => _showControls(),
        child: Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: (_) => _endDrag(),
          // The desktop panel takes a column of its own, so it never covers
          // the controls or the strip; the mobile sheet sits over them.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Transform.translate(
                        offset: Offset(0, _dragDy),
                        child: _buildPages(isFullscreen),
                      ),
                    ),
                    _buildTopBar(specs, fade),
                    if (_walkable) ..._buildChevrons(fade),
                    _buildBottom(specs, fade),
                    if (_infoOpen && isMobileMediaPlatform) _buildInfo(),
                  ],
                ),
              ),
              if (_infoOpen && !isMobileMediaPlatform) _buildInfo(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPages(bool isFullscreen) {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.001;
    return PageView.builder(
      controller: _pages,
      allowImplicitScrolling: true,
      physics: zoomed || _items.length <= 1
          ? const NeverScrollableScrollPhysics()
          : const PageScrollPhysics(),
      onPageChanged: _onPageChanged,
      itemCount: _items.length,
      itemBuilder: (context, i) {
        final item = _items[i];
        final isCurrent = i == _index;
        if (item.kind == MediaKind.video) {
          return MediaVideoPage(
            key: ValueKey('media-video-${item.fileId}'),
            item: item,
            isCurrent: isCurrent,
            isFullscreen: isFullscreen,
            onFullscreen: _videoFullscreenAction(),
            onController: (controller) {
              if (!isCurrent || _video == controller) return;
              // Reported from the page's own build phase, so the rebuild this
              // needs waits for the frame to finish.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && _video != controller) {
                  setState(() => _video = controller);
                }
              });
            },
          );
        }
        return MediaZoomView(
          key: ValueKey('media-image-${item.fileId}'),
          item: item,
          transform: _transform,
          quarterTurns: isCurrent ? _rotation : 0,
          minScale: _minScale,
          maxScale: _maxScale,
          filterQuality: _quality,
          isCurrent: isCurrent,
          onGeometry: isCurrent ? _onGeometry : null,
          onTapAt: _onTapAt,
          onDoubleTapAt: _onDoubleTapAt,
          onSecondaryTapAt: _openOverflow,
        );
      },
    );
  }

  /// What the player's own fullscreen button does: leave the way we came in.
  VoidCallback? _videoFullscreenAction() {
    if (isMobileMediaPlatform || !FullscreenNotifier.supported) return null;
    if (widget.enterFullscreen) return _dismiss;
    return _toggleWindowFullscreen;
  }

  void _toggleWindowFullscreen() {
    if (ref.read(fullscreenProvider)) {
      unawaited(exitWindowFullscreen());
    } else {
      unawaited(enterWindowFullscreen());
    }
  }

  Widget _buildTopBar(List<MediaControlSpec> specs, double fade) {
    final mobile = isMobileMediaPlatform;
    final visible = fade > 0;
    return Positioned(
      top: HollowSpacing.lg,
      left: HollowSpacing.lg,
      right: HollowSpacing.lg,
      child: AnimatedOpacity(
        opacity: fade,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !visible,
          child: Row(
            children: [
              MediaControlBar(children: [
                MediaControlButton(
                  spec: MediaControlSpec(
                    icon: LucideIcons.x,
                    label: 'Close',
                    onTap: _dismiss,
                  ),
                ),
                MediaCounterLabel(index: _index, total: _items.length),
              ]),
              const Spacer(),
              if (!mobile && _current.kind != MediaKind.video) ...[
                MediaControlBar(children: [
                  MediaZoomReadout(
                    transform: _transform,
                    actualScale: _actualScale,
                  ),
                ]),
                const SizedBox(width: HollowSpacing.sm),
              ],
              if (mobile)
                MediaControlBar(children: [
                  MediaControlButton(
                    spec: MediaControlSpec(
                      icon: LucideIcons.info,
                      label: 'Details',
                      active: _infoOpen,
                      onTap: _toggleInfo,
                    ),
                  ),
                  MediaRotateButton(
                    landscape: forcedLandscape,
                    onTap: toggleForcedLandscape,
                  ),
                ])
              else
                MediaControlBar(children: [
                  for (final spec in specs)
                    Padding(
                      key: spec.label == 'React' ? _reactAnchor : null,
                      padding: const EdgeInsets.symmetric(horizontal: 1),
                      child: MediaControlButton(spec: spec),
                    ),
                ]),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildChevrons(double fade) {
    Widget side({required bool forward}) => Positioned(
          left: forward ? null : HollowSpacing.md,
          right: forward ? HollowSpacing.md : null,
          top: 0,
          bottom: 0,
          child: Center(
            child: AnimatedOpacity(
              opacity: fade,
              duration: const Duration(milliseconds: 200),
              child: IgnorePointer(
                ignoring: fade == 0,
                child: MediaChevron(
                  forward: forward,
                  onTap: forward
                      ? (_index < _items.length - 1 ? () => _go(1) : null)
                      : (_index > 0 ? () => _go(-1) : null),
                ),
              ),
            ),
          ),
        );
    return [side(forward: false), side(forward: true)];
  }

  Widget _buildBottom(List<MediaControlSpec> specs, double fade) {
    final mobile = isMobileMediaPlatform;
    final video = _current.isVideo ? _video : null;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedOpacity(
        opacity: fade,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: fade == 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mobile)
                Padding(
                  padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
                  child: MediaControlBar(children: [
                    for (final spec in specs)
                      Padding(
                        key: spec.label == 'React' ? _reactAnchor : null,
                        padding: const EdgeInsets.symmetric(horizontal: 1),
                        child: MediaControlButton(spec: spec),
                      ),
                  ]),
                ),
              if (video != null)
                MediaVideoControls(
                  controller: video,
                  isFullscreen: ref.watch(fullscreenProvider),
                  onFullscreen: _videoFullscreenAction(),
                ),
              if (_walkable)
                MediaStrip(
                  items: _items,
                  index: _index,
                  onSelect: (i) => _go(i - _index),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfo() {
    final panel = MediaInfoPanel(
      item: _current,
      onClose: _toggleInfo,
      onJumpToMessage: widget.actions.onJumpTo == null ||
              _current.messageId == null
          ? null
          : _jumpToMessage,
      isSidePanel: !isMobileMediaPlatform,
    );
    if (isMobileMediaPlatform) {
      return Positioned(left: 0, right: 0, bottom: 0, child: panel);
    }
    return panel;
  }

  // --- swipe down to dismiss (mobile) -------------------------------------

  void _onPointerDown(PointerDownEvent event) {
    if (!isMobileMediaPlatform || _dragPointer != null) return;
    if (_transform.value.getMaxScaleOnAxis() > 1.001) return;
    _dragPointer = event.pointer;
    _dragStart = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _dragPointer) return;
    final delta = event.position - _dragStart;
    // A horizontal intent belongs to the PageView, which owns the gesture
    // arena; this only follows a clearly downward finger.
    if (delta.dy <= 0 || delta.dy.abs() < delta.dx.abs()) return;
    setState(() => _dragDy = delta.dy);
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _dragPointer) return;
    final travelled = _dragDy;
    _endDrag();
    if (travelled > _kDismissDrag) _dismiss();
  }

  void _endDrag() {
    _dragPointer = null;
    if (_dragDy != 0 && mounted) setState(() => _dragDy = 0);
  }
}
