import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/services/untrusted_link.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_card.dart';
import 'package:hollow/src/ui/components/hollow_checkbox.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';
import 'package:hollow/src/ui/shop/shop_art.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// One listing, shown on your own profile: what it is, who made it, what it
/// costs, and either Buy (the artist's Ko-fi, in the browser) or Wear it. A
/// dialog on desktop, a sheet on a phone; the shop website's item sheet draws
/// the same content in the same order.
Future<void> showShopItem(BuildContext context, shop.ShopListing listing) {
  if (isShopPhone) {
    return showHollowSheet<void>(
      context: context,
      scrollControlled: true,
      builder: (_) => _ShopItemView(listing: listing, sheet: true),
    );
  }
  return showHollowDialog<void>(
    context: context,
    builder: (_) => _ShopItemView(listing: listing, sheet: false),
  );
}

/// The buyer agrees to this before paying: in the EU the right to cancel a
/// digital item ends only on that agreement, and Buy in the app goes straight
/// to the artist's Ko-fi, so this box is the only place an app buyer gives it.
const String kShopConsent =
    'I want my code right away, and I understand that I give up my 14-day '
    'right to cancel.';

const String kShopKofiUpfront =
    'You pay on Ko-fi. Your code for the supporter badge arrives by email '
    'within a minute.';

const String kShopSeeAllWork = 'See all their work';

/// A piece with no Ko-fi item behind it cannot be bought, so the sheet says that
/// instead of offering a button that leads nowhere.
const String kShopNotOnSale = 'Not on sale right now.';

/// What a screen reader hears on Buy while the box above is unticked.
const String kShopBuyWaitsHint = 'Tick the box above to buy';

const double _kTryOnWidth = 320;
const double _kDialogWidth = 820;

/// Below this the dialog stacks like the phone sheet instead of two columns.
const double _kTwoColumnMin = 640;

const double _kArtistFace = 48;

/// Touch layout: a sheet instead of a dialog, full-width buttons. Read from
/// the target platform so a widget test can render the phone.
bool get isShopPhone =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

String _kindLabel(shop.ShopListing listing) {
  if (listing.bundle) return 'Bundle';
  return switch (listing.primaryKind) {
    'avatar' => 'Avatar',
    'frame' => 'Frame',
    'banner' => 'Banner',
    _ => 'Art',
  };
}

Future<void> _open(BuildContext context, String url) async {
  if (await openUntrustedUrl(url)) return;
  if (!context.mounted) return;
  HollowToast.show(context, 'That link could not be opened',
      type: HollowToastType.error);
}

class _ShopItemView extends ConsumerStatefulWidget {
  final shop.ShopListing listing;
  final bool sheet;

  const _ShopItemView({required this.listing, required this.sheet});

  @override
  ConsumerState<_ShopItemView> createState() => _ShopItemViewState();
}

class _ShopItemViewState extends ConsumerState<_ShopItemView> {
  bool _busy = false;

  /// Lives with this route, so every piece opened asks again.
  bool _agreed = false;

  /// The imported item that covers EVERY file this listing sells, if any. One
  /// shared file is not enough: a single's pack does not cover the bundle that
  /// carries it, while the bundle's pack does cover the single.
  OwnedItem? _ownedItem() {
    final wanted = {for (final file in widget.listing.files) file.sha256};
    if (wanted.isEmpty) return null;
    for (final item in ref.read(ownedArtProvider)) {
      if (item.hashes.toSet().containsAll(wanted)) return item;
    }
    return null;
  }

  bool get _sellsOnKofi => widget.listing.buyUrl.isNotEmpty;

  Future<void> _buy() async {
    // Straight to the artist's Ko-fi item: the shop's own page would only
    // show the same piece again and send the buyer on.
    try {
      if (!await openUntrustedUrl(widget.listing.buyUrl)) {
        throw const FormatException('No browser took the link');
      }
      if (!mounted) return;
      HollowToast.show(context, 'Opening Ko-fi in your browser',
          type: HollowToastType.info);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'That link could not be opened',
          type: HollowToastType.error);
    }
  }

  Future<void> _wear(OwnedItem item) async {
    setState(() => _busy = true);
    try {
      // Wear what THIS listing sells, from the item that covers it: wearing a
      // single avatar out of a bundle's pack must not put the frame on too.
      final kinds =
          item.kinds.toSet().intersection(widget.listing.kinds.toSet());
      await ref
          .read(ownedArtProvider.notifier)
          .wear(item, kinds.isEmpty ? item.kinds.toSet() : kinds);
      if (!mounted) return;
      HollowToast.show(context, 'Wearing ${item.title}',
          type: HollowToastType.success);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(
          context,
          friendlyError(e,
              fallback: "Couldn't put this on your profile. Try again."),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _redeem() {
    Navigator.of(context).pop();
    showRedeemEntryDialog(context);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final listing = widget.listing;
    final available = ref.watch(shopAvailableProvider);
    final origin = ref.watch(shop.shopCatalogProvider).valueOrNull?.origin ??
        ref.watch(shop.shopOriginProvider).valueOrNull ??
        '';
    // Bought means a credential for THIS listing was redeemed by this identity.
    // The library, which anyone could have handed over, only decides whether
    // Wear it is offered; Buy stays until the piece is bought.
    final bought = listing.credentialItem.isNotEmpty &&
        ref
            .watch(shop.ownCredentialItemsProvider)
            .contains(listing.credentialItem);
    // Watched, not read: importing the pack while this is open flips the action
    // from Buy to Wear it.
    ref.watch(ownedArtProvider);
    final owned = _ownedItem();
    // Never a price, a Buy button or a way out to the shop on a store build;
    // the page is already gone there, and this is the second lock.
    final forSale = available && !bought;
    // Like the site: without a Ko-fi item there is nothing to buy, so no Buy
    // and no box, only a line that says so.
    final showBuy = forSale && _sellsOnKofi;
    final notOnSale = forSale && !_sellsOnKofi;
    final touch = widget.sheet;

    final Widget? buy = !showBuy
        ? null
        : _buyButton(
            primary: owned == null,
            enabled: !_busy && _agreed,
            touch: touch,
          );
    final Widget? wear = owned == null
        ? null
        : HollowButton.filled(
            onPressed: _busy ? null : () => _wear(owned),
            loading: _busy,
            touch: touch,
            expand: touch,
            child: const Text('Wear it'),
          );
    final Widget? redeem = forSale && owned == null
        ? HollowButton.ghost(
            onPressed: _redeem,
            touch: touch,
            expand: touch,
            child: const Text('Redeem a code'),
          )
        : null;
    // The primary first: these sit in the content, read from the left.
    final actions = [wear, buy, redeem].whereType<Widget>().toList();

    final tryOn = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ShopTryOnCard(listing: listing),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          listing.primaryKind == 'frame' && !listing.bundle
              ? 'On your avatar, as people will see it'
              : 'On your profile, as people will see it',
          style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
        ),
      ],
    );

    final secondary =
        HollowTypography.bodySmall.copyWith(color: hollow.textSecondary);
    final artistRoom = available ? listing.artist.url : '';

    final buying = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          // Clear of the close button that floats over this corner.
          padding: EdgeInsetsDirectional.only(
              end: widget.sheet ? 0 : HollowSpacing.xxl + HollowSpacing.sm),
          child: Text(listing.title,
              style:
                  HollowTypography.heading.copyWith(color: hollow.textPrimary)),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('by',
                    style: HollowTypography.label
                        .copyWith(color: hollow.textSecondary)),
                const SizedBox(width: HollowSpacing.xs),
                Flexible(
                  child: artistRoom.isEmpty
                      ? Text(listing.artist.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: HollowTypography.label
                              .copyWith(color: hollow.textPrimary))
                      : HollowTextLink(listing.artist.displayName,
                          onTap: () => _open(context, artistRoom)),
                ),
              ],
            ),
            HollowBadge(_kindLabel(listing)),
            if (bought)
              const HollowBadge('Owned', kind: HollowBadgeKind.success),
          ],
        ),
        if (available) ...[
          const SizedBox(height: HollowSpacing.lg),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              if (listing.wasLabel.isNotEmpty) ...[
                Text(
                  listing.wasLabel,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textTertiary,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
              ],
              Text(listing.priceLabel,
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary)),
            ],
          ),
        ],
        if (listing.description.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.md),
          HollowDialogText(listing.description),
        ],
        if (showBuy) ...[
          const SizedBox(height: HollowSpacing.lg),
          HollowCheckbox(
            value: _agreed,
            onChanged: (v) => setState(() => _agreed = v),
            label: kShopConsent,
            footer: origin.isEmpty
                ? null
                : Wrap(
                    spacing: HollowSpacing.md,
                    runSpacing: HollowSpacing.xs,
                    children: [
                      HollowTextLink('Terms',
                          quiet: true,
                          onTap: () => _open(context, '$origin/terms')),
                      HollowTextLink('Refunds',
                          quiet: true,
                          onTap: () => _open(context, '$origin/refunds')),
                    ],
                  ),
          ),
        ],
        if (actions.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          if (touch)
            for (final (i, button) in actions.indexed) ...[
              if (i > 0) const SizedBox(height: HollowSpacing.sm),
              button,
            ]
          else
            Wrap(
              spacing: HollowSpacing.sm,
              runSpacing: HollowSpacing.sm,
              children: actions,
            ),
        ],
        if (showBuy) ...[
          const SizedBox(height: HollowSpacing.md),
          Text(kShopKofiUpfront, style: secondary),
        ],
        if (notOnSale) ...[
          const SizedBox(height: HollowSpacing.md),
          Text(kShopNotOnSale, style: secondary),
        ],
        if (bought && owned == null) ...[
          const SizedBox(height: HollowSpacing.md),
          Text(
            'You bought this. Import the pack from your receipt to wear it.',
            style: secondary,
          ),
        ],
      ],
    );

    // The piece's terms and its maker: under the preview on desktop, last on
    // a phone, after the buying decision.
    final about = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (listing.license.isNotEmpty) ...[
          Text(listing.license,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textTertiary)),
          const SizedBox(height: HollowSpacing.lg),
        ],
        _ArtistCard(artist: listing.artist, outbound: available),
      ],
    );

    // One column: the preview, the buying decision, then the piece's terms and
    // its maker. Two columns put those last two under the preview instead.
    final stacked = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        tryOn,
        const SizedBox(height: HollowSpacing.lg),
        buying,
        const SizedBox(height: HollowSpacing.xl),
        const HollowDivider(),
        const SizedBox(height: HollowSpacing.lg),
        about,
      ],
    );

    if (widget.sheet) {
      return SingleChildScrollView(
        padding: EdgeInsets.only(
          left: HollowSpacing.lg,
          right: HollowSpacing.lg,
          // The artist's links sit last: keep them out of the gesture bar.
          bottom: HollowSpacing.lg + MediaQuery.viewPaddingOf(context).bottom,
        ),
        child: stacked,
      );
    }

    return HollowDialogSurface(
      width: _kDialogWidth,
      child: Stack(
        children: [
          SingleChildScrollView(
            child: LayoutBuilder(builder: (context, constraints) {
              // Stacked, the preview leads, so the close button gets a band of
              // its own above it instead of floating over the art.
              if (constraints.maxWidth < _kTwoColumnMin) {
                return Padding(
                  padding: const EdgeInsets.only(
                      top: HollowSpacing.xxl + HollowSpacing.sm),
                  child: stacked,
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: _kTryOnWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        tryOn,
                        const SizedBox(height: HollowSpacing.xl),
                        about,
                      ],
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.xl),
                  Expanded(child: buying),
                ],
              );
            }),
          ),
          const PositionedDirectional(
            top: 0,
            end: 0,
            child: HollowDialogCloseButton(),
          ),
        ],
      ),
    );
  }

  Widget _buyButton(
      {required bool primary, required bool enabled, required bool touch}) {
    const label = Text('Buy on Ko-fi');
    const icon = Icon(LucideIcons.externalLink, size: 14);
    final onPressed = enabled ? _buy : null;
    // Beside Wear it, Buy is the quieter button.
    final button = primary
        ? HollowButton.filled(
            onPressed: onPressed,
            touch: touch,
            expand: touch,
            icon: icon,
            child: label,
          )
        : HollowButton.outline(
            onPressed: onPressed,
            touch: touch,
            expand: touch,
            icon: icon,
            child: label,
          );
    // A screen reader hears why Buy is dimmed, as the site's aria-describedby says.
    return MergeSemantics(
      child: Semantics(hint: _agreed ? null : kShopBuyWaitsHint, child: button),
    );
  }
}

/// The artist under the piece: the shop sells their work, so who they are is
/// part of what is being bought. Every string here is the artist's own, cut
/// and cleaned in Rust; links leave the app only on a tap.
class _ArtistCard extends StatelessWidget {
  final shop.ShopArtist artist;

  /// False on a store build: no way out to the shop or the artist's links.
  final bool outbound;

  const _ArtistCard({required this.artist, required this.outbound});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final links = outbound ? artist.links : const <shop.ShopLink>[];
    final room = outbound ? artist.url : '';
    // A square is a place for a face, so the avatar wins over the header.
    final face =
        artist.avatarHash.isNotEmpty ? artist.avatarHash : artist.headerHash;

    // A step up from the dialog's overlay, like the site's artist block.
    return HollowCard(
      color: hollow.hover,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ShopArtistFace(hash: face, size: _kArtistFace),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      artist.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.label.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600),
                    ),
                    if (artist.bio.isNotEmpty) ...[
                      const SizedBox(height: HollowSpacing.xxs),
                      Text(
                        artist.bio,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.bodySmall
                            .copyWith(color: hollow.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (links.isNotEmpty || room.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Wrap(
                    spacing: HollowSpacing.md,
                    runSpacing: HollowSpacing.xs,
                    children: [
                      for (final link in links)
                        HollowTooltip(
                          // The label is the artist's word; the host is where
                          // the tap actually goes.
                          message: Uri.tryParse(link.url)?.host ?? link.url,
                          child: HollowTextLink(link.label,
                              quiet: true,
                              onTap: () => _open(context, link.url)),
                        ),
                    ],
                  ),
                ),
                if (room.isNotEmpty) ...[
                  const SizedBox(width: HollowSpacing.md),
                  HollowTextLink(kShopSeeAllWork,
                      onTap: () => _open(context, room)),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }
}
