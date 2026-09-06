import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/emote_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/sticker_provider.dart';
import 'package:hollow/src/rust/api/emotes.dart' as emotes_api;
import 'package:hollow/src/rust/api/stickers.dart' as stickers_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/chat/sticker_picker.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The server's custom emote set. Everyone can view; add and remove need
/// MANAGE_EMOTES. Images are processed locally and replicate
/// content-addressed, so the CRDT carries only the name and hash.
class EmotesTab extends ConsumerWidget {
  final String serverId;

  const EmotesTab({super.key, required this.serverId});

  static const _maxEmotes = 50;

  Future<void> _addEmote(BuildContext context, WidgetRef ref) async {
    final named = await pickAndNameEmote(context);
    if (named == null || !context.mounted) return;
    try {
      await emotes_api.addServerEmote(
        serverId: serverId,
        name: named.name,
        hash: named.processed.hash,
        animated: named.processed.animated,
      );
      // CrdtStore persists fire-and-forget, so the write needs a beat.
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverEmotesProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  Future<void> _removeEmote(
      BuildContext context, WidgetRef ref, String name) async {
    try {
      await emotes_api.removeServerEmote(serverId: serverId, name: name);
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverEmotesProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final emotes = ref.watch(serverEmotesProvider(serverId)).valueOrNull ?? [];
    final canManage = (ref.watch(myPermissionsProvider(serverId)).valueOrNull ??
                0) &
            Permission.manageEmotes !=
        0;

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Custom Emotes',
                style: HollowTypography.subheading
                    .copyWith(color: hollow.textPrimary),
              ),
            ),
            Text(
              '${emotes.length} / $_maxEmotes',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Everyone in this server can use these in messages and reactions '
          'as :name:. Images are shared between members automatically.',
          style:
              HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.lg),
        if (canManage)
          Align(
            alignment: Alignment.centerLeft,
            child: HollowButton.outline(
              onPressed: emotes.length >= _maxEmotes
                  ? null
                  : () => _addEmote(context, ref),
              icon: const Icon(LucideIcons.imagePlus, size: 14),
              child: const Text('Add emote'),
            ),
          ),
        if (canManage) const SizedBox(height: HollowSpacing.md),
        if (emotes.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.xl),
            child: Center(
              child: Text(
                canManage
                    ? 'No custom emotes yet. Add one, or import from the\n'
                        'FFZ tab of the emoji picker in any chat.'
                    : 'No custom emotes yet.',
                textAlign: TextAlign.center,
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary),
              ),
            ),
          )
        else
          ...emotes.map((e) => _EmoteRow(
                emote: e,
                canManage: canManage,
                onRemove: () => _removeEmote(context, ref, e.name),
              )),
        const SizedBox(height: HollowSpacing.xl),
        Divider(height: 1, color: hollow.border),
        const SizedBox(height: HollowSpacing.lg),
        ServerStickersSection(serverId: serverId, canManage: canManage),
      ],
    );
  }
}

/// The server's sticker pack: same permission, same rail, same "bytes never
/// ride the CRDT" rule as the emote set. Its own widget so the mobile server
/// settings route renders exactly this rather than a second copy.
class ServerStickersSection extends ConsumerWidget {
  final String serverId;
  final bool canManage;

  const ServerStickersSection({
    super.key,
    required this.serverId,
    required this.canManage,
  });

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final processed = await pickAndProcessSticker(context);
    if (processed == null || !context.mounted) return;
    try {
      await stickers_api.addServerSticker(
        serverId: serverId,
        hash: processed.hash,
        name: '',
        pack: '',
        animated: processed.animated,
        w: processed.w,
        h: processed.h,
      );
      // CrdtStore persists fire-and-forget, so the write needs a beat.
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverStickersProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  Future<void> _remove(
      BuildContext context, WidgetRef ref, String hash) async {
    try {
      await stickers_api.removeServerSticker(serverId: serverId, hash: hash);
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverStickersProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final stickers =
        ref.watch(serverStickersProvider(serverId)).valueOrNull ?? [];
    final max = ref.watch(stickerLimitsProvider).perServer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Stickers',
                style: HollowTypography.subheading
                    .copyWith(color: hollow.textPrimary),
              ),
            ),
            Text(
              '${stickers.length} / $max',
              style:
                  HollowTypography.caption.copyWith(color: hollow.textTertiary),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'Bigger than emotes and picked from the sticker panel rather than '
          'typed. Send several in a row and they tile edge to edge, so a pack '
          'can be drawn as one picture cut into pieces.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.md),
        if (canManage)
          HollowButton.outline(
            onPressed:
                stickers.length >= max ? null : () => _add(context, ref),
            icon: const Icon(LucideIcons.imagePlus, size: 14),
            child: const Text('Add sticker'),
          ),
        if (canManage) const SizedBox(height: HollowSpacing.md),
        if (stickers.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
            child: Center(
              child: Text(
                canManage
                    ? 'No stickers yet. Add artwork, or save some from the\n'
                        'KLIPY tab of the sticker panel in any chat.'
                    : 'No stickers yet.',
                textAlign: TextAlign.center,
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary),
              ),
            ),
          )
        else
          Wrap(
            spacing: HollowSpacing.sm,
            runSpacing: HollowSpacing.sm,
            children: [
              for (final s in stickers)
                _ServerStickerTile(
                  sticker: s,
                  canManage: canManage,
                  onRemove: () => _remove(context, ref, s.hash),
                ),
            ],
          ),
      ],
    );
  }
}

class _ServerStickerTile extends StatelessWidget {
  final stickers_api.ServerSticker sticker;
  final bool canManage;
  final VoidCallback onRemove;

  const _ServerStickerTile({
    required this.sticker,
    required this.canManage,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
      ),
      child: Stack(
        children: [
          ChatAssetImage(
            kind: 's',
            hash: sticker.hash,
            aspect: sticker.w / sticker.h,
            width: 72,
            height: 72,
          ),
          if (canManage)
            Positioned(
              top: -2,
              right: -2,
              child: HollowPressable(
                semanticLabel: 'Remove sticker',
                onTap: onRemove,
                borderRadius: BorderRadius.circular(999),
                padding: const EdgeInsets.all(2),
                child: Container(
                  decoration: BoxDecoration(
                    color: hollow.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: hollow.border),
                  ),
                  padding: const EdgeInsets.all(2),
                  child:
                      Icon(LucideIcons.x, size: 11, color: hollow.error),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmoteRow extends StatelessWidget {
  final emotes_api.ServerEmote emote;
  final bool canManage;
  final VoidCallback onRemove;

  const _EmoteRow({
    required this.emote,
    required this.canManage,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: HollowSpacing.xs),
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          EmoteImage(name: emote.name, hash: emote.hash, size: 28),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Text(
              ':${emote.name}:',
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (emote.animated)
            Padding(
              padding: const EdgeInsets.only(right: HollowSpacing.sm),
              child: Text(
                'GIF',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (canManage)
            HollowPressable(
              semanticLabel: 'Remove emote ${emote.name}',
              onTap: onRemove,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.trash2, size: 16, color: hollow.error),
            ),
        ],
      ),
    );
  }
}
