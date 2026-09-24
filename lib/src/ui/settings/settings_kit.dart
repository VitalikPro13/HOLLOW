import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_slider.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The building blocks of every Settings page, desktop and phone alike: a page
/// is sections, a section is rows, a row is a name, one line of explanation
/// and a control on its trailing edge. No cards, no icons on rows.
///
/// The phone wraps its pages in `SettingsDensity(touch: true)`, which grows the
/// rows to touch height and moves wide controls under the title.

/// Pointer or touch sizing for the settings blocks below it.
class SettingsDensity extends InheritedWidget {
  final bool touch;

  const SettingsDensity({super.key, required this.touch, required super.child});

  static bool touchOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsDensity>()?.touch ??
      false;

  @override
  bool updateShouldNotify(SettingsDensity oldWidget) =>
      touch != oldWidget.touch;
}

/// One settings page: its title, an optional line under it, then its big
/// sections with a hairline between each two. Each child is one section; the
/// host owns the scroll and the page padding.
class SettingsPage extends StatelessWidget {
  final String? title;
  final String? intro;
  final List<Widget> children;

  const SettingsPage({
    super.key,
    this.title,
    this.intro,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // The phone's route bar already names the page.
    final showTitle = title != null && !SettingsDensity.touchOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showTitle)
          Text(
            title!,
            style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
          ),
        if (intro != null) ...[
          if (showTitle) const SizedBox(height: HollowSpacing.sm),
          Text(
            intro!,
            style: HollowTypography.body.copyWith(color: hollow.textSecondary),
          ),
        ],
        if (showTitle || intro != null)
          const SizedBox(height: HollowSpacing.xl),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: HollowSpacing.xl),
              child: HollowDivider(),
            ),
          _SettingsTopLevel(child: children[i]),
        ],
      ],
    );
  }
}

/// Marks a page's own sections: their spacing comes from the page's dividers,
/// so they drop their own top gap. A section nested inside one keeps it.
class _SettingsTopLevel extends InheritedWidget {
  const _SettingsTopLevel({required super.child});

  @override
  bool updateShouldNotify(_SettingsTopLevel oldWidget) => false;
}

/// The gap above a section or fold: none for a page's own sections (the
/// divider spaces them), [HollowSpacing.xl] for one nested inside another.
double _sectionTopGap(BuildContext context) {
  final topLevel =
      context.getInheritedWidgetOfExactType<_SettingsTopLevel>() != null &&
          context.findAncestorWidgetOfExactType<SettingsSection>() == null &&
          context.findAncestorWidgetOfExactType<SettingsAdvanced>() == null;
  return topLevel ? 0 : HollowSpacing.xl;
}

/// A titled group of rows. A page's sections are separated by one hairline;
/// never a card.
class SettingsSection extends StatelessWidget {
  final String? title;
  final String? subtitle;

  /// One trailing action on the header, a ghost button.
  final Widget? action;
  final List<Widget> children;

  const SettingsSection({
    super.key,
    this.title,
    this.subtitle,
    this.action,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: _sectionTopGap(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            HollowSectionHeader(title!, subtitle: subtitle, action: action),
          ...children,
        ],
      ),
    );
  }
}

/// The one settings row: [title], an optional line of [subtitle], and the
/// [trailing] control. [leading] is for a thing the row IS about (an avatar, a
/// server), never a decorative icon.
class SettingsRow extends StatelessWidget {
  final String title;
  final String? subtitle;

  /// Replaces [subtitle] when the line needs styling (a status word, a link).
  final Widget? subtitleWidget;
  final Widget? leading;
  final Widget? trailing;

  /// A control too wide for the trailing edge on a phone (chips, a slider)
  /// goes under the title there. Desktop keeps it trailing.
  final bool wideTrailing;

  /// Greys the title when the row's control is locked by another setting.
  final bool enabled;

  /// A badge beside the title ("This device", "In use").
  final Widget? titleTrailing;

  /// The title in the console voice, for a thing the protocol names (a relay).
  final bool monoTitle;

  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.leading,
    this.trailing,
    this.wideTrailing = false,
    this.enabled = true,
    this.titleTrailing,
    this.monoTitle = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final titleStyle = (monoTitle
            ? HollowTypography.mono
            : touch
                ? HollowTypography.bodyTouch
                : HollowTypography.body)
        .copyWith(color: enabled ? hollow.textPrimary : hollow.textSecondary);
    final sub = subtitleWidget ??
        (subtitle == null
            ? null
            : Text(
                subtitle!,
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary),
              ));
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (titleTrailing == null)
          Text(title, style: titleStyle)
        else
          Wrap(
            spacing: HollowSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [Text(title, style: titleStyle), titleTrailing!],
          ),
        if (sub != null) ...[
          const SizedBox(height: HollowSpacing.xxs),
          DefaultTextStyle.merge(
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
            child: sub,
          ),
        ],
      ],
    );
    final stacked = touch && wideTrailing && trailing != null;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: touch ? 56 : 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
        child: stacked
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (leading == null)
                    text
                  else
                    Row(
                      children: [
                        leading!,
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(child: text),
                      ],
                    ),
                  const SizedBox(height: HollowSpacing.md),
                  trailing!,
                ],
              )
            : Row(
                children: [
                  if (leading != null) ...[
                    leading!,
                    const SizedBox(width: HollowSpacing.md),
                  ],
                  Expanded(child: text),
                  if (trailing != null) ...[
                    const SizedBox(width: HollowSpacing.lg),
                    trailing!,
                  ],
                ],
              ),
      ),
    );
  }
}

/// A row whose control is a switch.
class SettingsSwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;

  /// Null disables the switch.
  final ValueChanged<bool>? onChanged;

  const SettingsSwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      enabled: onChanged != null,
      trailing: HollowToggle(
        value: value,
        onChanged: onChanged,
        semanticLabel: title,
      ),
    );
  }
}

/// A row choosing one of a few options, as chips.
class SettingsChoiceRow<T> extends StatelessWidget {
  final String title;
  final String? subtitle;
  final T value;
  final List<(T, String)> options;

  /// Null disables the chips.
  final ValueChanged<T>? onChanged;

  const SettingsChoiceRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      wideTrailing: true,
      enabled: onChanged != null,
      trailing: Wrap(
        spacing: HollowSpacing.sm,
        runSpacing: HollowSpacing.sm,
        children: [
          for (final (opt, label) in options)
            HollowChip(
              label: label,
              selected: opt == value,
              onTap: onChanged == null ? null : () => onChanged!(opt),
            ),
        ],
      ),
    );
  }
}

/// A row with a slider and its value in the console voice.
class SettingsSliderRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;

  /// The readout beside the slider ("120%", "25 MB", "Auto").
  final String valueLabel;

  /// Null locks the slider (another setting owns the value).
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double sliderWidth;

  const SettingsSliderRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.valueLabel,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.sliderWidth = 200,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final slider = HollowSlider(
      value: value.clamp(min, max),
      min: min,
      max: max,
      divisions: divisions,
      label: valueLabel,
      onChanged: onChanged,
      onChangeStart: onChangeStart,
      onChangeEnd: onChangeEnd,
    );
    final readout = SizedBox(
      width: 64,
      child: Text(
        valueLabel,
        textAlign: TextAlign.right,
        style: HollowTypography.monoSmall.copyWith(
          color: hollow.textSecondary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
    return SettingsRow(
      title: title,
      subtitle: subtitle,
      enabled: onChanged != null,
      wideTrailing: true,
      trailing: touch
          ? Row(children: [Expanded(child: slider), readout])
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(width: sliderWidth, child: slider),
                readout,
              ],
            ),
    );
  }
}

/// A quiet note under a group: a footnote, a hint, a caution.
class SettingsNote extends StatelessWidget {
  final String text;
  const SettingsNote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xs),
      child: Text(
        text,
        style: HollowTypography.bodySmall.copyWith(color: hollow.textSecondary),
      ),
    );
  }
}

/// A row that reveals a list under it ("Blocked users", "By conversation").
/// The rows it reveals are indented one step so they read as its children.
class SettingsExpandRow extends StatefulWidget {
  final String title;
  final String? subtitle;
  final String showLabel;
  final String hideLabel;
  final bool initiallyOpen;
  final List<Widget> children;

  const SettingsExpandRow({
    super.key,
    required this.title,
    this.subtitle,
    this.showLabel = 'Show',
    this.hideLabel = 'Hide',
    this.initiallyOpen = false,
    required this.children,
  });

  @override
  State<SettingsExpandRow> createState() => _SettingsExpandRowState();
}

class _SettingsExpandRowState extends State<SettingsExpandRow> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          title: widget.title,
          subtitle: widget.subtitle,
          trailing: HollowButton.ghost(
            compact: true,
            onPressed: () => setState(() => _open = !_open),
            child: Text(_open ? widget.hideLabel : widget.showLabel),
          ),
        ),
        // Opening a list is switching what the region shows: instant.
        if (_open)
          Padding(
            padding: const EdgeInsets.only(
                left: HollowSpacing.md, bottom: HollowSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: widget.children,
            ),
          ),
      ],
    );
  }
}

/// The fold at the end of a page for what few people change. It starts open
/// when [initiallyOpen] (a setting inside it was changed from its default), so
/// nothing someone set is ever hidden from them.
class SettingsAdvanced extends StatefulWidget {
  final bool initiallyOpen;
  final List<Widget> children;

  const SettingsAdvanced({
    super.key,
    this.initiallyOpen = false,
    required this.children,
  });

  @override
  State<SettingsAdvanced> createState() => _SettingsAdvancedState();
}

class _SettingsAdvancedState extends State<SettingsAdvanced> {
  late bool _open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: _sectionTopGap(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: HollowPressable(
              onTap: () => setState(() => _open = !_open),
              semanticLabel: _open ? 'Hide advanced settings' : 'Show advanced settings',
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.xs, vertical: HollowSpacing.xs),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: HollowDurations.fast,
                    child: Icon(LucideIcons.chevronRight,
                        size: 16, color: hollow.textSecondary),
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  Text(
                    'Advanced',
                    style: HollowTypography.label
                        .copyWith(color: hollow.textSecondary),
                  ),
                ],
              ),
            ),
          ),
          if (_open) ...widget.children,
        ],
      ),
    );
  }
}
