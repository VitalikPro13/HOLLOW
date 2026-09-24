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
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const int _kMaxEmotes = 50;

/// The server's emotes and stickers. Everyone sees them; adding and removing
/// needs MANAGE_EMOTES. The CRDT carries only names and hashes, the images
/// ride the asset rail.
class EmotesPage extends ConsumerWidget {
  final String serverId;
  const EmotesPage({super.key, required this.serverId});

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
        HollowToast.show(context, 'Could not add the emote: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _removeEmote(
      BuildContext context, WidgetRef ref, String name) async {
    final ok = await showHollowConfirm(
      context: context,
      title: 'Remove :$name:?',
      message: 'It leaves the emoji picker for everyone here.',
      confirmLabel: 'Remove emote',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await emotes_api.removeServerEmote(serverId: serverId, name: name);
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverEmotesProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Could not remove the emote: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _addSticker(BuildContext context, WidgetRef ref) async {
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
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverStickersProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Could not add the sticker: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _removeSticker(
      BuildContext context, WidgetRef ref, String hash) async {
    final ok = await showHollowConfirm(
      context: context,
      title: 'Remove this sticker?',
      message: 'It leaves the sticker panel for everyone here.',
      confirmLabel: 'Remove sticker',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await stickers_api.removeServerSticker(serverId: serverId, hash: hash);
      await Future.delayed(const Duration(milliseconds: 150));
      ref.invalidate(serverStickersProvider(serverId));
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Could not remove the sticker: $e',
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final emotes = ref.watch(serverEmotesProvider(serverId)).valueOrNull ?? [];
    final stickers =
        ref.watch(serverStickersProvider(serverId)).valueOrNull ?? [];
    final maxStickers = ref.watch(stickerLimitsProvider).perServer;
    final canManage =
        (ref.watch(myPermissionsProvider(serverId)).valueOrNull ?? 0) &
                Permission.manageEmotes !=
            0;

    return SettingsPage(
      title: 'Emotes and stickers',
      children: [
        SettingsSection(
          title: 'Emotes',
          count: '${emotes.length} of $_kMaxEmotes',
          subtitle: 'Everyone here can use them in messages and reactions as '
              ':name:',
          action: canManage
              ? HollowButton.ghost(
                  compact: true,
                  icon: const Icon(LucideIcons.plus),
                  onPressed: emotes.length >= _kMaxEmotes
                      ? null
                      : () => _addEmote(context, ref),
                  child: const Text('Add emote'),
                )
              : null,
          children: [
            if (emotes.isEmpty)
              HollowEmptyState(
                dense: true,
                title: 'No emotes yet',
                description: canManage
                    ? 'Add one, or bring some in from the FFZ tab of the '
                        'emoji picker in any chat.'
                    : null,
              )
            else
              Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  for (final e in emotes)
                    _Tile(
                      width: 96,
                      semanticLabel: ':${e.name}:',
                      removeLabel: 'Remove :${e.name}:',
                      onRemove: canManage
                          ? () => _removeEmote(context, ref, e.name)
                          : null,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          EmoteImage(name: e.name, hash: e.hash, size: 32),
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            ':${e.name}:',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: HollowTypography.monoSmall
                                .copyWith(color: hollow.textSecondary),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
        SettingsSection(
          title: 'Stickers',
          count: '${stickers.length} of $maxStickers',
          subtitle: 'Picked from the sticker panel. Several in a row tile edge '
              'to edge, so a pack can draw one big picture.',
          action: canManage
              ? HollowButton.ghost(
                  compact: true,
                  icon: const Icon(LucideIcons.plus),
                  onPressed: stickers.length >= maxStickers
                      ? null
                      : () => _addSticker(context, ref),
                  child: const Text('Add sticker'),
                )
              : null,
          children: [
            if (stickers.isEmpty)
              HollowEmptyState(
                dense: true,
                title: 'No stickers yet',
                description: canManage
                    ? 'Add artwork, or save some from the KLIPY tab of the '
                        'sticker panel in any chat.'
                    : null,
              )
            else
              Wrap(
                spacing: HollowSpacing.sm,
                runSpacing: HollowSpacing.sm,
                children: [
                  for (final s in stickers)
                    _Tile(
                      semanticLabel: 'Sticker',
                      removeLabel: 'Remove this sticker',
                      onRemove: canManage
                          ? () => _removeSticker(context, ref, s.hash)
                          : null,
                      child: ChatAssetImage(
                        kind: 's',
                        hash: s.hash,
                        aspect: s.w / s.h,
                        width: 72,
                        height: 72,
                      ),
                    ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// One emote or sticker: the art is the tile. A manager's tap opens Remove.
class _Tile extends StatelessWidget {
  final double? width;
  final String semanticLabel;
  final String removeLabel;
  final VoidCallback? onRemove;
  final Widget child;

  const _Tile({
    this.width,
    required this.semanticLabel,
    required this.removeLabel,
    required this.onRemove,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Builder(
      builder: (tileContext) => HollowPressable(
        onTap: onRemove == null
            ? null
            : () => showHollowMenu(
                  context: tileContext,
                  anchor: overlayAnchorOf(tileContext,
                      localOffset:
                          Offset(0, (tileContext.size?.height ?? 0))),
                  builder: (_, _) => [
                    HollowMenuItem(
                      icon: LucideIcons.trash2,
                      label: removeLabel,
                      isDanger: true,
                      onTap: onRemove,
                    ),
                  ],
                ),
        subtle: true,
        semanticLabel: semanticLabel,
        backgroundColor: hollow.elevated,
        hoverColor: hollow.hover,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.all(HollowSpacing.sm),
        child: SizedBox(width: width, child: Center(child: child)),
      ),
    );
  }
}
