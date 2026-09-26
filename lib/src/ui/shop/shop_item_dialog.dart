import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';
import 'package:hollow/src/ui/shop/shop_art.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// One listing, shown on your own profile: who made it, what it costs, and
/// either Buy (the artist's Ko-fi, in the browser) or Wear it. A dialog on
/// desktop, a sheet on a phone.
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

const double _kTryOnWidth = 280;

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

class _ShopItemView extends ConsumerStatefulWidget {
  final shop.ShopListing listing;
  final bool sheet;

  const _ShopItemView({required this.listing, required this.sheet});

  @override
  ConsumerState<_ShopItemView> createState() => _ShopItemViewState();
}

class _ShopItemViewState extends ConsumerState<_ShopItemView> {
  bool _busy = false;

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
    final url = _sellsOnKofi ? widget.listing.buyUrl : widget.listing.itemUrl;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const FormatException('No browser took the link');
      }
      if (!mounted) return;
      HollowToast.show(
          context,
          _sellsOnKofi
              ? 'Opening Ko-fi in your browser'
              : 'Opening the shop in your browser',
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

  Future<void> _openArtist() async {
    final uri = Uri.tryParse(widget.listing.artist.url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
    // Never a price or a Buy button on a store build; the page is already gone
    // there, and this is the second lock.
    final showBuy = available && !bought;
    final buyLabel = Text(_sellsOnKofi ? 'Buy on Ko-fi' : 'Buy');
    const buyIcon = Icon(LucideIcons.externalLink, size: 14);
    final touch = widget.sheet;

    final Widget? buy = !showBuy
        ? null
        : owned != null
            // Beside Wear it, Buy is the quieter button.
            ? HollowButton.outline(
                onPressed: _busy ? null : _buy,
                touch: touch,
                expand: touch,
                icon: buyIcon,
                child: buyLabel,
              )
            : HollowButton.filled(
                onPressed: _busy ? null : _buy,
                touch: touch,
                expand: touch,
                icon: buyIcon,
                child: buyLabel,
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
    final Widget? redeem = showBuy && owned == null
        ? HollowButton.ghost(
            onPressed: _redeem,
            touch: touch,
            expand: touch,
            child: const Text('Redeem a code'),
          )
        : null;

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

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            HollowBadge(_kindLabel(listing)),
            if (bought) ...[
              const SizedBox(width: HollowSpacing.xs),
              const HollowBadge('Owned', kind: HollowBadgeKind.success),
            ],
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        if (listing.artist.url.isEmpty)
          Text('by ${listing.artist.displayName}',
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textSecondary))
        else
          HollowTextLink('by ${listing.artist.displayName}',
              onTap: _openArtist),
        if (available) ...[
          const SizedBox(height: HollowSpacing.md),
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
        if (listing.license.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(listing.license,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary)),
        ],
        if (bought && owned == null) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'You bought this. Import the pack from your receipt to wear it.',
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary),
          ),
        ],
      ],
    );

    if (widget.sheet) {
      return SingleChildScrollView(
        padding: const EdgeInsets.only(
          left: HollowSpacing.lg,
          right: HollowSpacing.lg,
          bottom: HollowSpacing.lg,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            tryOn,
            const SizedBox(height: HollowSpacing.lg),
            Text(listing.title,
                style: HollowTypography.heading
                    .copyWith(color: hollow.textPrimary)),
            const SizedBox(height: HollowSpacing.sm),
            details,
            const SizedBox(height: HollowSpacing.xl),
            // Primary first under the thumb; the quiet alternative below it.
            for (final button in [wear, buy, redeem].whereType<Widget>()) ...[
              button,
              const SizedBox(height: HollowSpacing.sm),
            ],
          ],
        ),
      );
    }

    return HollowDialog(
      title: listing.title,
      showClose: true,
      width: 680,
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: _kTryOnWidth, child: tryOn),
          const SizedBox(width: HollowSpacing.xl),
          Expanded(child: details),
        ],
      ),
      leadingActions: [?redeem],
      actions: [?buy, ?wear],
    );
  }
}
