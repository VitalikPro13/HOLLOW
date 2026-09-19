import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/avatar_frame.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hover_scope.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/shop/hollowpack_import.dart';
import 'package:hollow/src/ui/shop/shop_item_dialog.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// The Hollow Shop wall: a grid of listings pulled from the signed catalog.
///
/// Buying happens in the system browser and comes back as a `.hollowpack`
/// imported from this same page; nothing here unlocks anything inside Hollow.
/// Renders nothing at all when the shop is unavailable, which is defence in
/// depth: a store build has no button that reaches this page either.
class ShopDashboard extends ConsumerStatefulWidget {
  /// Pushed as a mobile route (or inside a settings sub-page) rather than
  /// taking over the desktop centre pane, so the page skips its own title.
  final bool embedded;

  const ShopDashboard({super.key, this.embedded = false});

  @override
  ConsumerState<ShopDashboard> createState() => _ShopDashboardState();
}

/// The filter pills. `null` means the kind filter is off.
enum _ShopFilter { all, frames, avatars, banners, bundles }

class _ShopDashboardState extends ConsumerState<ShopDashboard> {
  _ShopFilter _filter = _ShopFilter.all;
  bool _dragging = false;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  bool _matches(shop.ShopListing listing) {
    switch (_filter) {
      case _ShopFilter.all:
        return true;
      case _ShopFilter.frames:
        return listing.kinds.contains('frame');
      case _ShopFilter.avatars:
        return listing.kinds.contains('avatar');
      case _ShopFilter.banners:
        return listing.kinds.contains('banner');
      case _ShopFilter.bundles:
        return listing.bundle;
    }
  }

  Future<void> _openInBrowser() async {
    final origin = ref.read(shop.shopOriginProvider).valueOrNull;
    if (origin == null || origin.isEmpty) return;
    final uri = Uri.tryParse(origin);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!mounted) return;
    HollowToast.show(context, 'Opening the shop in your browser',
        type: HollowToastType.info);
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (details.files.isEmpty) return;
    final path = details.files.first.path;
    if (path.isEmpty) return;
    await importHollowpackAt(context, ref, path);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(shopAvailableProvider)) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);

    return Container(
      color: hollow.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(hollow),
          Expanded(child: _wrapDropTarget(hollow, _buildBody(hollow))),
        ],
      ),
    );
  }

  Widget _buildHeader(HollowTheme hollow) {
    final pills = [
      for (final filter in _ShopFilter.values)
        HollowChip(
          label: _filterLabel(filter),
          selected: _filter == filter,
          onTap: () => setState(() => _filter = filter),
        ),
    ];

    // Nothing here is the primary action: buying happens on a card, and these
    // four are utilities. An action row with no primary is all ghost, so the
    // two outlines went, and the bare pressable became a button like its
    // neighbours.
    final actions = [
      HollowButton.ghost(
        onPressed: _openInBrowser,
        compact: true,
        icon: const Icon(LucideIcons.externalLink, size: 14),
        child: const Text('Open in browser'),
      ),
      const SizedBox(width: HollowSpacing.sm),
      HollowButton.ghost(
        onPressed: () => showRedeemEntryDialog(context),
        compact: true,
        icon: const Icon(LucideIcons.ticket, size: 14),
        child: const Text('Redeem a code'),
      ),
      const SizedBox(width: HollowSpacing.sm),
      HollowButton.ghost(
        onPressed: () => pickAndImportHollowpack(context, ref),
        compact: true,
        icon: const Icon(LucideIcons.packageOpen, size: 14),
        child: const Text('Import a pack'),
      ),
      const SizedBox(width: HollowSpacing.sm),
      HollowTooltip(
        message: 'Refresh the shop',
        child: HollowButton.ghost(
          semanticLabel: 'Refresh the shop',
          compact: true,
          onPressed: () {
            ref.invalidate(shop.shopCatalogProvider);
            // The catalog is fetched fresh every time, so the toast is the only
            // sign the tap did anything when nothing on the wall changed.
            HollowToast.show(context, 'Shop refreshed');
          },
          child: const Icon(LucideIcons.refreshCw, size: 16),
        ),
      ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: hollow.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Narrow: the pills take their own line rather than fighting the
          // buttons for width.
          final stacked = constraints.maxWidth < 620;
          final title = widget.embedded
              ? null
              : Text('Hollow Shop',
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary));

          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (title != null) ...[
                  title,
                  const SizedBox(height: HollowSpacing.sm),
                ],
                Row(children: [const Spacer(), ...actions]),
                const SizedBox(height: HollowSpacing.sm),
                Wrap(
                  spacing: HollowSpacing.sm,
                  runSpacing: HollowSpacing.xs,
                  children: pills,
                ),
              ],
            );
          }

          return Row(
            children: [
              if (title != null) ...[
                title,
                const SizedBox(width: HollowSpacing.lg),
              ],
              // Takes the free width, doubling as the Spacer that pushes the
              // actions right.
              Expanded(
                child: Wrap(
                  spacing: HollowSpacing.sm,
                  runSpacing: HollowSpacing.xs,
                  children: pills,
                ),
              ),
              ...actions,
            ],
          );
        },
      ),
    );
  }

  String _filterLabel(_ShopFilter filter) {
    switch (filter) {
      case _ShopFilter.all:
        return 'All';
      case _ShopFilter.frames:
        return 'Frames';
      case _ShopFilter.avatars:
        return 'Avatars';
      case _ShopFilter.banners:
        return 'Banners';
      case _ShopFilter.bundles:
        return 'Bundles';
    }
  }

  Widget _wrapDropTarget(HollowTheme hollow, Widget child) {
    if (_isMobile) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _handleDrop,
      child: Stack(
        children: [
          child,
          if (_dragging)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: hollow.background.withValues(alpha: 0.85),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.xl,
                      vertical: HollowSpacing.lg,
                    ),
                    decoration: BoxDecoration(
                      color: hollow.surface,
                      borderRadius: BorderRadius.circular(hollow.radiusLg),
                      border: Border.all(color: hollow.accent, width: 2),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.packageOpen,
                            size: 40, color: hollow.accent),
                        const SizedBox(height: HollowSpacing.sm),
                        Text(
                          'Drop a .hollowpack to import',
                          style: HollowTypography.subheading
                              .copyWith(color: hollow.textPrimary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(HollowTheme hollow) {
    final catalog = ref.watch(shop.shopCatalogProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _artistStrip(hollow),
        Expanded(
          child: catalog.when(
            loading: () => const Center(child: HollowSpinner.large()),
            error: (error, _) => _buildError(hollow, error),
            data: (data) => _buildGrid(hollow, data),
          ),
        ),
      ],
    );
  }

  Widget _buildError(HollowTheme hollow, Object error) {
    final message = error.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'The shop could not be reached',
              style: HollowTypography.subheading
                  .copyWith(color: hollow.textPrimary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              message,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: HollowSpacing.lg),
            HollowButton.outline(
              onPressed: () => ref.invalidate(shop.shopCatalogProvider),
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGrid(HollowTheme hollow, shop.ShopCatalog catalog) {
    final listings = catalog.listings.where(_matches).toList();
    if (listings.isEmpty) {
      return HollowEmptyState(
        title: catalog.listings.isEmpty
            ? 'Nothing is on sale yet'
            : 'Nothing here yet',
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 240,
        mainAxisSpacing: HollowSpacing.md,
        crossAxisSpacing: HollowSpacing.md,
        childAspectRatio: 0.74,
      ),
      itemCount: listings.length,
      itemBuilder: (context, index) {
        final listing = listings[index];
        return _ShopCard(key: ValueKey(listing.slug), listing: listing);
      },
    );
  }
}

class _ShopCard extends ConsumerWidget {
  final shop.ShopListing listing;

  const _ShopCard({super.key, required this.listing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Owned means BOUGHT: this identity redeemed a code and holds the listing's
    // credential. A pack in the library is not ownership, since a friend can
    // hand you the files but nobody can hand you the mark.
    final bought = ref.watch(shop.ownCredentialItemsProvider);
    final isOwned = listing.credentialItem.isNotEmpty &&
        bought.contains(listing.credentialItem);

    return HollowPressable(
      semanticLabel:
          '${listing.title} by ${listing.artist.displayName}, ${listing.priceLabel}',
      onTap: () => showShopItemDialog(context, listing),
      borderRadius: BorderRadius.circular(hollow.radiusLg),
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          // A background step, not a step AND a hairline: the art fills the
          // tile, so the boundary is never in doubt and an outline on top of it
          // only makes the wall read as a grid of boxes.
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusLg),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The art IS the card, so it takes the whole slot the caption
            // leaves rather than a fixed 96px floating in the middle of it.
            // Measured rather than given a hard AspectRatio, because the cell
            // height comes from the grid delegate and a square that does not
            // fit would overflow the text below.
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(HollowSpacing.sm),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final side = constraints.maxWidth < constraints.maxHeight
                        ? constraints.maxWidth
                        : constraints.maxHeight;
                    return Center(
                      child: SizedBox(
                        width: side,
                        height: side,
                        child: ShopArtPreview(
                          listing: listing,
                          size: side,
                          neutralFace: true,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HollowSpacing.sm,
                0,
                HollowSpacing.sm,
                HollowSpacing.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    listing.title,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'by ${listing.artist.displayName}',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: HollowSpacing.xs),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // The price group gives way before the chips do: a narrow
                      // card scales the numbers rather than cutting a chip in
                      // half, which would say nothing at all.
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (listing.wasLabel.isNotEmpty) ...[
                                // On sale: the list price, struck, right before
                                // what a buyer pays.
                                Text(
                                  listing.wasLabel,
                                  style: HollowTypography.caption.copyWith(
                                    color: hollow.textTertiary,
                                    decoration: TextDecoration.lineThrough,
                                  ),
                                ),
                                const SizedBox(width: HollowSpacing.xs),
                              ],
                              Text(
                                listing.priceLabel,
                                style: HollowTypography.body.copyWith(
                                  color: hollow.accentText,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      // The badges are one group at the trailing edge. Left as
                      // siblings of the price, spaceBetween spreads all three
                      // evenly and strands the kind in the middle of the row.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          HollowBadge(
                            listing.bundle
                                ? 'bundle'
                                : (listing.primaryKind.isEmpty
                                    ? 'art'
                                    : listing.primaryKind),
                          ),
                          if (isOwned) ...[
                            const SizedBox(width: HollowSpacing.xs),
                            const HollowBadge('Owned',
                                kind: HollowBadgeKind.success),
                          ],
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Teal strip below the header: the one sentence a buyer should read before the
/// wall, in the accent colour with a heart rather than a warning. `accentText`
/// for both glyph and copy, because raw `accent` is a fill.
Widget _artistStrip(HollowTheme hollow) {
  final color = hollow.accentText;
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: HollowSpacing.lg,
      vertical: 10,
    ),
    decoration: BoxDecoration(
      color: hollow.accent.withValues(alpha: 0.08),
      border: Border(
        bottom: BorderSide(color: hollow.border.withValues(alpha: 0.3)),
      ),
    ),
    child: Row(
      children: [
        Icon(LucideIcons.heart, size: 14, color: color),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            'Avatars, banners and frames drawn by real people. The artist '
            'gets 100% of every sale, and the art is yours to keep: '
            'real files without DRM.',
            style: HollowTypography.caption.copyWith(
              color: color,
              fontSize: 11,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The preview for a listing's primary kind. Shared by the wall (still, 96px)
/// and the item dialog (bigger, and the avatar animates there).
class ShopArtPreview extends ConsumerWidget {
  final shop.ShopListing listing;
  final double size;

  /// The wall stays still; the dialog is where a person is actually looking.
  final bool animate;

  /// Render this kind instead of the listing's primary one, so a bundle can
  /// show one preview per kind.
  final String? kindOverride;

  /// A frame on the WALL sits over a neutral face, so the frame itself is what
  /// the card shows. The item dialog leaves this false and puts the frame on
  /// your own avatar, which is the question that dialog answers.
  final bool neutralFace;

  const ShopArtPreview({
    super.key,
    required this.listing,
    required this.size,
    this.animate = false,
    this.kindOverride,
    this.neutralFace = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';
    final kind = kindOverride ?? listing.primaryKind;

    Widget placeholder() => Container(
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
        );

    Widget failed() => Container(
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
          alignment: Alignment.center,
          child: Icon(LucideIcons.imageOff, size: 20, color: hollow.textTertiary),
        );

    // Hover means the ROW (the card's HollowPressable publishes it): at rest
    // the still, hovered the animation, and the item dialog always plays.
    final wantAnim = animate || (HoverScope.maybeOf(context) ?? false);

    // For a bundle the display hash is the primary kind's art; another kind
    // falls back to the file that carries it.
    final hash = _hashFor(kind, wantAnim);
    if (hash.isEmpty) return placeholder();

    final art = ref.watch(shop.shopArtProvider(hash));
    // The first hover asks the shop for the animation; the still keeps painting
    // until it lands.
    final stillHash = _hashFor(kind, false);
    final Uint8List? fallback = wantAnim && stillHash != hash
        ? ref.watch(shop.shopArtProvider(stillHash)).valueOrNull
        : null;
    final bytes = art.valueOrNull ?? fallback;
    if (bytes == null) {
      return art.hasError ? failed() : placeholder();
    }
    if (bytes.isEmpty) return failed();

    if (kind == 'frame') {
      // Frame art has to be judged in front of a face, so it is seeded into the
      // shared frame cache (RAM only) and painted by the avatar.
      final seeded =
          ref.watch(avatarFrameProvider.select((m) => m.containsKey(hash)));
      if (!seeded) {
        final frames = ref.read(avatarFrameProvider.notifier);
        Future.microtask(() => frames.seed(hash, bytes));
      }
      if (neutralFace) {
        final face = Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Color.alphaBlend(
              Colors.white.withValues(alpha: 0.14),
              hollow.elevated,
            ),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(
              color: hollow.accent.withValues(alpha: 0.65),
              width: 1,
            ),
          ),
        );
        return Center(
          child: AvatarFrame(
            id: hash,
            size: size,
            radius: hollow.radiusMd,
            animate: wantAnim,
            child: face,
          ),
        );
      }
      return Center(
        child: HollowAvatar(
          peerId: me,
          size: size,
          frameId: hash,
          animate: wantAnim,
        ),
      );
    }
    if (kind == 'avatar') {
      return Center(
        child: HollowAvatar(
          peerId: me,
          size: size,
          imageBytes: bytes,
          frameId: '',
          animate: wantAnim,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      child: AnimatedGifImage(
        bytes: bytes,
        fit: listing.wide ? BoxFit.contain : BoxFit.cover,
        animate: wantAnim,
        errorWidget: failed(),
      ),
    );
  }

  /// The art to show for [kind]. At rest the still sibling wins, so a grid of
  /// cards is not a grid of running animations.
  String _hashFor(String kind, bool wantAnim) {
    if (kindOverride == null || kindOverride == listing.primaryKind) {
      if (!wantAnim && listing.stillHash.isNotEmpty) {
        return listing.stillHash;
      }
      return listing.displayHash;
    }
    for (final file in listing.files) {
      if (file.role == kind ||
          file.role == '${kind}_still' ||
          file.role == '${kind}_anim') {
        return file.sha256;
      }
    }
    return listing.displayHash;
  }
}
