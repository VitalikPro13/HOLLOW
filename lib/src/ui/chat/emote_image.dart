import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/emote_provider.dart';
import '../../theme/hollow_theme.dart';

/// Where to pull unknown emote bytes from — chat panes wrap their message
/// area in an [EmoteScope] so every token/reaction below (bubbles, reaction
/// bars, pinned overlays) knows its pull source without threading params.
class EmoteScope extends InheritedWidget {
  /// Server room to ask (channel context).
  final String? serverId;

  /// DM counterpart master id to ask (DM context).
  final String? peerHint;

  const EmoteScope({
    super.key,
    this.serverId,
    this.peerHint,
    required super.child,
  });

  static EmoteScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<EmoteScope>();

  @override
  bool updateShouldNotify(EmoteScope oldWidget) =>
      serverId != oldWidget.serverId || peerHint != oldWidget.peerHint;
}

/// Inline custom-emote image, keyed by content hash. Renders the cached WebP
/// (animated WebP animates natively); while the bytes are missing it shows
/// the `:name:` text fallback and fires a once-per-session network pull via
/// the surrounding [EmoteScope].
class EmoteImage extends ConsumerWidget {
  final String name;
  final String hash;
  final double size;

  /// Style for the `:name:` fallback while bytes are loading.
  final TextStyle? fallbackStyle;

  const EmoteImage({
    super.key,
    required this.name,
    required this.hash,
    required this.size,
    this.fallbackStyle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final bytes = ref.watch(emoteBytesProvider(hash)).valueOrNull;

    if (bytes == null) {
      final scope = EmoteScope.of(context);
      requestEmoteOnce(hash,
          serverId: scope?.serverId, peerHint: scope?.peerHint);
      return Text(
        ':$name:',
        style: (fallbackStyle ?? const TextStyle())
            .copyWith(color: hollow.textTertiary),
      );
    }

    return Semantics(
      image: true,
      label: ':$name: emote',
      child: Image.memory(
        bytes,
        width: size,
        height: size,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => Text(
          ':$name:',
          style: (fallbackStyle ?? const TextStyle())
              .copyWith(color: hollow.textTertiary),
        ),
      ),
    );
  }
}

/// Grammar shared with Rust (`node/emotes.rs::parse_emote_token`):
/// `[e:name:hash]`, name = 2-24 of [a-z0-9_], hash = 64 hex.
final emoteTokenRegex = RegExp(r'\[e:([a-z0-9_]{2,24}):([0-9a-f]{64})\]');

/// Parse a string that is EXACTLY one emote token (reaction strings).
({String name, String hash})? parseEmoteToken(String s) {
  final m = emoteTokenRegex.matchAsPrefix(s);
  if (m == null || m.end != s.length) return null;
  return (name: m.group(1)!, hash: m.group(2)!);
}

/// Plain-text form for surfaces that can't render images (OS toasts, push
/// notification bodies): every `[e:name:hash]` token becomes `:name:`.
String emoteTokensToShortcodes(String text) =>
    text.replaceAllMapped(emoteTokenRegex, (m) => ':${m.group(1)}:');

/// Inline spans for one-line message previews (notification cards/banners):
/// plain text with each emote token swapped for an [EmoteImage] sized to the
/// line. Chat bubbles use the full message parser instead — this is for
/// surfaces that would otherwise print the raw token.
List<InlineSpan> emotePreviewSpans(String text, TextStyle style) {
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in emoteTokenRegex.allMatches(text)) {
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: EmoteImage(
        name: m.group(1)!,
        hash: m.group(2)!,
        size: (style.fontSize ?? 14) * 1.35,
        fallbackStyle: style,
      ),
    ));
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return spans;
}
