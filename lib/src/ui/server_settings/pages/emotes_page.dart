import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
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
    final emote = emotes_api.ServerEmote(
      // As Rust stores it, so the overlay recognises the stored copy.
      name: named.name.trim().toLowerCase(),
      hash: named.processed.hash,
      animated: named.processed.animated,
    );
    final undo = ref
        .read(serverEmoteWritesProvider(serverId).notifier)
        .write(emote.name, emote);
    try {
      await emotes_api.addServerEmote(
        serverId: serverId,
        name: named.name,
        hash: emote.hash,
        animated: emote.animated,
      );
    } catch (e) {
      undo();
      if (context.mounted) {
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't add the emote. Try again."),
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _removeEmote(
      BuildContext context, WidgetRef ref, String name) async {
    final writes = ref.read(serverEmoteWritesProvider(serverId).notifier);
    await showHollowConfirm(
      context: context,
      title: 'Remove :$name:?',
      message: 'It leaves the emoji picker for everyone here.',
      confirmLabel: 'Remove emote',
      destructive: true,
      onConfirm: () async {
        final undo = writes.write(name, null);
        try {
          await emotes_api.removeServerEmote(serverId: serverId, name: name);
        } catch (_) {
          undo();
          rethrow;
        }
      },
    );
  }

  Future<void> _addSticker(BuildContext context, WidgetRef ref) async {
    final processed = await pickAndProcessSticker(context);
    if (processed == null || !context.mounted) return;
    final sticker = stickers_api.ServerSticker(
      hash: processed.hash,
      name: '',
      pack: '',
      animated: processed.animated,
      w: processed.w,
      h: processed.h,
    );
    final undo = ref
        .read(serverStickerWritesProvider(serverId).notifier)
        .write(sticker.hash, sticker);
    try {
      await stickers_api.addServerSticker(
        serverId: serverId,
        hash: sticker.hash,
        name: sticker.name,
        pack: sticker.pack,
        animated: sticker.animated,
        w: sticker.w,
        h: sticker.h,
      );
    } catch (e) {
      undo();
      if (context.mounted) {
        HollowToast.show(
            context,
            friendlyError(e,
                fallback: "Couldn't add the sticker. Try again."),
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _removeSticker(
      BuildContext context, WidgetRef ref, String hash) async {
    final writes = ref.read(serverStickerWritesProvider(serverId).notifier);
    await showHollowConfirm(
      context: context,
      title: 'Remove this sticker?',
      message: 'It leaves the sticker panel for everyone here.',
      confirmLabel: 'Remove sticker',
      destructive: true,
      onConfirm: () async {
        final undo = writes.write(hash, null);
        try {
          await stickers_api.removeServerSticker(
              serverId: serverId, hash: hash);
        } catch (_) {
          undo();
          rethrow;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final emotes = overAssetWrites<emotes_api.ServerEmote>(
        ref.watch(serverEmotesProvider(serverId)).valueOrNull ?? const [],
        ref.watch(serverEmoteWritesProvider(serverId)),
        (e) => e.name);
    final stickers = overAssetWrites<stickers_api.ServerSticker>(
        ref.watch(serverStickersProvider(serverId)).valueOrNull ?? const [],
        ref.watch(serverStickerWritesProvider(serverId)),
        (s) => s.hash);
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

/// This page's own emote and sticker writes by key (null = removed), drawn
/// over the stored list until a refetch shows them: the FFI only queues the
/// op, so a read right after it returns still sees the previous list.
abstract class AssetWritesNotifier<T>
    extends AutoDisposeFamilyNotifier<Map<String, T?>, String> {
  /// How long a write waits before one last refetch decides it: the node can
  /// still refuse it (a limit, a permission) after the FFI returned.
  static const settleAfter = Duration(seconds: 2);

  final _settling = <String>{};
  final _timers = <Timer>[];
  bool _disposed = false;

  String keyOf(T item);
  FutureProvider<List<T>> storedFor(String serverId);

  @override
  Map<String, T?> build(String serverId) {
    ref.listen(storedFor(serverId), (_, next) {
      final stored = next.valueOrNull;
      if (stored != null) _settle(stored);
    });
    ref.onDispose(() {
      _disposed = true;
      for (final t in _timers) {
        t.cancel();
      }
    });
    return const {};
  }

  /// Shows [item] under [key] now (null hides it); the returned undo puts
  /// back what the page showed before.
  VoidCallback write(String key, T? item) {
    final had = state.containsKey(key);
    final before = state[key];
    state = {...state, key: item};
    _timers.add(Timer(settleAfter, () {
      _settling.add(key);
      ref.invalidate(storedFor(arg));
    }));
    return () {
      if (_disposed) return;
      final next = {...state};
      if (had) {
        next[key] = before;
      } else {
        next.remove(key);
      }
      state = next;
    };
  }

  /// Forgets every write [stored] shows, and every write past [settleAfter]
  /// that it still does not: the store is the truth from then on.
  void _settle(List<T> stored) {
    bool shows(String key, T? item) => item == null
        ? !stored.any((s) => keyOf(s) == key)
        : stored.contains(item);
    final next = {
      for (final e in state.entries)
        if (!shows(e.key, e.value) && !_settling.contains(e.key))
          e.key: e.value,
    };
    _settling.clear();
    if (next.length != state.length) state = next;
  }
}

/// [stored] with [writes] applied: a removed key gone, a changed one in
/// place, a new one at the end.
List<T> overAssetWrites<T>(
    List<T> stored, Map<String, T?> writes, String Function(T) keyOf) {
  return [
    for (final s in stored)
      if (!writes.containsKey(keyOf(s)))
        s
      else if (writes[keyOf(s)] != null)
        writes[keyOf(s)] as T,
    for (final e in writes.entries)
      if (e.value != null && !stored.any((s) => keyOf(s) == e.key))
        e.value as T,
  ];
}

class ServerEmoteWrites extends AssetWritesNotifier<emotes_api.ServerEmote> {
  @override
  String keyOf(emotes_api.ServerEmote item) => item.name;

  @override
  FutureProvider<List<emotes_api.ServerEmote>> storedFor(String serverId) =>
      serverEmotesProvider(serverId);
}

class ServerStickerWrites
    extends AssetWritesNotifier<stickers_api.ServerSticker> {
  @override
  String keyOf(stickers_api.ServerSticker item) => item.hash;

  @override
  FutureProvider<List<stickers_api.ServerSticker>> storedFor(
          String serverId) =>
      serverStickersProvider(serverId);
}

/// This page's pending emote writes, per server.
final serverEmoteWritesProvider = NotifierProvider.autoDispose.family<
    ServerEmoteWrites,
    Map<String, emotes_api.ServerEmote?>,
    String>(ServerEmoteWrites.new);

/// This page's pending sticker writes, per server.
final serverStickerWritesProvider = NotifierProvider.autoDispose.family<
    ServerStickerWrites,
    Map<String, stickers_api.ServerSticker?>,
    String>(ServerStickerWrites.new);
