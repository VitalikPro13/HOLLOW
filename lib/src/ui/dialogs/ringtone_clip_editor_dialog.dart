import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/waveform.dart' as waveform_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_progress_bar.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void showRingtoneClipEditor(BuildContext context, String filePath) {
  showHollowDialog(
    context: context,
    builder: (_) => RingtoneClipEditorDialog(filePath: filePath),
  );
}

/// Max clip length the ringtone can be trimmed to.
const double _kMaxClip = 30.0;

/// Decoded once at this resolution; the painter folds buckets into pixel
/// columns, so any dialog width up to this many pixels shows every peak.
const int _kWaveformBuckets = 2048;

/// A ringtone file as the trim dialog sees it. [durationSecs] 0 = the file
/// could not be read at all; null peaks = its length is known but it could
/// not be decoded for drawing.
class RingtoneWaveform {
  final double durationSecs;
  final Float32List? min;
  final Float32List? max;
  final Float32List? rms;

  const RingtoneWaveform({
    required this.durationSecs,
    this.min,
    this.max,
    this.rms,
  });

  bool get hasPeaks => min != null && max != null && rms != null;
}

/// Decodes [path] in Rust for the real duration and peaks. A format the
/// decoder lacks (Opus in Ogg) falls back to the player's duration with no
/// waveform, so the file can still be trimmed by time.
Future<RingtoneWaveform> loadRingtoneWaveform(String path) async {
  try {
    final w = await waveform_api.audioWaveform(
        path: path, buckets: _kWaveformBuckets);
    if (w.durationSecs > 0) {
      return RingtoneWaveform(
        durationSecs: w.durationSecs,
        min: w.min,
        max: w.max,
        rms: w.rms,
      );
    }
  } catch (e) {
    debugPrint('[ringtone] waveform decode failed: $e');
  }
  final probe = AudioPlayer();
  try {
    await probe
        .setSource(DeviceFileSource(path))
        .timeout(const Duration(seconds: 5));
    final d = await probe.getDuration();
    return RingtoneWaveform(durationSecs: (d?.inMilliseconds ?? 0) / 1000.0);
  } catch (e) {
    debugPrint('[ringtone] duration probe failed: $e');
    return const RingtoneWaveform(durationSecs: 0);
  } finally {
    unawaited(probe.dispose().catchError((_) {}));
  }
}

class RingtoneClipEditorDialog extends ConsumerStatefulWidget {
  final String filePath;

  /// Replaced in tests, which have no Rust.
  final Future<RingtoneWaveform> Function(String path) loadWaveform;

  const RingtoneClipEditorDialog({
    super.key,
    required this.filePath,
    this.loadWaveform = loadRingtoneWaveform,
  });

  @override
  ConsumerState<RingtoneClipEditorDialog> createState() =>
      _RingtoneClipEditorDialogState();
}

class _RingtoneClipEditorDialogState
    extends ConsumerState<RingtoneClipEditorDialog> with HollowDialogAction {
  AudioPlayer? _player;
  RingtoneWaveform? _wave;
  double _start = 0.0;
  double _end = _kMaxClip;
  double _currentPos = 0.0;
  bool _isPlaying = false;
  StreamSubscription? _posSub;

  double get _total => _wave?.durationSecs ?? 0;
  bool get _loaded => _wave != null;
  bool get _readable => _total > 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final wave = await widget.loadWaveform(widget.filePath);
    double start = 0;
    double end = _kMaxClip;
    double cached = 0;
    try {
      start = await ref.read(ringtoneStartProvider.future);
      end = await ref.read(ringtoneEndProvider.future);
      cached = await ref.read(ringtoneDurationProvider.future);
    } catch (e) {
      debugPrint('[ringtone] could not read the saved trim: $e');
    }
    if (!mounted) return;
    final total = wave.durationSecs;
    if (total > 0) {
      if (end > total) end = total;
      if (start >= end) start = 0;
      if (end - start > _kMaxClip) end = start + _kMaxClip;
      if ((cached - total).abs() > 0.05) {
        unawaited(ref
            .read(ringtoneDurationProvider.notifier)
            .setDuration(total)
            .catchError((_) {}));
      }
    }
    setState(() {
      _wave = wave;
      _start = start;
      _end = end;
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    final player = _player;
    _player = null;
    if (player != null) {
      unawaited(player.stop().then((_) => player.dispose()).catchError((_) {}));
    }
    super.dispose();
  }

  Future<void> _startPreview() async {
    await _stopPreview();
    try {
      final player = AudioPlayer();
      _player = player;
      final volume = await ref.read(ringtoneVolumeProvider.future);
      await player.setVolume(volume);
      await player.play(DeviceFileSource(widget.filePath));
      await player.seek(Duration(milliseconds: (_start * 1000).round()));
      _posSub = player.onPositionChanged.listen((pos) {
        if (!mounted) return;
        final posSeconds = pos.inMilliseconds / 1000.0;
        setState(() => _currentPos = posSeconds);
        if (posSeconds >= _end || posSeconds < _start - 0.5) {
          _player?.seek(Duration(milliseconds: (_start * 1000).round()));
        }
      });
      if (mounted) {
        setState(() {
          _isPlaying = true;
          actionError = null;
        });
      }
    } catch (e) {
      await _stopPreview();
      if (mounted) {
        setState(() => actionError = friendlyError(e,
            fallback: "Hollow couldn't play this file. Try another one."));
      }
    }
  }

  Future<void> _stopPreview() async {
    _posSub?.cancel();
    _posSub = null;
    final player = _player;
    _player = null;
    if (player != null) {
      try {
        await player.stop();
        await player.dispose();
      } catch (_) {
        // Already torn down by the platform; nothing is playing either way.
      }
    }
    if (mounted && _isPlaying) setState(() => _isPlaying = false);
  }

  Future<void> _save() async {
    final ok = await runDialogAction(() async {
      await ref.read(ringtoneStartProvider.notifier).setStart(_start);
      await ref.read(ringtoneEndProvider.notifier).setEnd(_end);
    }, fallback: "Hollow couldn't save the trim. Try again.");
    if (!ok || !mounted) return;
    await _stopPreview();
    if (mounted) Navigator.pop(context);
  }

  Widget _flexField(bool compact, Widget field) =>
      compact ? field : Expanded(child: field);

  String _formatTime(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toInt();
    final ms = ((seconds - seconds.truncate()) * 10).floor();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.$ms';
  }

  /// Moves the start handle, keeping start below end and the clip under the
  /// maximum.
  void _setStart(double v) {
    setState(() {
      _start = v.clamp(0.0, _total);
      if (_start > _end - 0.1) _start = (_end - 0.1).clamp(0.0, _total);
      if (_end - _start > _kMaxClip) _end = _start + _kMaxClip;
    });
  }

  /// Moves the end handle, keeping end above start and the clip under the
  /// maximum.
  void _setEnd(double v) {
    setState(() {
      _end = v.clamp(0.0, _total);
      if (_end < _start + 0.1) _end = (_start + 0.1).clamp(0.0, _total);
      if (_end - _start > _kMaxClip) _start = _end - _kMaxClip;
    });
  }

  /// Shifts the whole window by [delta] seconds, preserving its length.
  void _nudgeWindow(double delta) {
    final len = _end - _start;
    final newStart =
        (_start + delta).clamp(0.0, math.max(0.0, _total - len)).toDouble();
    setState(() {
      _start = newStart;
      _end = newStart + len;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final fileName = widget.filePath.split(RegExp(r'[\\/]')).last;

    if (_loaded && !_readable) {
      return const HollowDialog(
        title: 'Trim ringtone',
        showClose: true,
        content: HollowDialogText(
          "Hollow can't read this file, so there's nothing to trim. Choose "
          'another ringtone with Change.',
        ),
      );
    }

    final compact = HollowDialogSurface.isCompact(context);
    final iconSize = compact ? 44.0 : 32.0;
    const tabular = [FontFeature.tabularFigures()];
    return HollowDialog(
      title: 'Trim ringtone',
      width: 520,
      busy: actionRunning,
      error: actionError,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  fileName,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (_loaded) ...[
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  _formatTime(_total),
                  style: HollowTypography.monoSmall
                      .copyWith(color: hollow.textSecondary),
                ),
              ],
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          if (!_loaded)
            const SizedBox(
              height: _WaveformSelectorState.height,
              child: Center(child: HollowSpinner.medium()),
            )
          else ...[
            _WaveformSelector(
              wave: _wave!,
              start: _start,
              end: _end,
              playhead: _isPlaying ? _currentPos : null,
              onStart: _setStart,
              onEnd: _setEnd,
              onWindow: (s) => _nudgeWindow(s - _start),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    _wave!.hasPeaks
                        ? 'Drag an edge to trim, or the middle to move the '
                            'selection.'
                        : "Hollow can't draw a waveform for this file. Trim "
                            'it with the times below.',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  '${(_end - _start).clamp(0.0, _kMaxClip).toStringAsFixed(1)}'
                  ' s selected (${_kMaxClip.toInt()} s max)',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontFeatures: tabular,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.lg),
            // Side by side, two touch-size fields leave the time too little
            // room on a phone.
            Flex(
              direction: compact ? Axis.vertical : Axis.horizontal,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _flexField(
                  compact,
                  _NudgeField(
                    label: 'Start',
                    value: _formatTime(_start),
                    iconSize: iconSize,
                    earlierLabel: 'Start half a second earlier',
                    laterLabel: 'Start half a second later',
                    onMinus: () => _setStart(_start - 0.5),
                    onPlus: () => _setStart(_start + 0.5),
                  ),
                ),
                const SizedBox(
                    width: HollowSpacing.md, height: HollowSpacing.md),
                _flexField(
                  compact,
                  _NudgeField(
                    label: 'End',
                    value: _formatTime(_end),
                    iconSize: iconSize,
                    earlierLabel: 'End half a second earlier',
                    laterLabel: 'End half a second later',
                    onMinus: () => _setEnd(_end - 0.5),
                    onPlus: () => _setEnd(_end + 0.5),
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.md),
            const SettingsFieldLabel(label: 'Move the selection'),
            const SizedBox(height: HollowSpacing.xs),
            Row(
              children: [
                for (var i = 0; i < _kMoves.length; i++) ...[
                  if (i > 0) const SizedBox(width: HollowSpacing.xs),
                  HollowIconButton(
                    icon: _kMoves[i].$1,
                    label: _kMoves[i].$3,
                    size: iconSize,
                    onPressed: () => _nudgeWindow(_kMoves[i].$2),
                  ),
                ],
              ],
            ),
            if (_isPlaying) ...[
              const SizedBox(height: HollowSpacing.md),
              HollowProgressBar(
                value: _end > _start
                    ? (_currentPos - _start) / (_end - _start)
                    : 0,
                semanticLabel: 'Preview position',
              ),
            ],
          ],
        ],
      ),
      leadingActions: [
        if (_loaded)
          HollowButton.ghost(
            onPressed: actionRunning
                ? null
                : (_isPlaying ? _stopPreview : _startPreview),
            icon: Icon(
              _isPlaying ? LucideIcons.square : LucideIcons.play,
              size: 14,
            ),
            child: Text(_isPlaying ? 'Stop' : 'Preview'),
          ),
      ],
      actions: [
        HollowButton.ghost(
          onPressed: actionRunning ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        HollowButton.filled(
          onPressed: _loaded ? _save : null,
          loading: actionRunning,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

const _kMoves = <(IconData, double, String)>[
  (LucideIcons.chevronsLeft, -5.0, 'Move 5 seconds earlier'),
  (LucideIcons.chevronLeft, -1.0, 'Move 1 second earlier'),
  (LucideIcons.chevronRight, 1.0, 'Move 1 second later'),
  (LucideIcons.chevronsRight, 5.0, 'Move 5 seconds later'),
];

/// A field label over a time flanked by nudge buttons.
class _NudgeField extends StatelessWidget {
  final String label;
  final String value;
  final double iconSize;
  final String earlierLabel;
  final String laterLabel;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _NudgeField({
    required this.label,
    required this.value,
    required this.iconSize,
    required this.earlierLabel,
    required this.laterLabel,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsFieldLabel(label: label),
        const SizedBox(height: HollowSpacing.xs),
        Row(
          children: [
            HollowIconButton(
              icon: LucideIcons.minus,
              label: earlierLabel,
              size: iconSize,
              onPressed: onMinus,
            ),
            Expanded(
              child: Text(
                value,
                textAlign: TextAlign.center,
                style: HollowTypography.mono.copyWith(
                  color: hollow.textPrimary,
                ),
              ),
            ),
            HollowIconButton(
              icon: LucideIcons.plus,
              label: laterLabel,
              size: iconSize,
              onPressed: onPlus,
            ),
          ],
        ),
      ],
    );
  }
}

/// Waveform strip with a draggable selection window: near an edge the drag
/// moves that handle, in the middle it pans the window.
class _WaveformSelector extends StatefulWidget {
  final RingtoneWaveform wave;
  final double start;
  final double end;
  final double? playhead;
  final ValueChanged<double> onStart;
  final ValueChanged<double> onEnd;
  final ValueChanged<double> onWindow;

  const _WaveformSelector({
    required this.wave,
    required this.start,
    required this.end,
    required this.playhead,
    required this.onStart,
    required this.onEnd,
    required this.onWindow,
  });

  @override
  State<_WaveformSelector> createState() => _WaveformSelectorState();
}

class _WaveformSelectorState extends State<_WaveformSelector> {
  static const double height = 80;
  // Which part of the window the active drag grabbed.
  int _drag = 0; // -1 start, 1 end, 2 window pan, 0 none
  double _panAnchor = 0;

  double get _total => widget.wave.durationSecs;

  double _xToSeconds(double dx, double width) {
    if (width <= 0 || _total <= 0) return 0;
    return (dx / width * _total).clamp(0.0, _total);
  }

  void _onDown(Offset local, double width) {
    final t = _xToSeconds(local.dx, width);
    final startX = widget.start / _total * width;
    final endX = widget.end / _total * width;
    const edge = 18.0;
    if ((local.dx - startX).abs() < edge) {
      _drag = -1;
    } else if ((local.dx - endX).abs() < edge) {
      _drag = 1;
    } else if (local.dx > startX && local.dx < endX) {
      _drag = 2;
      _panAnchor = t - widget.start;
    } else {
      _drag = (t < widget.start) ? -1 : 1;
      if (_drag == -1) {
        widget.onStart(t);
      } else {
        widget.onEnd(t);
      }
    }
  }

  void _onMove(Offset local, double width) {
    final t = _xToSeconds(local.dx, width);
    switch (_drag) {
      case -1:
        widget.onStart(t);
      case 1:
        widget.onEnd(t);
      case 2:
        widget.onWindow((t - _panAnchor).clamp(0.0, _total));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // A screen reader cannot meaningfully drag this, and the accessible
        // path is the labelled nudge fields below, so the painted surface stays
        // out of the semantics tree rather than being an unusable node.
        return ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (d) => _onDown(d.localPosition, width),
            onHorizontalDragUpdate: (d) => _onMove(d.localPosition, width),
            onHorizontalDragEnd: (_) => _drag = 0,
            onTapDown: (d) {
              _onDown(d.localPosition, width);
              _drag = 0;
            },
            child: SizedBox(
              height: height,
              width: double.infinity,
              child: CustomPaint(
                painter: RingtoneWaveformPainter(
                  wave: widget.wave,
                  start: widget.start,
                  end: widget.end,
                  playhead: widget.playhead,
                  accent: hollow.accent,
                  muted: hollow.textTertiary,
                  playheadColor: hollow.textPrimary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Draws the peak envelope (min to max per pixel column) with the RMS body
/// inside it, so drops and peaks read at a glance; the selection is accent.
class RingtoneWaveformPainter extends CustomPainter {
  final RingtoneWaveform wave;
  final double start;
  final double end;
  final double? playhead;
  final Color accent;
  final Color muted;
  final Color playheadColor;

  RingtoneWaveformPainter({
    required this.wave,
    required this.start,
    required this.end,
    required this.playhead,
    required this.accent,
    required this.muted,
    required this.playheadColor,
  });

  /// Envelope and RMS outlines, one vertex pair per pixel column.
  (Path, Path) _paths(Size size) {
    final peak = Path();
    final body = Path();
    final mid = size.height / 2;
    final half = size.height / 2 - 1;
    final cols = math.max(1, size.width.ceil());
    final n = wave.max!.length;
    final tops = List<double>.filled(cols, 0);
    final bottoms = List<double>.filled(cols, 0);
    final rmsH = List<double>.filled(cols, 0);
    for (var c = 0; c < cols; c++) {
      final from = (c * n / cols).floor();
      final to = math.max(from + 1, ((c + 1) * n / cols).floor()).clamp(1, n);
      var lo = 0.0;
      var hi = 0.0;
      var sq = 0.0;
      for (var i = from; i < to; i++) {
        lo = math.min(lo, wave.min![i]);
        hi = math.max(hi, wave.max![i]);
        sq += wave.rms![i] * wave.rms![i];
      }
      final r = math.sqrt(sq / (to - from));
      // Half a pixel either side keeps silence a visible hairline.
      tops[c] = math.min(mid - hi * half, mid - 0.5);
      bottoms[c] = math.max(mid - lo * half, mid + 0.5);
      rmsH[c] = math.max(r * half, 0.5);
    }
    double x(int c) => c + 0.5;
    peak.moveTo(0, tops[0]);
    body.moveTo(0, mid - rmsH[0]);
    for (var c = 0; c < cols; c++) {
      peak.lineTo(x(c), tops[c]);
      body.lineTo(x(c), mid - rmsH[c]);
    }
    peak.lineTo(size.width, tops[cols - 1]);
    peak.lineTo(size.width, bottoms[cols - 1]);
    body.lineTo(size.width, mid - rmsH[cols - 1]);
    body.lineTo(size.width, mid + rmsH[cols - 1]);
    for (var c = cols - 1; c >= 0; c--) {
      peak.lineTo(x(c), bottoms[c]);
      body.lineTo(x(c), mid + rmsH[c]);
    }
    peak.lineTo(0, bottoms[0]);
    body.lineTo(0, mid + rmsH[0]);
    peak.close();
    body.close();
    return (peak, body);
  }

  void _drawSound(Canvas canvas, Size size, Path? peak, Path? body, Color c) {
    if (peak == null || body == null) {
      final mid = size.height / 2;
      canvas.drawRect(
          Rect.fromLTRB(0, mid - 0.5, size.width, mid + 0.5), Paint()..color = c);
      return;
    }
    canvas.drawPath(peak, Paint()..color = c.withValues(alpha: 0.45));
    canvas.drawPath(body, Paint()..color = c);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final total = wave.durationSecs;
    if (total <= 0 || size.width <= 0) return;
    final startX = (start / total) * size.width;
    final endX = (end / total) * size.width;
    final window = Rect.fromLTRB(startX, 0, endX, size.height);

    final paths = wave.hasPeaks && wave.max!.isNotEmpty ? _paths(size) : null;
    _drawSound(canvas, size, paths?.$1, paths?.$2, muted);

    canvas.drawRect(window, Paint()..color = accent.withValues(alpha: 0.12));
    canvas.save();
    canvas.clipRect(window);
    _drawSound(canvas, size, paths?.$1, paths?.$2, accent);
    canvas.restore();

    final handlePaint = Paint()
      ..color = accent
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
        Offset(startX, 4), Offset(startX, size.height - 4), handlePaint);
    canvas.drawLine(Offset(endX, 4), Offset(endX, size.height - 4), handlePaint);

    final head = playhead;
    if (head != null) {
      final px = (head.clamp(0.0, total) / total) * size.width;
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = playheadColor
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(RingtoneWaveformPainter old) =>
      old.start != start ||
      old.end != end ||
      old.playhead != playhead ||
      !identical(old.wave, wave) ||
      old.accent != accent ||
      old.muted != muted ||
      old.playheadColor != playheadColor;
}
