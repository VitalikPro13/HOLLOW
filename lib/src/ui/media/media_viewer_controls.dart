import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:video_player/video_player.dart';

import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/media/media_zoom_math.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';

/// One control of the viewer's bars, and the same row of the overflow menu.
@immutable
class MediaControlSpec {
  final IconData icon;

  /// Screen-reader name and menu row label. Sentence case.
  final String label;
  final VoidCallback? onTap;

  /// Shows a spinner in place of the icon while the action is in flight.
  final bool busy;

  /// A toggle that is currently on, tinted with the accent.
  final bool active;

  /// Destructive intent, for the menu row's tint.
  final bool danger;

  const MediaControlSpec({
    required this.icon,
    required this.label,
    this.onTap,
    this.busy = false,
    this.active = false,
    this.danger = false,
  });
}

/// One icon control of the viewer.
class MediaControlButton extends StatelessWidget {
  final MediaControlSpec spec;

  const MediaControlButton({super.key, required this.spec});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = spec.onTap == null
        ? Colors.white.withValues(alpha: 0.35)
        : spec.active
            ? hollow.accentText
            : Colors.white;
    return HollowPressable(
      onTap: spec.busy ? null : spec.onTap,
      disabled: spec.onTap == null,
      semanticLabel: spec.label,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      padding: const EdgeInsets.all(HollowSpacing.sm),
      // The spinner keeps the icon's box so the control row never shifts.
      child: spec.busy
          ? SizedBox.square(
              dimension: _controlIconSize,
              child: Center(child: HollowSpinner(color: color)),
            )
          : Icon(spec.icon, size: _controlIconSize, color: color),
    );
  }
}

/// A floating row of controls over the media.
class MediaControlBar extends StatelessWidget {
  final List<Widget> children;

  const MediaControlBar({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.xs,
        vertical: HollowSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

/// "3 of 12", announced on every page change.
class MediaCounterLabel extends StatelessWidget {
  final int index;
  final int total;

  const MediaCounterLabel({super.key, required this.index, required this.total});

  @override
  Widget build(BuildContext context) {
    final text = '${index + 1} of $total';
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
        child: Text(
          text,
          style: HollowTypography.caption.copyWith(
            color: Colors.white,
            fontSize: 12,
            decoration: TextDecoration.none,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
    );
  }
}

/// The live zoom readout, where 100 percent is one image pixel per device
/// pixel. Rebuilds only this label, never the image.
class MediaZoomReadout extends StatelessWidget {
  final TransformationController transform;
  final double actualScale;

  const MediaZoomReadout({
    super.key,
    required this.transform,
    required this.actualScale,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Matrix4>(
      valueListenable: transform,
      builder: (context, matrix, _) {
        final percent =
            MediaZoomMath.zoomPercent(matrix.getMaxScaleOnAxis(), actualScale);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          child: Text(
            '$percent%',
            style: HollowTypography.caption.copyWith(
              color: Colors.white,
              fontSize: 12,
              decoration: TextDecoration.none,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}

/// A previous or next affordance that fades with the rest of the controls.
class MediaChevron extends StatelessWidget {
  final bool forward;
  final VoidCallback? onTap;

  const MediaChevron({super.key, required this.forward, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return const SizedBox(width: 40);
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      semanticLabel: forward ? 'Next item' : 'Previous item',
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      backgroundColor: Colors.black.withValues(alpha: 0.45),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.xs,
        vertical: HollowSpacing.md,
      ),
      child: Icon(
        forward ? LucideIcons.chevronRight : LucideIcons.chevronLeft,
        size: 22,
        color: Colors.white,
      ),
    );
  }
}

/// Playback speeds, in the order the one speed control cycles them.
const List<double> kMediaSpeeds = [1.0, 1.25, 1.5, 2.0, 0.5, 0.75];

/// `m:ss`, the only time format a media surface shows.
String formatMediaDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = d.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// The viewer's own transport for a video page.
///
/// The viewer owns these rather than the inline player: its strip and chevrons
/// are drawn over the page, so a control bar inside the page ends up under them
/// and out of reach.
class MediaVideoControls extends StatefulWidget {
  final VideoPlayerController controller;

  /// True while the window covers the monitor, which is what the button says.
  final bool isFullscreen;

  /// Null where there is no window fullscreen, which hides the control.
  final VoidCallback? onFullscreen;

  const MediaVideoControls({
    super.key,
    required this.controller,
    this.isFullscreen = false,
    this.onFullscreen,
  });

  @override
  State<MediaVideoControls> createState() => _MediaVideoControlsState();
}

class _MediaVideoControlsState extends State<MediaVideoControls> {
  Duration? _hoverTime;
  double _hoverX = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTick);
  }

  @override
  void didUpdateWidget(MediaVideoControls old) {
    super.didUpdateWidget(old);
    if (old.controller == widget.controller) return;
    old.controller.removeListener(_onTick);
    widget.controller.addListener(_onTick);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTick);
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _togglePlay() {
    final c = widget.controller;
    if (c.value.isPlaying) {
      c.pause();
    } else {
      c.play();
    }
  }

  void _cycleSpeed() {
    final current = widget.controller.value.playbackSpeed;
    final at = kMediaSpeeds.indexWhere((s) => (s - current).abs() < 0.01);
    final next = kMediaSpeeds[(at < 0 ? 0 : at + 1) % kMediaSpeeds.length];
    widget.controller.setPlaybackSpeed(next);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final value = widget.controller.value;
    final durationMs = value.duration.inMilliseconds;
    final speed = value.playbackSpeed;

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xxs,
      ),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        children: [
          MediaControlButton(
            spec: MediaControlSpec(
              icon: value.isPlaying ? LucideIcons.pause : LucideIcons.play,
              label: value.isPlaying ? 'Pause video' : 'Play video',
              onTap: _togglePlay,
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            '${formatMediaDuration(value.position)} / '
            '${formatMediaDuration(value.duration)}',
            style: HollowTypography.caption.copyWith(
              color: Colors.white,
              fontSize: 11,
              decoration: TextDecoration.none,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(child: _seekBar(hollow, durationMs)),
          const SizedBox(width: HollowSpacing.sm),
          HollowPressable(
            onTap: _cycleSpeed,
            semanticLabel: 'Playback speed',
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.xs,
              vertical: HollowSpacing.sm,
            ),
            child: Text(
              speed == speed.roundToDouble()
                  ? '${speed.toStringAsFixed(0)}x'
                  : '${speed}x',
              style: HollowTypography.caption.copyWith(
                color: Colors.white,
                fontSize: 11,
                decoration: TextDecoration.none,
              ),
            ),
          ),
          MediaControlButton(
            spec: MediaControlSpec(
              icon: value.isLooping ? LucideIcons.repeat1 : LucideIcons.repeat,
              label: 'Loop video',
              active: value.isLooping,
              onTap: () => widget.controller.setLooping(!value.isLooping),
            ),
          ),
          VerticalVolumePopover(controller: widget.controller),
          if (widget.onFullscreen != null)
            MediaControlButton(
              spec: MediaControlSpec(
                icon: widget.isFullscreen
                    ? LucideIcons.minimize2
                    : LucideIcons.maximize2,
                label: widget.isFullscreen
                    ? 'Exit fullscreen'
                    : 'Enter fullscreen',
                onTap: widget.onFullscreen,
              ),
            ),
        ],
      ),
    );
  }

  /// The seek bar, with the time under the pointer while it is over the track.
  Widget _seekBar(HollowTheme hollow, int durationMs) {
    final position = widget.controller.value.position.inMilliseconds;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MouseRegion(
          onHover: (event) {
            if (durationMs <= 0 || width <= 0) return;
            final fraction = (event.localPosition.dx / width).clamp(0.0, 1.0);
            setState(() {
              _hoverX = event.localPosition.dx;
              _hoverTime =
                  Duration(milliseconds: (durationMs * fraction).round());
            });
          },
          onExit: (_) => setState(() => _hoverTime = null),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Semantics(
                label: 'Seek',
                container: true,
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 12),
                    activeTrackColor: hollow.accent,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: hollow.accent,
                    overlayColor: hollow.accent.withValues(alpha: 0.2),
                  ),
                  child: Slider(
                    min: 0,
                    max: durationMs.toDouble().clamp(1, double.infinity),
                    value: position.clamp(0, durationMs).toDouble(),
                    onChanged: (v) => widget.controller
                        .seekTo(Duration(milliseconds: v.toInt())),
                  ),
                ),
              ),
              if (_hoverTime != null)
                Positioned(
                  // Kept clear of the right edge, or the label lays out in
                  // no width at all and paints as a sliver.
                  left: (_hoverX - 20).clamp(0.0, math.max(0.0, width - 44)),
                  top: -18,
                  child: Text(
                    formatMediaDuration(_hoverTime!),
                    style: HollowTypography.caption.copyWith(
                      color: Colors.white,
                      fontSize: 10,
                      decoration: TextDecoration.none,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// The volume control both media surfaces use: a mute toggle whose level
/// slider opens above it on hover.
///
/// The slider rides an [OverlayEntry] rather than the surface's own Stack: a
/// popover that overflows its parent paints fine and then refuses every
/// pointer, because hit testing stops at each parent's bounds.
class VerticalVolumePopover extends StatefulWidget {
  final VideoPlayerController controller;
  final double iconSize;
  final EdgeInsetsGeometry padding;

  const VerticalVolumePopover({
    super.key,
    required this.controller,
    this.iconSize = 18,
    this.padding = const EdgeInsets.all(HollowSpacing.sm),
  });

  @override
  State<VerticalVolumePopover> createState() => _VerticalVolumePopoverState();
}

class _VerticalVolumePopoverState extends State<VerticalVolumePopover> {
  static const double _popoverWidth = 34;
  static const double _popoverHeight = 116;
  static const double _step = 0.05;

  OverlayEntry? _entry;
  Timer? _hideTimer;
  bool _overIcon = false;
  bool _overPopover = false;
  double _lastVolume = 1.0;

  @override
  void deactivate() {
    _hide();
    super.deactivate();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _hide();
    super.dispose();
  }

  void _hide() {
    _hideTimer?.cancel();
    OverlayHosts.unregister(this);
    _entry?.remove();
    _entry = null;
  }

  /// Hover leaving the icon may be on its way to the popover, so the two share
  /// one grace period.
  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted || _overIcon || _overPopover) return;
      _hide();
    });
  }

  void _show() {
    _hideTimer?.cancel();
    if (_entry != null) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final anchor = overlayAnchorOf(context);
    final left = anchor.dx + (box.size.width - _popoverWidth) / 2;
    final top = anchor.dy - _popoverHeight - HollowSpacing.xs;

    _entry = OverlayEntry(
      builder: (context) => Positioned(
        left: math.max(0, left),
        top: math.max(0, top),
        width: _popoverWidth,
        height: _popoverHeight,
        child: _popover(context),
      ),
    );
    Overlay.of(context).insert(_entry!);
    OverlayHosts.register(this, _hide);
  }

  void _setVolume(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped > 0) _lastVolume = clamped;
    widget.controller.setVolume(clamped);
  }

  void _toggleMute() {
    final volume = widget.controller.value.volume;
    if (volume > 0) _lastVolume = volume;
    widget.controller
        .setVolume(volume > 0 ? 0 : (_lastVolume <= 0 ? 1 : _lastVolume));
  }

  void _onSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final direction = event.scrollDelta.dy > 0 ? -1 : 1;
    _setVolume(widget.controller.value.volume + direction * _step);
  }

  Widget _popover(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return MouseRegion(
      onEnter: (_) {
        _overPopover = true;
        _hideTimer?.cancel();
      },
      onExit: (_) {
        _overPopover = false;
        _scheduleHide();
      },
      child: Listener(
        onPointerSignal: _onSignal,
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            ),
            child: ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) => Semantics(
                label: 'Volume',
                container: true,
                child: RotatedBox(
                  quarterTurns: 3,
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 5),
                      overlayShape: SliderComponentShape.noOverlay,
                      activeTrackColor: hollow.accent,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: hollow.accent,
                    ),
                    child: Slider(
                      value: value.volume.clamp(0.0, 1.0),
                      onChanged: _setVolume,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final volume = widget.controller.value.volume;
    final muted = volume == 0;
    return MouseRegion(
      onEnter: (_) {
        _overIcon = true;
        _show();
      },
      onExit: (_) {
        _overIcon = false;
        _scheduleHide();
      },
      child: Listener(
        onPointerSignal: _onSignal,
        child: HollowPressable(
          onTap: _toggleMute,
          semanticLabel: muted ? 'Unmute video' : 'Mute video',
          borderRadius: BorderRadius.circular(4),
          padding: widget.padding,
          child: Icon(
            muted
                ? LucideIcons.volumeX
                : (volume < 0.5 ? LucideIcons.volume1 : LucideIcons.volume2),
            size: widget.iconSize,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

const double _controlIconSize = 18;
