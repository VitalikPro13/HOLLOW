import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/hollow_theme.dart';
import '../../theme/hollow_typography.dart';
import '../components/hollow_pressable.dart';
import 'emoji_data.dart';
import 'emote_image.dart';

/// Composer support for custom emotes:
///
/// - [EmoteComposerController] renders emotes INLINE in the input bar. Each
///   inserted emote occupies exactly ONE private-use character in the text,
///   drawn as the actual emote image via [buildTextSpan] — the 1-char ↔
///   1-WidgetSpan match is what keeps caret/selection math correct (a widget
///   standing in for the full 70-char wire token would desync them).
///   [expandedText] produces the real `[e:name:hash]` / `[a:kind:hash:w:h]`
///   tokens at send time (assets — GIFs/stickers — use the same mechanism).
/// - [EmoteAutocomplete] is the `:` shortcode overlay (mention-overlay
///   pattern): typing `:na` suggests custom emotes and Unicode emoji.

// ---------------------------------------------------------------------------
// Inline-emote controller
// ---------------------------------------------------------------------------

class ComposerEmote {
  final String name;
  final String hash;
  const ComposerEmote(this.name, this.hash);
}

/// A generic asset (GIF/sticker) staged in the composer — same 1-char
/// placeholder mechanism as emotes, expanding to `[a:kind:hash:w:h]`.
class ComposerAsset {
  final String kind; // 'g' GIF | 's' sticker
  final String hash;
  final int w;
  final int h;
  const ComposerAsset(this.kind, this.hash, this.w, this.h);
}

/// First Unicode private-use codepoint; placeholders are allocated upward.
const int _puaBase = 0xE000;
const int _puaLast = 0xF8FF;

bool _isPua(int codeUnit) => codeUnit >= _puaBase && codeUnit <= _puaLast;

class EmoteComposerController extends TextEditingController {
  final Map<String, ComposerEmote> _emotes = {};
  final Map<String, ComposerAsset> _assets = {};
  int _nextPua = _puaBase;

  /// Register an emote and return its 1-char placeholder for insertion.
  String placeholderFor(String name, String hash) {
    final char = String.fromCharCode(_nextPua++);
    _emotes[char] = ComposerEmote(name, hash);
    return char;
  }

  /// Register a GIF/sticker asset and return its 1-char placeholder.
  String placeholderForAsset(String kind, String hash, int w, int h) {
    final char = String.fromCharCode(_nextPua++);
    _assets[char] = ComposerAsset(kind, hash, w, h);
    return char;
  }

  /// Convert a picker/autocomplete result into composer display text:
  /// custom-emote and asset wire tokens become a registered placeholder
  /// char, anything else (Unicode emoji) passes through unchanged.
  String displayTextFor(String emoji) {
    final emote = parseEmoteToken(emoji);
    if (emote != null) return placeholderFor(emote.name, emote.hash);
    final asset = parseAssetToken(emoji);
    if (asset != null) {
      return placeholderForAsset(asset.kind, asset.hash, asset.w, asset.h);
    }
    return emoji;
  }

  /// The outgoing message text: placeholders expanded to `[e:name:hash]` /
  /// `[a:kind:hash:w:h]` wire tokens. Unmapped private-use characters
  /// (pasted from elsewhere) are stripped.
  String expandedText() {
    final buf = StringBuffer();
    for (final code in text.codeUnits) {
      if (_isPua(code)) {
        final key = String.fromCharCode(code);
        final emote = _emotes[key];
        if (emote != null) {
          buf.write('[e:${emote.name}:${emote.hash}]');
          continue;
        }
        final asset = _assets[key];
        if (asset != null) {
          buf.write('[a:${asset.kind}:${asset.hash}:${asset.w}:${asset.h}]');
        }
      } else {
        buf.writeCharCode(code);
      }
    }
    return buf.toString();
  }

  @override
  void clear() {
    _emotes.clear();
    _assets.clear();
    _nextPua = _puaBase;
    super.clear();
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final value = text;
    if ((_emotes.isEmpty && _assets.isEmpty) ||
        !value.codeUnits.any(_isPua)) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    // WidgetSpans are opaque to the text scaler, so the inline emote has to
    // follow the chat text size by hand (same rule as message_text_parser).
    final emoteSize = MediaQuery.textScalerOf(context).scale(22);
    final assetHeight = MediaQuery.textScalerOf(context).scale(36);
    final children = <InlineSpan>[];
    final run = StringBuffer();
    void flushRun() {
      if (run.isEmpty) return;
      children.add(TextSpan(text: run.toString()));
      run.clear();
    }

    for (final code in value.codeUnits) {
      final key = _isPua(code) ? String.fromCharCode(code) : null;
      final emote = key == null ? null : _emotes[key];
      final asset = key == null ? null : _assets[key];
      if (emote == null && asset == null) {
        run.writeCharCode(code);
        continue;
      }
      flushRun();
      // Exactly one placeholder per mapped char keeps offsets aligned.
      children.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: emote != null
            ? SizedBox(
                width: emoteSize,
                height: emoteSize,
                child: EmoteImage(
                    name: emote.name, hash: emote.hash, size: emoteSize),
              )
            : ChatAssetImage(
                kind: asset!.kind,
                hash: asset.hash,
                aspect: asset.h == 0 ? 1.0 : asset.w / asset.h,
                height: assetHeight,
              ),
      ));
    }
    flushRun();
    return TextSpan(style: style, children: children);
  }
}

// ---------------------------------------------------------------------------
// `:` shortcode autocomplete (mention-overlay pattern)
// ---------------------------------------------------------------------------

class EmoteSuggestion {
  final String name;

  /// Custom emote hash, or null for a Unicode emoji.
  final String? hash;

  /// The Unicode emoji character (null for custom emotes).
  final String? char;

  const EmoteSuggestion.custom(this.name, String this.hash) : char = null;
  const EmoteSuggestion.unicode(this.name, String this.char) : hash = null;
}

class EmoteShortcodeScan {
  /// Index of the triggering ':' in the text.
  final int colonPos;
  final List<EmoteSuggestion> suggestions;
  const EmoteShortcodeScan(this.colonPos, this.suggestions);
}

final _shortcodeQueryRegex = RegExp(r'^[a-zA-Z0-9_]+$');

/// Scan backward from [cursor] for a `:query` shortcode trigger (colon
/// preceded by whitespace/start, 2+ query chars) and collect matching
/// suggestions: custom [emotes] first, then Unicode emoji by name.
/// Returns null when there is no active trigger or nothing matches.
EmoteShortcodeScan? scanEmoteShortcode({
  required String text,
  required int cursor,
  required List<ComposerEmote> emotes,
  int max = 8,
}) {
  if (cursor < 0 || cursor > text.length) return null;

  int colonPos = -1;
  for (int i = cursor - 1; i >= 0; i--) {
    final c = text[i];
    if (c == ':') {
      if (i == 0 || text[i - 1] == ' ' || text[i - 1] == '\n') {
        colonPos = i;
      }
      break;
    }
    if (c == ' ' || c == '\n') break;
  }
  if (colonPos < 0) return null;

  final query = text.substring(colonPos + 1, cursor);
  if (query.length < 2 || !_shortcodeQueryRegex.hasMatch(query)) return null;

  final q = query.toLowerCase();
  final suggestions = <EmoteSuggestion>[];
  final seen = <String>{};
  for (final e in emotes) {
    if (suggestions.length >= max) break;
    if (e.name.contains(q) && seen.add(e.name)) {
      suggestions.add(EmoteSuggestion.custom(e.name, e.hash));
    }
  }
  if (suggestions.length < max) {
    outer:
    for (final group in kUnicodeEmojiGroups.values) {
      for (final e in group) {
        if (e.name.contains(q)) {
          suggestions.add(EmoteSuggestion.unicode(e.name, e.char));
          if (suggestions.length >= max) break outer;
        }
      }
    }
  }
  if (suggestions.isEmpty) return null;
  return EmoteShortcodeScan(colonPos, suggestions);
}

/// Replace the active `:query` (from [colonPos] to the cursor) with the
/// picked suggestion — a registered placeholder char for custom emotes, the
/// raw character for Unicode — plus a trailing space.
void acceptEmoteSuggestion({
  required EmoteComposerController controller,
  required int colonPos,
  required EmoteSuggestion suggestion,
}) {
  final text = controller.text;
  final cursor = controller.selection.baseOffset;
  if (colonPos < 0 || cursor < colonPos || cursor > text.length) return;
  final insert = suggestion.hash != null
      ? controller.placeholderFor(suggestion.name, suggestion.hash!)
      : suggestion.char!;
  final replacement = '$insert ';
  final newText = text.replaceRange(colonPos, cursor, replacement);
  controller.value = TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: colonPos + replacement.length),
  );
}

/// Self-contained `:` autocomplete for one composer. The host pane calls
/// [update] from its onChanged, routes key events through [handleKey], and
/// wraps its composer in a `CompositedTransformTarget` using [link] (an
/// existing mention LayerLink can be shared — only one overlay shows at a
/// time since the triggers differ).
class EmoteAutocomplete {
  final LayerLink link;
  final EmoteComposerController controller;

  /// Merged custom emotes available in this composer (server + personal),
  /// refreshed by the host before each [update] call.
  List<ComposerEmote> Function() emotesSource;

  EmoteAutocomplete({
    required this.link,
    required this.controller,
    required this.emotesSource,
  });

  OverlayEntry? _entry;
  List<EmoteSuggestion> _candidates = [];
  int _selected = 0;
  int _colonPos = -1;

  bool get isActive => _entry != null;

  /// Scan the text around the cursor for a `:query` trigger and show/update
  /// or dismiss the overlay accordingly.
  void update(BuildContext context, String text) {
    final scan = scanEmoteShortcode(
      text: text,
      cursor: controller.selection.baseOffset,
      emotes: emotesSource(),
    );
    if (scan == null) {
      dismiss();
      return;
    }
    _colonPos = scan.colonPos;
    _candidates = scan.suggestions;
    if (_selected >= _candidates.length) _selected = 0;
    _show(context);
  }

  /// Key handling while the overlay is up. Call BEFORE the pane's own send
  /// key handling; returns [KeyEventResult.ignored] when inactive.
  KeyEventResult handleKey(KeyEvent event) {
    if (_entry == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _selected = (_selected + 1).clamp(0, _candidates.length - 1);
      _entry?.markNeedsBuild();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _selected = (_selected - 1).clamp(0, _candidates.length - 1);
      _entry?.markNeedsBuild();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      _accept(_candidates[_selected]);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      dismiss();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void dismiss() {
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    _candidates = [];
    _selected = 0;
    _colonPos = -1;
  }

  void _accept(EmoteSuggestion c) {
    acceptEmoteSuggestion(
        controller: controller, colonPos: _colonPos, suggestion: c);
    dismiss();
  }

  void _show(BuildContext context) {
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(builder: (ctx) => _build(ctx));
    overlay.insert(_entry!);
  }

  Widget _build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Positioned(
      width: 260,
      child: CompositedTransformFollower(
        link: link,
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -4),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.all(4),
              itemCount: _candidates.length,
              itemBuilder: (ctx, i) {
                final c = _candidates[i];
                final selected = i == _selected;
                return HollowPressable(
                  onTap: () => _accept(c),
                  borderRadius: BorderRadius.circular(hollow.radiusSm),
                  backgroundColor: selected
                      ? hollow.accent.withValues(alpha: 0.12)
                      : null,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: Center(
                          child: c.hash != null
                              ? EmoteImage(
                                  name: c.name, hash: c.hash!, size: 20)
                              : Text(c.char!,
                                  style: const TextStyle(fontSize: 17)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.hash != null ? ':${c.name}:' : c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HollowTypography.label.copyWith(
                            color: selected
                                ? hollow.textPrimary
                                : hollow.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
