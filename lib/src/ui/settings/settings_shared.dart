import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/rainbow_slider_track.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shared scaffolding for the Settings surfaces, desktop and mobile. One
/// implementation of the card, toggle, segment and slider blocks so the two
/// cannot drift: extend this module instead of copying widgets between them.

/// Shortens a peer_id for display (`12D3…JQcW`).
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

/// Horizontal segmented control for a small set of mutually-exclusive options.
/// Each segment is a [HollowPressable], so it is keyboard- and
/// screen-reader-actionable.
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

/// Labeled slider block: header, themed slider and a min/max caption row.
/// Callers supply the computed value, range and display labels.
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

// Display size (issue #20), shared by the desktop Accessibility category and
// the mobile Accessibility tab so the two cannot drift apart.

/// Interface scale ("zoom") slider: text, icons and spacing together.
///
/// Committed on RELEASE, not on every drag tick, because this control lives
/// inside the UI it resizes and a live commit moves the track out from under
/// the pointer. Keyboard adjustment fires without a drag and commits at once.
class InterfaceScaleControl extends ConsumerStatefulWidget {
  const InterfaceScaleControl({super.key});

  @override
  ConsumerState<InterfaceScaleControl> createState() =>
      _InterfaceScaleControlState();
}

class _InterfaceScaleControlState extends ConsumerState<InterfaceScaleControl> {
  /// Non-null only while the thumb is being dragged.
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final saved = ref.watch(uiScaleProvider);
    final shown = _dragValue ?? saved;
    final min = uiScaleMin;
    final max = uiScaleMax;
    // A window too small for the chosen scale gets a reduced one, so the
    // controls that undo it stay reachable. Saying so keeps a slider that stops
    // mattering past a point from reading as broken.
    final info = UiScaleInfo.maybeOf(context);
    final clampedTo = info != null && info.isClamped ? info.effective : null;

    return _ScaleSliderBlock(
      hollow: hollow,
      icon: LucideIcons.scaling,
      title: 'Interface scale',
      subtitle: clampedTo != null
          ? 'Limited to ${scalePercentLabel(clampedTo)} by this window size. '
              'Enlarge the window for more'
          : 'Text, icons and spacing (applies when you release)',
      value: shown,
      min: min,
      max: max,
      isDefault: (saved - kUiScaleDefault).abs() < 0.001,
      onReset: () => ref.read(uiScaleProvider.notifier).reset(),
      onChangeStart: (v) => setState(() => _dragValue = v),
      onChanged: (v) {
        if (_dragValue != null) {
          setState(() => _dragValue = v);
        } else {
          // Keyboard or assistive adjustment: no drag, so commit right away.
          ref.read(uiScaleProvider.notifier).setScale(v);
        }
      },
      onChangeEnd: (v) {
        setState(() => _dragValue = null);
        ref.read(uiScaleProvider.notifier).setScale(v);
      },
    );
  }
}

/// Chat text size slider: message text and the composer only, on top of the
/// interface scale. Live, with a worked example underneath, because nothing it
/// resizes is on screen while Settings is open.
class ChatTextScaleControl extends ConsumerStatefulWidget {
  const ChatTextScaleControl({super.key});

  @override
  ConsumerState<ChatTextScaleControl> createState() =>
      _ChatTextScaleControlState();
}

class _ChatTextScaleControlState extends ConsumerState<ChatTextScaleControl> {
  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final value = ref.watch(chatTextScaleProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ScaleSliderBlock(
          hollow: hollow,
          icon: LucideIcons.aLargeSmall,
          title: 'Chat text size',
          subtitle: 'Message text and the box you type in',
          value: value,
          min: kChatTextScaleMin,
          max: kChatTextScaleMax,
          isDefault: (value - kChatTextScaleDefault).abs() < 0.001,
          onReset: () => ref.read(chatTextScaleProvider.notifier).reset(),
          onChanged: (v) =>
              ref.read(chatTextScaleProvider.notifier).setScale(v),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _ChatTextPreview(hollow: hollow, factor: value),
      ],
    );
  }
}

/// A worked sample of one message row at the chosen chat text size.
class _ChatTextPreview extends StatelessWidget {
  final HollowTheme hollow;
  final double factor;

  const _ChatTextPreview({required this.hollow, required this.factor});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.background.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: MediaQuery(
        data: mq.copyWith(
          textScaler:
              MultipliedTextScaler(base: mq.textScaler, factor: factor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Hollow',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Flexible(
                  child: Text(
                    'Today at 12:34',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textTertiary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              'This is how your messages will look.',
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Side-panel zoom (issue #54): the server strip, channel list and member list,
/// without touching the chat. Live, because all three are visible behind the
/// Settings dialog.
class PanelScaleControl extends ConsumerWidget {
  const PanelScaleControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final value = ref.watch(panelScaleProvider);
    return _ScaleSliderBlock(
      hollow: hollow,
      icon: LucideIcons.panelsLeftRight,
      title: 'Side panel size',
      subtitle: 'Icons and names in the server, channel and member lists',
      value: value,
      min: kPanelScaleMin,
      max: kPanelScaleMax,
      isDefault: (value - kPanelScaleDefault).abs() < 0.001,
      onReset: () => ref.read(panelScaleProvider.notifier).reset(),
      onChanged: (v) => ref.read(panelScaleProvider.notifier).setScale(v),
    );
  }
}

/// Shared skeleton for both scale sliders: header with a live percentage badge
/// and a Reset action, the slider, and min/max captions.
class _ScaleSliderBlock extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final bool isDefault;
  final VoidCallback onReset;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  const _ScaleSliderBlock({
    required this.hollow,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.isDefault,
    required this.onReset,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
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
            const SizedBox(width: HollowSpacing.sm),
            Text(
              scalePercentLabel(value),
              style: HollowTypography.mono.copyWith(
                color: hollow.accentText,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (!isDefault) ...[
              const SizedBox(width: HollowSpacing.xs),
              HollowPressable(
                semanticLabel: 'Reset $title',
                onTap: onReset,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(HollowSpacing.xxs + 2),
                child: Icon(LucideIcons.rotateCcw,
                    size: 14, color: hollow.textSecondary),
              ),
            ],
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
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: scaleDivisions(min, max),
            label: scalePercentLabel(value),
            semanticFormatterCallback: scalePercentLabel,
            onChangeStart: onChangeStart,
            onChanged: onChanged,
            onChangeEnd: onChangeEnd,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(scalePercentLabel(min),
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary, fontSize: 9)),
              Text(scalePercentLabel(max),
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary, fontSize: 9)),
            ],
          ),
        ),
      ],
    );
  }
}

/// 1px divider with a looping accent shimmer sweep, on [SharedTickers.shimmer]
/// rather than an AnimationController of its own.
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

/// Square accent colour preview box. Size and radius differ between desktop and
/// mobile, so they are passed in.
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

/// Rainbow hue slider for the accent colour pickers. Track and thumb sizing
/// differ between the two surfaces, so they are passed in.
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
