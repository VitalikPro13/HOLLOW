import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';

/// Parses message text with lightweight markup into styled spans.
///
/// Supported:
/// - **bold** or __bold__
/// - *italic* or _italic_
/// - ~~strikethrough~~
/// - `inline code`
/// - ```code blocks``` (multi-line)
/// - ||spoiler|| (tap to reveal)
///
/// No headings, images, links, or HTML.

/// Parse message text and return a widget. Uses Text.rich for inline
/// formatting, but returns a Column when code blocks are present
/// (since code blocks need their own Container).
///
/// [suffixSpans] are appended after the parsed text (e.g., "(edited)" indicator).
Widget buildMessageText(
  String text,
  BuildContext context, {
  TextStyle? baseStyle,
  List<InlineSpan>? suffixSpans,
}) {
  final haven = HavenTheme.of(context);
  final style = baseStyle ??
      HavenTypography.body.copyWith(color: haven.textPrimary);

  // Check for code blocks first — they split the message into segments.
  final codeBlockPattern = RegExp(r'```(\w*)\n?([\s\S]*?)```');
  if (codeBlockPattern.hasMatch(text)) {
    return _buildWithCodeBlocks(
        text, codeBlockPattern, style, haven, suffixSpans);
  }

  // No code blocks — pure inline parsing.
  final spans = _parseInline(text, style, haven);
  if (suffixSpans != null) spans.addAll(suffixSpans);
  return Text.rich(TextSpan(children: spans));
}

/// Builds a Column with alternating text and code block widgets.
Widget _buildWithCodeBlocks(
  String text,
  RegExp pattern,
  TextStyle style,
  HavenTheme haven,
  List<InlineSpan>? suffixSpans,
) {
  final children = <Widget>[];
  int lastEnd = 0;

  for (final match in pattern.allMatches(text)) {
    // Text before the code block.
    if (match.start > lastEnd) {
      final before = text.substring(lastEnd, match.start).trimRight();
      if (before.isNotEmpty) {
        children.add(Text.rich(
          TextSpan(children: _parseInline(before, style, haven)),
        ));
      }
    }

    // The code block itself.
    final code = match.group(2) ?? '';
    children.add(Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: haven.background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: haven.border),
      ),
      child: Text(
        code.endsWith('\n') ? code.substring(0, code.length - 1) : code,
        style: HavenTypography.mono.copyWith(
          color: haven.textPrimary,
          fontSize: 13,
        ),
      ),
    ));

    lastEnd = match.end;
  }

  // Text after the last code block.
  if (lastEnd < text.length) {
    final after = text.substring(lastEnd).trimLeft();
    if (after.isNotEmpty) {
      final spans = _parseInline(after, style, haven);
      if (suffixSpans != null) spans.addAll(suffixSpans);
      children.add(Text.rich(TextSpan(children: spans)));
      suffixSpans = null; // Already appended.
    }
  }

  // If suffix wasn't appended yet (message ends with code block), add it.
  if (suffixSpans != null && suffixSpans.isNotEmpty) {
    children.add(Text.rich(TextSpan(children: suffixSpans)));
  }

  if (children.length == 1) return children.first;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: children,
  );
}

/// Parse inline formatting markers into a list of InlineSpans.
List<InlineSpan> _parseInline(String text, TextStyle style, HavenTheme haven) {
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  int i = 0;
  while (i < text.length) {
    // ** bold **
    if (i + 1 < text.length && text[i] == '*' && text[i + 1] == '*') {
      final end = text.indexOf('**', i + 2);
      if (end != -1) {
        _flushBuffer(buffer, spans, style);
        final inner = text.substring(i + 2, end);
        spans.addAll(_parseInline(
          inner,
          style.copyWith(fontWeight: FontWeight.w700),
          haven,
        ));
        i = end + 2;
        continue;
      }
    }

    // ~~ strikethrough ~~
    if (i + 1 < text.length && text[i] == '~' && text[i + 1] == '~') {
      final end = text.indexOf('~~', i + 2);
      if (end != -1) {
        _flushBuffer(buffer, spans, style);
        final inner = text.substring(i + 2, end);
        spans.addAll(_parseInline(
          inner,
          style.copyWith(decoration: TextDecoration.lineThrough),
          haven,
        ));
        i = end + 2;
        continue;
      }
    }

    // || spoiler ||
    if (i + 1 < text.length && text[i] == '|' && text[i + 1] == '|') {
      final end = text.indexOf('||', i + 2);
      if (end != -1) {
        _flushBuffer(buffer, spans, style);
        final inner = text.substring(i + 2, end);
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _SpoilerText(text: inner, style: style, haven: haven),
        ));
        i = end + 2;
        continue;
      }
    }

    // ` inline code `
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      if (end != -1) {
        _flushBuffer(buffer, spans, style);
        final code = text.substring(i + 1, end);
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: haven.background,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: haven.border),
            ),
            child: Text(
              code,
              style: HavenTypography.mono.copyWith(
                color: haven.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
        ));
        i = end + 1;
        continue;
      }
    }

    // * italic * or _ italic _
    // Only match single * not followed by *, and _ not between word chars.
    if (text[i] == '*' && (i + 1 >= text.length || text[i + 1] != '*')) {
      final end = _findClosing(text, '*', i + 1);
      if (end != -1) {
        _flushBuffer(buffer, spans, style);
        final inner = text.substring(i + 1, end);
        spans.addAll(_parseInline(
          inner,
          style.copyWith(fontStyle: FontStyle.italic),
          haven,
        ));
        i = end + 1;
        continue;
      }
    }

    if (text[i] == '_' &&
        (i + 1 >= text.length || text[i + 1] != '_') &&
        (i == 0 || text[i - 1] == ' ')) {
      final end = _findClosing(text, '_', i + 1);
      if (end != -1 && (end + 1 >= text.length || text[end + 1] == ' ')) {
        _flushBuffer(buffer, spans, style);
        final inner = text.substring(i + 1, end);
        spans.addAll(_parseInline(
          inner,
          style.copyWith(fontStyle: FontStyle.italic),
          haven,
        ));
        i = end + 1;
        continue;
      }
    }

    buffer.write(text[i]);
    i++;
  }

  _flushBuffer(buffer, spans, style);
  return spans;
}

/// Find closing marker, ensuring it's not escaped or empty.
int _findClosing(String text, String marker, int from) {
  if (from >= text.length) return -1;
  final idx = text.indexOf(marker, from);
  if (idx == from) return -1; // Empty content.
  return idx;
}

/// Flush any accumulated plain text from the buffer into spans.
void _flushBuffer(
    StringBuffer buffer, List<InlineSpan> spans, TextStyle style) {
  if (buffer.isNotEmpty) {
    spans.add(TextSpan(text: buffer.toString(), style: style));
    buffer.clear();
  }
}

/// Spoiler text — shows as blurred/hidden until tapped.
class _SpoilerText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final HavenTheme haven;

  const _SpoilerText({
    required this.text,
    required this.style,
    required this.haven,
  });

  @override
  State<_SpoilerText> createState() => _SpoilerTextState();
}

class _SpoilerTextState extends State<_SpoilerText> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _revealed = !_revealed),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
        decoration: BoxDecoration(
          color: _revealed
              ? widget.haven.elevated
              : widget.haven.textSecondary,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          widget.text,
          style: widget.style.copyWith(
            color: _revealed
                ? widget.haven.textPrimary
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}
