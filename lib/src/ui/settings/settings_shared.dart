import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/rainbow_slider_track.dart';

/// Shared scaffolding for the Settings surfaces (desktop dialog categories +
/// mobile Settings tab). One implementation of the card/toggle/segment/slider
/// building blocks so the two surfaces can't drift apart — extend this module
/// instead of copying widgets between them.

/// Helper: shorten a peer_id for display (`12D3…JQcW`).
String shortenPeerId(String id) =>
    id.length <= 12 ? id : '${id.substring(0, 6)}…${id.substring(id.length - 4)}';

/// Wraps a list of settings cards in a scroll view with standard spacing.
Widget settingsCardList(List<Widget> cards) {
  return SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: HollowSpacing.lg),
          cards[i],
        ],
      ],
    ),
  );
}

/// A titled, bordered card grouping related settings in the content area.
/// This is the visual unit Vitalik asked for — each category is a short stack
/// of these instead of one undifferentiated scroll.
class SettingsCard extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsCard({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.lg),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(hollow.radiusLg),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title.toUpperCase(),
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

/// Small uppercase section/field label (e.g. "APP LOCK", "DISPLAY NAME").
class SettingsSectionLabel extends StatelessWidget {
  final String label;
  const SettingsSectionLabel({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Text(
      label,
      style: HollowTypography.caption.copyWith(
        color: hollow.textSecondary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        fontSize: 10,
      ),
    );
  }
}

/// Reusable toggle row: icon + label (+ optional subtitle) + HollowToggle.
class SettingsToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsToggleRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Row(
      children: [
        Icon(icon, size: 16, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: subtitle != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
                    ),
                    Text(
                      subtitle!,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                )
              : Text(
                  label,
                  style: HollowTypography.body
                      .copyWith(color: hollow.textPrimary),
                ),
        ),
        HollowToggle(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// Horizontal segmented control for a small set of mutually-exclusive
/// options (e.g. Reduce Motion's Auto/On/Off). Each segment is a
/// [HollowPressable] so it is keyboard- and screen-reader-actionable.
class TriStateSegment<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  const TriStateSegment({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: hollow.border),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        children: [
          for (final (opt, label) in options)
            Expanded(
              child: HollowPressable(
                onTap: () => onChanged(opt),
                borderRadius: BorderRadius.circular(6),
                child: AnimatedContainer(
                  duration: HollowDurations.fast,
                  alignment: Alignment.center,
                  padding:
                      const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
                  decoration: BoxDecoration(
                    color: opt == value ? hollow.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    style: HollowTypography.body.copyWith(
                      color: opt == value
                          ? hollow.textOnAccent
                          : hollow.textSecondary,
                      fontWeight:
                          opt == value ? FontWeight.w600 : FontWeight.w400,
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

/// Labeled slider block: icon + title + subtitle header, themed slider, and a
/// min/max caption row underneath. The scaffold shared by the cache-limit and
/// auto-download sliders (Storage category) — callers supply the computed
/// value, range, and display labels.
class SettingsLabeledSlider extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final String minLabel;
  final String maxLabel;
  final ValueChanged<double> onChanged;

  const SettingsLabeledSlider({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.minLabel,
    required this.maxLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary)),
                  Text(
                    subtitle,
                    style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: hollow.accent,
            inactiveTrackColor: hollow.border,
            thumbColor: hollow.accent,
            overlayColor: hollow.accent.withValues(alpha: 0.1),
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: divisions,
            label: label,
            onChanged: onChanged,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(minLabel,
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary, fontSize: 9)),
              Text(maxLabel,
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary, fontSize: 9)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 1px divider with a looping accent shimmer sweep (ASOT style). Uses
/// [SharedTickers.shimmer] instead of its own AnimationController. Shared by
/// the About sections (desktop + mobile) and the home dashboard.
class ShimmerDividerLine extends StatelessWidget {
  final HollowTheme hollow;
  const ShimmerDividerLine({super.key, required this.hollow});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SharedTickers.instance.shimmer,
      builder: (context, value, _) {
        final pos = value * 4.0 - 1.5;
        return Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(pos - 0.5, 0),
              end: Alignment(pos + 0.5, 0),
              colors: [
                hollow.border,
                hollow.accent.withValues(alpha: 0.6),
                hollow.border,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Square accent color preview box (current hue swatch next to the label).
/// Size/radius differ between desktop and mobile — passed in.
class AccentHuePreviewBox extends StatelessWidget {
  final double hue;
  final double size;
  final double radius;

  const AccentHuePreviewBox({
    super.key,
    required this.hue,
    required this.size,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: accentFromHue(hue),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.2),
        ),
      ),
    );
  }
}

/// Rainbow hue slider used by the accent color pickers (desktop + mobile).
/// Track/thumb sizing differs between the two surfaces — passed in.
class AccentHueSliderRow extends StatelessWidget {
  final double hue;
  final double height;
  final double trackHeight;
  final double thumbRadius;
  final ValueChanged<double> onChanged;

  const AccentHueSliderRow({
    super.key,
    required this.hue,
    required this.height,
    required this.trackHeight,
    required this.thumbRadius,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: SliderTheme(
        data: SliderThemeData(
          trackHeight: trackHeight,
          thumbShape: RoundSliderThumbShape(
            enabledThumbRadius: thumbRadius,
            elevation: 2,
          ),
          thumbColor: Colors.white,
          overlayShape: SliderComponentShape.noOverlay,
          trackShape: RainbowSliderTrackShape(),
          activeTrackColor: Colors.transparent,
          inactiveTrackColor: Colors.transparent,
        ),
        child: Slider(
          value: hue.clamp(0, 359),
          min: 0,
          max: 359,
          onChanged: onChanged,
        ),
      ),
    );
  }
}
