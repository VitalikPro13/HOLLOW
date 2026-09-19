import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

/// The one slider: volume, scale, cache caps, seek bars.
///
/// One geometry everywhere (3 px track, 6 px thumb), the accent for the filled
/// part because dragging it is the interaction, and no tick marks: a 50-step
/// cache slider drew a comb. A [label] shows while dragging, on the overlay
/// surface like a tooltip.
class HollowSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final SemanticFormatterCallback? semanticFormatterCallback;

  /// Over video or a dark scrim: the unfilled track is a translucent white
  /// that reads on any frame, independent of the theme.
  final bool onMedia;

  /// Draws the press halo. Off where the slider's box is tight enough that a
  /// halo would be clipped (a vertical volume popover).
  final bool halo;

  /// The filled track and thumb. Only for a slider whose value IS a colour
  /// the user picked (the annotation pen); everything else keeps the accent.
  final Color? activeColor;

  const HollowSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.semanticFormatterCallback,
    this.onMedia = false,
    this.halo = true,
    this.activeColor,
  });

  static const double trackHeight = 3;
  static const double thumbRadius = 6;
  static const double haloRadius = 12;
  static const double touchTarget = 48;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final active = activeColor ?? hollow.accent;
    final inactive = onMedia
        ? const Color(0x3DFFFFFF) // design-ignore: over video, not a theme surface
        : hollow.border;

    final slider = SliderTheme(
      data: SliderThemeData(
        trackHeight: trackHeight,
        trackShape: const RoundedRectSliderTrackShape(),
        activeTrackColor: active,
        inactiveTrackColor: inactive,
        disabledActiveTrackColor: hollow.textTertiary,
        disabledInactiveTrackColor: inactive,
        thumbColor: active,
        disabledThumbColor: hollow.textTertiary,
        thumbShape: const RoundSliderThumbShape(
          enabledThumbRadius: thumbRadius,
          disabledThumbRadius: thumbRadius,
          elevation: 0,
          pressedElevation: 0,
        ),
        overlayColor: halo ? active.withValues(alpha: 0.12) : Colors.transparent,
        overlayShape: halo
            ? const RoundSliderOverlayShape(overlayRadius: haloRadius)
            : SliderComponentShape.noOverlay,
        tickMarkShape: SliderTickMarkShape.noTickMark,
        showValueIndicator: ShowValueIndicator.onDrag,
        valueIndicatorShape: const RectangularSliderValueIndicatorShape(),
        valueIndicatorColor: hollow.overlay,
        valueIndicatorTextStyle:
            HollowTypography.label.copyWith(color: hollow.textPrimary),
      ),
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        divisions: divisions,
        label: label,
        semanticFormatterCallback: semanticFormatterCallback,
        onChangeStart: onChangeStart,
        onChanged: onChanged,
        onChangeEnd: onChangeEnd,
      ),
    );

    // A finger needs 48 px; the track stays thin and centres in the taller
    // box. A fixed height, not a minimum: the render slider ignores a minimum
    // when its height is unbounded, and asserts.
    if (!_isTouch) return slider;
    return SizedBox(height: touchTarget, child: slider);
  }

  static bool get _isTouch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}
