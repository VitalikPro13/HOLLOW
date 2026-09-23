import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Design language CI guard (`reports/reference/HOLLOW_DESIGN_LANGUAGE.md` §7).
///
/// A RATCHET, not a ban. Each rule carries a baseline count taken the day the
/// guard landed: the count may fall and may never rise. That is deliberate.
/// Rules like the numeric-EdgeInsets one have hundreds of existing sites, and a
/// guard that fails on all of them from day one gets suppressed and stops
/// protecting anything. This one fails the moment a NEW violation appears,
/// which is the behaviour that actually keeps the UI consistent.
///
/// When a sweep removes violations, lower the baseline in the same commit. The
/// failure message prints the number to write.
///
/// A genuine one-off (a brand asset's exact colour, a platform-mandated metric)
/// is exempted with `// design-ignore: <reason>` on the offending line. It is
/// not for "I did not want to add a token".
///
/// Run `HOLLOW_DESIGN_BASELINE=print flutter test test/design_language_guard_test.dart`
/// to print the current counts for every rule.
void main() {
  final printMode = Platform.environment['HOLLOW_DESIGN_BASELINE'] == 'print';

  test('design language rules do not gain new violations', () {
    expect(Directory('lib/src/ui').existsSync(), isTrue,
        reason: 'expected to run from the project root (lib/src/ui missing)');

    final report = <String, List<_Hit>>{};
    for (final rule in _rules) {
      report[rule.id] = rule.scan();
    }

    if (printMode) {
      final buf = StringBuffer('\nCurrent counts (paste into _rules):\n\n');
      for (final rule in _rules) {
        buf.writeln("  '${rule.id}': ${report[rule.id]!.length},");
      }
      // ignore: avoid_print
      print(buf.toString());
      return;
    }

    final regressions = <_Rule>[];
    final improvements = <String>[];
    for (final rule in _rules) {
      final count = report[rule.id]!.length;
      if (count > rule.baseline) {
        regressions.add(rule);
      } else if (count < rule.baseline) {
        improvements.add('  ${rule.id}: ${rule.baseline} -> $count');
      }
    }

    if (regressions.isNotEmpty) {
      final buf = StringBuffer()
        ..writeln('\nNew design language violations.\n')
        ..writeln('The rules are reports/reference/HOLLOW_DESIGN_LANGUAGE.md '
            'section 7.')
        ..writeln('Load the `hollow-ui` skill before editing UI.\n');
      for (final rule in regressions) {
        final hits = report[rule.id]!;
        buf
          ..writeln('  [${rule.id}] ${rule.what}')
          ..writeln('      baseline ${rule.baseline}, now ${hits.length}')
          ..writeln('      fix: ${rule.fix}');
        // Only the tail is new, but which sites are new is not knowable from a
        // count alone, so show a sample the author can scan.
        for (final hit in hits.take(12)) {
          buf.writeln('        ${hit.location}  ${hit.snippet}');
        }
        if (hits.length > 12) {
          buf.writeln('        ... and ${hits.length - 12} more');
        }
        buf.writeln('');
      }
      buf.writeln('If a site is a genuine one-off, add '
          '`// design-ignore: <reason>` to its line.');
      fail(buf.toString());
    }

    if (improvements.isNotEmpty) {
      final buf = StringBuffer()
        ..writeln('\nViolations went DOWN. Lower these baselines in the same '
            'commit so the ratchet holds:\n')
        ..writeln(improvements.join('\n'));
      fail(buf.toString());
    }
  });

  test('no dialog draws its own frame', () {
    // A hand-drawn dialog opens as `showHollowDialog(... builder: ... Center(`
    // with its own Material and decorated Container. The frame is
    // HollowDialogSurface; a builder returns HollowDialog, the surface, or a
    // widget that builds one.
    final frame = RegExp(r'\b(Center|Material|Container|DecoratedBox)\(');
    final hits = <String>[];
    for (final entity in Directory('lib/src/ui').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.startsWith(_components)) continue;
      final source = entity.readAsStringSync();
      for (final call in RegExp(r'showHollowDialog\b').allMatches(source)) {
        final window = source.substring(
            call.end, (call.end + 500).clamp(0, source.length));
        final builder = window.indexOf('builder:');
        if (builder < 0) continue;
        final start = builder + 'builder:'.length;
        final body =
            window.substring(start, (start + 260).clamp(0, window.length));
        if (frame.hasMatch(body)) {
          final line = '\n'.allMatches(source.substring(0, call.start)).length;
          hits.add('$path:${line + 1}');
        }
      }
    }
    expect(hits, isEmpty,
        reason: 'These dialogs draw their own frame. Return HollowDialog, or '
            'HollowDialogSurface for a layout of its own '
            '(HOLLOW_DESIGN_LANGUAGE.md 4.4):\n  ${hits.join('\n  ')}');
  });

  test('no action row holds two filled buttons', () {
    // Siblings share the innermost list literal (`children:` or `actions:`).
    // A filled in the else of a condition never shares the screen with the
    // one in its if.
    final filled = RegExp(r'HollowButton\.filled\(');
    final hits = <String>[];
    for (final entity in Directory('lib/src/ui').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (path.startsWith(_components)) continue;
      final source = _blankComments(entity.readAsStringSync());
      final byList = <int, List<int>>{};
      for (final m in filled.allMatches(source)) {
        final before = source.substring(0, m.start).trimRight();
        // `) :` is a ternary's else; `child:` is a named argument.
        if (before.endsWith('else') ||
            RegExp(r'\)\s*:$').hasMatch(before)) {
          continue;
        }
        final lineStart = source.lastIndexOf('\n', m.start) + 1;
        final lineEnd = source.indexOf('\n', m.start);
        if (source
            .substring(lineStart, lineEnd < 0 ? source.length : lineEnd)
            .contains('design-ignore:')) {
          continue;
        }
        final list = _enclosingList(source, m.start);
        if (list < 0) continue;
        byList.putIfAbsent(list, () => []).add(m.start);
      }
      for (final starts in byList.values.where((s) => s.length > 1)) {
        final lines = starts
            .map((s) => '\n'.allMatches(source.substring(0, s)).length + 1);
        hits.add('$path:${lines.join(',')}');
      }
    }
    expect(hits, isEmpty,
        reason: 'Two filled buttons side by side. One region has ONE primary: '
            'the other becomes outline (an alternative) or ghost '
            '(HOLLOW_DESIGN_LANGUAGE.md 4.2):\n  ${hits.join('\n  ')}');
  });
}

/// Offset of the `[` that opens the list literal holding [pos], or -1 when a
/// block body (`{`) is met first, since a builder's statements are not
/// siblings.
int _enclosingList(String source, int pos) {
  var open = 0;
  for (var i = pos - 1; i >= 0; i--) {
    final c = source[i];
    if (c == ')' || c == ']' || c == '}') {
      open++;
    } else if (c == '(' || c == '[' || c == '{') {
      if (open > 0) {
        open--;
      } else if (c == '[') {
        return i;
      } else if (c == '{') {
        return -1;
      }
    }
  }
  return -1;
}

/// Blanks `//` comment lines in place, so brackets in prose do not unbalance
/// the scan and offsets still map to lines.
String _blankComments(String source) => source
    .split('\n')
    .map((l) => l.trimLeft().startsWith('//') ? ' ' * l.length : l)
    .join('\n');

// --- The rules ---------------------------------------------------------------

const _theme = 'lib/src/theme';
const _components = 'lib/src/ui/components';

final _rules = <_Rule>[
  _Rule(
    id: 'font-size-literal',
    what: 'fontSize: outside the theme',
    fix: 'use a HollowTypography role; a size with no role is a decision, '
        'not a literal',
    pattern: RegExp(r'\bfontSize\s*:'),
    excludeDirs: [_theme],
    baseline: 565,
  ),
  _Rule(
    id: 'material-colors',
    what: 'Colors.<name> outside the theme',
    fix: 'use hollow.<token>; Colors.transparent is the only allowed one',
    pattern: RegExp(r'\bColors\.(?!transparent\b)\w+'),
    excludeDirs: [_theme],
    baseline: 183,
  ),
  _Rule(
    id: 'color-literal',
    what: 'Color(0x...) outside the theme',
    fix: 'add a token in lib/src/theme/hollow_colors.dart and read it from '
        'HollowTheme',
    pattern: RegExp(r'\bColor\(\s*0x'),
    excludeDirs: [_theme],
    baseline: 130,
  ),
  _Rule(
    id: 'radius-literal',
    what: 'BorderRadius.circular(<number>) outside the theme',
    fix: 'use hollow.radiusXs / radiusMd / radiusLg / radiusXl',
    pattern: RegExp(r'BorderRadius\.circular\(\s*[0-9]'),
    excludeDirs: [_theme],
    baseline: 108,
  ),
  _Rule(
    id: 'letter-spacing',
    what: 'letterSpacing: outside the theme',
    fix: 'hierarchy comes from weight and colour, not tracking',
    pattern: RegExp(r'\bletterSpacing\s*:'),
    excludeDirs: [_theme],
    baseline: 0,
  ),
  _Rule(
    id: 'upper-case-label',
    what: 'toUpperCase() on a label',
    fix: 'sentence case; the tracked all-caps eyebrow is the loudest '
        'generated-UI tell',
    pattern: RegExp(r'\.toUpperCase\(\)'),
    excludeDirs: [_theme],
    baseline: 0,
  ),
  _Rule(
    id: 'raw-divider',
    what: 'Divider( outside components/',
    fix: 'use HollowDivider',
    pattern: RegExp(r'(?<![\w.])(Vertical)?Divider\('),
    excludeDirs: [_theme, _components],
    baseline: 0,
  ),
  _Rule(
    id: 'local-label-class',
    what: 'a Chip / Pill / Tag / Badge class outside components/',
    fix: 'clickable is HollowChip, static is HollowBadge; there is no third '
        'option',
    pattern: RegExp(r'^\s*class\s+\w*(Chip|Pill|Tag|Badge)\w*\b'),
    excludeDirs: [_theme, _components],
    baseline: 0,
  ),
  _Rule(
    id: 'local-section-header',
    what: 'a local section header / section label class outside components/',
    fix: 'a group title is HollowSectionHeader; the label above one settings '
        'field is SettingsFieldLabel',
    pattern: RegExp(r'^\s*class\s+\w*Section(Label|Header|Title)\b'),
    excludeDirs: [_theme, _components],
    baseline: 0,
  ),
  _Rule(
    id: 'local-empty-state',
    what: 'a local empty-state class or _xEmpty builder outside components/',
    fix: 'HollowEmptyState: a pane takes the default, a list inside a card '
        'or section takes dense: true',
    pattern: RegExp(
        r'Widget\s+_(?!\w*OrEmpty)\w*[Ee]mpty\w*\(|class\s+\w*Empty\w*\s+extends'),
    excludeDirs: [_theme, _components],
    baseline: 0,
  ),
  _Rule(
    id: 'raw-spinner',
    what: 'a raw CircularProgressIndicator',
    fix: 'HollowSpinner (small in a row or button, medium in a card, large '
        'for a pane); a busy button is HollowButton(loading: true)',
    pattern: RegExp(r'\bCircularProgressIndicator\('),
    excludeFiles: ['hollow_spinner.dart'],
    baseline: 0,
  ),
  _Rule(
    id: 'raw-bottom-sheet',
    what: 'a hand-styled showModalBottomSheet',
    fix: 'showHollowSheet (surface, radius and handle in one place); a '
        'DraggableScrollableSheet passes handle: false and places '
        'HollowSheetHandle itself',
    pattern: RegExp(r'\bshowModalBottomSheet\b'),
    excludeFiles: ['hollow_sheet.dart'],
    baseline: 0,
  ),
  _Rule(
    id: 'raw-slider',
    what: 'a Material Slider / RangeSlider',
    fix: 'HollowSlider (onMedia: true over video); a slider with its own '
        'track art is a design-ignore with the reason',
    pattern: RegExp(r'(?<![\w.])(Range)?Slider\('),
    excludeFiles: ['hollow_slider.dart'],
    baseline: 0,
  ),
  _Rule(
    id: 'raw-switch',
    what: 'a Material or Cupertino Switch / Checkbox / Radio',
    fix: 'HollowToggle with a semanticLabel; a choice among a few options is '
        'a row of HollowChip',
    pattern: RegExp(
        r'(?<![\w.])(Cupertino)?(Switch|Checkbox|Radio)(ListTile)?(\.adaptive)?\('),
    baseline: 0,
  ),
  _Rule(
    id: 'local-label-builder',
    what: 'a _xChip / _xPill / _xTag / _xBadge builder function outside '
        'components/',
    fix: 'the same rule as a class: call HollowChip or HollowBadge instead '
        'of building a local one',
    pattern: RegExp(r'Widget\s+_\w*(Chip|Pill|Tag|Badge)\w*\('),
    excludeDirs: [_theme, _components],
    baseline: 0,
  ),
  _Rule(
    id: 'material-popup-menu',
    what: 'a Material PopupMenuButton',
    fix: 'open showHollowMenu from the trigger; a chip that opens a menu is '
        'settings/channel_access_pickers.dart',
    pattern: RegExp(r'\bPopupMenu(Button|Item)\b'),
    excludeDirs: [_theme],
    baseline: 0,
  ),
  _Rule(
    id: 'edge-insets-literal',
    what: 'numeric EdgeInsets outside the theme',
    fix: 'use HollowSpacing; inside a control 4 to 8, inside a container 12 '
        'to 16, around a section 24 to 32',
    pattern:
        RegExp(r'EdgeInsets\.(all|symmetric|only|fromLTRB)\([^)]*\b\d'),
    excludeDirs: [_theme],
    baseline: 216,
  ),
  _Rule(
    id: 'sized-box-gap',
    what: 'numeric SizedBox gap outside the theme',
    fix: 'gaps come from the ramp: 4 glued, 8 adjacent (two buttons, two '
        'chips), 12 grouped, 16 separated, 24 sectioned',
    pattern: RegExp(r'SizedBox\(\s*(width|height)\s*:\s*\d'),
    excludeDirs: [_theme],
    baseline: 164,
  ),
  _Rule(
    id: 'gradient',
    what: 'a gradient outside the theme and the annotation overlay',
    fix: 'depth comes from a luminance step, not a gradient',
    pattern: RegExp(r'\b(Linear|Radial|Sweep)Gradient\b'),
    excludeDirs: [_theme],
    excludeFiles: ['annotation_overlay.dart'],
    baseline: 21,
  ),
  _Rule(
    id: 'big-shadow',
    what: 'BoxShadow with blurRadius above 12',
    fix: 'shadows only on things that float above the app (menus, popovers, '
        'dialogs, toasts), blur 12 or less',
    pattern: RegExp(r'blurRadius\s*:\s*(\d+(?:\.\d+)?)'),
    threshold: 12,
    excludeDirs: [_theme],
    baseline: 15,
  ),
  _Rule(
    id: 'raw-dialog',
    what: 'showDialog / showGeneralDialog / AlertDialog / SimpleDialog / '
        'Dialog( outside components/',
    fix: 'showHollowDialog with HollowDialog (or HollowDialogSurface); a '
        'yes-or-no question is showHollowConfirm',
    pattern: RegExp(
        r'\bshow(General)?Dialog\s*[<(]|(?<![\w.])(Alert|Simple)?Dialog\('),
    excludeDirs: [_theme, _components],
    baseline: 0,
  ),
  _Rule(
    id: 'raw-material',
    what: 'raw Material( outside components/',
    fix: 'Hollow surfaces are HollowCard / showHollowDialog / showHollowMenu; '
        'a documented overlay host is the only exception',
    pattern: RegExp(r'(?<![\w.])Material\('),
    excludeDirs: [_theme, _components],
    baseline: 26,
  ),
];

// --- Scanning ----------------------------------------------------------------

class _Hit {
  final String location;
  final String snippet;
  _Hit(this.location, this.snippet);
}

class _Rule {
  final String id;

  /// One line naming the violation, printed on failure.
  final String what;

  /// What to do instead, printed on failure.
  final String fix;

  final RegExp pattern;

  /// When set, the pattern's first capture group is a number and only values
  /// ABOVE this count as a violation.
  final double? threshold;

  final List<String> excludeDirs;
  final List<String> excludeFiles;

  /// Violations present the day this rule landed. May fall, never rise.
  final int baseline;

  const _Rule({
    required this.id,
    required this.what,
    required this.fix,
    required this.pattern,
    required this.baseline,
    this.threshold,
    this.excludeDirs = const [],
    this.excludeFiles = const [],
  });

  List<_Hit> scan() {
    final hits = <_Hit>[];
    for (final entity in Directory('lib/src').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      if (excludeDirs.any(path.startsWith)) continue;
      if (excludeFiles.any((f) => path.endsWith('/$f'))) continue;

      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final trimmed = line.trimLeft();
        // A rule about rendered UI has nothing to say about prose.
        if (trimmed.startsWith('//')) continue;
        if (line.contains('design-ignore:')) continue;

        for (final match in pattern.allMatches(line)) {
          if (threshold != null) {
            final value = double.tryParse(match.group(1) ?? '');
            if (value == null || value <= threshold!) continue;
          }
          hits.add(_Hit('$path:${i + 1}', trimmed.length > 72
              ? '${trimmed.substring(0, 69)}...'
              : trimmed));
        }
      }
    }
    return hits;
  }
}
