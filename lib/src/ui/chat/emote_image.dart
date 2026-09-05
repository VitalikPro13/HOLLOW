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

/// Longest side a chat sticker is drawn at when it stands alone.
const double kStickerChatBox = 160;

/// The chat media caps for each asset kind — GIFs match image attachments so
/// a GIF-with-caption reads exactly like a photo-with-caption.
Size assetChatBox(String kind, int srcW, int srcH) => kind == 'g'
    ? fitAssetBox(srcW, srcH, maxW: 300, maxH: 250)
    : fitAssetBox(srcW, srcH, maxW: kStickerChatBox, maxH: kStickerChatBox);

/// One asset parsed out of an `[a:kind:hash:w:h]` token.
typedef ChatAsset = ({String kind, String hash, int w, int h});

/// Corner rounding for one sticker in a VERTICAL run — consecutive
/// sticker-only messages that tile into each other. Only the run's outer
/// edges are rounded; a rounded corner at a seam would carve a notch out of
/// the tiling exactly where it is supposed to vanish.
///
/// Horizontal runs are gone (issue #36, one sticker per message), so the only
/// seams left are the ones between messages.
BorderRadius stickerRunRadius({
  required bool tileTop,
  required bool tileBottom,
  double radius = 8,
}) {
  Radius r(bool on) => Radius.circular(on ? radius : 0);
  return BorderRadius.only(
    topLeft: r(!tileTop),
    topRight: r(!tileTop),
    bottomLeft: r(!tileBottom),
    bottomRight: r(!tileBottom),
  );
}

/// One asset token drawn as a block at its chat media box.
///
/// Stickers are capped at ONE per message (issue #36), so there is no
/// horizontal run and nothing ever shrinks to make room for a neighbour: a
/// sticker is always drawn at [kStickerChatBox], a GIF at the photo box.
/// [tileTop]/[tileBottom] say the neighbouring MESSAGE continues a vertical
/// sticker run, which squares the seam corners and bleeds the media across
/// the join (see [_seamBleed]).
class ChatAssetBlock extends StatelessWidget {
  final ChatAsset asset;
  final bool tileTop;
  final bool tileBottom;

  const ChatAssetBlock({
    super.key,
    required this.asset,
    this.tileTop = false,
    this.tileBottom = false,
  });

  /// How far the media overruns its layout box on a tiled edge, in this
  /// subtree's logical pixels — exactly ONE device pixel.
  ///
  /// Two tiles that abut *exactly* still show a seam, and that is not a
  /// layout bug: each rounded-clip edge is antialiased, so where they meet
  /// the compositor gives `1-αβ` coverage rather than 1, leaving up to 25%
  /// of the background showing through. Whether it shows at all depends on
  /// where the shared edge lands within a device pixel, which is why the line
  /// appeared at 105%, vanished at 115% and came back at 125% — at some zooms
  /// the edge lands on a pixel boundary (α=0) and at others dead centre
  /// (α=0.5, worst case).
  ///
  /// Overlapping by a full device pixel puts that antialiased edge INSIDE the
  /// neighbour's opaque body instead of against the background, so it
  /// composites to solid at every zoom. The cost is ~0.6% of vertical stretch
  /// on a 160px sticker, across artwork that is continuous by construction.
  ///
  /// `devicePixelRatioOf` is the right measure at any zoom because
  /// `UiScaleBox` folds the zoom factor INTO the ratio it publishes — one of
  /// our logical pixels really does cover `dpr * scale` device pixels here.
  static double _seamBleed(BuildContext context) =>
      1.0 / MediaQuery.devicePixelRatioOf(context);

  @override
  Widget build(BuildContext context) {
    final box = assetChatBox(asset.kind, asset.w, asset.h);
    final radius = stickerRunRadius(tileTop: tileTop, tileBottom: tileBottom);

    Widget image(double height) => ChatAssetImage(
          kind: asset.kind,
          hash: asset.hash,
          aspect: asset.w / asset.h,
          width: box.width,
          height: height,
          borderRadius: radius,
        );

    if (!tileTop && !tileBottom) return image(box.height);

    final bleed = _seamBleed(context);
    final overTop = tileTop ? bleed : 0.0;
    final overBottom = tileBottom ? bleed : 0.0;

    // The LAYOUT box is untouched — only the paint overruns — so the rows
    // above and below keep their exact positions and nothing reflows.
    return SizedBox(
      width: box.width,
      height: box.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            top: -overTop,
            left: 0,
            child: image(box.height + overTop + overBottom),
          ),
        ],
      ),
    );
  }
}

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

  /// Corner rounding. [ChatAssetBlock] squares the edges that sit against a
  /// tiled neighbouring message so the seam stays invisible.
  final BorderRadius? borderRadius;

  const ChatAssetImage({
    super.key,
    required this.kind,
    required this.hash,
    required this.aspect,
    required this.height,
    this.width,
    this.borderRadius,
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

    final radius = borderRadius ?? BorderRadius.circular(8);

    Widget placeholder() => DecoratedBox(
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: radius,
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
            borderRadius: radius,
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

    // The two states have to READ differently, for a screen reader and for
    // the probe alike: "GIF" is a picture that arrived, "GIF loading" is a
    // reserved box still waiting on the asset rail. One label for both said
    // a placeholder was the picture.
    return Semantics(
      image: bytes != null,
      label: bytes == null ? '$_label loading' : _label,
      child: box,
    );
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
