import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:url_launcher/url_launcher.dart';

/// Parses message text with lightweight markup into styled spans.
///
/// Supported:
/// - **bold** or __bold__
/// - *italic* or _italic_
/// - ~~strikethrough~~
/// - `inline code`
/// - ```code blocks``` (multi-line)
/// - ||spoiler|| (tap to reveal)
/// - http(s):// and hollow:// URLs — clickable, accent-colored, underlined
///
/// URL matching happens BEFORE marker parsing so that URLs containing
/// underscores or asterisks (e.g. `https://en.wikipedia.org/wiki/Rick_Astley`)
/// don't get mis-parsed as italic/bold markers.
///
/// No headings, images, or HTML.

final _inlineUrlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');

class MessageText extends StatelessWidget {
  final String text;
  final TextStyle? baseStyle;
  final List<InlineSpan>? suffixSpans;
  final Set<String>? memberNames;

  const MessageText(
    this.text, {
    super.key,
    this.baseStyle,
    this.suffixSpans,
    this.memberNames,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style = baseStyle ??
        HollowTypography.body.copyWith(color: hollow.textPrimary);

    final codeBlockPattern = RegExp(r'```(\w*)\n?([\s\S]*?)```');
    if (codeBlockPattern.hasMatch(text)) {
      return _buildWithCodeBlocks(
          text, codeBlockPattern, style, hollow, suffixSpans);
    }

    final spans = _parseInline(text, style, hollow, memberNames: memberNames);
    if (suffixSpans != null) spans.addAll(suffixSpans!);
    return Text.rich(TextSpan(children: spans));
  }

  Widget _buildWithCodeBlocks(
    String text,
    RegExp pattern,
    TextStyle style,
    HollowTheme hollow,
    List<InlineSpan>? suffixSpans,
  ) {
    final children = <Widget>[];
    int lastEnd = 0;

    for (final match in pattern.allMatches(text)) {
      if (match.start > lastEnd) {
        final before = text.substring(lastEnd, match.start).trimRight();
        if (before.isNotEmpty) {
          children.add(Text.rich(
            TextSpan(children: _parseInline(before, style, hollow)),
          ));
        }
      }

      final code = match.group(2) ?? '';
      children.add(Container(
        width: double.infinity,
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: hollow.background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: hollow.border),
        ),
        child: Text(
          code.endsWith('\n') ? code.substring(0, code.length - 1) : code,
          style: HollowTypography.mono.copyWith(
            color: hollow.textPrimary,
            fontSize: 13,
          ),
        ),
      ));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      final after = text.substring(lastEnd).trimLeft();
      if (after.isNotEmpty) {
        final spans = _parseInline(after, style, hollow);
        if (suffixSpans != null) spans.addAll(suffixSpans);
        children.add(Text.rich(TextSpan(children: spans)));
        suffixSpans = null;
      }
    }

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
}

Widget buildMessageText(
  String text,
  BuildContext context, {
  TextStyle? baseStyle,
  List<InlineSpan>? suffixSpans,
  Set<String>? memberNames,
}) {
  return MessageText(text, baseStyle: baseStyle, suffixSpans: suffixSpans, memberNames: memberNames);
}

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

List<InlineSpan> _parseInline(
  String text,
  TextStyle style,
  HollowTheme hollow, {
  int depth = 0,
  Set<String>? memberNames,
}) {
  if (depth > 10) {
    return [TextSpan(text: text, style: style)];
  }
  final spans = <InlineSpan>[];
  final buffer = StringBuffer();

  int i = 0;
  while (i < text.length) {
    if ((text[i] == 'h' || text[i] == 'H') &&
        _looksLikeUrlStart(text, i)) {
      final match = _inlineUrlRegex.matchAsPrefix(text, i);
      if (match != null) {
        _flushBuffer(buffer, spans, style);
        final url = match.group(0)!;
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => _openUrl(url),
              child: Text(
                url,
                style: style.copyWith(
                  color: hollow.accent,
                  decoration: TextDecoration.underline,
                  decorationColor: hollow.accent,
                ),
              ),
            ),
          ),
        ));
        i = match.end;
        continue;
      }
    }

    // @mention — @everyone or @displayName (longest-match against memberNames)
    if (text[i] == '@') {
      final rest = text.substring(i + 1);
      String? matched;
      if (rest.startsWith('everyone')) {
        matched = 'everyone';
      } else if (memberNames != null) {
        for (final name in memberNames) {
          if (rest.startsWith(name) &&
              (matched == null || name.length > matched.length)) {
            matched = name;
          }
        }
      }
      if (matched != null) {
        _flushBuffer(buffer, spans, style);
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: hollow.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              '@$matched',
              style: style.copyWith(
                color: hollow.accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ));
        i += 1 + matched.length;
        continue;
      }
    }

    // ** bold **
    if (i + 1 < text.length && text[i] == '*' && text[i + 1] == '*') {
      final end = text.indexOf('**', i + 2);
      if (end != -1) {
        _flushBuffer(buffer, spans, style);
        final inner = text.substring(i + 2, end);
        spans.addAll(_parseInline(
          inner,
          style.copyWith(fontWeight: FontWeight.w700),
          hollow,
          depth: depth + 1,
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
          hollow,
          depth: depth + 1,
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
          child: _SpoilerText(text: inner, style: style, hollow: hollow),
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
              color: hollow.background,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: hollow.border),
            ),
            child: Text(
              code,
              style: HollowTypography.mono.copyWith(
                color: hollow.textPrimary,
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
    if (text[i] == '*' && (i + 1 >= text.length || text[i + 1] != '*')) {
      final end = _findClosing(text, '*', i + 1);
      if (end != -1) {
        _flushBuffer(buffer, spans, style);
        final inner = text.substring(i + 1, end);
        spans.addAll(_parseInline(
          inner,
          style.copyWith(fontStyle: FontStyle.italic),
          hollow,
          depth: depth + 1,
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
          hollow,
          depth: depth + 1,
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

bool _looksLikeUrlStart(String text, int start) {
  if (start + 7 > text.length) return false;
  final c1 = text[start];
  if (c1 != 'h' && c1 != 'H') return false;
  final lower = text.substring(start, (start + 9).clamp(0, text.length))
      .toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('hollow://');
}

int _findClosing(String text, String marker, int from) {
  if (from >= text.length) return -1;
  final idx = text.indexOf(marker, from);
  if (idx == from) return -1;
  return idx;
}

void _flushBuffer(
    StringBuffer buffer, List<InlineSpan> spans, TextStyle style) {
  if (buffer.isNotEmpty) {
    spans.add(TextSpan(text: buffer.toString(), style: style));
    buffer.clear();
  }
}

class _SpoilerText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final HollowTheme hollow;

  const _SpoilerText({
    required this.text,
    required this.style,
    required this.hollow,
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
              ? widget.hollow.elevated
              : widget.hollow.textSecondary,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          widget.text,
          style: widget.style.copyWith(
            color: _revealed
                ? widget.hollow.textPrimary
                : Colors.transparent,
          ),
        ),
      ),
    );
  }
}
