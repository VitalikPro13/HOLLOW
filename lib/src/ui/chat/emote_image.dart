import 'dart:math' as math;

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
        errorBuilder: (_, _, _) => Text(
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
String emoteTokensToShortcodes(String text) => text
    .replaceAllMapped(emoteTokenRegex, (m) => ':${m.group(1)}:')
    .replaceAllMapped(
        assetTokenRegex, (m) => m.group(1) == 'g' ? '[GIF]' : '[Sticker]');

/// Grammar shared with Rust (`node/emotes.rs::parse_asset_token`):
/// `[a:kind:hash:w:h]`, kind = `s` (sticker) | `g` (GIF), hash = 64 hex,
/// w/h = pixel dimensions 1..=4096 (the regex admits up to 9999 — the
/// parser enforces the 4096 bound). Keep in sync with the Rust side.
final assetTokenRegex = RegExp(
    r'\[a:(s|g):([0-9a-f]{64}):([1-9][0-9]{0,3}):([1-9][0-9]{0,3})\]');

/// Parse a string that is EXACTLY one asset token.
({String kind, String hash, int w, int h})? parseAssetToken(String s) {
  final m = assetTokenRegex.matchAsPrefix(s);
  if (m == null || m.end != s.length) return null;
  final w = int.parse(m.group(3)!);
  final h = int.parse(m.group(4)!);
  if (w > 4096 || h > 4096) return null;
  return (kind: m.group(1)!, hash: m.group(2)!, w: w, h: h);
}

/// Chat media box for a block-rendered asset: fit inside [maxW]x[maxH]
/// preserving the aspect, and NEVER upscale past the asset's own pixels.
/// Same rule (and same numbers) as image attachments — see
/// `file_attachment_widget._buildImagePreview`, 300x250.
Size fitAssetBox(int srcW, int srcH,
    {required double maxW, required double maxH}) {
  if (srcW <= 0 || srcH <= 0) return Size(maxW, maxH);
  final aspect = srcW / srcH;
  var w = math.min(maxW, srcW.toDouble());
  var h = w / aspect;
  // w <= srcW, so h <= srcH here: clamping height can only shrink further,
  // never upscale.
  if (h > maxH) {
    h = maxH;
    w = h * aspect;
  }
  return Size(w, h);
}

/// The chat media caps for each asset kind — GIFs match image attachments so
/// a GIF-with-caption reads exactly like a photo-with-caption.
Size assetChatBox(String kind, int srcW, int srcH) => kind == 'g'
    ? fitAssetBox(srcW, srcH, maxW: 300, maxH: 250)
    : fitAssetBox(srcW, srcH, maxW: 160, maxH: 160);

/// Renders a generalized asset token (sticker/GIF) from the content-addressed
/// blob cache. The token's w/h reserve the EXACT final box before bytes
/// arrive — a sized placeholder flips to the image with zero reflow.
class ChatAssetImage extends ConsumerWidget {
  /// Token kind: 's' (sticker) or 'g' (GIF).
  final String kind;
  final String hash;

  /// w/h aspect ratio from the token.
  final double aspect;

  /// Exact display height.
  final double height;

  /// Exact display width. Null = inline mode: the width follows [aspect],
  /// clamped at 4:1 so a wide asset can't swallow the line. Block callers
  /// pass a box from [assetChatBox].
  final double? width;

  const ChatAssetImage({
    super.key,
    required this.kind,
    required this.hash,
    required this.aspect,
    required this.height,
    this.width,
  });

  String get _label => kind == 'g' ? 'GIF' : 'sticker';

  /// The db/request kind string for the pull path.
  String get _dbKind => kind == 'g' ? 'gif' : 'sticker';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final bytes = ref.watch(emoteBytesProvider(hash)).valueOrNull;

    if (bytes == null) {
      final scope = EmoteScope.of(context);
      requestAssetOnce(hash,
          kind: _dbKind, serverId: scope?.serverId, peerHint: scope?.peerHint);
    }

    Widget placeholder() => DecoratedBox(
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: hollow.border),
          ),
          child: Center(
            child: Icon(
              kind == 'g' ? Icons.gif_box_outlined : Icons.image_outlined,
              color: hollow.textTertiary,
              size: 20,
            ),
          ),
        );

    final content = bytes == null
        ? placeholder()
        : ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => placeholder(),
            ),
          );

    final box = SizedBox(
      width: width ?? height * aspect.clamp(0.25, 4.0),
      height: height,
      child: content,
    );

    return Semantics(image: true, label: _label, child: box);
  }
}

/// Inline spans for one-line message previews (notification cards/banners):
/// plain text with each emote token swapped for an [EmoteImage] and each
/// asset token (GIF/sticker) for a line-sized [ChatAssetImage]. Chat bubbles
/// use the full message parser instead — this is for surfaces that would
/// otherwise print the raw token.
List<InlineSpan> emotePreviewSpans(String text, TextStyle style) {
  final spans = <InlineSpan>[];
  final matches = [
    ...emoteTokenRegex.allMatches(text),
    ...assetTokenRegex.allMatches(text),
  ]..sort((a, b) => a.start.compareTo(b.start));
  var last = 0;
  for (final m in matches) {
    if (m.start < last) continue; // overlap can't happen, but stay safe
    if (m.start > last) {
      spans.add(TextSpan(text: text.substring(last, m.start)));
    }
    final token = m.group(0)!;
    final asset = parseAssetToken(token);
    final emote = asset == null ? parseEmoteToken(token) : null;
    if (asset != null) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: ChatAssetImage(
          kind: asset.kind,
          hash: asset.hash,
          aspect: asset.w / asset.h,
          height: (style.fontSize ?? 14) * 1.8,
        ),
      ));
    } else if (emote != null) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: EmoteImage(
          name: emote.name,
          hash: emote.hash,
          size: (style.fontSize ?? 14) * 1.35,
          fallbackStyle: style,
        ),
      ));
    } else {
      // Regex-matched but parse-rejected (out-of-range dims): raw text.
      spans.add(TextSpan(text: token));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return spans;
}
