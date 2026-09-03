import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/avatar_frame_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/shop_provider.dart' as shop;
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shop/hollowpack_import.dart';
import 'package:hollow/src/ui/shop/shop_dashboard.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// "Art you own": the packs this identity has imported, with one button per
/// wearable kind, plus any support codes kept for later.
///
/// Lives inside the profile settings on both shells, because that is where a
/// person goes to change how they look. Absent entirely on store builds.
class OwnedArtPanel extends ConsumerStatefulWidget {
  /// Mobile spacing and typography (the desktop settings dialog is wider and
  /// uses the settings section labels).
  final bool compact;

  const OwnedArtPanel({super.key, this.compact = false});

  @override
  ConsumerState<OwnedArtPanel> createState() => _OwnedArtPanelState();
}

class _OwnedArtPanelState extends ConsumerState<OwnedArtPanel> {
  bool _dragging = false;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  Future<void> _handleDrop(DropDoneDetails details) async {
    setState(() => _dragging = false);
    if (details.files.isEmpty) return;
    final path = details.files.first.path;
    if (path.isEmpty) return;
    await importHollowpackAt(context, ref, path);
  }

  void _openShop() {
    if (_isMobile) {
      Navigator.of(context).push(hollowMobileRoute(
        builder: (_) => const ShopDashboard(embedded: true),
      ));
      return;
    }
    // Desktop: the panel lives inside the settings dialog, which has to close
    // before the centre tab underneath it can be seen.
    Navigator.of(context).maybePop();
    openShopTab(ref.read);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(shopAvailableProvider)) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final items = ref.watch(ownedArtProvider);
    final compact = widget.compact;

    final header = Row(
      children: [
        Expanded(
          child: compact
              ? Text(
                  'Art you own',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary),
                )
              : const SettingsSectionLabel(label: 'ART YOU OWN'),
        ),
        HollowButton.outline(
          onPressed: () => pickAndImportHollowpack(context, ref),
          compact: true,
          icon: const Icon(LucideIcons.packageOpen, size: 14),
          child: const Text('Import a pack'),
        ),
      ],
    );

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        if (!compact) ...[
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'or drop a .hollowpack here',
            style: HollowTypography.caption
                .copyWith(color: hollow.textTertiary, fontSize: 11),
          ),
        ],
        const SizedBox(height: HollowSpacing.md),
        if (items.isEmpty)
          _EmptyState(onOpenShop: _openShop)
        else
          for (final item in items)
            Padding(
              key: ValueKey(item.itemId),
              padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
              child: _OwnedItemRow(item: item),
            ),
        const _KeptCodesSection(),
        const _SupportMarksSection(),
      ],
    );

    if (_isMobile) return body;

    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _handleDrop,
      child: Stack(
        children: [
          body,
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
                            size: 32, color: hollow.accent),
                        const SizedBox(height: HollowSpacing.sm),
                        Text(
                          'Drop a .hollowpack to import',
                          style: HollowTypography.body
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
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onOpenShop;

  const _EmptyState({required this.onOpenShop});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Art bought in the Hollow Shop appears here once you import its '
          'pack.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            onPressed: onOpenShop,
            compact: true,
            child: const Text('Open the shop'),
          ),
        ),
      ],
    );
  }
}

// ── One owned item ──────────────────────────────────────────────────────────

class _OwnedItemRow extends ConsumerStatefulWidget {
  final OwnedItem item;

  const _OwnedItemRow({required this.item});

  @override
  ConsumerState<_OwnedItemRow> createState() => _OwnedItemRowState();
}

class _OwnedItemRowState extends ConsumerState<_OwnedItemRow> {
  String? _busyKind;

  Future<void> _wear(String kind) async {
    setState(() => _busyKind = kind);
    try {
      await ref.read(ownedArtProvider.notifier).wear(widget.item, {kind});
      if (!mounted) return;
      HollowToast.show(context, 'Wearing ${widget.item.title}',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
      HollowToast.show(context, message, type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busyKind = null);
    }
  }

  Future<void> _openArtist() async {
    final url = widget.item.artistUrl;
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Whether the profile is already wearing this kind of this item.
  bool _isWorn(String kind, Set<String> worn) {
    switch (kind) {
      case 'frame':
        final hash = widget.item.frameHash;
        return hash != null && worn.contains(hash);
      case 'avatar':
        final anim = widget.item.avatarAnimHash;
        final still = widget.item.avatarStillHash;
        return (anim != null && worn.contains(anim)) ||
            (still != null && worn.contains(still));
      case 'banner':
        final anim = widget.item.bannerAnimHash;
        final still = widget.item.bannerStillHash;
        return (anim != null && worn.contains(anim)) ||
            (still != null && worn.contains(still));
      default:
        return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final item = widget.item;
    final worn = ref.watch(myWornHashesProvider);

    return Container(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _OwnedThumb(item: item),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.title,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (item.artistUrl.isEmpty)
                  Text(
                    'by ${item.artistName}',
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
                        'by ${item.artistName}',
                        style: HollowTypography.caption
                            .copyWith(color: hollow.accentText),
                      ),
                    ),
                  ),
                const SizedBox(height: HollowSpacing.xs),
                Wrap(
                  spacing: HollowSpacing.xs,
                  runSpacing: HollowSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final kind in item.kinds) _KindChip(label: kind),
                    for (final kind in item.kinds)
                      if (_isWorn(kind, worn))
                        const HollowButton.ghost(
                          onPressed: null,
                          compact: true,
                          icon: Icon(LucideIcons.circleCheck, size: 14),
                          child: Text('Worn'),
                        )
                      else
                        HollowButton.outline(
                          onPressed:
                              _busyKind == null ? () => _wear(kind) : null,
                          compact: true,
                          icon: _busyKind == kind
                              ? SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: hollow.textSecondary,
                                  ),
                                )
                              : null,
                          child: Text(wearKindLabel(kind)),
                        ),
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

class _KindChip extends StatelessWidget {
  final String label;

  const _KindChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
      ),
      child: Text(
        label,
        style: HollowTypography.caption
            .copyWith(color: hollow.textSecondary, fontSize: 10),
      ),
    );
  }
}

/// A 56px preview of what an item looks like when worn.
class _OwnedThumb extends ConsumerWidget {
  final OwnedItem item;

  const _OwnedThumb({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';
    final kinds = item.kinds;
    final kind = kinds.isEmpty ? '' : kinds.first;

    Widget placeholder() => Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: hollow.elevated,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
          ),
        );

    if (kind == 'frame') {
      final hash = item.frameHash;
      if (hash == null) return placeholder();
      final bytes = ref.watch(railBytesProvider(hash)).valueOrNull;
      final seeded =
          ref.watch(avatarFrameProvider.select((m) => m.containsKey(hash)));
      if (!seeded && bytes != null && bytes.isNotEmpty) {
        final frames = ref.read(avatarFrameProvider.notifier);
        Future.microtask(() => frames.seed(hash, bytes));
      }
      // The frame is decoration painted in front of an avatar, so it needs a
      // real face under it to be judged.
      return HollowAvatar(peerId: me, size: 56, frameId: hash);
    }

    if (kind == 'avatar') {
      final hash = item.avatarStillHash;
      if (hash == null) return placeholder();
      final bytes = ref.watch(railBytesProvider(hash)).valueOrNull;
      if (bytes == null || bytes.isEmpty) return placeholder();
      // An explicit override, not the lazy self-fetch: these bytes are the
      // PACK's, which is what the row is showing off.
      return HollowAvatar(
          peerId: me, size: 56, imageBytes: bytes, frameId: '');
    }

    if (kind == 'banner') {
      final hash = item.bannerStillHash ?? item.bannerAnimHash;
      if (hash == null) return placeholder();
      final bytes = ref.watch(railBytesProvider(hash)).valueOrNull;
      if (bytes == null || bytes.isEmpty) {
        return SizedBox(
          height: 56,
          child: AspectRatio(aspectRatio: 2.5, child: placeholder()),
        );
      }
      return SizedBox(
        height: 56,
        child: AspectRatio(
          aspectRatio: 2.5,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: AnimatedGifImage(
              bytes: bytes,
              fit: BoxFit.cover,
              animate: false,
              errorWidget: placeholder(),
            ),
          ),
        ),
      );
    }

    return placeholder();
  }
}

// ── Kept support codes ──────────────────────────────────────────────────────

class _KeptCodesSection extends ConsumerWidget {
  const _KeptCodesSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final codes = ref.watch(shop.keptRedeemCodesProvider).valueOrNull;
    if (codes == null || codes.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: HollowSpacing.lg),
        const SettingsSectionLabel(label: 'CODES KEPT FOR LATER'),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Codes that arrived by a receipt link and are not redeemed yet. '
          'Redeem one to light its support mark and fetch the art; the '
          'receipt email has it too. A code the shop no longer honours is '
          'dropped the moment it is looked up.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.sm),
        for (final kept in codes)
          Padding(
            key: ValueKey(kept.code),
            padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
            child: _KeptCodeRow(code: kept.code),
          ),
      ],
    );
  }
}

class _KeptCodeRow extends ConsumerStatefulWidget {
  final String code;

  const _KeptCodeRow({required this.code});

  @override
  ConsumerState<_KeptCodeRow> createState() => _KeptCodeRowState();
}

class _KeptCodeRowState extends ConsumerState<_KeptCodeRow> {
  /// Hidden by default, the way the recovery phrase is: a code is a bearer
  /// token, and a screen share should not hand it to the room.
  bool _revealed = false;

  String get code => widget.code;

  /// The code with every character but the dashes covered.
  String get _masked => code.replaceAll(RegExp(r'[^-]'), '\u2022');

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    HollowToast.show(context, 'Code copied', type: HollowToastType.success);
  }

  Future<void> _forget(BuildContext context, WidgetRef ref) async {
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) => HollowDialog(
        title: 'Forget this code?',
        content: Text(
          'Hollow will stop keeping it. The receipt email still has it, so '
          'this is not the last copy.',
          style: HollowTypography.body
              .copyWith(color: HollowTheme.of(dialogContext).textSecondary),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await shop.forgetRedeemCode(code: code);
      ref.invalidate(shop.keptRedeemCodesProvider);
    } catch (e) {
      if (!context.mounted) return;
      HollowToast.show(context, 'That code could not be forgotten: $e',
          type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            _revealed ? code : _masked,
            style: HollowTypography.mono
                .copyWith(color: hollow.textSecondary, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowPressable(
          semanticLabel: _revealed ? 'Hide code' : 'Reveal code',
          onTap: () => setState(() => _revealed = !_revealed),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(HollowSpacing.xs),
          child: Icon(
            _revealed ? LucideIcons.eyeOff : LucideIcons.eye,
            size: 14,
            color: hollow.textSecondary,
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowButton.outline(
          onPressed: () => showRedeemCodeDialog(context, code),
          compact: true,
          child: const Text('Redeem'),
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowPressable(
          semanticLabel: 'Copy code',
          onTap: () => _copy(context),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(HollowSpacing.xs),
          child: Icon(LucideIcons.copy, size: 14, color: hollow.textSecondary),
        ),
        HollowPressable(
          semanticLabel: 'Forget code',
          onTap: () => _forget(context, ref),
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(HollowSpacing.xs),
          child: Icon(LucideIcons.trash2, size: 14, color: hollow.textSecondary),
        ),
      ],
    );
  }
}

// ── Support marks ───────────────────────────────────────────────────────────

/// What to call a credential in a sentence.
///
/// The redeem record is what names a mark, and an old one may carry no title
/// (or nothing at all), so every case has to end in a phrase that reads: the
/// dialog that asks to remove one must never say "The mark for  by ".
String supportCredLabel(shop.OwnSupportCred cred) {
  final title = cred.title.trim();
  final artist = cred.artistName.trim();
  if (title.isNotEmpty) return artist.isEmpty ? title : '$title by $artist';
  if (artist.isNotEmpty) return 'a piece by $artist';
  return 'a piece';
}

/// The credentials this identity holds (design 5.5) and the two choices the
/// holder makes about them: whether the mark also sits next to their name
/// (5.6), and whether it shows at all.
class _SupportMarksSection extends ConsumerStatefulWidget {
  const _SupportMarksSection();

  @override
  ConsumerState<_SupportMarksSection> createState() =>
      _SupportMarksSectionState();
}

class _SupportMarksSectionState extends ConsumerState<_SupportMarksSection> {
  bool _saving = false;

  /// Our own profile card reads the row the republish just rewrote, so it has
  /// to be re-read for the chip to appear or go.
  Future<void> _reloadMyProfile() async {
    final me = ref.read(identityProvider).peerId;
    if (me != null && me.isNotEmpty) {
      await ref.read(profileProvider.notifier).reloadProfile(me);
    }
  }

  Future<void> _setBadge(bool show) async {
    setState(() => _saving = true);
    try {
      await ref.read(shop.supportMarksFfiProvider).setBadge(show);
      ref.invalidate(shop.supportBadgeProvider);
      ref.invalidate(shop.ownSupportCredsProvider);
      await _reloadMyProfile();
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
      HollowToast.show(context, message, type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setHidden(bool hidden) async {
    setState(() => _saving = true);
    try {
      await ref.read(shop.supportMarksFfiProvider).setHidden(hidden);
      ref.invalidate(shop.supportMarksHiddenProvider);
      await _reloadMyProfile();
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
      HollowToast.show(context, message, type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final creds = ref.watch(shop.ownSupportCredsProvider).valueOrNull ??
        const <shop.OwnSupportCred>[];
    final badge = ref.watch(shop.supportBadgeProvider).valueOrNull ?? true;
    final hidden =
        ref.watch(shop.supportMarksHiddenProvider).valueOrNull ?? false;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: HollowSpacing.lg),
        const SettingsSectionLabel(label: 'SUPPORT MARKS'),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Each mark proves you bought the art, without the shop knowing it '
          'was you. It shows on your profile card whether or not you wear '
          'that art right now.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.sm),
        // Dimmed while hidden, because nothing it says is on screen for
        // anyone then. Still usable, so the choice is ready for the moment the
        // marks come back.
        AnimatedOpacity(
          opacity: hidden ? 0.45 : 1.0,
          duration: const Duration(milliseconds: 150),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Show the mark next to my name in chats and member lists',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowToggle(
                value: badge,
                onChanged: _saving ? null : _setBadge,
                semanticLabel: 'Show the support mark next to my name',
              ),
            ],
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Hide my support marks',
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Nobody sees your marks while this is on, and they come '
                    'back when you switch it off.',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowToggle(
              value: hidden,
              onChanged: _saving ? null : _setHidden,
              semanticLabel: 'Hide my support marks',
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
        if (creds.isEmpty)
          Text(
            'No marks yet. Redeem a code on the Shop tab to earn one.',
            style:
                HollowTypography.caption.copyWith(color: hollow.textSecondary),
          )
        else
          for (final cred in creds)
            Padding(
              key: ValueKey(cred.item),
              padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
              child: _CredentialRow(cred: cred),
            ),
      ],
    );
  }
}

/// One held credential, with the one irreversible thing that can be done to
/// it.
class _CredentialRow extends ConsumerStatefulWidget {
  final shop.OwnSupportCred cred;

  const _CredentialRow({required this.cred});

  @override
  ConsumerState<_CredentialRow> createState() => _CredentialRowState();
}

class _CredentialRowState extends ConsumerState<_CredentialRow> {
  bool _busy = false;

  shop.OwnSupportCred get cred => widget.cred;

  /// `Redeemed 2026-09-02`, plus the item's first eight hex when nothing else
  /// names this mark: an unnamed row still has to be tellable from the next
  /// unnamed row.
  String get _meta {
    final ms = cred.redeemedAt.toInt();
    final parts = <String>[];
    if (ms > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      parts.add('Redeemed ${d.year}-${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}');
    }
    if (cred.title.trim().isEmpty && cred.artistName.trim().isEmpty) {
      parts.add(cred.item.length >= 8 ? cred.item.substring(0, 8) : cred.item);
    }
    return parts.join('  ·  ');
  }

  Future<void> _remove() async {
    final label = supportCredLabel(cred);
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (dialogContext) => HollowDialog(
        title: 'Remove this mark?',
        content: Text(
          'The mark for $label leaves your profile on every device and cannot '
          'be brought back. The code you redeemed is spent. The files stay in '
          'your library, and Owned on the Shop tab goes away.',
          style: HollowTypography.body
              .copyWith(color: HollowTheme.of(dialogContext).textSecondary),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(shop.supportMarksFfiProvider).remove(cred.item);
      ref.invalidate(shop.ownSupportCredsProvider);
      ref.invalidate(shop.ownCredentialItemsProvider);
      final me = ref.read(identityProvider).peerId;
      if (me != null && me.isNotEmpty) {
        await ref.read(profileProvider.notifier).reloadProfile(me);
      }
      if (!mounted) return;
      HollowToast.show(context, 'Mark removed', type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      final message = e.toString().replaceFirst(RegExp(r'^[A-Za-z]+: '), '');
      HollowToast.show(context, message, type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final meta = _meta;
    return Row(
      children: [
        Icon(LucideIcons.sparkles, size: 14, color: hollow.accentText),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                supportCredLabel(cred),
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 13,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (meta.isNotEmpty)
                Text(
                  meta,
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textTertiary, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
            ],
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          onPressed: _busy ? null : _remove,
          compact: true,
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
          child: const Text('Remove'),
        ),
      ],
    );
  }
}
