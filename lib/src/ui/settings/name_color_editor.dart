import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/name_text.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Hues of the preset swatches. Each theme moves a stop's lightness until it
/// reads, so only the hue and saturation of a pick survive everywhere: these
/// are the hues that still read as themselves at 4.5:1 on dark and on light
/// (a warmer amber, since a yellow that dark turns olive on light).
const List<double> kNameColorPresetHues = [
  0, 20, 40, 95, 150, 185, 210, 250, 280, 320,
];

/// A pick from a hue: saturated and mid-light, the theme does the rest. A
/// fuller saturation keeps a lifted red red and a darkened orange orange,
/// where a paler one drifts to pink and brown.
Color nameColorFromHue(double hue) =>
    HSLColor.fromAHSL(1.0, hue % 360, 0.9, 0.55).toColor();

/// Settings > Profile > Name colour (#140): one colour, or two or three for a
/// gradient across the name, with the name previewed on a dark and a light
/// surface. Edits wait in the profile draft like every other profile field.
class NameColorEditor extends ConsumerStatefulWidget {
  final String peerId;

  const NameColorEditor({super.key, required this.peerId});

  @override
  ConsumerState<NameColorEditor> createState() => _NameColorEditorState();
}

class _NameColorEditorState extends ConsumerState<NameColorEditor> {
  /// Which stop a swatch or the hue bar changes.
  int _selected = 0;

  void _set(List<Color> stops) {
    ref
        .read(profileDraftProvider.notifier)
        .setNameColor(stops.isEmpty ? '' : nameColorField(stops));
  }

  void _pick(List<Color> stops, Color color) {
    if (stops.isEmpty) {
      _selected = 0;
      _set([color]);
      return;
    }
    _set([...stops]..[_selected] = color);
  }

  void _add(List<Color> stops) {
    final last = HSLColor.fromColor(stops.last).hue;
    setState(() => _selected = stops.length);
    _set([...stops, nameColorFromHue(last + 60)]);
  }

  void _removeSelected(List<Color> stops) {
    final at = _selected;
    setState(() => _selected = at > 0 ? at - 1 : 0);
    _set([...stops]..removeAt(at));
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final touch = SettingsDensity.touchOf(context);
    final draft = ref.watch(profileDraftProvider);
    final saved = ref.watch(
        profileProvider.select((p) => p[widget.peerId]?.nameColor ?? ''));
    final field = draft.effectiveNameColor ?? saved;
    final stops = nameColorStops(field) ?? const <Color>[];
    if (_selected >= stops.length) _selected = stops.isEmpty ? 0 : stops.length - 1;
    final swatch = touch ? 36.0 : 24.0;
    final selectedHue =
        stops.isEmpty ? null : HSLColor.fromColor(stops[_selected]).hue;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SettingsRow(
          title: 'Name colour',
          subtitle: switch (stops.length) {
            0 => 'Your usual colour. Pick one, or up to three for a gradient.',
            1 => 'One colour. Add another for a gradient.',
            _ => 'A gradient of ${stops.length} colours',
          },
          trailing: stops.isEmpty
              ? null
              : HollowButton.ghost(
                  onPressed: () => _set(const []),
                  compact: true,
                  semanticLabel: 'Remove name colour',
                  child: const Text('Remove'),
                ),
        ),
        if (stops.isNotEmpty) ...[
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < stops.length; i++)
                _Swatch(
                  color: stops[i],
                  size: swatch,
                  selected: i == _selected,
                  label: 'Colour ${i + 1} of ${stops.length}',
                  onTap: () => setState(() => _selected = i),
                ),
              if (stops.length < kMaxNameColorStops)
                HollowIconButton(
                  icon: LucideIcons.plus,
                  label: 'Add a colour',
                  size: touch ? 44 : 32,
                  onPressed: () => _add(stops),
                ),
              if (stops.length > 1)
                HollowIconButton(
                  icon: LucideIcons.x,
                  label: 'Remove colour ${_selected + 1}',
                  size: touch ? 44 : 32,
                  onPressed: () => _removeSelected(stops),
                ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            for (final hue in kNameColorPresetHues)
              _Swatch(
                color: nameColorFromHue(hue),
                size: swatch,
                selected: false,
                label: 'Use this colour',
                onTap: () => _pick(stops, nameColorFromHue(hue)),
              ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        Semantics(
          label: 'Hue of the selected colour',
          child: AccentHueSliderRow(
            hue: selectedHue ?? kNameColorPresetHues.first,
            height: swatch,
            trackHeight: 12,
            thumbRadius: 8,
            onChanged: (hue) => _pick(stops, nameColorFromHue(hue)),
          ),
        ),
        const SizedBox(height: HollowSpacing.md),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable:
              ref.read(profileDraftProvider.notifier).displayName,
          builder: (context, value, _) {
            final typed = value.text.trim();
            final name = typed.isNotEmpty ? typed : 'Your name';
            return Row(
              children: [
                Expanded(
                  child: NameColorPreview(
                    name: name,
                    peerId: widget.peerId,
                    field: field,
                    theme: HollowTheme.dark(),
                    caption: 'On dark',
                    radius: hollow.radiusMd,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: NameColorPreview(
                    name: name,
                    peerId: widget.peerId,
                    field: field,
                    theme: HollowTheme.light(),
                    caption: 'On light',
                    radius: hollow.radiusMd,
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: HollowSpacing.md),
      ],
    );
  }
}

/// [name] as everyone else on [theme] sees it: the canvas of that theme, the
/// name in the paint it gets there, a pick in the accent band turned as theirs is.
class NameColorPreview extends StatelessWidget {
  final String name;
  final String peerId;
  final String field;
  final HollowTheme theme;
  final String caption;
  final double radius;

  const NameColorPreview({
    super.key,
    required this.name,
    required this.peerId,
    required this.field,
    required this.theme,
    required this.caption,
    required this.radius,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        color: theme.background,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: HollowTheme.of(context).border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          NameText(
            name,
            paint: namePaintFor(peerId, theme, field: field),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.body.copyWith(fontWeight: FontWeight.w600),
          ),
          Text(
            caption,
            style: HollowTypography.caption
                .copyWith(color: theme.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// One colour square. Selected wears a stronger outline, never a fill change.
class _Swatch extends StatelessWidget {
  final Color color;
  final double size;
  final bool selected;
  final String label;
  final VoidCallback onTap;

  const _Swatch({
    required this.color,
    required this.size,
    required this.selected,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusXs);
    return HollowFocusRing(
      onActivate: onTap,
      borderRadius: radius,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: HollowTooltip(
              message: label,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: radius,
                  border: Border.all(
                    color: selected ? hollow.textPrimary : hollow.border,
                    width: selected ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
