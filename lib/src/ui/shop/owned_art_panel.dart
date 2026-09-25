import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
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
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_text_link.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/shop/hollowpack_import.dart';
import 'package:hollow/src/ui/shop/shop_dashboard.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// The same slot as Settings > Profile's Avatar and Banner rows, so a piece of
/// art looks here exactly as it does there.
const double _kThumb = 48;

/// A banner keeps its own 2.5:1 shape, as on the Profile's Banner row.
const double _kBannerThumbHeight = _kThumb / 2.5;

/// "Your art": the packs this identity has imported, one row per wearable
/// kind, then the support marks they earned and any codes kept for later.
///
/// A section of Settings > Profile on both shells, because that is where a
/// person goes to change how they look. Absent entirely on store builds.
class OwnedArtPanel extends ConsumerStatefulWidget {
  /// Touch sizing, for a phone host that does not set [SettingsDensity].
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
    openShopTab(ref.read);
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(shopAvailableProvider)) return const SizedBox.shrink();

    final hollow = HollowTheme.of(context);
    final items = ref.watch(ownedArtProvider);

    Widget body = SettingsSection(
      title: 'Your art',
      subtitle: _isMobile ? null : 'Or drop a .hollowpack here',
      action: HollowButton.ghost(
        onPressed: () => pickAndImportHollowpack(context, ref),
        compact: true,
        child: const Text('Import a pack'),
      ),
      children: [
        if (items.isEmpty)
          HollowEmptyState(
            dense: true,
            title: 'No art yet',
            description: 'Art bought in the Hollow Shop appears here once you '
                'import its pack.',
            action: HollowButton.ghost(
              onPressed: _openShop,
              compact: true,
              child: const Text('Open the shop'),
            ),
          )
        else
          for (final item in items)
            for (final kind in item.kinds)
              _OwnedItemRow(
                  key: ValueKey('${item.itemId}/$kind'), item: item, kind: kind),
      ],
    );
    if (widget.compact) body = SettingsDensity(touch: true, child: body);

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
                      color: hollow.overlay,
                      borderRadius: BorderRadius.circular(hollow.radiusLg),
                      border: Border.all(color: hollow.accent, width: 2),
                    ),
                    child: Text(
                      'Drop a .hollowpack to import',
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
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

/// One wearable kind of one owned item.
class _OwnedItemRow extends ConsumerStatefulWidget {
  final OwnedItem item;
  final String kind;

  const _OwnedItemRow({super.key, required this.item, required this.kind});

  @override
  ConsumerState<_OwnedItemRow> createState() => _OwnedItemRowState();
}

class _OwnedItemRowState extends ConsumerState<_OwnedItemRow> {
  bool _busy = false;

  Future<void> _wear() async {
    setState(() => _busy = true);
    try {
      await ref.read(ownedArtProvider.notifier).wear(widget.item, {widget.kind});
      if (!mounted) return;
      HollowToast.show(context, 'Wearing ${widget.item.title}',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, friendlyError(e),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final item = widget.item;
    final owned = ref.read(ownedArtProvider.notifier);
    final removed = await showHollowConfirm(
      context: context,
      title: 'Remove ${item.title}?',
      message: '${ownedKindsLeaveSentence(item.kinds)} Anything you wear now '
          'stays on until you change it. Import the pack again to get it '
          'back.',
      confirmLabel: 'Remove',
      destructive: true,
      onConfirm: () => owned.remove(item),
    );
    if (!removed || !mounted) return;
    HollowToast.show(context, 'Removed ${item.title}',
        type: HollowToastType.success);
  }

  Future<void> _openArtist() async {
    final uri = Uri.tryParse(widget.item.artistUrl);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Whether the profile is already wearing this kind of this item.
  bool _isWorn(Set<String> worn) {
    final item = widget.item;
    bool has(String? hash) => hash != null && worn.contains(hash);
    return switch (widget.kind) {
      'frame' => has(item.frameHash),
      'avatar' => has(item.avatarAnimHash) || has(item.avatarStillHash),
      'banner' => has(item.bannerAnimHash) || has(item.bannerStillHash),
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final item = widget.item;
    final worn = _isWorn(ref.watch(myWornHashesProvider));
    final kindLabel = ownedRoleLabel(widget.kind);

    return SettingsRow(
      title: item.title,
      subtitleWidget: item.artistUrl.isEmpty
          ? Text('$kindLabel · by ${item.artistName}')
          : Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('$kindLabel · '),
                HollowTextLink('by ${item.artistName}', onTap: _openArtist),
              ],
            ),
      leading: _OwnedThumb(item: item, kind: widget.kind),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (worn)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
              child: Text(
                'Worn',
                style: HollowTypography.label
                    .copyWith(color: hollow.textTertiary),
              ),
            )
          else
            HollowButton.outline(
              onPressed: _wear,
              compact: true,
              loading: _busy,
              semanticLabel: wearKindLabel(widget.kind),
              child: const Text('Wear'),
            ),
          const SizedBox(width: HollowSpacing.xs),
          Builder(
            builder: (buttonContext) => HollowIconButton(
              icon: LucideIcons.ellipsis,
              label: 'More for ${item.title}',
              tooltip: 'More',
              onPressed: () => showHollowMenu(
                context: buttonContext,
                anchor: overlayAnchorOf(
                  buttonContext,
                  localOffset: Offset(buttonContext.size?.width ?? 0,
                      (buttonContext.size?.height ?? 0) + HollowSpacing.xs),
                ),
                alignEnd: true,
                builder: (_, _) => [
                  HollowMenuItem(
                    icon: LucideIcons.trash2,
                    label: 'Remove from Your art',
                    isDanger: true,
                    onTap: _remove,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What an item looks like when worn.
class _OwnedThumb extends ConsumerWidget {
  final OwnedItem item;
  final String kind;

  const _OwnedThumb({required this.item, required this.kind});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final me = ref.watch(identityProvider.select((s) => s.peerId)) ?? '';

    final placeholder = Container(
      width: _kThumb,
      height: _kThumb,
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
    );

    if (kind == 'frame') {
      final hash = item.frameHash;
      if (hash == null) return placeholder;
      final bytes = ref.watch(railBytesProvider(hash)).valueOrNull;
      final seeded =
          ref.watch(avatarFrameProvider.select((m) => m.containsKey(hash)));
      if (!seeded && bytes != null && bytes.isNotEmpty) {
        final frames = ref.read(avatarFrameProvider.notifier);
        Future.microtask(() => frames.seed(hash, bytes));
      }
      // A frame is decoration painted in front of an avatar, so it needs a real
      // face under it to be judged. The art reaches past the avatar's edge, so
      // the face is smaller than the slot and the whole frame stays in it.
      return SizedBox.square(
        dimension: _kThumb,
        child: ClipRect(
          child: Center(
            child: HollowAvatar(
                peerId: me, size: _kThumb - HollowSpacing.md, frameId: hash),
          ),
        ),
      );
    }

    if (kind == 'avatar') {
      final hash = item.avatarStillHash;
      if (hash == null) return placeholder;
      final bytes = ref.watch(railBytesProvider(hash)).valueOrNull;
      if (bytes == null || bytes.isEmpty) return placeholder;
      // An explicit override rather than the lazy self-fetch: these bytes are
      // the PACK's, which is what the row is showing off.
      return HollowAvatar(
          peerId: me, size: _kThumb, imageBytes: bytes, frameId: '');
    }

    if (kind == 'banner') {
      final bannerPlaceholder = Container(
        width: _kThumb,
        height: _kBannerThumbHeight,
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusXs),
        ),
      );
      final hash = item.bannerStillHash ?? item.bannerAnimHash;
      if (hash == null) return bannerPlaceholder;
      final bytes = ref.watch(railBytesProvider(hash)).valueOrNull;
      if (bytes == null || bytes.isEmpty) return bannerPlaceholder;
      return ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        child: AnimatedGifImage(
          bytes: bytes,
          width: _kThumb,
          height: _kBannerThumbHeight,
          fit: BoxFit.cover,
          animate: false,
          errorWidget: bannerPlaceholder,
        ),
      );
    }

    return placeholder;
  }
}

/// Codes that arrived by a receipt link and are not redeemed yet, folded
/// behind one row. A code the shop no longer honours drops on lookup.
class _KeptCodesRow extends ConsumerWidget {
  const _KeptCodesRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final codes = ref.watch(shop.keptRedeemCodesProvider).valueOrNull;
    if (codes == null || codes.isEmpty) return const SizedBox.shrink();

    return SettingsExpandRow(
      title: codes.length == 1 ? '1 code waiting' : '${codes.length} codes waiting',
      subtitle:
          'From a receipt link. Redeeming lights the mark and fetches the art.',
      children: [
        for (final kept in codes)
          _KeptCodeRow(key: ValueKey(kept.code), code: kept.code),
      ],
    );
  }
}

class _KeptCodeRow extends ConsumerStatefulWidget {
  final String code;

  const _KeptCodeRow({super.key, required this.code});

  @override
  ConsumerState<_KeptCodeRow> createState() => _KeptCodeRowState();
}

class _KeptCodeRowState extends ConsumerState<_KeptCodeRow> {
  /// Hidden by default like the recovery phrase: a code is a bearer token, and
  /// a screen share should not hand it to the room.
  bool _revealed = false;

  String get code => widget.code;

  /// The code with every character but the dashes covered.
  String get _masked => code.replaceAll(RegExp(r'[^-]'), '•');

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    HollowToast.show(context, 'Code copied', type: HollowToastType.success);
  }

  Future<void> _forget(BuildContext context) async {
    final forgotten = await showHollowConfirm(
      context: context,
      title: 'Forget this code?',
      message: 'Hollow will stop keeping it. The receipt email still has it, '
          'so this is not the last copy.',
      confirmLabel: 'Forget',
      destructive: true,
      onConfirm: () => shop.forgetRedeemCode(code: code),
    );
    if (forgotten) ref.invalidate(shop.keptRedeemCodesProvider);
  }

  void _openMenu(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    showHollowMenu(
      context: buttonContext,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(box.size.width, box.size.height)),
      alignEnd: true,
      builder: (menuContext, _) => [
        HollowMenuItem(
          icon: LucideIcons.copy,
          label: 'Copy code',
          onTap: () => _copy(buttonContext),
        ),
        HollowMenuItem(
          icon: LucideIcons.trash2,
          label: 'Forget code',
          isDanger: true,
          onTap: () => _forget(buttonContext),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              _revealed ? code : _masked,
              style: HollowTypography.monoSmall
                  .copyWith(color: hollow.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowIconButton(
            icon: _revealed ? LucideIcons.eyeOff : LucideIcons.eye,
            label: _revealed ? 'Hide code' : 'Reveal code',
            onPressed: () => setState(() => _revealed = !_revealed),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowButton.outline(
            onPressed: () => showRedeemCodeDialog(context, code),
            compact: true,
            child: const Text('Redeem'),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Builder(
            builder: (buttonContext) => HollowIconButton(
              icon: LucideIcons.ellipsis,
              label: 'More',
              onPressed: () => _openMenu(buttonContext),
            ),
          ),
        ],
      ),
    );
  }
}

/// What to call a credential in a sentence. An old redeem record may carry no
/// title at all, so every case has to end in a phrase that still reads.
String supportCredLabel(shop.OwnSupportCred cred) {
  final title = cred.title.trim();
  final artist = cred.artistName.trim();
  if (title.isNotEmpty) return artist.isEmpty ? title : '$title by $artist';
  if (artist.isNotEmpty) return 'a piece by $artist';
  return 'a piece';
}

/// Settings > Profile's "Support marks" section: the marks this identity holds,
/// the two choices about them (beside the name, hidden) and codes kept for
/// later. Absent entirely on store builds, like Your art.
class SupportMarksSection extends ConsumerStatefulWidget {
  const SupportMarksSection({super.key});

  @override
  ConsumerState<SupportMarksSection> createState() =>
      _SupportMarksSectionState();
}

class _SupportMarksSectionState extends ConsumerState<SupportMarksSection> {
  bool _saving = false;

  /// Our profile card reads the row the republish just rewrote, so it has to be
  /// re-read for the chip to appear or go.
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
      HollowToast.show(context, friendlyError(e),
          type: HollowToastType.error);
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
      HollowToast.show(context, friendlyError(e),
          type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!ref.watch(shopAvailableProvider)) return const SizedBox.shrink();
    final creds = ref.watch(shop.ownSupportCredsProvider).valueOrNull ??
        const <shop.OwnSupportCred>[];
    final badge = ref.watch(shop.supportBadgeProvider).valueOrNull ?? true;
    final hidden =
        ref.watch(shop.supportMarksHiddenProvider).valueOrNull ?? false;

    return SettingsSection(
        title: 'Support marks',
        subtitle: 'Each mark proves you bought the art, without the shop '
            'knowing it was you.',
        children: [
          // Greyed while hidden, because nothing it says is on screen then.
          // Still usable, so the choice is ready when the marks come back.
          SettingsRow(
            title: 'Show the mark next to my name',
            subtitle: 'In chats and member lists',
            enabled: !hidden,
            trailing: HollowToggle(
              value: badge,
              onChanged: _saving ? null : _setBadge,
              semanticLabel: 'Show the mark next to my name',
            ),
          ),
          SettingsSwitchRow(
            title: 'Hide my support marks',
            subtitle: 'Nobody sees them until you switch this off',
            value: hidden,
            onChanged: _saving ? null : _setHidden,
          ),
          if (creds.isEmpty)
            const HollowEmptyState(
              dense: true,
              title: 'No marks yet',
              description: 'Redeem a code on the Shop tab to earn one.',
            )
          else
            for (final cred in creds)
              _CredentialRow(key: ValueKey(cred.item), cred: cred),
          const _KeptCodesRow(),
        ],
    );
  }
}

/// One held credential, with the one irreversible thing that can be done to it
/// kept behind its More menu.
class _CredentialRow extends ConsumerStatefulWidget {
  final shop.OwnSupportCred cred;

  const _CredentialRow({super.key, required this.cred});

  @override
  ConsumerState<_CredentialRow> createState() => _CredentialRowState();
}

class _CredentialRowState extends ConsumerState<_CredentialRow> {

  shop.OwnSupportCred get cred => widget.cred;

  /// `Redeemed 2026-09-02`, plus the item's first eight hex when nothing else
  /// names the mark, so one unnamed row is tellable from the next.
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
    final marks = ref.read(shop.supportMarksFfiProvider);
    final confirmed = await showHollowConfirm(
      context: context,
      title: 'Remove this mark?',
      message: 'The mark for $label leaves your profile on every device and '
          'cannot be brought back. The code you redeemed is spent. The files '
          'stay in your library, and Owned on the Shop tab goes away.',
      confirmLabel: 'Remove',
      destructive: true,
      onConfirm: () => marks.remove(cred.item),
    );
    if (!confirmed || !mounted) return;
    ref.invalidate(shop.ownSupportCredsProvider);
    ref.invalidate(shop.ownCredentialItemsProvider);
    HollowToast.show(context, 'Mark removed', type: HollowToastType.success);
    final me = ref.read(identityProvider).peerId;
    if (me != null && me.isNotEmpty) {
      // The mark is already gone; a failed re-read only delays the card.
      await ref
          .read(profileProvider.notifier)
          .reloadProfile(me)
          .catchError((_) {});
    }
  }

  void _openMenu(BuildContext buttonContext) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    showHollowMenu(
      context: buttonContext,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(box.size.width, box.size.height)),
      alignEnd: true,
      builder: (menuContext, _) => [
        HollowMenuItem(
          icon: LucideIcons.trash2,
          label: 'Remove',
          isDanger: true,
          onTap: _remove,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    return SettingsRow(
      title: supportCredLabel(cred),
      subtitle: meta.isEmpty ? null : meta,
      trailing: Builder(
        builder: (buttonContext) => HollowIconButton(
          icon: LucideIcons.ellipsis,
          label: 'More',
          onPressed: () => _openMenu(buttonContext),
        ),
      ),
    );
  }
}

/// "Its frame leaves Your art on this device." with the kinds joined as a
/// sentence, so a bundle reads "Its avatar and banner leave ...".
String ownedKindsLeaveSentence(List<String> kinds) {
  final names = [for (final k in kinds) ownedRoleLabel(k).toLowerCase()];
  if (names.isEmpty) return 'It leaves Your art on this device.';
  final joined = names.length == 1
      ? names.single
      : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  final verb = names.length == 1 ? 'leaves' : 'leave';
  return 'Its $joined $verb Your art on this device.';
}
