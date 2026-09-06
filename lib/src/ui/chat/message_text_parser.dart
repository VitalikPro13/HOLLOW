import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:url_launcher/url_launcher.dart';

/// Parses message text with lightweight markup (bold, italic, strikethrough,
/// inline code, code blocks, spoilers, mentions, links) into styled spans. No
/// headings, images or HTML.
///
/// URLs match BEFORE markers, so a URL carrying `_` or `*` is not mis-parsed as
/// italic or bold.

final _inlineUrlRegex = RegExp(r'(?:https?|hollow)://[^\s<>"' "'" r')\]}]+');
final _codeBlockPattern = RegExp(r'```(\w*)\n?([\s\S]*?)```');

// Safe to cache: no widgets and no closures.

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
  asset,
}

class _Token {
  final _TokenKind kind;
  final String text;
  final List<_Token>? children;
  final String? extra; // customEmote: the content hash

  /// asset: the token already starts or ends its own line, so the block render
  /// needs no synthetic break on that side. Always true for other kinds.
  final bool atLineStart;
  final bool atLineEnd;

  const _Token(this.kind, this.text,
      [this.children, this.extra, this.atLineStart = true, this.atLineEnd = true]);
}

// LRU cache, so identical message text is not re-parsed every rebuild.

const _cacheMaxSize = 200;

/// Keyed on the text plus the memberNames hash, so the same message in two
/// servers with different member lists gets separate entries.
final _tokenCache = <int, List<_Token>>{};

int _cacheKey(String text, Set<String>? memberNames) {
  var h = text.hashCode;
  if (memberNames != null && memberNames.isNotEmpty) {
    // Sort-independent, so member order cannot change the key.
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

/// One successfully matched token plus the index just past its markup.
class _TokenMatch {
  final _Token token;
  final int end;

  const _TokenMatch(this.token, this.end);
}

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
    final match = _matchTokenAt(text, i, depth, memberNames);
    if (match != null) {
      flushBuffer();
      tokens.add(match.token);
      i = match.end;
      continue;
    }

    buffer.write(text[i]);
    i++;
  }

  flushBuffer();
  return tokens;
}

/// Tries each token grammar at position [i], in the original priority order.
_TokenMatch? _matchTokenAt(
  String text,
  int i,
  int depth,
  Set<String>? memberNames,
) {
  return _matchUrl(text, i) ??
      _matchCustomEmote(text, i) ??
      _matchAssetToken(text, i) ??
      _matchMention(text, i, memberNames) ??
      _matchDoubleMarker(text, i, '**', _TokenKind.bold, depth) ??
      _matchDoubleMarker(text, i, '~~', _TokenKind.strikethrough, depth) ??
      _matchSpoiler(text, i) ??
      _matchInlineCode(text, i) ??
      _matchStarItalic(text, i, depth) ??
      _matchUnderscoreItalic(text, i, depth);
}

_TokenMatch? _matchUrl(String text, int i) {
  if ((text[i] == 'h' || text[i] == 'H') && _looksLikeUrlStart(text, i)) {
    final match = _inlineUrlRegex.matchAsPrefix(text, i);
    if (match != null) {
      return _TokenMatch(_Token(_TokenKind.url, match.group(0)!), match.end);
    }
  }
  return null;
}

// Token form: [e:name:hash].
_TokenMatch? _matchCustomEmote(String text, int i) {
  if (text[i] == '[') {
    final match = emoteTokenRegex.matchAsPrefix(text, i);
    if (match != null) {
      return _TokenMatch(
        _Token(
          _TokenKind.customEmote,
          match.group(1)!,
          null,
          match.group(2)!,
        ),
        match.end,
      );
    }
  }
  return null;
}

/// `[a:kind:hash:w:h]`, the sticker/GIF token. ALWAYS renders as a block at the
/// chat media box, so text sharing the line becomes a caption above or below it
/// rather than shrinking the media. A token with out-of-bound dims fails
/// [parseAssetToken] and falls through to plain text, as an old client renders
/// it.
///
/// One block asset per message (issue #36): each token is its own full-size
/// block, never a shared-height run. Mosaics live on VERTICALLY, across
/// consecutive sticker-only messages ([isStickerOnlyMessage] +
/// `stickerTilingFor`).
_TokenMatch? _matchAssetToken(String text, int i) {
  if (text[i] != '[') return null;
  final match = assetTokenRegex.matchAsPrefix(text, i);
  if (match == null) return null;
  if (parseAssetToken(match.group(0)!) == null) return null;

  final end = match.end;
  var before = i;
  while (before > 0 && _isHSpace(text[before - 1])) {
    before--;
  }
  var after = end;
  while (after < text.length && _isHSpace(text[after])) {
    after++;
  }
  return _TokenMatch(
    _Token(
      _TokenKind.asset,
      text.substring(i, end),
      null,
      null,
      before == 0 || text[before - 1] == '\n',
      after == text.length || text[after] == '\n',
    ),
    end,
  );
}

/// Every well-formed asset token in [source], in order.
List<ChatAsset> parseAssetTokens(String source) {
  final out = <ChatAsset>[];
  for (final m in assetTokenRegex.allMatches(source)) {
    final a = parseAssetToken(m.group(0)!);
    if (a != null) out.add(a);
  }
  return out;
}

/// How many well-formed BLOCK ASSET tokens [source] carries, stickers and GIFs
/// together, since the send guard caps their combined count at one (issue #36).
/// Count over the EXPANDED wire text, so a hand-pasted token is caught too.
int countBlockAssetTokens(String source) => parseAssetTokens(source).length;

/// The block assets of a message that is NOTHING BUT block assets, or null when
/// real text sits alongside them.
///
/// The render fast-path, and what makes a vertical mosaic seamless: `Text.rich`
/// gives the line holding a WidgetSpan the font's own ascent and descent, so
/// two tiled messages land a hairline apart however much padding is zeroed.
/// Broader than [isStickerOnlyMessage], which decides TILING and excludes GIFs.
List<ChatAsset>? blockAssetsOnlyMessage(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final assets = parseAssetTokens(trimmed);
  if (assets.isEmpty) return null;
  if (trimmed.replaceAll(assetTokenRegex, '').trim().isNotEmpty) return null;
  return assets;
}

/// Whether [text] is nothing but stickers, the condition for tiling this
/// message into its neighbours. Shared by both chat panes and the mobile route
/// so their grouping rules cannot drift.
bool isStickerOnlyMessage(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  final assets = parseAssetTokens(trimmed);
  if (assets.isEmpty || assets.any((a) => a.kind != 's')) return false;
  return trimmed.replaceAll(assetTokenRegex, '').trim().isEmpty;
}

/// Whether the spans built so far already end in a line break, so a block
/// asset does not add a second one and open a blank line.
bool _endsWithNewline(List<InlineSpan> spans) {
  if (spans.isEmpty) return false;
  final last = spans.last;
  return last is TextSpan && (last.text?.endsWith('\n') ?? false);
}

/// Which seams of a block asset are continued by a neighbouring message.
typedef AssetTiling = ({bool top, bool bottom});

const AssetTiling _noTiling = (top: false, bottom: false);

bool _isHSpace(String c) => c == ' ' || c == '\t';

final _leadingHSpaces = RegExp(r'^[ \t]+');

_TokenMatch? _matchMention(String text, int i, Set<String>? memberNames) {
  if (text[i] == '@') {
    final rest = text.substring(i + 1);
    final matched = _longestMentionName(rest, memberNames);
    if (matched != null) {
      return _TokenMatch(
        _Token(_TokenKind.mention, matched),
        i + 1 + matched.length,
      );
    }
  }
  return null;
}

String? _longestMentionName(String rest, Set<String>? memberNames) {
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
  return matched;
}

/// Shared **bold** / ~~strikethrough~~ handling: a two-char [marker] pair whose
/// inner text is recursively tokenized.
_TokenMatch? _matchDoubleMarker(
  String text,
  int i,
  String marker,
  _TokenKind kind,
  int depth,
) {
  if (i + 1 < text.length &&
      text[i] == marker[0] &&
      text[i + 1] == marker[1]) {
    final end = text.indexOf(marker, i + 2);
    if (end != -1) {
      final inner = text.substring(i + 2, end);
      return _TokenMatch(
        _Token(
          kind,
          inner,
          _tokenize(inner, depth: depth + 1),
        ),
        end + 2,
      );
    }
  }
  return null;
}

_TokenMatch? _matchSpoiler(String text, int i) {
  if (i + 1 < text.length && text[i] == '|' && text[i + 1] == '|') {
    final end = text.indexOf('||', i + 2);
    if (end != -1) {
      return _TokenMatch(
        _Token(_TokenKind.spoiler, text.substring(i + 2, end)),
        end + 2,
      );
    }
  }
  return null;
}

_TokenMatch? _matchInlineCode(String text, int i) {
  if (text[i] == '`') {
    final end = text.indexOf('`', i + 1);
    if (end != -1) {
      return _TokenMatch(
        _Token(_TokenKind.code, text.substring(i + 1, end)),
        end + 1,
      );
    }
  }
  return null;
}

_TokenMatch? _matchStarItalic(String text, int i, int depth) {
  if (text[i] == '*' && (i + 1 >= text.length || text[i + 1] != '*')) {
    final end = _findClosing(text, '*', i + 1);
    if (end != -1) {
      final inner = text.substring(i + 1, end);
      return _TokenMatch(
        _Token(
          _TokenKind.italic,
          inner,
          _tokenize(inner, depth: depth + 1),
        ),
        end + 1,
      );
    }
  }
  return null;
}

// Word-boundary only, so snake_case words stay plain.
_TokenMatch? _matchUnderscoreItalic(String text, int i, int depth) {
  if (text[i] == '_' &&
      (i + 1 >= text.length || text[i + 1] != '_') &&
      (i == 0 || text[i - 1] == ' ')) {
    final end = _findClosing(text, '_', i + 1);
    if (end != -1 && (end + 1 >= text.length || text[end + 1] == ' ')) {
      final inner = text.substring(i + 1, end);
      return _TokenMatch(
        _Token(
          _TokenKind.italic,
          inner,
          _tokenize(inner, depth: depth + 1),
        ),
        end + 1,
      );
    }
  }
  return null;
}

/// [scaler] is the ambient text scaler. Plain spans inherit it from the
/// enclosing `Text.rich`, but a [WidgetSpan] is laid out as an opaque box, so a
/// custom emote sized off the raw `style.fontSize` would never grow with the
/// words around it.
List<InlineSpan> _tokensToSpans(
  List<_Token> tokens,
  TextStyle style,
  HollowTheme hollow,
  TextScaler scaler,
  AssetTiling tiling,
) {
  final spans = <InlineSpan>[];
  // Set by a block asset's synthetic trailing newline: the caption that follows
  // must not keep the space that separated it from the token.
  var trimLeadingSpaces = false;
  for (final tok in tokens) {
    final trimNow = trimLeadingSpaces;
    trimLeadingSpaces = false;
    switch (tok.kind) {
      case _TokenKind.plain:
        spans.add(TextSpan(
          text: trimNow ? tok.text.replaceFirst(_leadingHSpaces, '') : tok.text,
          style: style,
        ));
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
          scaler,
          tiling,
        ));
      case _TokenKind.italic:
        spans.addAll(_tokensToSpans(
          tok.children!,
          style.copyWith(fontStyle: FontStyle.italic),
          hollow,
          scaler,
          tiling,
        ));
      case _TokenKind.strikethrough:
        spans.addAll(_tokensToSpans(
          tok.children!,
          style.copyWith(decoration: TextDecoration.lineThrough),
          hollow,
          scaler,
          tiling,
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
            size: scaler.scale(style.fontSize ?? 15) * 1.45,
            fallbackStyle: style,
          ),
        ));
      case _TokenKind.asset:
        final asset = parseAssetToken(tok.text);
        if (asset == null) {
          // Unreachable (the matcher validates); degrade like an old client.
          spans.add(TextSpan(text: tok.text, style: style));
          break;
        }
        // Media follows the interface scale, not the chat TEXT scale, the same
        // rule as avatars and file cards. Padding goes to zero on a side a
        // neighbouring message continues, so the seam survives the boundary.
        final tileTop = tiling.top && tok.atLineStart;
        final tileBottom = tiling.bottom && tok.atLineEnd;
        // Two adjacent block assets each want a break on the side they share,
        // which would open a blank line; only the first is needed.
        if (!tok.atLineStart && !_endsWithNewline(spans)) {
          spans.add(TextSpan(text: '\n', style: style));
        }
        spans.add(WidgetSpan(
          child: Padding(
            padding: EdgeInsets.only(
              top: tileTop ? 0 : 4,
              bottom: tileBottom ? 0 : 4,
            ),
            child: ChatAssetBlock(
              asset: asset,
              tileTop: tileTop,
              tileBottom: tileBottom,
            ),
          ),
        ));
        if (!tok.atLineEnd) {
          spans.add(TextSpan(text: '\n', style: style));
          trimLeadingSpaces = true;
        }
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

class MessageText extends StatelessWidget {
  final String text;
  final TextStyle? baseStyle;
  final List<InlineSpan>? suffixSpans;
  final Set<String>? memberNames;

  /// Seams continued by the previous or next MESSAGE, so the block asset drops
  /// its padding and squares its corners on that side and a run of stickers
  /// tiles into one image.
  final AssetTiling tiling;

  const MessageText(
    this.text, {
    super.key,
    this.baseStyle,
    this.suffixSpans,
    this.memberNames,
    this.tiling = _noTiling,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style = baseStyle ??
        HollowTypography.body.copyWith(color: hollow.textPrimary);

    final scaler = MediaQuery.textScalerOf(context);

    if (_codeBlockPattern.hasMatch(text)) {
      return _buildWithCodeBlocks(text, style, hollow, suffixSpans, scaler);
    }

    // No text, no paragraph: Text.rich pads a bare sticker with the font's
    // ascent and descent, which is the hairline between two tiled halves of one
    // drawing. A suffix like "(edited)" is real text and never tiles.
    if (suffixSpans == null) {
      final assets = blockAssetsOnlyMessage(text);
      // Exactly one asset is the only shape that tiles. A legacy multi-asset
      // message stays on the paragraph, because stacking those in a Column
      // overflows inside a height-constrained box.
      if (assets != null && assets.length == 1) {
        return _assetOnlyBody(assets.first);
      }
    }

    final tokens = _cachedTokenize(text, memberNames: memberNames);
    final spans = _tokensToSpans(tokens, style, hollow, scaler, tiling);
    if (suffixSpans != null) spans.addAll(suffixSpans!);
    return Text.rich(TextSpan(children: spans));
  }

  /// A message that is one block asset and nothing else, laid out as a bare
  /// widget so the media touches its own bounds exactly. The outer padding is
  /// the seam: zero on a side a neighbouring message continues.
  Widget _assetOnlyBody(ChatAsset asset) {
    final body = ChatAssetBlock(
      asset: asset,
      tileTop: tiling.top,
      tileBottom: tiling.bottom,
    );
    return Padding(
      padding: EdgeInsets.only(
        top: tiling.top ? 0 : 4,
        bottom: tiling.bottom ? 0 : 4,
      ),
      // Align, not a bare child: a message row hands down a TIGHT width and the
      // media must keep its own box inside it. `heightFactor: 1` is load
      // bearing, or Align fills the offered height and centres the media in it,
      // eating the padding difference tiling exists to remove.
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        heightFactor: 1,
        child: body,
      ),
    );
  }

  Widget _buildWithCodeBlocks(
    String text,
    TextStyle style,
    HollowTheme hollow,
    List<InlineSpan>? suffixSpans,
    TextScaler scaler,
  ) {
    final children = <Widget>[];
    int lastEnd = 0;

    for (final match in _codeBlockPattern.allMatches(text)) {
      if (match.start > lastEnd) {
        _addSegmentBeforeBlock(
          children,
          text.substring(lastEnd, match.start),
          style,
          hollow,
          scaler,
        );
      }

      final code = match.group(2) ?? '';
      children.add(_codeBlockContainer(code, hollow));

      lastEnd = match.end;
    }

    if (lastEnd < text.length) {
      suffixSpans = _addSegmentAfterBlocks(
        children,
        text.substring(lastEnd),
        style,
        hollow,
        suffixSpans,
        scaler,
      );
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

  void _addSegmentBeforeBlock(
    List<Widget> children,
    String raw,
    TextStyle style,
    HollowTheme hollow,
    TextScaler scaler,
  ) {
    final before = raw.trimRight();
    if (before.isNotEmpty) {
      final tokens = _cachedTokenize(before);
      children.add(Text.rich(
        TextSpan(children: _tokensToSpans(tokens, style, hollow, scaler, _noTiling)),
      ));
    }
  }

  Widget _codeBlockContainer(String code, HollowTheme hollow) {
    return Container(
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
    );
  }

  /// Adds the text after the last code block. Returns the suffixSpans that were
  /// NOT consumed, null once they were appended to the trailing segment.
  List<InlineSpan>? _addSegmentAfterBlocks(
    List<Widget> children,
    String raw,
    TextStyle style,
    HollowTheme hollow,
    List<InlineSpan>? suffixSpans,
    TextScaler scaler,
  ) {
    final after = raw.trimLeft();
    if (after.isNotEmpty) {
      final tokens = _cachedTokenize(after);
      final spans = _tokensToSpans(tokens, style, hollow, scaler, _noTiling);
      if (suffixSpans != null) spans.addAll(suffixSpans);
      children.add(Text.rich(TextSpan(children: spans)));
      return null;
    }
    return suffixSpans;
  }
}

Widget buildMessageText(
  String text,
  BuildContext context, {
  TextStyle? baseStyle,
  List<InlineSpan>? suffixSpans,
  Set<String>? memberNames,
  AssetTiling tiling = _noTiling,
}) {
  return MessageText(text,
      baseStyle: baseStyle,
      suffixSpans: suffixSpans,
      memberNames: memberNames,
      tiling: tiling);
}

Future<void> _openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
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
