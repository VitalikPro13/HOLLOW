import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_skeleton.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/shop/hollowpack_import.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';
import 'package:hollow/src/ui/shop/shop_art.dart';
import 'package:hollow/src/ui/shop/shop_item_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// The Hollow Shop: one shelf per kind, each kind at its own shape, pulled
/// from the signed catalog.
///
/// Buying happens on the artist's Ko-fi and comes back as a code redeemed or a
/// `.hollowpack` imported here; nothing on this page unlocks anything. Renders
/// nothing at all when the shop is unavailable, which is defence in depth: a
/// store build has no button that reaches this page either.
class ShopDashboard extends ConsumerStatefulWidget {
  /// Pushed as a phone page whose app bar already names it, so the page skips
  /// its own title.
  final bool embedded;

  const ShopDashboard({super.key, this.embedded = false});

  @override
  ConsumerState<ShopDashboard> createState() => _ShopDashboardState();
}

/// Below this a square tile stops reading as the art, so a column goes.
const double _kMinTile = 200;

const _kShelfTitles = {
  ShopShelf.avatars: 'Avatars',
  ShopShelf.frames: 'Frames',
  ShopShelf.banners: 'Banners',
  ShopShelf.bundles: 'Bundles',
};

class _ShopDashboardState extends ConsumerState<ShopDashboard> {
  /// Null shows every shelf, one row each.
  ShopShelf? _filter;
  bool _framesOnMe = false;
  bool _dragging = false;

  bool get _isMobile => isShopPhone;

  Future<void> _openInBrowser() async {
    // Awaited, not `valueOrNull`: nothing watches the origin, so the first
    // read only STARTED the lookup and the first tap did nothing.
    try {
      final origin = await ref.read(shop.shopOriginProvider.future);
      final uri = Uri.tryParse(origin);
      if (origin.isEmpty || uri == null) {
        throw const FormatException('The shop has no address');
      }
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const FormatException('No browser took the link');
      }
      if (!mounted) return;
      HollowToast.show(context, 'Opening the shop in your browser',
          type: HollowToastType.info);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'The shop could not be opened',
          type: HollowToastType.error);
    }
  }

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (details.files.isEmpty) return;
    final path = details.files.first.path;
    if (path.isEmpty) return;
    await importHollowpackAt(context, ref, path);
  }

  void _showMore(BuildContext buttonContext) {
    showHollowMenu(
      context: buttonContext,
      alignEnd: true,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(buttonContext.size?.width ?? 0,
              buttonContext.size?.height ?? 0)),
      builder: (_, _) => [
        HollowMenuItem(
          icon: LucideIcons.packageOpen,
          label: 'Import a pack',
          onTap: () => pickAndImportHollowpack(context, ref),
        ),
        HollowMenuItem(
          icon: LucideIcons.externalLink,
          label: 'Open the shop in your browser',
          onTap: _openInBrowser,
        ),
        HollowMenuItem(
          icon: LucideIcons.refreshCw,
          label: 'Refresh',
          onTap: () async {
            ref.invalidate(shop.shopCatalogProvider);
            // The catalog is fetched fresh every time, so the toast is the
            // only sign the tap did anything when nothing on the wall changed.
            try {
              await ref.read(shop.shopCatalogProvider.future);
            } catch (_) {
              return; // The page shows the failure itself.
            }
            if (mounted) HollowToast.show(context, 'Shop refreshed');
          },
        ),
        // The phone's Profile is one tap back in Settings; the desktop's is a
        // place away.
        if (!_isMobile) ...[
          const HollowMenuDivider(),
          HollowMenuItem(
            icon: LucideIcons.user,
            label: 'Your art in Settings',
            onTap: () =>
                openSettings(ref.read, category: SettingsCategory.profile),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(shopAvailableProvider)) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    return ColoredBox(
      color: hollow.background,
      child: _wrapDropTarget(
        hollow,
        LayoutBuilder(
          builder: (context, constraints) =>
              _buildPage(hollow, constraints.maxWidth),
        ),
      ),
    );
  }

  Widget _buildPage(HollowTheme hollow, double width) {
    final touch = widget.embedded && _isMobile;
    final pad = touch ? HollowSpacing.lg : HollowSpacing.xl;
    // Cards carry an xs inset for their hover, so the grid sits xs further out
    // and the ART lines up with the headings.
    final gridPad = pad - HollowSpacing.xs;
    final content = width - pad * 2;
    final squareCols =
        ((content + HollowSpacing.lg) / (_kMinTile + HollowSpacing.lg))
            .floor()
            .clamp(2, 12);
    final wideCols = squareCols >= 4 ? 2 : 1;

    final catalog = ref.watch(shop.shopCatalogProvider);
    final children = <Widget>[
      _buildHeader(hollow, pad, touch),
      _buildFilters(pad, touch),
      ...catalog.when(
        loading: () => _skeletonShelves(pad, gridPad, squareCols, wideCols),
        error: (error, _) => [_buildError(error, retrying: catalog.isLoading)],
        data: (data) =>
            _buildShelves(hollow, data, pad, gridPad, squareCols, wideCols),
      ),
      const SizedBox(height: HollowSpacing.xxl),
    ];
    return ListView(children: children);
  }

  Widget _buildHeader(HollowTheme hollow, double pad, bool touch) {
    final intro = Text(
      'Avatars, banners and frames made by real people. The artist gets 100% '
      'of every sale, and the art is yours to keep: real files without DRM.',
      style: HollowTypography.body.copyWith(color: hollow.textSecondary),
    );
    // The one thing only the app can do: the purchase happens on Ko-fi, the
    // code it mails comes back here.
    final redeem = HollowButton.filled(
      onPressed: () => showRedeemEntryDialog(context),
      touch: touch,
      icon: const Icon(LucideIcons.ticket, size: 16),
      child: const Text('Redeem a code'),
    );
    final more = Builder(
      builder: (buttonContext) => HollowIconButton(
        icon: LucideIcons.moreHorizontal,
        label: 'More shop actions',
        size: touch ? 44 : 32,
        onPressed: () => _showMore(buttonContext),
      ),
    );

    if (widget.embedded) {
      return Padding(
        padding: EdgeInsets.only(left: pad, top: HollowSpacing.lg, right: pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            intro,
            const SizedBox(height: HollowSpacing.lg),
            Row(children: [redeem, const Spacer(), more]),
          ],
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(left: pad, top: HollowSpacing.xl, right: pad),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Hollow Shop',
                    style: HollowTypography.heading
                        .copyWith(color: hollow.textPrimary)),
                const SizedBox(height: HollowSpacing.xs),
                // Prose keeps a reading measure; the page itself runs to the
                // pane's edges.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: intro,
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.lg),
          redeem,
          const SizedBox(width: HollowSpacing.sm),
          more,
        ],
      ),
    );
  }

  Widget _buildFilters(double pad, bool touch) {
    final chips = [
      HollowChip(
        label: 'All',
        selected: _filter == null,
        onTap: () => setState(() => _filter = null),
      ),
      for (final shelf in ShopShelf.values)
        HollowChip(
          label: _kShelfTitles[shelf]!,
          selected: _filter == shelf,
          onTap: () => setState(() => _filter = shelf),
        ),
    ];
    final padding =
        EdgeInsets.fromLTRB(pad, HollowSpacing.xl, pad, HollowSpacing.xl);
    if (touch) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        child: Row(
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) const SizedBox(width: HollowSpacing.sm),
              chips[i],
            ],
          ],
        ),
      );
    }
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: HollowSpacing.sm,
        runSpacing: HollowSpacing.sm,
        children: chips,
      ),
    );
  }

  List<Widget> _buildShelves(
    HollowTheme hollow,
    shop.ShopCatalog catalog,
    double pad,
    double gridPad,
    int squareCols,
    int wideCols,
  ) {
    if (catalog.listings.isEmpty) {
      return const [HollowEmptyState(title: 'Nothing is on sale yet')];
    }
    final byShelf = {for (final s in ShopShelf.values) s: <shop.ShopListing>[]};
    for (final listing in catalog.listings) {
      byShelf[shelfOf(listing)]!.add(listing);
    }

    final out = <Widget>[];
    for (final shelf in ShopShelf.values) {
      if (_filter != null && _filter != shelf) continue;
      final listings = byShelf[shelf]!;
      if (listings.isEmpty) continue;
      final cols = isWideShelf(shelf) ? wideCols : squareCols;
      // All shows one row per shelf; a shelf's own filter shows everything.
      final shown = _filter == null ? listings.take(cols).toList() : listings;
      if (out.isNotEmpty) out.add(const SizedBox(height: HollowSpacing.xl));
      out.add(Padding(
        padding: EdgeInsets.symmetric(horizontal: pad),
        child: HollowSectionHeader(
          _kShelfTitles[shelf]!,
          count: '${listings.length}',
          action: _shelfAction(hollow, shelf, listings.length > shown.length),
        ),
      ));
      out.addAll(_tileRows(
        gridPad,
        cols,
        [
          for (final listing in shown)
            _ShopCard(
              key: ValueKey(listing.slug),
              listing: listing,
              shelf: shelf,
              framesOnMe: _framesOnMe,
            ),
        ],
      ));
    }
    if (out.isEmpty) {
      return const [HollowEmptyState(title: 'Nothing here yet')];
    }
    return out;
  }

  Widget? _shelfAction(HollowTheme hollow, ShopShelf shelf, bool more) {
    final frames = shelf == ShopShelf.frames;
    if (!frames && !more) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (frames) ...[
          Text('On my avatar',
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary)),
          const SizedBox(width: HollowSpacing.sm),
          HollowToggle(
            value: _framesOnMe,
            semanticLabel: 'Preview frames on my avatar',
            onChanged: (v) => setState(() => _framesOnMe = v),
          ),
        ],
        if (frames && more) const SizedBox(width: HollowSpacing.lg),
        if (more)
          HollowButton.ghost(
            compact: true,
            onPressed: () => setState(() => _filter = shelf),
            child: const Text('See all'),
          ),
      ],
    );
  }

  /// [tiles] in rows of [cols], equal widths, the last row left-aligned.
  List<Widget> _tileRows(double gridPad, int cols, List<Widget> tiles) {
    final rows = <Widget>[];
    for (var start = 0; start < tiles.length; start += cols) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: HollowSpacing.md));
      rows.add(Padding(
        padding: EdgeInsets.symmetric(horizontal: gridPad),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < cols; i++) ...[
              if (i > 0) const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: start + i < tiles.length
                    ? tiles[start + i]
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ));
    }
    return rows;
  }

  List<Widget> _skeletonShelves(
      double pad, double gridPad, int squareCols, int wideCols) {
    final out = <Widget>[];
    for (final shelf in ShopShelf.values) {
      if (_filter != null && _filter != shelf) continue;
      final wide = isWideShelf(shelf);
      if (out.isNotEmpty) out.add(const SizedBox(height: HollowSpacing.xl));
      out.add(Padding(
        padding: EdgeInsets.only(left: pad, right: pad, bottom: HollowSpacing.sm),
        child: const Align(
          alignment: Alignment.centerLeft,
          child: HollowSkeleton(height: HollowSpacing.lg, width: 120),
        ),
      ));
      out.addAll(_tileRows(gridPad, wide ? wideCols : squareCols, [
        for (var i = 0; i < (wide ? wideCols : squareCols); i++)
          _SkeletonCard(wide: wide),
      ]));
    }
    return out;
  }

  Widget _buildError(Object error, {required bool retrying}) {
    return HollowEmptyState(
      glyph: LucideIcons.wifiOff,
      title: 'The shop could not be reached',
      description: friendlyError(error,
          fallback: 'Check your connection and try again.'),
      action: HollowButton.ghost(
        onPressed: () => ref.invalidate(shop.shopCatalogProvider),
        loading: retrying,
        child: const Text('Try again'),
      ),
    );
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
                child: ColoredBox(
                  color: hollow.background,
                  child: const HollowEmptyState(
                    glyph: LucideIcons.packageOpen,
                    title: 'Drop a .hollowpack to import it',
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One listing: the art IS the card, full bleed, title and price beneath it.
class _ShopCard extends ConsumerWidget {
  final shop.ShopListing listing;
  final ShopShelf shelf;
  final bool framesOnMe;

  const _ShopCard({
    super.key,
    required this.listing,
    required this.shelf,
    required this.framesOnMe,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Owned means BOUGHT: this identity redeemed a code and holds the listing's
    // credential. A pack in the library is not ownership, since a friend can
    // hand you the files but nobody can hand you the mark.
    final bought = ref.watch(shop.ownCredentialItemsProvider);
    final isOwned = listing.credentialItem.isNotEmpty &&
        bought.contains(listing.credentialItem);

    final Widget art = switch (shelf) {
      ShopShelf.avatars || ShopShelf.banners =>
        ShopArtFill(listing: listing, kind: listing.primaryKind),
      ShopShelf.frames => ShopFrameArt(listing: listing, onMe: framesOnMe),
      ShopShelf.bundles => ShopBundleArt(listing: listing),
    };

    return HollowPressable(
      semanticLabel: '${listing.title} by ${listing.artist.displayName}, '
          '${listing.priceLabel}${isOwned ? ', owned' : ''}',
      semanticButton: false,
      onTap: () => showShopItem(context, listing),
      // Concentric with the art's radius across the xs inset.
      borderRadius: BorderRadius.circular(hollow.radiusXl),
      padding: const EdgeInsets.all(HollowSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            child: AspectRatio(
              aspectRatio: isWideShelf(shelf) ? kShopBannerAspect : 1,
              child: art,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xxs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        listing.title,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    if (listing.wasLabel.isNotEmpty) ...[
                      // On sale: the list price, struck, right before what a
                      // buyer pays.
                      Text(
                        listing.wasLabel,
                        style: HollowTypography.bodySmall.copyWith(
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
                const SizedBox(height: HollowSpacing.xxs),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'by ${listing.artist.displayName}',
                        style: HollowTypography.bodySmall
                            .copyWith(color: hollow.textSecondary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // The shelf already names the kind, so Owned is the one
                    // badge a card carries.
                    if (isOwned)
                      const HollowBadge('Owned', kind: HollowBadgeKind.success),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  final bool wide;
  const _SkeletonCard({required this.wide});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.all(HollowSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) => HollowSkeleton(
              height: constraints.maxWidth / (wide ? kShopBannerAspect : 1),
              radius: hollow.radiusLg,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          const FractionallySizedBox(
            widthFactor: 0.6,
            child: HollowSkeleton(height: HollowSpacing.md),
          ),
          const SizedBox(height: HollowSpacing.xs),
          const FractionallySizedBox(
            widthFactor: 0.35,
            child: HollowSkeleton(height: HollowSpacing.md),
          ),
        ],
      ),
    );
  }
}
