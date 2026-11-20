import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// #149: a person's chosen name colour shows the same way wherever their name
/// is drawn. A gradient survives only through `NameText` (or `PeerNameText`,
/// `NameLine`, `HollowListRow.titlePaint`, `ConversationRow.titlePaint`), so a
/// name paint read down to `.color` is a name that lost its gradient.
///
/// Allowed: surfaces that draw ONE colour by nature (a speaking ring, the
/// stream overlay, which is a browser source with one text colour).
const _oneColourSites = {
  'lib/src/ui/call/call_theme.dart': 2, // callRingColor: a ring is one colour
  'lib/src/ui/settings/stream_overlay/overlay_people_section.dart': 1,
  'lib/src/ui/settings/stream_overlay/overlay_look_editor.dart': 2,
  'lib/src/core/services/overlay_publisher.dart': 2,
};

/// A paint held in a variable and read down to one colour, by file: the
/// plain-colour arm of `NameText` itself, and the screen icon beside a sharer's
/// name, which is one colour by nature.
const _oneColourReads = {
  'lib/src/ui/components/name_text.dart': 2,
  'lib/src/ui/call/share_tile.dart': 1,
};

/// A read, never an assignment (`_paint.color = c` sets a brush).
final _paintColorRead = RegExp(r'\b\w*[Pp]aint[!?]?\.color\b(?!\s*=[^=])');

/// Name labels drawn with no paint on purpose, by file: the real name in small
/// type under a nickname (the nickname above carries the colour), and the
/// recovery pool's helper list, a management list that stays neutral.
const _neutralNameSites = {
  'lib/src/ui/chat/dm_profile_panel.dart': 1,
  'lib/src/ui/archive/recovery_pool_dashboard.dart': 1,
};

const _nameFn =
    r'(?:displayNameFor|displayNameForPeer|serverDisplayNameFor|chosenNameForPeer)\(';
final _nameAssign =
    RegExp(r'\b(?:final|var|String\??)\s+(\w+)\s*=\s*' + _nameFn);
final _labelCall = RegExp(r'\b(HollowListRow|ConversationRow|Text)\(');

/// Each `Text(` whose text, or `HollowListRow`/`ConversationRow` whose title,
/// is a display name (a call or a local holding one) drawn with no paint.
List<String> _unpaintedNameLabels(String s) {
  final names = {for (final m in _nameAssign.allMatches(s)) m.group(1)!};
  final isName = RegExp('^(?:$_nameFn'
      '${names.isEmpty ? '' : '|(?:${names.join('|')})\\b'})');
  final hits = <String>[];
  for (final m in _labelCall.allMatches(s)) {
    final body = s.substring(m.end, _callEnd(s, m.end - 1));
    final String? label;
    if (m.group(1) == 'Text') {
      label = body.trimLeft();
    } else if (body.contains('titlePaint:')) {
      label = null;
    } else {
      label = RegExp(r'\btitle:\s*([^\n]*)').firstMatch(body)?.group(1);
    }
    if (label != null && isName.hasMatch(label)) {
      hits.add('${m.group(1)}(${label.split('\n').first})');
    }
  }
  return hits;
}

final _painterCall = RegExp(
    r'\b(namePaintFor|namePaint|personNamePaint|chosenNamePaint|chosenNamePaintOf|callNamePaint)\(');

String _source(File f) => f
    .readAsStringSync()
    .replaceAll('\r\n', '\n')
    // Line comments say nothing about what is drawn.
    .replaceAll(RegExp(r'//[^\n]*'), '');

/// The index just past the call's closing parenthesis.
int _callEnd(String s, int open) {
  var depth = 0;
  for (var i = open; i < s.length; i++) {
    if (s[i] == '(') depth++;
    if (s[i] == ')' && --depth == 0) return i + 1;
  }
  return s.length;
}

Iterable<File> _dartFiles() => Directory('lib/src')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .where((f) => !f.path.replaceAll(r'\', '/').contains('/rust/'));

void main() {
  test('no name paint is read down to one colour outside one-colour surfaces',
      () {
    final counts = <String, int>{};
    final where = <String>[];
    for (final f in _dartFiles()) {
      final path = f.path.replaceAll(r'\', '/');
      final s = _source(f);
      for (final m in _painterCall.allMatches(s)) {
        final end = _callEnd(s, m.end - 1);
        final after = s.substring(end).trimLeft();
        if (after.startsWith('.color') ||
            after.startsWith('?.color') ||
            after.startsWith('!.color')) {
          counts[path] = (counts[path] ?? 0) + 1;
          where.add('$path: ${m.group(1)}(...).color');
        }
      }
    }
    final over = [
      for (final e in counts.entries)
        if (e.value > (_oneColourSites[e.key] ?? 0)) e.key,
    ];
    expect(over, isEmpty,
        reason: 'A name drawn from one stop drops a chosen gradient. Draw it '
            'with NameText (or pass the NamePaint to PeerNameText, NameLine, '
            'HollowListRow.titlePaint, ConversationRow.titlePaint).\n'
            '${where.join('\n')}');
  });

  test('no name paint held in a variable is read down to one colour', () {
    final counts = <String, int>{};
    final where = <String>[];
    for (final f in _dartFiles()) {
      final path = f.path.replaceAll(r'\', '/');
      final s = _source(f);
      for (final m in _paintColorRead.allMatches(s)) {
        counts[path] = (counts[path] ?? 0) + 1;
        where.add('$path: ${m.group(0)}');
      }
    }
    final over = [
      for (final e in counts.entries)
        if (e.value > (_oneColourReads[e.key] ?? 0)) e.key,
    ];
    expect(over, isEmpty,
        reason: 'A NamePaint read down to .color drops a chosen gradient: hand '
            'the paint to NameText (or a component taking one).\n'
            '${where.join('\n')}');
  });

  test('every name label carries a paint, outside the neutral sites', () {
    final counts = <String, int>{};
    final where = <String>[];
    for (final f in _dartFiles()) {
      final path = f.path.replaceAll(r'\', '/');
      for (final hit in _unpaintedNameLabels(_source(f))) {
        counts[path] = (counts[path] ?? 0) + 1;
        where.add('$path: $hit');
      }
    }
    final over = [
      for (final e in counts.entries)
        if (e.value > (_neutralNameSites[e.key] ?? 0)) e.key,
    ];
    expect(over, isEmpty,
        reason: "A person's name drawn as plain text shows no chosen colour. "
            'Use NameText or PeerNameText, or pass titlePaint (ref.'
            'chosenNamePaintOf; null keeps it neutral where that is meant).\n'
            '${where.join('\n')}');
  });

  test('the unpainted-name scan sees every shape', () {
    const sample = """
final n = displayNameFor(p, id);
Text(n, style: s);
Text('Settings');
HollowListRow(title: displayNameForPeer(p, id));
HollowListRow(title: n, titlePaint: x);
ConversationRow(title: serverDisplayNameFor(p, id, nickname: ''));
NameText(n, paint: x);
""";
    expect(_unpaintedNameLabels(sample), hasLength(3));
  });

  test('the hashed colour reaches names only through the painter', () {
    final hits = <String>[];
    for (final f in _dartFiles()) {
      final path = f.path.replaceAll(r'\', '/');
      if (path.endsWith('lib/src/core/color_utils.dart')) continue;
      if (_source(f).contains(RegExp(r'\bnameColorFor\('))) hits.add(path);
    }
    expect(hits, isEmpty,
        reason: 'nameColorFor skips the chosen colour, the accent-band turn '
            'and the "Show custom name colours" switch: use namePaintFor.');
  });
}
