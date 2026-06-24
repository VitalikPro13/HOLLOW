import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Accessibility label CI guard (Phase 2 — VoiceOver / Voice Control).
///
/// Scans the `lib/src/ui` source tree for interactive controls that a screen
/// reader cannot name. An icon-only [HollowPressable] / [HollowButton] (its
/// child is a bare Icon / glyph with no text) MUST pass a `semanticLabel:`, or
/// VoiceOver and Voice Control announce nothing for it. A control whose child
/// is (or contains) `Text` is auto-named and is intentionally NOT flagged.
///
/// This is a STATIC source scan, not a widget test — it runs in milliseconds
/// with no FFI / rendering, and it catches the one thing the foundation widget
/// tests can't: a NEW icon-only control added later that forgets its label.
///
/// If this test fails it prints `file:line` for each offender plus the icon it
/// wraps. Fix by adding `semanticLabel: '<concise action>'` to that control
/// (sentence case, no trailing period — see the Phase 2 labels for the house
/// style). If a flagged control genuinely needs no label (rare — e.g. it is
/// purely decorative and also non-interactive), add an inline
/// `// a11y-ignore: <reason>` comment on the line with the `child:` or the
/// constructor, and the guard will skip it.
///
/// Detection is deliberately conservative: it favours missing a borderline
/// case over crying wolf, because a noisy guard gets suppressed and stops
/// protecting anything. It flags only the unambiguous "tappable thing whose
/// only content is an icon, with no label" shape.
void main() {
  test('icon-only HollowPressable/HollowButton controls have a semanticLabel',
      () {
    final uiDir = Directory('lib/src/ui');
    expect(uiDir.existsSync(), isTrue,
        reason: 'expected to run from the project root (lib/src/ui missing)');

    final offenders = <_Offender>[];

    for (final entity in uiDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      offenders.addAll(_scanFile(entity.path, source));
    }

    if (offenders.isNotEmpty) {
      final buf = StringBuffer()
        ..writeln('\nFound ${offenders.length} icon-only control(s) with no '
            'semanticLabel (screen readers announce nothing for these):\n');
      for (final o in offenders) {
        buf.writeln('  ${o.location}  →  ${o.widget} wrapping ${o.iconHint}');
      }
      buf
        ..writeln('\nFix: add `semanticLabel: \'<concise action>\'` to each '
            'control (sentence case, no trailing period).')
        ..writeln('If a control truly needs none, add `// a11y-ignore: '
            '<reason>` on its line.');
      fail(buf.toString());
    }
  });
}

class _Offender {
  final String location; // file:line
  final String widget; // HollowPressable / HollowButton.ghost / ...
  final String iconHint; // the icon expression
  _Offender(this.location, this.widget, this.iconHint);
}

/// Hollow's custom interactive controls. `HollowButton` covers the named
/// constructors (`.filled` etc.) via the regex.
final _ctorPattern = RegExp(r'\b(HollowPressable|HollowButton(?:\.\w+)?)\s*\(');

/// Raw Flutter tap widgets. These are flagged ONLY when they additionally have
/// an `onTap:` (so they're actually a button, not a drag/pan surface) AND are
/// not already wrapped in a `Semantics(...)`. The mobile nav "+" button slipped
/// through the original guard because it was a bare `GestureDetector`, not a
/// `HollowPressable` — this closes that gap.
final _rawTapPattern = RegExp(r'\b(GestureDetector|InkWell)\s*\(');

/// Child widgets that carry NO readable text on their own → icon-only.
final _iconChildPattern = RegExp(
    r'^(Icon|ImageIcon|SvgPicture|LucideIcons|Atlas|BrandIcons|BrandIconColors)\b');

List<_Offender> _scanFile(String path, String source) {
  final out = <_Offender>[];
  // Normalise the path for display (forward slashes, repo-relative).
  final displayPath = path.replaceAll('\\', '/');

  // --- Hollow custom controls: an icon-only one MUST carry a semanticLabel. ---
  for (final m in _ctorPattern.allMatches(source)) {
    final ctorName = m.group(1)!;
    final openParen = m.end - 1; // index of '('
    final span = _balancedSpan(source, openParen);
    if (span == null) continue; // unbalanced / truncated — skip defensively
    final args = source.substring(openParen + 1, span);

    if (_optedOut(source, m.start, args)) continue;

    // Already labelled at this call's top level? Then it's fine.
    if (RegExp(r'\bsemantic[s]?Label\s*:').hasMatch(args)) continue;

    final childExpr = _directChildExpr(args);
    if (childExpr == null) continue; // no direct child (e.g. uses `children:`)
    if (_containsText(childExpr)) continue; // auto-named by its text

    final trimmed = childExpr.trimLeft();
    if (_iconChildPattern.hasMatch(trimmed)) {
      final line = _lineNumberOf(source, m.start);
      out.add(_Offender('$displayPath:$line', ctorName, _firstLine(trimmed)));
    }
  }

  // --- Raw GestureDetector / InkWell: icon-only tappable, not Semantics-wrapped. ---
  for (final m in _rawTapPattern.allMatches(source)) {
    final widget = m.group(1)!;
    final openParen = m.end - 1;
    final span = _balancedSpan(source, openParen);
    if (span == null) continue;
    final args = source.substring(openParen + 1, span);

    if (_optedOut(source, m.start, args)) continue;

    // Must actually be a tap target (has onTap:). Drag/pan-only surfaces are
    // not buttons and aren't expected to carry a label.
    if (!RegExp(r'\bonTap\s*:').hasMatch(args)) continue;

    // Already labelled somewhere in this subtree — including the icon's own
    // `Icon(..., semanticLabel: ...)` property, which is a valid way to name
    // it. (The custom-control loop applies the same check on its own args.)
    if (RegExp(r'\bsemantic[s]?Label\s*:').hasMatch(args)) continue;

    final childExpr = _directChildExpr(args);
    if (childExpr == null) continue;
    if (_containsText(childExpr)) continue;

    final trimmed = childExpr.trimLeft();
    if (!_iconChildPattern.hasMatch(trimmed)) continue;

    // If a `Semantics(` encloses this widget, the label/role lives there — the
    // standard pattern for wrapping a raw GestureDetector. Not an offender.
    if (_enclosedBySemantics(source, m.start)) continue;

    final line = _lineNumberOf(source, m.start);
    out.add(_Offender('$displayPath:$line', widget, _firstLine(trimmed)));
  }

  return out;
}

/// True if an `// a11y-ignore` opt-out is on the construct's own line or
/// anywhere inside its argument span.
bool _optedOut(String source, int ctorStart, String args) =>
    args.contains('a11y-ignore') ||
    _lineOf(source, ctorStart).contains('a11y-ignore');

/// Whether the construct at [pos] is lexically enclosed by a `Semantics(` call
/// (i.e. some `Semantics(` opens before [pos] and its balanced span extends
/// past [pos]). This is how a raw GestureDetector legitimately gets its
/// label/role — by being wrapped, not by carrying a semanticLabel arg itself.
bool _enclosedBySemantics(String source, int pos) {
  for (final s in RegExp(r'\bSemantics\s*\(').allMatches(source)) {
    final open = s.end - 1;
    if (open >= pos) break; // Semantics opens after us — can't enclose.
    final end = _balancedSpan(source, open);
    if (end != null && end > pos) return true;
  }
  return false;
}

/// Returns the index of the `)` that closes the `(` at [openParen], skipping
/// nested brackets, string literals, and comments. Null if unbalanced.
int? _balancedSpan(String s, int openParen) {
  var depth = 0;
  var i = openParen;
  final n = s.length;
  while (i < n) {
    final c = s[i];
    // Skip string literals (single/double, including simple escapes).
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    // Skip line comments.
    if (c == '/' && i + 1 < n && s[i + 1] == '/') {
      while (i < n && s[i] != '\n') {
        i++;
      }
      continue;
    }
    // Skip block comments.
    if (c == '/' && i + 1 < n && s[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(s[i] == '*' && s[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return null;
}

/// Advances past a string literal starting at [start]. Handles escapes and
/// triple-quoted strings minimally. Returns index just AFTER the closing quote.
int _skipString(String s, int start) {
  final quote = s[start];
  final n = s.length;
  // Triple-quoted?
  if (start + 2 < n && s[start + 1] == quote && s[start + 2] == quote) {
    var i = start + 3;
    while (i + 2 < n &&
        !(s[i] == quote && s[i + 1] == quote && s[i + 2] == quote)) {
      i++;
    }
    return i + 3;
  }
  var i = start + 1;
  while (i < n) {
    if (s[i] == r'\') {
      i += 2;
      continue;
    }
    if (s[i] == quote) return i + 1;
    if (s[i] == '\n') return i + 1; // unterminated — bail to next line
    i++;
  }
  return n;
}

/// Extracts the value expression of the TOP-LEVEL `child:` argument inside an
/// argument-span string [args]. Returns null if there is no direct `child:`.
String? _directChildExpr(String args) {
  // Walk the top level (depth 0) looking for the `child:` label.
  final n = args.length;
  var i = 0;
  while (i < n) {
    final c = args[i];
    if (c == "'" || c == '"') {
      i = _skipString(args, i);
      continue;
    }
    if (c == '/' && i + 1 < n && args[i + 1] == '/') {
      while (i < n && args[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && args[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(args[i] == '*' && args[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      i = (_balancedSpan(args, i) ?? n) + 1;
      continue;
    }
    // At depth 0, try to match `child:`.
    if (args.startsWith('child:', i) &&
        (i == 0 || !_isIdentChar(args[i - 1]))) {
      final valStart = i + 'child:'.length;
      return _readArgValue(args, valStart);
    }
    i++;
  }
  return null;
}

/// Reads one argument value starting at [start] until the top-level comma or
/// end of the span. Skips nested brackets/strings.
String _readArgValue(String s, int start) {
  final n = s.length;
  var i = start;
  // Skip leading whitespace.
  while (i < n && (s[i] == ' ' || s[i] == '\n' || s[i] == '\t' || s[i] == '\r')) {
    i++;
  }
  final valStart = i;
  while (i < n) {
    final c = s[i];
    if (c == "'" || c == '"') {
      i = _skipString(s, i);
      continue;
    }
    if (c == '(' || c == '[' || c == '{') {
      i = (_balancedSpan(s, i) ?? n) + 1;
      continue;
    }
    if (c == ',') break;
    i++;
  }
  return s.substring(valStart, i);
}

/// Whether [expr] (a child value expression) contains a Text widget anywhere —
/// meaning the control is auto-named and should not be flagged.
bool _containsText(String expr) {
  return RegExp(r'\bText\s*\(').hasMatch(expr) ||
      RegExp(r'\bRichText\s*\(').hasMatch(expr) ||
      RegExp(r'\bSelectableText\s*\(').hasMatch(expr) ||
      // A child that is itself another custom widget may carry its own text /
      // semantics we can't see here; be conservative and don't flag those.
      RegExp(r'\bText\.rich\s*\(').hasMatch(expr);
}

bool _isIdentChar(String c) => RegExp(r'[A-Za-z0-9_$]').hasMatch(c);

String _firstLine(String s) {
  final nl = s.indexOf('\n');
  final line = (nl == -1 ? s : s.substring(0, nl)).trim();
  return line.length > 60 ? '${line.substring(0, 57)}...' : line;
}

String _lineOf(String s, int index) {
  final start = s.lastIndexOf('\n', index) + 1;
  var end = s.indexOf('\n', index);
  if (end == -1) end = s.length;
  return s.substring(start, end);
}

int _lineNumberOf(String s, int index) {
  var line = 1;
  for (var i = 0; i < index && i < s.length; i++) {
    if (s[i] == '\n') line++;
  }
  return line;
}
