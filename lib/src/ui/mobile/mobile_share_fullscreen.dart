import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/media/fullscreen_media_chrome.dart';
import 'package:hollow/src/ui/media/media_zoom_view.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A watched share full screen on the phone: turned to landscape, pinch to
/// zoom, a tap brings the controls back.
Future<void> openMobileShareFullscreen(
    BuildContext context, CallStageSource source, String owner) {
  return Navigator.of(context, rootNavigator: true)
      .push(hollowMobileRoute(
        transition: HollowRouteTransition.fade,
        builder: (_) => MobileShareFullscreen(source: source, owner: owner),
      ))
      // Neither this nor the route's dispose alone is sure to run before the
      // next push (see [restoreAppOrientation]).
      .whenComplete(restoreAppOrientation);
}

class MobileShareFullscreen extends ConsumerStatefulWidget {
  final CallStageSource source;

  /// The sharer, as the call keys them.
  final String owner;

  const MobileShareFullscreen({
    super.key,
    required this.source,
    required this.owner,
  });

  @override
  ConsumerState<MobileShareFullscreen> createState() =>
      _MobileShareFullscreenState();
}

class _MobileShareFullscreenState extends ConsumerState<MobileShareFullscreen>
    with FullscreenMediaChrome<MobileShareFullscreen> {
  final _transform = TransformationController();
  bool _chrome = true;
  Timer? _hide;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    beginFullscreenMedia(const Size(16, 9));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) toggleForcedLandscape();
    });
    _scheduleHide();
  }

  @override
  void dispose() {
    _hide?.cancel();
    _transform.dispose();
    endFullscreenMedia();
    super.dispose();
  }

  /// The controls fade after two quiet seconds; Reduce motion keeps them.
  void _scheduleHide() {
    _hide?.cancel();
    if (ReduceMotionController.instance.isReduced) return;
    _hide = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _chrome = false);
    });
  }

  void _toggleChrome() {
    setState(() => _chrome = !_chrome);
    if (_chrome) _scheduleHide();
  }

  void _leave() {
    if (_leaving) return;
    _leaving = true;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.source.watchData(context, ref);
    CallShare? share;
    for (final s in data?.shares ?? const <CallShare>[]) {
      if (s.owner == widget.owner && s.watched && !s.isMine) share = s;
    }
    if (share == null) {
      // The share ended or the call did: nothing left to watch.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _leave();
      });
      return const ColoredBox(color: HollowColors.mediaBlack);
    }
    final renderer = share.renderer;
    final media = callMediaTheme(HollowTheme.of(context));
    final duration = ReduceMotionController.instance.isReduced
        ? Duration.zero
        : HollowDurations.fast;
    final stopWatching = data!.onStopWatching;
    final owner = share.owner;

    return Scaffold(
      backgroundColor: HollowColors.mediaBlack,
      body: Stack(
        children: [
          Positioned.fill(
            child: ZoomSurface(
              transform: _transform,
              maxScale: 6,
              onTapAt: (_) => _toggleChrome(),
              child: Center(
                child: renderer == null
                    ? const SizedBox.shrink()
                    : RepaintBoundary(
                        child: RTCVideoView(
                          renderer,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                        ),
                      ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedOpacity(
              opacity: _chrome ? 1 : 0,
              duration: duration,
              child: IgnorePointer(
                ignoring: !_chrome,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.all(HollowSpacing.md),
                    child: Row(
                      children: [
                        MobileScrimIconButton(
                          icon: LucideIcons.minimize,
                          label: 'Exit full screen',
                          onTap: _leave,
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        Flexible(
                          child: CallMediaLabel(
                            child: Text(
                              "${share.name}'s screen",
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: HollowTypography.label.copyWith(
                                color: callNameColor(media,
                                    isSelf: false, master: share.master),
                              ),
                            ),
                          ),
                        ),
                        const Spacer(),
                        MediaRotateButton(
                          landscape: forcedLandscape,
                          onTap: toggleForcedLandscape,
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        MobileScrimIconButton(
                          icon: LucideIcons.eyeOff,
                          label: 'Stop watching',
                          onTap: () {
                            stopWatching(owner);
                            _leave();
                          },
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
