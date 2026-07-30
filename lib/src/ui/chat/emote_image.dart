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

/// Below this a tiled run is unreadable, so it wraps to a second line at full
/// size instead of shrinking further.
const double _kMinRunHeight = 44;

/// The chat media caps for each asset kind — GIFs match image attachments so
/// a GIF-with-caption reads exactly like a photo-with-caption.
Size assetChatBox(String kind, int srcW, int srcH) => kind == 'g'
    ? fitAssetBox(srcW, srcH, maxW: 300, maxH: 250)
    : fitAssetBox(srcW, srcH, maxW: kStickerChatBox, maxH: kStickerChatBox);

/// One asset parsed out of an `[a:kind:hash:w:h]` token.
typedef ChatAsset = ({String kind, String hash, int w, int h});

/// Corner rounding for one member of a sticker run. Only the run's OUTER
/// edges are rounded — an inner corner would carve a notch out of a
/// multi-part sticker exactly where the seam is supposed to be invisible.
/// [tileTop]/[tileBottom] extend that to the seams BETWEEN messages.
BorderRadius stickerRunRadius({
  required bool first,
  required bool last,
  required bool tileTop,
  required bool tileBottom,
  double radius = 8,
}) {
  Radius r(bool on) => Radius.circular(on ? radius : 0);
  return BorderRadius.only(
    topLeft: r(first && !tileTop),
    bottomLeft: r(first && !tileBottom),
    topRight: r(last && !tileTop),
    bottomRight: r(last && !tileBottom),
  );
}

/// The height every piece of a run is drawn at, so a designed multi-part pack
/// lines up into one image. Null = the run cannot fit on one line at a
/// readable size and should wrap at natural size instead.
///
/// Pieces keep their own aspect within that shared height, and the height
/// never exceeds any piece's own pixels — a mosaic must not be upscaled into
/// mush just because there is room.
double? sharedRunHeight(List<ChatAsset> assets, double maxWidth) {
  if (assets.isEmpty) return null;
  var totalAspect = 0.0;
  var naturalCap = kStickerChatBox;
  for (final a in assets) {
    if (a.w <= 0 || a.h <= 0) return null;
    totalAspect += a.w / a.h;
    naturalCap = math.min(naturalCap, a.h.toDouble());
  }
  if (totalAspect <= 0) return null;
  final height = math.min(naturalCap, maxWidth / totalAspect);
  return height >= _kMinRunHeight ? height : null;
}

/// A run of adjacent stickers, drawn edge to edge with no gap so a pack
/// authored as several pieces reads as ONE image — the Telegram trick, which
/// is an emergent property of tight stacking rather than a declared feature.
///
/// [tileTop]/[tileBottom] say the neighbouring MESSAGE continues the run, so
/// the seam carries across messages too.
class ChatAssetRun extends StatelessWidget {
  final List<ChatAsset> assets;
  final bool tileTop;
  final bool tileBottom;

  const ChatAssetRun({
    super.key,
    required this.assets,
    this.tileTop = false,
    this.tileBottom = false,
  });

  Widget _piece(ChatAsset a, Size box, {required bool first, required bool last}) =>
      ChatAssetImage(
        kind: a.kind,
        hash: a.hash,
        aspect: a.w / a.h,
        width: box.width,
        height: box.height,
        borderRadius: stickerRunRadius(
          first: first,
          last: last,
          tileTop: tileTop,
          tileBottom: tileBottom,
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (assets.isEmpty) return const SizedBox.shrink();
    if (assets.length == 1) {
      final a = assets.first;
      final box = assetChatBox(a.kind, a.w, a.h);
      return _piece(a, box, first: true, last: true);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : kStickerChatBox * assets.length;
        final height = sharedRunHeight(assets, maxW);
        if (height == null) {
          // Too many to seam readably: fall back to wrapping at natural size.
          // Still gapless, so short rows keep tiling.
          return Wrap(
            spacing: 0,
            runSpacing: 0,
            children: [
              for (final a in assets)
                _piece(a, assetChatBox(a.kind, a.w, a.h),
                    first: true, last: true),
            ],
          );
        }
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < assets.length; i++)
              _piece(
                assets[i],
                Size(height * (assets[i].w / assets[i].h), height),
                first: i == 0,
                last: i == assets.length - 1,
              ),
          ],
        );
      },
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

  /// Corner rounding. Members of a [ChatAssetRun] pass an outer-edges-only
  /// radius so the seams between tiled pieces stay square.
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
