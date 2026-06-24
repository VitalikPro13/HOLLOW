import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void showRingtoneClipEditor(BuildContext context, String filePath) {
  showHollowDialog(
    context: context,
    builder: (_) => RingtoneClipEditorDialog(filePath: filePath),
  );
}

/// Max clip length the ringtone can be trimmed to.
const double _kMaxClip = 30.0;

class RingtoneClipEditorDialog extends ConsumerStatefulWidget {
  final String filePath;
  const RingtoneClipEditorDialog({super.key, required this.filePath});

  @override
  ConsumerState<RingtoneClipEditorDialog> createState() =>
      _RingtoneClipEditorDialogState();
}

class _RingtoneClipEditorDialogState
    extends ConsumerState<RingtoneClipEditorDialog> {
  AudioPlayer? _player;
  double _totalDuration = 60.0;
  double _start = 0.0;
  double _end = 30.0;
  double _currentPos = 0.0;
  bool _isPlaying = false;
  bool _loaded = false;
  StreamSubscription? _posSub;

  // Deterministic pseudo-waveform bars (stable per file). Real PCM decode is
  // overkill here — the strip is for visual context of the selection window.
  late final List<double> _bars;

  @override
  void initState() {
    super.initState();
    _bars = _generateBars(widget.filePath, 64);
    _loadDuration();
  }

  List<double> _generateBars(String seedSource, int count) {
    final rng = Random(seedSource.hashCode);
    return List<double>.generate(count, (i) {
      // Gentle envelope so it reads as audio, not noise.
      final envelope = 0.35 + 0.65 * sin((i / count) * pi);
      return (0.15 + rng.nextDouble() * 0.85) * envelope;
    });
  }

  Future<void> _loadDuration() async {
    _start = await ref.read(ringtoneStartProvider.future);
    _end = await ref.read(ringtoneEndProvider.future);

    final cached = await ref.read(ringtoneDurationProvider.future);
    if (cached > 0) {
      _totalDuration = cached;
    }

    if (_end > _totalDuration) _end = _totalDuration;
    if (_start >= _end) _start = 0;
    if (_end - _start > _kMaxClip) _end = _start + _kMaxClip;

    if (mounted) setState(() => _loaded = true);
  }

  @override
  void dispose() {
    _stopPreview();
    super.dispose();
  }

  Future<void> _startPreview() async {
    await _stopPreview();
    _player = AudioPlayer();
    final volume = await ref.read(ringtoneVolumeProvider.future);
    await _player!.setVolume(volume);
    await _player!.play(DeviceFileSource(widget.filePath));
    await _player!.seek(Duration(milliseconds: (_start * 1000).round()));

    _posSub = _player!.onPositionChanged.listen((pos) {
      if (!mounted) return;
      final posSeconds = pos.inMilliseconds / 1000.0;
      setState(() => _currentPos = posSeconds);
      if (posSeconds >= _end || posSeconds < _start - 0.5) {
        _player?.seek(Duration(milliseconds: (_start * 1000).round()));
      }
    });

    setState(() => _isPlaying = true);
  }

  Future<void> _stopPreview() async {
    _posSub?.cancel();
    _posSub = null;
    await _player?.stop();
    await _player?.dispose();
    _player = null;
    if (mounted) setState(() => _isPlaying = false);
  }

  String _formatTime(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toInt();
    final ms = ((seconds - seconds.truncate()) * 10).floor();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.$ms';
  }

  /// Move the start handle, keeping start < end and clip ≤ max.
  void _setStart(double v) {
    setState(() {
      _start = v.clamp(0.0, _totalDuration);
      if (_start > _end - 0.1) _start = (_end - 0.1).clamp(0.0, _totalDuration);
      if (_end - _start > _kMaxClip) _end = _start + _kMaxClip;
    });
  }

  /// Move the end handle, keeping end > start and clip ≤ max.
  void _setEnd(double v) {
    setState(() {
      _end = v.clamp(0.0, _totalDuration);
      if (_end < _start + 0.1) _end = (_start + 0.1).clamp(0.0, _totalDuration);
      if (_end - _start > _kMaxClip) _start = _end - _kMaxClip;
    });
  }

  /// Shift the whole window by [delta] seconds, preserving its length.
  void _nudgeWindow(double delta) {
    final len = _end - _start;
    var newStart = (_start + delta).clamp(0.0, _totalDuration - len);
    if (newStart < 0) newStart = 0;
    setState(() {
      _start = newStart;
      _end = newStart + len;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final fileName = widget.filePath.split(RegExp(r'[\\/]')).last;
    final clipDuration = (_end - _start).clamp(0.1, _kMaxClip);

    return HollowDialog(
      title: 'Trim Ringtone',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$fileName  ${_loaded ? _formatTime(_totalDuration) : ''}',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: HollowSpacing.lg),
          if (!_loaded)
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.lg),
              child: Center(
                child: Text(
                  'Loading...',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ),
            )
          else ...[
            Text(
              'Drag the highlighted region (max ${_kMaxClip.toInt()}s)',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            // Scrubbable waveform with draggable selection window.
            _WaveformSelector(
              bars: _bars,
              total: _totalDuration,
              start: _start,
              end: _end,
              playhead: _isPlaying ? _currentPos : null,
              accent: hollow.accent,
              barColor: hollow.border,
              onStart: _setStart,
              onEnd: _setEnd,
              // Pan the window so it starts at [s], preserving its length.
              onWindow: (s) => _nudgeWindow(s - _start),
            ),
            const SizedBox(height: HollowSpacing.md),
            // Numeric start / end with +/- nudge for precision on long tracks.
            Row(
              children: [
                Expanded(
                  child: _NudgeField(
                    label: 'Start',
                    value: _formatTime(_start),
                    onMinus: () => _setStart(_start - 0.5),
                    onPlus: () => _setStart(_start + 0.5),
                    hollow: hollow,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Column(
                  children: [
                    Text(
                      '${clipDuration.toStringAsFixed(1)}s',
                      style: HollowTypography.body.copyWith(
                        color: hollow.accent,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'clip',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: _NudgeField(
                    label: 'End',
                    value: _formatTime(_end),
                    onMinus: () => _setEnd(_end - 0.5),
                    onPlus: () => _setEnd(_end + 0.5),
                    hollow: hollow,
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            // Move the whole window in larger steps (handy on long tracks).
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('Move window',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary, fontSize: 11,
                    )),
                const SizedBox(width: HollowSpacing.sm),
                _StepButton(
                    icon: LucideIcons.chevronsLeft,
                    onTap: () => _nudgeWindow(-5),
                    label: 'Move window left 5 seconds',
                    hollow: hollow),
                _StepButton(
                    icon: LucideIcons.chevronLeft,
                    onTap: () => _nudgeWindow(-1),
                    label: 'Move window left 1 second',
                    hollow: hollow),
                _StepButton(
                    icon: LucideIcons.chevronRight,
                    onTap: () => _nudgeWindow(1),
                    label: 'Move window right 1 second',
                    hollow: hollow),
                _StepButton(
                    icon: LucideIcons.chevronsRight,
                    onTap: () => _nudgeWindow(5),
                    label: 'Move window right 5 seconds',
                    hollow: hollow),
              ],
            ),
            if (_isPlaying) ...[
              const SizedBox(height: HollowSpacing.sm),
              SizedBox(
                height: 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: _end > _start
                        ? ((_currentPos - _start) / (_end - _start))
                            .clamp(0.0, 1.0)
                        : 0,
                    backgroundColor: hollow.border,
                    valueColor: AlwaysStoppedAnimation<Color>(hollow.accent),
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
      actions: [
        if (_loaded)
          // Single full-width row so Preview sits on the LEFT and the
          // Cancel/Save pair stays on the right (a bare Wrap right-aligns all).
          SizedBox(
            width: double.infinity,
            child: Row(
              children: [
                HollowButton.ghost(
                  onPressed: _isPlaying ? _stopPreview : _startPreview,
                  compact: true,
                  icon: Icon(
                    _isPlaying ? LucideIcons.square : LucideIcons.play,
                    size: 14,
                  ),
                  child: Text(_isPlaying ? 'Stop' : 'Preview'),
                ),
                const Spacer(),
                HollowButton.ghost(
                  onPressed: () => Navigator.pop(context),
                  compact: true,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.filled(
                  onPressed: () {
                    ref.read(ringtoneStartProvider.notifier).setStart(_start);
                    ref.read(ringtoneEndProvider.notifier).setEnd(_end);
                    _stopPreview();
                    Navigator.pop(context);
                  },
                  compact: true,
                  child: const Text('Save'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// A label + value box flanked by − / + nudge buttons (0.5s steps).
class _NudgeField extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final HollowTheme hollow;

  const _NudgeField({
    required this.label,
    required this.value,
    required this.onMinus,
    required this.onPlus,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 10,
            )),
        const SizedBox(height: 2),
        Row(
          children: [
            _StepButton(
                icon: LucideIcons.minus,
                onTap: onMinus,
                label: 'Decrease $label',
                hollow: hollow),
            Expanded(
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  value,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 12,
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
            _StepButton(
                icon: LucideIcons.plus,
                onTap: onPlus,
                label: 'Increase $label',
                hollow: hollow),
          ],
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final HollowTheme hollow;
  final String? label;

  const _StepButton({
    required this.icon,
    required this.onTap,
    required this.hollow,
    this.label,
  });

  @override
  Widget build(BuildContext context) {
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(6),
      semanticLabel: label,
      child: Icon(icon, size: 16, color: hollow.textSecondary),
    );
  }
}

/// Waveform strip with a draggable selection window. Dragging near an edge
/// moves that handle; dragging the middle pans the whole window.
class _WaveformSelector extends StatefulWidget {
  final List<double> bars;
  final double total;
  final double start;
  final double end;
  final double? playhead;
  final Color accent;
  final Color barColor;
  final ValueChanged<double> onStart;
  final ValueChanged<double> onEnd;
  final ValueChanged<double> onWindow;

  const _WaveformSelector({
    required this.bars,
    required this.total,
    required this.start,
    required this.end,
    required this.playhead,
    required this.accent,
    required this.barColor,
    required this.onStart,
    required this.onEnd,
    required this.onWindow,
  });

  @override
  State<_WaveformSelector> createState() => _WaveformSelectorState();
}

class _WaveformSelectorState extends State<_WaveformSelector> {
  static const double _height = 64;
  // Which part of the window the active drag grabbed.
  int _drag = 0; // -1 start, 1 end, 2 window pan, 0 none

  double _xToSeconds(double dx, double width) {
    if (width <= 0 || widget.total <= 0) return 0;
    return (dx / width * widget.total).clamp(0.0, widget.total);
  }

  void _onDown(Offset local, double width) {
    final t = _xToSeconds(local.dx, width);
    final startX = widget.start / widget.total * width;
    final endX = widget.end / widget.total * width;
    const edge = 18.0;
    if ((local.dx - startX).abs() < edge) {
      _drag = -1;
    } else if ((local.dx - endX).abs() < edge) {
      _drag = 1;
    } else if (local.dx > startX && local.dx < endX) {
      _drag = 2;
      _panAnchor = t - widget.start;
    } else {
      // Tap outside: move nearest handle to here.
      _drag = (t < widget.start) ? -1 : 1;
      if (_drag == -1) {
        widget.onStart(t);
      } else {
        widget.onEnd(t);
      }
    }
  }

  double _panAnchor = 0;

  void _onMove(Offset local, double width) {
    final t = _xToSeconds(local.dx, width);
    switch (_drag) {
      case -1:
        widget.onStart(t);
        break;
      case 1:
        widget.onEnd(t);
        break;
      case 2:
        widget.onWindow((t - _panAnchor).clamp(0.0, widget.total));
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Drag-to-scrub waveform — a screen reader can't meaningfully drag this
        // to set the clip window; the accessible path is the labeled Start/End
        // nudge fields below it. Keep the gesture for sighted users but exclude
        // the painted surface from the semantics tree so it isn't an
        // unlabeled, unusable node.
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
            height: _height,
            width: double.infinity,
            child: CustomPaint(
              painter: _WaveformPainter(
                bars: widget.bars,
                total: widget.total,
                start: widget.start,
                end: widget.end,
                playhead: widget.playhead,
                accent: widget.accent,
                barColor: widget.barColor,
              ),
            ),
          ),
        ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double total;
  final double start;
  final double end;
  final double? playhead;
  final Color accent;
  final Color barColor;

  _WaveformPainter({
    required this.bars,
    required this.total,
    required this.start,
    required this.end,
    required this.playhead,
    required this.accent,
    required this.barColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (total <= 0) return;
    final startX = (start / total) * size.width;
    final endX = (end / total) * size.width;

    final mid = size.height / 2;
    final barW = size.width / bars.length;
    final inPaint = Paint()..color = accent;
    final outPaint = Paint()..color = barColor;

    for (var i = 0; i < bars.length; i++) {
      final x = i * barW;
      final h = bars[i] * (size.height * 0.9);
      final inWindow = (x + barW / 2) >= startX && (x + barW / 2) <= endX;
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x + barW * 0.2, mid - h / 2, barW * 0.6, h),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(r, inWindow ? inPaint : outPaint);
    }

    // Selection window outline.
    final winPaint = Paint()
      ..color = accent.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Rect.fromLTRB(startX, 0, endX, size.height), winPaint);

    final handlePaint = Paint()
      ..color = accent
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(startX, 4), Offset(startX, size.height - 4), handlePaint);
    canvas.drawLine(Offset(endX, 4), Offset(endX, size.height - 4), handlePaint);

    // Playhead.
    if (playhead != null) {
      final px = (playhead!.clamp(0.0, total) / total) * size.width;
      final pPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), pPaint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.start != start ||
      old.end != end ||
      old.playhead != playhead ||
      old.total != total;
}
