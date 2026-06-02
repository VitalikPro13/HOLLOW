import 'dart:async';
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void showRingtoneClipEditor(BuildContext context, String filePath) {
  showHollowDialog(
    context: context,
    builder: (_) => RingtoneClipEditorDialog(filePath: filePath),
  );
}

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

  @override
  void initState() {
    super.initState();
    _loadDuration();
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
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final fileName = widget.filePath.split(RegExp(r'[\\/]')).last;
    final clipDuration = (_end - _start).clamp(0.1, 30.0);

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
              'Select clip (max 30s)',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: hollow.accent,
                inactiveTrackColor: hollow.border,
                thumbColor: hollow.accent,
                overlayColor: hollow.accent.withValues(alpha: 0.1),
                trackHeight: 4,
                rangeThumbShape:
                    const RoundRangeSliderThumbShape(enabledThumbRadius: 7),
              ),
              child: RangeSlider(
                values: RangeValues(_start, _end),
                min: 0,
                max: _totalDuration,
                onChanged: (range) {
                  double newStart = range.start;
                  double newEnd = range.end;
                  if (newEnd - newStart > 30.0) {
                    if ((newStart - _start).abs() > (newEnd - _end).abs()) {
                      newStart = newEnd - 30.0;
                    } else {
                      newEnd = newStart + 30.0;
                    }
                  }
                  setState(() {
                    _start = newStart.clamp(0, _totalDuration);
                    _end = newEnd.clamp(0, _totalDuration);
                  });
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatTime(_start),
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  '${clipDuration.toStringAsFixed(1)}s clip',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _formatTime(_end),
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                    fontFeatures: [const FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: HollowSpacing.sm),
            if (_isPlaying)
              Padding(
                padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
                child: SizedBox(
                  height: 3,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: _end > _start
                          ? ((_currentPos - _start) / (_end - _start))
                              .clamp(0.0, 1.0)
                          : 0,
                      backgroundColor: hollow.border,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(hollow.accent),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
      actions: [
        if (_loaded) ...[
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
      ],
    );
  }
}
