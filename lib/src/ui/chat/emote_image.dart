import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers/emote_provider.dart';
import '../../theme/hollow_theme.dart';

/// Where to pull unknown emote bytes from. Chat panes wrap their message area
/// in one, so every token and reaction below knows its pull source without
/// threading parameters.
class EmoteScope extends InheritedWidget {
  /// Server room to ask, in a channel.
  final String? serverId;

  /// DM counterpart master id to ask, in a DM.
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

/// Inline custom-emote image, keyed by content hash. Missing bytes render the
/// `:name:` text fallback and fire a once-per-session pull through the
/// surrounding [EmoteScope].
class EmoteImage extends ConsumerWidget {
  final String name;
  final String hash;
  final double size;

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
/// `[a:kind:hash:w:h]`, kind `s` or `g`, hash 64 hex, w/h 1..=4096. The regex
/// admits up to 9999 and the parser enforces the bound. Keep both in sync.
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

/// Chat media box for a block-rendered asset: fits inside [maxW]x[maxH] at the
/// source aspect and NEVER upscales past the asset's own pixels, the same rule
/// and numbers as image attachments.
Size fitAssetBox(int srcW, int srcH,
    {required double maxW, required double maxH}) {
  if (srcW <= 0 || srcH <= 0) return Size(maxW, maxH);
  final aspect = srcW / srcH;
  var w = math.min(maxW, srcW.toDouble());
  var h = w / aspect;
  // w <= srcW here, so clamping height can only shrink further.
  if (h > maxH) {
    h = maxH;
    w = h * aspect;
  }
  return Size(w, h);
}

/// Longest side a chat sticker is drawn at when it stands alone.
const double kStickerChatBox = 160;

/// The chat media caps per asset kind. GIFs match image attachments, so a GIF
/// with a caption reads like a photo with a caption.
Size assetChatBox(String kind, int srcW, int srcH) => kind == 'g'
    ? fitAssetBox(srcW, srcH, maxW: 300, maxH: 250)
    : fitAssetBox(srcW, srcH, maxW: kStickerChatBox, maxH: kStickerChatBox);

typedef ChatAsset = ({String kind, String hash, int w, int h});

/// Corner rounding for one sticker in a VERTICAL run of tiled sticker-only
/// messages. Only the run's outer edges round: a rounded corner at a seam
/// carves a notch exactly where the join should vanish.
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

/// One asset token drawn as a block at its chat media box (issue #36, one per
/// message, so nothing shrinks for a neighbour). [tileTop] and [tileBottom] say
/// the neighbouring MESSAGE continues a vertical sticker run, which squares the
/// seam corners and bleeds the media across the join (see [_seamBleed]).
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

  /// How far the media overruns its layout box on a tiled edge: exactly ONE
  /// device pixel, in this subtree's logical pixels.
  ///
  /// Two tiles that abut exactly still show a seam, because each rounded-clip
  /// edge is antialiased and the compositor leaves background showing at some
  /// zooms. A device pixel of overlap puts that edge inside the neighbour's
  /// opaque body. `devicePixelRatioOf` is the right measure because `UiScaleBox`
  /// folds the zoom factor into the ratio it publishes.
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

    // Only the paint overruns; the LAYOUT box is untouched, so no row moves.
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

/// Renders an asset token from the content-addressed blob cache. The token's
/// w/h reserve the EXACT final box before bytes arrive, so the placeholder
/// flips to the image with no reflow.
class ChatAssetImage extends ConsumerWidget {
  /// 's' for a sticker, 'g' for a GIF.
  final String kind;
  final String hash;

  final double aspect;

  final double height;

  /// Null means inline mode, where the width follows [aspect] clamped at 4:1 so
  /// a wide asset cannot swallow the line. Block callers pass [assetChatBox].
  final double? width;

  /// [ChatAssetBlock] squares the edges against a tiled neighbouring message,
  /// so the seam stays invisible.
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

    // The two states must READ differently for a screen reader and the probe
    // alike: one label for both says a placeholder is the picture.
    return Semantics(
      image: bytes != null,
      label: bytes == null ? '$_label loading' : _label,
      child: box,
    );
  }
}

/// Inline spans for one-line message previews, with each emote and asset token
/// swapped for a line-sized image. For surfaces that would otherwise print the
/// raw token; chat bubbles use the full message parser.
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
      // Regex-matched but parse-rejected (out-of-range dims).
      spans.add(TextSpan(text: token));
    }
    last = m.end;
  }
  if (last < text.length) {
    spans.add(TextSpan(text: text.substring(last)));
  }
  return spans;
}
