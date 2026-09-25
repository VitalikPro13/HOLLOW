import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/avatar_frame.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Every banner surface, the cropper and Rust's 1200x480 storage agree on it.
const double kShopBannerAspect = 2.5;

/// The shelf a listing sits on. Each kind keeps its own shape: avatars and
/// frames are square tiles, banners and bundles are wide.
enum ShopShelf { avatars, frames, banners, bundles }

ShopShelf shelfOf(shop.ShopListing listing) {
  if (listing.bundle) return ShopShelf.bundles;
  switch (listing.primaryKind) {
    case 'avatar':
      return ShopShelf.avatars;
    case 'frame':
      return ShopShelf.frames;
    case 'banner':
      return ShopShelf.banners;
  }
  return listing.wide ? ShopShelf.banners : ShopShelf.avatars;
}

bool isWideShelf(ShopShelf shelf) =>
    shelf == ShopShelf.banners || shelf == ShopShelf.bundles;

/// The file that carries [kind] for [listing], `""` when none does. At rest the
/// still sibling wins, so a wall of cards is not a wall of running animations.
String shopArtHash(shop.ShopListing listing, String kind, {bool anim = false}) {
  if (kind == listing.primaryKind) {
    if (!anim && listing.stillHash.isNotEmpty) return listing.stillHash;
    return listing.displayHash;
  }
  String? any;
  for (final file in listing.files) {
    if (file.role == '${kind}_still' && !anim) return file.sha256;
    if (file.role == '${kind}_anim' && anim) return file.sha256;
    if (file.role == kind ||
        file.role == '${kind}_still' ||
        file.role == '${kind}_anim') {
      any ??= file.sha256;
    }
  }
  return any ?? '';
}

bool _listingHas(shop.ShopListing listing, String kind) =>
    listing.kinds.contains(kind) || listing.primaryKind == kind;

/// Bytes for [kind]: the animation while [anim], with the still painting until
/// it lands. Null while nothing has arrived; empty when the art failed.
Uint8List? _artBytes(
    WidgetRef ref, shop.ShopListing listing, String kind, bool anim) {
  final hash = shopArtHash(listing, kind, anim: anim);
  if (hash.isEmpty) return Uint8List(0);
  final art = ref.watch(shop.shopArtProvider(hash));
  if (art.hasError) return Uint8List(0);
  final still = shopArtHash(listing, kind);
  final fallback = anim && still != hash
      ? ref.watch(shop.shopArtProvider(still)).valueOrNull
      : null;
  return art.valueOrNull ?? fallback;
}

/// Frame art is judged in front of a face, so its bytes are seeded into the
/// shared frame cache (RAM only) and painted by [AvatarFrame]. Returns the id
/// once the frame can paint, `""` before.
String _seededFrame(WidgetRef ref, shop.ShopListing listing) {
  final hash = shopArtHash(listing, 'frame', anim: true);
  if (hash.isEmpty) return '';
  final bytes = ref.watch(shop.shopArtProvider(hash)).valueOrNull;
  if (bytes == null || bytes.isEmpty) return '';
  final seeded =
      ref.watch(avatarFrameProvider.select((m) => m.containsKey(hash)));
  if (!seeded) {
    final frames = ref.read(avatarFrameProvider.notifier);
    Future.microtask(() => frames.seed(hash, bytes));
  }
  return hash;
}

class _ArtPlaceholder extends StatelessWidget {
  final bool failed;
  const _ArtPlaceholder({this.failed = false});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return ColoredBox(
      color: hollow.elevated,
      child: failed
          ? Center(
              child: Icon(LucideIcons.imageOff,
                  size: 20, color: hollow.textTertiary),
            )
          : const SizedBox.expand(),
    );
  }
}

/// One kind's picture filling its box edge to edge. Still at rest; plays while
/// the enclosing card is hovered, or always when [animate].
class ShopArtFill extends ConsumerWidget {
  final shop.ShopListing listing;
  final String kind;
  final bool animate;

  const ShopArtFill({
    super.key,
    required this.listing,
    required this.kind,
    this.animate = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final anim = animate || (HoverScope.maybeOf(context) ?? false);
    final bytes = _artBytes(ref, listing, kind, anim);
    if (bytes == null) return const _ArtPlaceholder();
    if (bytes.isEmpty) return const _ArtPlaceholder(failed: true);
    return AnimatedGifImage(
      bytes: bytes,
      fit: BoxFit.cover,
      animate: anim,
      errorWidget: const _ArtPlaceholder(failed: true),
    );
  }
}

/// A frame tile: the frame on a plain face, or on your own avatar when
/// [onMe], so the frame itself is what the tile shows.
class ShopFrameArt extends ConsumerWidget {
  final shop.ShopListing listing;
  final bool onMe;

  const ShopFrameArt({super.key, required this.listing, this.onMe = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final anim = HoverScope.maybeOf(context) ?? false;
    final frameId = _seededFrame(ref, listing);
    final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';

    return ColoredBox(
      color: hollow.elevated,
      child: LayoutBuilder(builder: (context, constraints) {
        final side = constraints.biggest.shortestSide;
        // The frame overhangs its avatar by kFrameScale, so the face is sized
        // for the FRAMED square to sit inside the tile with a margin.
        final face = side * 0.88 / kFrameScale;
        final Widget framed;
        if (onMe) {
          framed = HollowAvatar(
            peerId: me,
            size: face,
            frameId: frameId,
            animate: anim,
          );
        } else {
          final plain = Container(
            width: face,
            height: face,
            decoration: BoxDecoration(
              color: hollow.hover,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
            ),
            alignment: Alignment.bottomCenter,
            clipBehavior: Clip.antiAlias,
            child: Icon(LucideIcons.user,
                size: 24, color: hollow.textTertiary),
          );
          framed = frameId.isEmpty
              ? plain
              : AvatarFrame(
                  id: frameId,
                  size: face,
                  radius: hollow.radiusMd,
                  animate: anim,
                  child: plain,
                );
        }
        return Center(child: framed);
      }),
    );
  }
}

/// A bundle as one look: its banner behind, its avatar (or yours) in front
/// with its frame, the way a profile card would put them together.
class ShopBundleArt extends ConsumerWidget {
  final shop.ShopListing listing;
  final bool animate;

  const ShopBundleArt({super.key, required this.listing, this.animate = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final anim = animate || (HoverScope.maybeOf(context) ?? false);
    final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';
    final hasAvatar = _listingHas(listing, 'avatar');
    final avatar = hasAvatar ? _artBytes(ref, listing, 'avatar', anim) : null;
    final frameId =
        _listingHas(listing, 'frame') ? _seededFrame(ref, listing) : null;

    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.maxHeight * 0.44;
      return Stack(
        fit: StackFit.expand,
        children: [
          if (_listingHas(listing, 'banner'))
            ShopArtFill(listing: listing, kind: 'banner', animate: animate)
          else
            ColoredBox(color: hollow.elevated),
          Positioned(
            left: size * 0.5,
            bottom: size * 0.4,
            child: HollowAvatar(
              peerId: me,
              size: size,
              imageBytes: avatar == null || avatar.isEmpty ? null : avatar,
              frameId: frameId,
              animate: anim,
            ),
          ),
        ],
      );
    });
  }
}

/// The piece on YOUR profile card: its banner, avatar and frame in place of
/// yours, and yours wherever it brings none. This is the question the item
/// view answers, so everything here plays.
class ShopTryOnCard extends ConsumerWidget {
  final shop.ShopListing listing;

  const ShopTryOnCard({super.key, required this.listing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';
    final profile = ref.watch(profileProvider.select((p) => p[me]));
    final name = me.isEmpty ? '' : displayNameForPeer(profile, me);
    final bringsBanner = _listingHas(listing, 'banner');
    final myBanner =
        bringsBanner || me.isEmpty ? null : ref.watch(bannerProvider(me)).valueOrNull;
    final avatar = _listingHas(listing, 'avatar')
        ? _artBytes(ref, listing, 'avatar', true)
        : null;
    final frameId =
        _listingHas(listing, 'frame') ? _seededFrame(ref, listing) : null;

    const avatarSize = 72.0;
    const ring = HollowSpacing.xs;

    final Widget banner = bringsBanner
        ? ShopArtFill(listing: listing, kind: 'banner', animate: true)
        : (myBanner != null && myBanner.isNotEmpty
            ? AnimatedGifImage(bytes: myBanner, fit: BoxFit.cover, animate: true)
            : ColoredBox(color: hollow.hover));

    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusLg),
      child: ColoredBox(
        color: hollow.elevated,
        child: LayoutBuilder(builder: (context, constraints) {
          final bannerHeight = constraints.maxWidth / kShopBannerAspect;
          return Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(height: bannerHeight, child: banner),
                  const SizedBox(height: avatarSize / 2 + ring + HollowSpacing.sm),
                  Padding(
                    padding: const EdgeInsets.only(
          left: HollowSpacing.lg,
          right: HollowSpacing.lg,
          bottom: HollowSpacing.lg,
        ),
                    child: Text(
                      name,
                      style: HollowTypography.subheading
                          .copyWith(color: hollow.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              Positioned(
                left: HollowSpacing.lg - ring,
                top: bannerHeight - avatarSize / 2 - ring,
                child: Container(
                  padding: const EdgeInsets.all(ring),
                  decoration: BoxDecoration(
                    color: hollow.elevated,
                    borderRadius: BorderRadius.circular(hollow.radiusLg),
                  ),
                  child: HollowAvatar(
                    peerId: me,
                    size: avatarSize,
                    imageBytes: avatar == null || avatar.isEmpty ? null : avatar,
                    frameId: frameId,
                    animate: true,
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }
}
