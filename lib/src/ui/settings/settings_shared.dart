import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/rainbow_slider_track.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
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
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowSectionHeader(title),
          const SizedBox(height: HollowSpacing.xs),
          ...children,
        ],
      ),
    );
  }
}

/// The label above a single field ("Display name", "Content rating").
///
/// A group of fields gets a [HollowSectionHeader] instead: this names one
/// input and carries no spacing of its own.
class SettingsFieldLabel extends StatelessWidget {
  final String label;
  const SettingsFieldLabel({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Text(
      label,
      style: HollowTypography.label.copyWith(color: hollow.textSecondary),
    );
  }
}

/// A switch row, drawn as the kit's [SettingsSwitchRow].
class SettingsToggleRow extends StatelessWidget {
  @Deprecated('Rows carry no icon')
  final IconData? icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const SettingsToggleRow({
    super.key,
    this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsSwitchRow(
      title: label,
      subtitle: subtitle,
      value: value,
      onChanged: onChanged,
    );
  }
}

/// A slider row, drawn as the kit's [SettingsSliderRow] with [label] as its
/// readout. [minLabel] and [maxLabel] are no longer drawn.
class SettingsLabeledSlider extends StatelessWidget {
  @Deprecated('Rows carry no icon')
  final IconData? icon;
  final String title;
  final String subtitle;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final String? minLabel;
  final String? maxLabel;
  final ValueChanged<double> onChanged;

  const SettingsLabeledSlider({
    super.key,
    this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    this.minLabel,
    this.maxLabel,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsSliderRow(
      title: title,
      subtitle: subtitle,
      value: value,
      min: min,
      max: max,
      divisions: divisions,
      valueLabel: label,
      onChanged: onChanged,
    );
  }
}

// Display size (issue #20), shared by the desktop Accessibility page and the
// mobile Accessibility tab so the two cannot drift apart.

/// Interface scale ("zoom"): text, icons and spacing together.
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
    final saved = ref.watch(uiScaleProvider);
    // A window too small for the chosen scale gets a reduced one, so the
    // controls that undo it stay reachable. Saying so keeps a slider that stops
    // mattering past a point from reading as broken.
    final info = UiScaleInfo.maybeOf(context);
    final clampedTo = info != null && info.isClamped ? info.effective : null;

    return _ScaleRow(
      title: 'Interface',
      subtitle: clampedTo != null
          ? 'Limited to ${scalePercentLabel(clampedTo)} by this window size. '
              'Enlarge the window for more'
          : 'Text, icons and spacing together',
      value: _dragValue ?? saved,
      min: uiScaleMin,
      max: uiScaleMax,
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

/// Chat text size: message text and the composer only, on top of the
/// interface scale. Live, with a worked example underneath, because nothing it
/// resizes is on screen while Settings is open.
class ChatTextScaleControl extends ConsumerWidget {
  const ChatTextScaleControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(chatTextScaleProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _ScaleRow(
          title: 'Chat text',
          subtitle: 'Messages and the box you type in',
          value: value,
          min: kChatTextScaleMin,
          max: kChatTextScaleMax,
          isDefault: (value - kChatTextScaleDefault).abs() < 0.001,
          onReset: () => ref.read(chatTextScaleProvider.notifier).reset(),
          onChanged: (v) =>
              ref.read(chatTextScaleProvider.notifier).setScale(v),
        ),
        _ChatTextPreview(factor: value),
        const SizedBox(height: HollowSpacing.sm),
      ],
    );
  }
}

/// A worked sample of one message row at the chosen chat text size.
class _ChatTextPreview extends StatelessWidget {
  final double factor;

  const _ChatTextPreview({required this.factor});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final mq = MediaQuery.of(context);
    return Container(
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
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
            const SizedBox(height: HollowSpacing.xxs),
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
/// without touching the chat. Live, because all three stay on screen beside
/// Settings.
class PanelScaleControl extends ConsumerWidget {
  const PanelScaleControl({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(panelScaleProvider);
    return _ScaleRow(
      title: 'Side panels',
      subtitle: 'Server, channel and member lists',
      value: value,
      min: kPanelScaleMin,
      max: kPanelScaleMax,
      isDefault: (value - kPanelScaleDefault).abs() < 0.001,
      onReset: () => ref.read(panelScaleProvider.notifier).reset(),
      onChanged: (v) => ref.read(panelScaleProvider.notifier).setScale(v),
    );
  }
}

/// The kit's slider row plus a reset. The reset keeps its slot while hidden,
/// so the track never shifts under a drag that leaves the default.
class _ScaleRow extends StatelessWidget {
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

  const _ScaleRow({
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
    // The phone tab still hosts these without a density, so a narrow column
    // stacks the slider under the title the way a touch page does.
    return LayoutBuilder(
      builder: (context, constraints) {
        final touch = SettingsDensity.touchOf(context) ||
            constraints.maxWidth < _kStackBelowWidth;
        return SettingsDensity(touch: touch, child: _row(context, touch));
      },
    );
  }

  Widget _row(BuildContext context, bool touch) {
    final hollow = HollowTheme.of(context);
    final label = scalePercentLabel(value);
    final slider = HollowSlider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: scaleDivisions(min, max),
      label: label,
      semanticFormatterCallback: scalePercentLabel,
      onChangeStart: onChangeStart,
      onChanged: onChanged,
      onChangeEnd: onChangeEnd,
    );
    final readout = SizedBox(
      width: _kReadoutWidth,
      child: Text(
        label,
        textAlign: TextAlign.right,
        style: HollowTypography.monoSmall.copyWith(
          color: hollow.textSecondary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    final reset = Visibility(
      visible: !isDefault,
      maintainSize: true,
      maintainAnimation: true,
      maintainState: true,
      child: HollowIconButton(
        icon: LucideIcons.rotateCcw,
        label: 'Reset $title to default',
        size: touch ? 44 : 32,
        onPressed: isDefault ? null : onReset,
      ),
    );
    final controls = [
      if (touch)
        Expanded(child: slider)
      else
        SizedBox(width: _kSliderWidth, child: slider),
      readout,
      const SizedBox(width: HollowSpacing.xs),
      reset,
    ];
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      wideTrailing: true,
      trailing: Row(
        mainAxisSize: touch ? MainAxisSize.max : MainAxisSize.min,
        children: controls,
      ),
    );
  }
}

const double _kSliderWidth = 200;
const double _kReadoutWidth = 48;

/// Narrower than this, a trailing slider leaves the title too little room.
const double _kStackBelowWidth = 480;

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
        child: Slider( // design-ignore: the hue picker paints its own rainbow track
          value: hue.clamp(0, 359),
          min: 0,
          max: 359,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// The Ambient opt-in, shared by the desktop and mobile Appearance pages.
class AmbientBackgroundToggle extends ConsumerWidget {
  const AmbientBackgroundToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(ambientBackgroundProvider).valueOrNull ?? false;
    return SettingsSwitchRow(
      title: 'Ambient light',
      subtitle: 'Slow drifting light behind your chats',
      value: on,
      onChanged: (v) => ref
          .read(ambientBackgroundProvider.notifier)
          .setEnabled(v)
          .catchError((_) {}),
    );
  }
}

/// Cozy or compact chat, shared by the desktop and mobile Appearance pages.
class MessageDisplayPicker extends ConsumerWidget {
  const MessageDisplayPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final display = ref.watch(messageDisplayProvider);
    return SettingsChoiceRow<MessageDisplay>(
      title: 'Messages',
      subtitle: display == MessageDisplay.cozy
          ? 'Cozy: avatars, grouped under a name'
          : 'Compact: one line per message, no avatars',
      value: display,
      options: const [
        (MessageDisplay.cozy, 'Cozy'),
        (MessageDisplay.compact, 'Compact'),
      ],
      onChanged: (d) => ref
          .read(messageDisplayProvider.notifier)
          .set(d)
          .catchError((_) {}),
    );
  }
}
