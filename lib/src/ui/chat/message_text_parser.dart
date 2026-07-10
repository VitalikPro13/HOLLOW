import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
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

// ---------------------------------------------------------------------------
// Static compiled regexes (avoid re-creation per build)
// ---------------------------------------------------------------------------

final _inlineUrlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');
final _codeBlockPattern = RegExp(r'```(\w*)\n?([\s\S]*?)```');

// ---------------------------------------------------------------------------
// Intermediate token representation — safe to cache (no widgets / closures)
// ---------------------------------------------------------------------------

enum _TokenKind {
  plain,
  bold,
  italic,
  strikethrough,
  code,
  codeBlock,
  spoiler,
  url,
  mention,
  customEmote,
}

class _Token {
  final _TokenKind kind;
  final String text;
  final List<_Token>? children; // for nested markup (bold > italic, etc.)
  final String? extra; // customEmote: the content hash

  const _Token(this.kind, this.text, [this.children, this.extra]);
}

// ---------------------------------------------------------------------------
// LRU token cache — avoids re-parsing identical message text every rebuild
// ---------------------------------------------------------------------------

const _cacheMaxSize = 200;

/// Cache key: combines the raw text with the memberNames hash so that the
/// same message rendered in two different servers (different member lists)
/// gets separate entries.
final _tokenCache = <int, List<_Token>>{};

int _cacheKey(String text, Set<String>? memberNames) {
  // Use a quick hash combining text identity + memberNames content.
  var h = text.hashCode;
  if (memberNames != null && memberNames.isNotEmpty) {
    // Sort-independent: XOR of individual hashes.
    var mh = memberNames.length;
    for (final n in memberNames) {
      mh ^= n.hashCode;
    }
    h = h ^ (mh * 0x9e3779b9);
  }
  return h;
}

List<_Token> _cachedTokenize(String text, {Set<String>? memberNames}) {
  final key = _cacheKey(text, memberNames);
  final existing = _tokenCache[key];
  if (existing != null) {
    // Move to end (most-recently-used).
    _tokenCache.remove(key);
    _tokenCache[key] = existing;
    return existing;
  }
  final tokens = _tokenize(text, memberNames: memberNames);
  _tokenCache[key] = tokens;
  if (_tokenCache.length > _cacheMaxSize) {
    _tokenCache.remove(_tokenCache.keys.first); // evict LRU
  }
  return tokens;
}

// ---------------------------------------------------------------------------
// Tokenizer — pure string parsing, produces _Token tree
// ---------------------------------------------------------------------------

List<_Token> _tokenize(
  String text, {
  int depth = 0,
  Set<String>? memberNames,
}) {
  if (depth > 10) {
    return [_Token(_TokenKind.plain, text)];
  }
  final tokens = <_Token>[];
  final buffer = StringBuffer();

  void flushBuffer() {
    if (buffer.isNotEmpty) {
      tokens.add(_Token(_TokenKind.plain, buffer.toString()));
      buffer.clear();
    }
  }

  int i = 0;
  while (i < text.length) {
    // --- URL ---
    if ((text[i] == 'h' || text[i] == 'H') && _looksLikeUrlStart(text, i)) {
      final match = _inlineUrlRegex.matchAsPrefix(text, i);
      if (match != null) {
        flushBuffer();
        tokens.add(_Token(_TokenKind.url, match.group(0)!));
        i = match.end;
        continue;
      }
    }

    // --- [e:name:hash] custom emote ---
    if (text[i] == '[') {
      final match = emoteTokenRegex.matchAsPrefix(text, i);
      if (match != null) {
        flushBuffer();
        tokens.add(_Token(
          _TokenKind.customEmote,
          match.group(1)!,
          null,
          match.group(2)!,
        ));
        i = match.end;
        continue;
      }
    }

    // --- @mention ---
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
        flushBuffer();
        tokens.add(_Token(_TokenKind.mention, matched));
        i += 1 + matched.length;
        continue;
      }
    }

    // --- **bold** ---
    if (i + 1 < text.length && text[i] == '*' && text[i + 1] == '*') {
      final end = text.indexOf('**', i + 2);
      if (end != -1) {
        flushBuffer();
        final inner = text.substring(i + 2, end);
        tokens.add(_Token(
          _TokenKind.bold,
          inner,
          _tokenize(inner, depth: depth + 1),
        ));
        i = end + 2;
        continue;
      }
    }

    // --- ~~strikethrough~~ ---
    if (i + 1 < text.length && text[i] == '~' && text[i + 1] == '~') {
      final end = text.indexOf('~~', i + 2);
      if (end != -1) {
        flushBuffer();
        final inner = text.substring(i + 2, end);
        tokens.add(_Token(
          _TokenKind.strikethrough,
          inner,
          _tokenize(inner, depth: depth + 1),
        ));
        i = end + 2;
        continue;
      }
    }

    // --- ||spoiler|| ---
    if (i + 1 < text.length && text[i] == '|' && text[i + 1] == '|') {
      final end = text.indexOf('||', i + 2);
      if (end != -1) {
        flushBuffer();
        tokens.add(_Token(_TokenKind.spoiler, text.substring(i + 2, end)));
        i = end + 2;
        continue;
      }
    }

    // --- `inline code` ---
    if (text[i] == '`') {
      final end = text.indexOf('`', i + 1);
      if (end != -1) {
        flushBuffer();
        tokens.add(_Token(_TokenKind.code, text.substring(i + 1, end)));
        i = end + 1;
        continue;
      }
    }

    // --- *italic* ---
    if (text[i] == '*' && (i + 1 >= text.length || text[i + 1] != '*')) {
      final end = _findClosing(text, '*', i + 1);
      if (end != -1) {
        flushBuffer();
        final inner = text.substring(i + 1, end);
        tokens.add(_Token(
          _TokenKind.italic,
          inner,
          _tokenize(inner, depth: depth + 1),
        ));
        i = end + 1;
        continue;
      }
    }

    // --- _italic_ (word-boundary) ---
    if (text[i] == '_' &&
        (i + 1 >= text.length || text[i + 1] != '_') &&
        (i == 0 || text[i - 1] == ' ')) {
      final end = _findClosing(text, '_', i + 1);
      if (end != -1 && (end + 1 >= text.length || text[end + 1] == ' ')) {
        flushBuffer();
        final inner = text.substring(i + 1, end);
        tokens.add(_Token(
          _TokenKind.italic,
          inner,
          _tokenize(inner, depth: depth + 1),
        ));
        i = end + 1;
        continue;
      }
    }

    buffer.write(text[i]);
    i++;
  }

  flushBuffer();
  return tokens;
}

// ---------------------------------------------------------------------------
// Token → Widget span conversion (cheap, uses live theme + callbacks)
// ---------------------------------------------------------------------------

List<InlineSpan> _tokensToSpans(
  List<_Token> tokens,
  TextStyle style,
  HollowTheme hollow,
) {
  final spans = <InlineSpan>[];
  for (final tok in tokens) {
    switch (tok.kind) {
      case _TokenKind.plain:
        spans.add(TextSpan(text: tok.text, style: style));
      case _TokenKind.url:
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Semantics(
            link: true,
            label: tok.text,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: () => _openUrl(tok.text),
                child: Text(
                  tok.text,
                  style: style.copyWith(
                    color: hollow.accentText,
                    decoration: TextDecoration.underline,
                    decorationColor: hollow.accentText,
                  ),
                ),
              ),
            ),
          ),
        ));
      case _TokenKind.mention:
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Semantics(
            label: '@${tok.text}',
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: hollow.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '@${tok.text}',
                style: style.copyWith(
                  color: hollow.accentText,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ));
      case _TokenKind.bold:
        spans.addAll(_tokensToSpans(
          tok.children!,
          style.copyWith(fontWeight: FontWeight.w700),
          hollow,
        ));
      case _TokenKind.italic:
        spans.addAll(_tokensToSpans(
          tok.children!,
          style.copyWith(fontStyle: FontStyle.italic),
          hollow,
        ));
      case _TokenKind.strikethrough:
        spans.addAll(_tokensToSpans(
          tok.children!,
          style.copyWith(decoration: TextDecoration.lineThrough),
          hollow,
        ));
      case _TokenKind.spoiler:
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: _SpoilerText(text: tok.text, style: style, hollow: hollow),
        ));
      case _TokenKind.customEmote:
        spans.add(WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: EmoteImage(
            name: tok.text,
            hash: tok.extra!,
            size: (style.fontSize ?? 15) * 1.45,
            fallbackStyle: style,
          ),
        ));
      case _TokenKind.code:
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
              tok.text,
              style: HollowTypography.mono.copyWith(
                color: hollow.textPrimary,
                fontSize: 13,
              ),
            ),
          ),
        ));
      case _TokenKind.codeBlock:
        break; // handled at widget level, not inline
    }
  }
  return spans;
}

// ---------------------------------------------------------------------------
// Public widgets
// ---------------------------------------------------------------------------

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

    if (_codeBlockPattern.hasMatch(text)) {
      return _buildWithCodeBlocks(text, style, hollow, suffixSpans);
    }

    final tokens = _cachedTokenize(text, memberNames: memberNames);
    final spans = _tokensToSpans(tokens, style, hollow);
    if (suffixSpans != null) spans.addAll(suffixSpans!);
    return Text.rich(TextSpan(children: spans));
  }

  Widget _buildWithCodeBlocks(
    String text,
    TextStyle style,
    HollowTheme hollow,
    List<InlineSpan>? suffixSpans,
  ) {
    final children = <Widget>[];
    int lastEnd = 0;

    for (final match in _codeBlockPattern.allMatches(text)) {
      if (match.start > lastEnd) {
        final before = text.substring(lastEnd, match.start).trimRight();
        if (before.isNotEmpty) {
          final tokens = _cachedTokenize(before);
          children.add(Text.rich(
            TextSpan(children: _tokensToSpans(tokens, style, hollow)),
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
        final tokens = _cachedTokenize(after);
        final spans = _tokensToSpans(tokens, style, hollow);
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

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
    return Semantics(
      button: true,
      label: _revealed ? 'Hide spoiler' : 'Reveal spoiler',
      child: GestureDetector(
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
      ),
    );
  }
}
