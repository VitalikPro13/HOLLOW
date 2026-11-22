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

/// Hues of the preset swatches. A pick is drawn as picked wherever it clears
/// [kChosenNameContrast]; where it does not (yellows on light, deep blues on
/// dark) its lightness moves, so these are the hues that still read as
/// themselves then (a warmer amber, since a darkened yellow turns olive).
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
        _ReadabilityNote(field: field),
        const SizedBox(height: HollowSpacing.md),
      ],
    );
  }
}

/// What the readability floor did to a pick's stops on the dark and light
/// themes, as one line, or null when every stop is drawn as picked. [dark] and
/// [light] are [chosenNameShifts] for those themes.
String? nameColorShiftNote(List<int>? dark, List<int>? light) {
  final moves = <_Move>[];
  for (final (theme, shifts) in [('dark', dark), ('light', light)]) {
    if (shifts == null) continue;
    final moved = [
      for (var i = 0; i < shifts.length; i++)
        if (shifts[i] != 0) i,
    ];
    if (moved.isEmpty) continue;
    final way = moved.every((i) => shifts[i] > 0)
        ? 'ightened'
        : moved.every((i) => shifts[i] < 0)
            ? 'arkened'
            : 'djusted';
    // Every stop moved: the pick as a whole, no colour named.
    moves.add(_Move(way, theme, moved.length == shifts.length ? null : moved));
  }
  if (moves.isEmpty) return null;
  final one = moves.length == 1 ||
      _sameStops(moves[0].stops, moves[1].stops);
  final stops = moves.first.stops;
  if (one && stops == null) {
    return '${moves.first.how(capital: true)}'
        '${moves.length > 1 ? ' and ${moves[1].how()}' : ''} '
        'so it stays readable.';
  }
  if (one) {
    return '${_colours(stops!, capital: true)} '
        '${moves.map((m) => m.how()).join(' and ')} '
        'so ${stops.length == 1 ? 'it stays' : 'they stay'} readable.';
  }
  return '${moves[0].clause(capital: true)} and ${moves[1].clause()} '
      'so they stay readable.';
}

bool _sameStops(List<int>? a, List<int>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _colours(List<int> stops, {bool capital = false}) {
  final n = [for (final i in stops) '${i + 1}'];
  final word = capital ? 'Colour' : 'colour';
  return n.length == 1
      ? '$word ${n.first} is'
      : '${word}s ${n.sublist(0, n.length - 1).join(', ')} and ${n.last} are';
}

/// One theme's move: [way] is the verb past its first letter, so a sentence
/// can start with it without changing case at run time.
class _Move {
  final String way;
  final String theme;

  /// Which stops moved, or null for all of them.
  final List<int>? stops;

  const _Move(this.way, this.theme, this.stops);

  String how({bool capital = false}) {
    final first = switch (way) {
      'ightened' => capital ? 'L' : 'l',
      'arkened' => capital ? 'D' : 'd',
      _ => capital ? 'A' : 'a',
    };
    return '$first$way on $theme';
  }

  String clause({bool capital = false}) => stops == null
      ? '${capital ? 'Every' : 'every'} colour is ${how()}'
      : '${_colours(stops!, capital: capital)} ${how()}';
}

/// The floor's note under the previews (#140), from the paint they draw.
class _ReadabilityNote extends StatelessWidget {
  final String field;

  const _ReadabilityNote({required this.field});

  @override
  Widget build(BuildContext context) {
    final note = nameColorShiftNote(
      chosenNameShifts(HollowTheme.dark(), field),
      chosenNameShifts(HollowTheme.light(), field),
    );
    if (note == null) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            // Level with the first line's x-height.
            padding: const EdgeInsets.only(top: HollowSpacing.xxs),
            child: Icon(LucideIcons.triangleAlert,
                size: 14, color: hollow.warning),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: Text(
              note,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary),
            ),
          ),
        ],
      ),
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
