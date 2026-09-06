import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/shop/shop_dashboard.dart' show ShopArtPreview;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// One listing, big enough to judge: the art, who drew it, what the licence
/// says, and either Buy (which leaves for the browser) or Wear it.
Future<void> showShopItemDialog(
  BuildContext context,
  shop.ShopListing listing,
) {
  return showHollowDialog<void>(
    context: context,
    builder: (_) => _ShopItemDialog(listing: listing),
  );
}

class _ShopItemDialog extends ConsumerStatefulWidget {
  final shop.ShopListing listing;

  const _ShopItemDialog({required this.listing});

  @override
  ConsumerState<_ShopItemDialog> createState() => _ShopItemDialogState();
}

class _ShopItemDialogState extends ConsumerState<_ShopItemDialog> {
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

  Future<void> _buy() async {
    final uri = Uri.tryParse(widget.listing.itemUrl);
    if (uri == null) return;
    setState(() => _busy = true);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      HollowToast.show(context, 'Opening the shop in your browser',
          type: HollowToastType.info);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'That link could not be opened: $e',
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wear(OwnedItem item) async {
    setState(() => _busy = true);
    try {
      // Wear what THIS listing sells, from the item that covers it: wearing a
      // single avatar out of a bundle's pack must not put the frame on too.
      final kinds = item.kinds.toSet().intersection(widget.listing.kinds.toSet());
      await ref
          .read(ownedArtProvider.notifier)
          .wear(item, kinds.isEmpty ? item.kinds.toSet() : kinds);
      if (!mounted) return;
      HollowToast.show(context, 'Wearing ${item.title}',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
      HollowToast.show(context, message, type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openArtist() async {
    final url = widget.listing.artist.url;
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _preview(String kind) {
    if (kind == 'banner') {
      return Padding(
        padding: const EdgeInsets.only(bottom: HollowSpacing.md),
        child: AspectRatio(
          aspectRatio: 2.5,
          child: ShopArtPreview(
            listing: widget.listing,
            size: 128,
            animate: true,
            kindOverride: kind,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.md),
      child: Center(
        child: SizedBox(
          width: 128,
          height: 128,
          child: ShopArtPreview(
            listing: widget.listing,
            size: 128,
            animate: true,
            kindOverride: kind,
          ),
        ),
      ),
    );
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
        ref.watch(shop.ownCredentialItemsProvider).contains(listing.credentialItem);
    // Watched, not read: importing the pack while this is open flips the action
    // from Buy to Wear it.
    ref.watch(ownedArtProvider);
    final owned = _ownedItem();

    final kinds = listing.bundle && listing.kinds.isNotEmpty
        ? listing.kinds
        : [
            listing.primaryKind.isEmpty
                ? (listing.kinds.isEmpty ? 'avatar' : listing.kinds.first)
                : listing.primaryKind
          ];

    return HollowDialog(
      title: listing.title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final kind in kinds) _preview(kind),
          if (listing.description.isNotEmpty) ...[
            Text(
              listing.description,
              style:
                  HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.md),
          ],
          if (listing.artist.url.isEmpty)
            Text(
              'by ${listing.artist.displayName}',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textSecondary),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: HollowPressable(
                onTap: _openArtist,
                semanticButton: false,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: EdgeInsets.zero,
                child: Text(
                  'by ${listing.artist.displayName}',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.accentText),
                ),
              ),
            ),
          if (listing.license.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.xs),
            Text(
              listing.license,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary, fontSize: 11),
            ),
          ],
          if (available) ...[
            const SizedBox(height: HollowSpacing.md),
            Row(
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
                Text(
                  listing.priceLabel,
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.accentText),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        HollowButton.ghost(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        // Never a price or a Buy button on a store build; the dashboard is
        // already gone there, and this is the second lock.
        if (available) ...[
          if (owned != null)
            HollowButton.filled(
              onPressed: _busy ? null : () => _wear(owned),
              icon: _busy
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: hollow.textSecondary,
                      ),
                    )
                  : null,
              child: const Text('Wear it'),
            ),
          // Beside Wear it, Buy is the quieter button.
          if (!bought)
            owned != null
                ? HollowButton.outline(
                    onPressed: _busy ? null : _buy,
                    icon: const Icon(LucideIcons.externalLink, size: 14),
                    child: const Text('Buy'),
                  )
                : HollowButton.filled(
                    onPressed: _busy ? null : _buy,
                    icon: const Icon(LucideIcons.externalLink, size: 14),
                    child: const Text('Buy'),
                  ),
        ],
      ],
    );
  }
}
