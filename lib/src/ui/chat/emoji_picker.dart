import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers/emote_provider.dart';
import '../../rust/api/emotes.dart' as emotes_api;
import '../../rust/api/storage.dart' as storage_api;
import '../../theme/hollow_spacing.dart';
import '../../theme/hollow_theme.dart';
import '../../theme/hollow_typography.dart';
import '../components/hollow_button.dart';
import '../components/hollow_dialog.dart';
import '../components/hollow_pressable.dart';
import '../components/hollow_text_field.dart';
import '../components/hollow_toast.dart';
import '../components/hollow_tooltip.dart';
import 'emoji_data.dart';
import 'emote_image.dart';

/// Quick-reaction defaults (mobile long-press row, hover bar shortcuts).
const kQuickReactionEmojis = [
  '\u{1F44D}', // thumbs up
  '\u{2764}\u{FE0F}', // red heart
  '\u{1F602}', // face with tears of joy
  '\u{1F525}', // fire
  '\u{1F44F}', // clapping hands
  '\u{1F389}', // party popper
  '\u{1F440}', // eyes
  '\u{1F480}', // skull
];

/// The unified emoji/emote picker: full Unicode set (search + recents),
/// the current server's custom emotes, the user's personal (global) emotes,
/// and an FFZ browse tab (authoring-time import via OUR website cache).
///
/// `onSelect` receives either a Unicode emoji or a custom-emote wire token
/// (`[e:name:hash]`) — callers treat both as an opaque string.
void showEmojiPicker({
  required BuildContext context,
  required Offset anchorPosition,
  required void Function(String emoji) onSelect,
  String? serverId,
}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  // Removal guard: a rapid double-tap on a cell fires onSelect twice before
  // the removal frame builds out (the overlay widget stays mounted until the
  // next frame) — a second remove() on an already-removed entry crashes.
  var removed = false;
  void teardown() {
    if (removed) return;
    removed = true;
    entry.remove();
    entry.dispose();
  }

  entry = OverlayEntry(
    builder: (ctx) => _EmojiPickerOverlay(
      anchorPosition: anchorPosition,
      serverId: serverId,
      onSelect: (emoji) {
        final first = !removed;
        teardown();
        if (first) onSelect(emoji);
      },
      onDismiss: teardown,
    ),
  );

  overlay.insert(entry);
}

// ---------------------------------------------------------------------------
// Recently used (persisted in app_settings as a JSON list; newest first)
// ---------------------------------------------------------------------------

const _recentsKey = 'recent_emojis';
const _recentsMax = 24;
List<String>? _recentsCache;

Future<List<String>> _loadRecentEmojis() async {
  if (_recentsCache != null) return _recentsCache!;
  try {
    final raw = await storage_api.loadSetting(key: _recentsKey);
    if (raw != null && raw.isNotEmpty) {
      _recentsCache =
          (jsonDecode(raw) as List).whereType<String>().toList();
    }
  } catch (_) {}
  return _recentsCache ??= [];
}

void _recordRecentEmoji(String emoji) {
  final recents = _recentsCache ?? [];
  recents.remove(emoji);
  recents.insert(0, emoji);
  if (recents.length > _recentsMax) recents.removeRange(_recentsMax, recents.length);
  _recentsCache = recents;
  // try/catch AND catchError: an uninitialized bridge throws SYNCHRONOUSLY
  // (before a Future exists), which .catchError alone can't intercept.
  try {
    storage_api
        .saveSetting(key: _recentsKey, value: jsonEncode(recents))
        .catchError((_) {});
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Overlay shell
// ---------------------------------------------------------------------------

enum _PickerTab { emoji, server, mine, ffz }

class _EmojiPickerOverlay extends StatelessWidget {
  final Offset anchorPosition;
  final String? serverId;
  final void Function(String emoji) onSelect;
  final VoidCallback onDismiss;

  const _EmojiPickerOverlay({
    required this.anchorPosition,
    required this.serverId,
    required this.onSelect,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final screenSize = MediaQuery.of(context).size;

    final pickerWidth = screenSize.width < 400 ? screenSize.width - 16 : 360.0;
    final pickerHeight =
        screenSize.height < 520 ? screenSize.height - 32 : 440.0;

    double left = anchorPosition.dx - pickerWidth + 30;
    double top = anchorPosition.dy - pickerHeight - 8;

    if (left < 8) left = 8;
    if (left + pickerWidth > screenSize.width - 8) {
      left = screenSize.width - pickerWidth - 8;
    }
    if (top < 8) {
      top = (anchorPosition.dy + 30)
          .clamp(8.0, (screenSize.height - pickerHeight - 8).clamp(8.0, double.infinity));
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: pickerWidth,
              height: pickerHeight,
              decoration: BoxDecoration(
                color: hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                child: EmojiPickerBody(
                  serverId: serverId,
                  onSelect: onSelect,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Picker body (reusable: overlay on desktop, bottom sheet on mobile)
// ---------------------------------------------------------------------------

class EmojiPickerBody extends ConsumerStatefulWidget {
  final String? serverId;
  final void Function(String emoji) onSelect;

  const EmojiPickerBody({
    super.key,
    required this.serverId,
    required this.onSelect,
  });

  @override
  ConsumerState<EmojiPickerBody> createState() => _EmojiPickerBodyState();
}

class _EmojiPickerBodyState extends ConsumerState<EmojiPickerBody> {
  _PickerTab _tab = _PickerTab.emoji;
  final _searchController = TextEditingController();
  String _search = '';
  List<String> _recents = const [];

  // FFZ tab state.
  List<emotes_api.FfzEmote>? _ffzResults;
  bool _ffzLoading = false;
  String? _ffzError;
  int _ffzQuerySeq = 0;

  @override
  void initState() {
    super.initState();
    _loadRecentEmojis().then((r) {
      if (mounted) setState(() => _recents = List.of(r));
    });
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q == _search) return;
      setState(() => _search = q);
      if (_tab == _PickerTab.ffz) _runFfzSearch();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _select(String emoji) {
    _recordRecentEmoji(emoji);
    widget.onSelect(emoji);
  }

  void _runFfzSearch() {
    final q = _search;
    final seq = ++_ffzQuerySeq;
    setState(() {
      _ffzLoading = true;
      _ffzError = null;
    });
    final future = q.isEmpty
        ? emotes_api.ffzGlobal()
        : Future.delayed(const Duration(milliseconds: 350))
            .then((_) => emotes_api.ffzSearch(query: q));
    future.then((rows) {
      if (!mounted || seq != _ffzQuerySeq) return;
      setState(() {
        _ffzResults = rows;
        _ffzLoading = false;
      });
    }).catchError((e) {
      if (!mounted || seq != _ffzQuerySeq) return;
      setState(() {
        _ffzLoading = false;
        _ffzError = 'Search failed — check your connection';
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.sm, HollowSpacing.sm, HollowSpacing.sm, 0),
          child: HollowTextField(
            controller: _searchController,
            hintText: _tab == _PickerTab.ffz
                ? 'Search FrankerFaceZ…'
                : 'Search emoji…',
            isDense: true,
            prefixIcon: const Icon(LucideIcons.search, size: 14),
            autofocus: true,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm, vertical: 6),
          child: Row(
            children: [
              _tabChip(_PickerTab.emoji, 'Emoji'),
              const SizedBox(width: 4),
              if (widget.serverId != null) ...[
                _tabChip(_PickerTab.server, 'Server'),
                const SizedBox(width: 4),
              ],
              _tabChip(_PickerTab.mine, 'Mine'),
              const SizedBox(width: 4),
              _tabChip(_PickerTab.ffz, 'FFZ'),
            ],
          ),
        ),
        Divider(height: 1, color: hollow.border),
        Expanded(child: _buildTabContent(hollow)),
      ],
    );
  }

  Widget _tabChip(_PickerTab tab, String label) {
    final hollow = HollowTheme.of(context);
    final selected = _tab == tab;
    return HollowPressable(
      onTap: () {
        if (_tab == tab) return;
        setState(() => _tab = tab);
        if (tab == _PickerTab.ffz && _ffzResults == null) _runFfzSearch();
      },
      semanticLabel: '$label emotes tab',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? hollow.accent.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(
            color: selected
                ? hollow.accent.withValues(alpha: 0.4)
                : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.caption.copyWith(
            color: selected ? hollow.accentText : hollow.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildTabContent(HollowTheme hollow) {
    switch (_tab) {
      case _PickerTab.emoji:
        return _UnicodeGrid(
          search: _search,
          recents: _recents,
          onSelect: _select,
        );
      case _PickerTab.server:
        return _serverTab(hollow);
      case _PickerTab.mine:
        return _mineTab(hollow);
      case _PickerTab.ffz:
        return _ffzTab(hollow);
    }
  }

  // -- Server emotes tab --

  Widget _serverTab(HollowTheme hollow) {
    final serverId = widget.serverId!;
    final emotes = ref.watch(serverEmotesProvider(serverId)).valueOrNull ?? [];
    final filtered = _search.isEmpty
        ? emotes
        : emotes.where((e) => e.name.contains(_search)).toList();
    if (filtered.isEmpty) {
      return _emptyHint(
          hollow,
          emotes.isEmpty
              ? 'No custom emotes yet.\nAdmins add them in Server Settings.'
              : 'No matches');
    }
    return _emoteGrid(
      filtered.length,
      (i) => _emoteCell(
        name: filtered[i].name,
        hash: filtered[i].hash,
      ),
    );
  }

  // -- Personal emotes tab --

  Widget _mineTab(HollowTheme hollow) {
    final emotes = ref.watch(personalEmotesProvider).valueOrNull ?? [];
    final filtered = _search.isEmpty
        ? emotes
        : emotes.where((e) => e.name.contains(_search)).toList();
    return Column(
      children: [
        Expanded(
          child: filtered.isEmpty
              ? _emptyHint(
                  hollow,
                  emotes.isEmpty
                      ? 'Your personal emotes work in every\nchat. Upload one, or grab some\nfrom the FFZ tab.'
                      : 'No matches')
              : _emoteGrid(
                  filtered.length,
                  (i) => _emoteCell(
                    name: filtered[i].name,
                    hash: filtered[i].hash,
                    onRemove: () async {
                      try {
                        await emotes_api.removePersonalEmote(
                            name: filtered[i].name);
                        ref.invalidate(personalEmotesProvider);
                      } catch (_) {}
                    },
                  ),
                ),
        ),
        Padding(
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: HollowPressable(
            onTap: _uploadPersonalEmote,
            semanticLabel: 'Upload a personal emote image',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.imagePlus, size: 14, color: hollow.textSecondary),
                const SizedBox(width: 6),
                Text('Upload emote',
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _uploadPersonalEmote() async {
    final processed = await pickAndProcessEmoteImage(context);
    if (processed == null || !mounted) return;
    final name = await promptEmoteName(context, hash: processed.hash);
    if (name == null || !mounted) return;
    try {
      await emotes_api.addPersonalEmote(
        name: name,
        hash: processed.hash,
        animated: processed.animated,
        source: 'upload',
      );
      ref.invalidate(personalEmotesProvider);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, e.toString().replaceFirst('Exception: ', ''),
            type: HollowToastType.error);
      }
    }
  }

  // -- FFZ browse tab --

  Widget _ffzTab(HollowTheme hollow) {
    if (_ffzLoading) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: hollow.textTertiary),
        ),
      );
    }
    if (_ffzError != null) return _emptyHint(hollow, _ffzError!);
    final rows = _ffzResults ?? const [];
    if (rows.isEmpty) {
      return _emptyHint(hollow, 'No emotes found');
    }
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(HollowSpacing.sm),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final e = rows[i];
              return HollowPressable(
                onTap: () => _importFfz(e),
                semanticLabel: 'Use FFZ emote ${e.name}',
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                padding: const EdgeInsets.all(4),
                child: HollowTooltip(
                  message: '${e.name} · by ${e.owner}',
                  child: Image.network(
                    e.imageUrl,
                    width: 28,
                    height: 28,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    errorBuilder: (context, error, stackTrace) => Icon(
                        LucideIcons.imageOff,
                        size: 16,
                        color: hollow.textTertiary),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            'Emotes from FrankerFaceZ · tap to add & use',
            style: HollowTypography.caption
                .copyWith(color: hollow.textTertiary, fontSize: 10),
          ),
        ),
      ],
    );
  }

  Future<void> _importFfz(emotes_api.FfzEmote e) async {
    try {
      final processed = await emotes_api.ffzImportEmote(imageUrl: e.imageUrl);
      // FFZ names may not fit our grammar (case, symbols) — normalize, and
      // fall back to a prompt when nothing valid survives.
      var name = e.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
      if (name.length > 24) name = name.substring(0, 24);
      if (name.length < 2) {
        if (!mounted) return;
        final picked = await promptEmoteName(context, hash: processed.hash);
        if (picked == null) return;
        name = picked;
      }
      await emotes_api.addPersonalEmote(
        name: name,
        hash: processed.hash,
        animated: processed.animated,
        source: 'ffz:${e.id}',
      );
      ref.invalidate(personalEmotesProvider);
      _select(emotes_api.emoteToken(name: name, hash: processed.hash));
    } catch (err) {
      if (mounted) {
        HollowToast.show(context, 'Could not import emote',
            type: HollowToastType.error);
      }
    }
  }

  // -- Shared cells --

  Widget _emoteGrid(int count, Widget Function(int) cell) {
    return GridView.builder(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 6,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: count,
      itemBuilder: (context, i) => cell(i),
    );
  }

  Widget _emoteCell({
    required String name,
    required String hash,
    Future<void> Function()? onRemove,
  }) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: () =>
          _select(emotes_api.emoteToken(name: name, hash: hash)),
      onLongPress: onRemove == null
          ? null
          : () => _confirmRemove(name, onRemove),
      semanticLabel: 'Emote $name',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(4),
      child: HollowTooltip(
        message: ':$name:',
        child: Center(
          child: EmoteImage(name: name, hash: hash, size: 26),
        ),
      ),
    );
  }

  Future<void> _confirmRemove(String name, Future<void> Function() remove) async {
    final hollow = HollowTheme.of(context);
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Remove :$name:?',
        content: Text(
          'This only removes it from your personal set — '
          'messages that already use it keep working.',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) await remove();
  }

  Widget _emptyHint(HollowTheme hollow, String text) {
    return Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Unicode grid — lazily built by ROW so the 1.9k-emoji list stays cheap
// ---------------------------------------------------------------------------

const _gridColumns = 8;

sealed class _GridEntry {}

class _HeaderEntry extends _GridEntry {
  final String title;
  _HeaderEntry(this.title);
}

class _RowEntry extends _GridEntry {
  final List<UnicodeEmoji> emojis;
  _RowEntry(this.emojis);
}

class _UnicodeGrid extends StatelessWidget {
  final String search;
  final List<String> recents;
  final void Function(String emoji) onSelect;

  const _UnicodeGrid({
    required this.search,
    required this.recents,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final entries = <_GridEntry>[];

    if (search.isEmpty) {
      if (recents.isNotEmpty) {
        entries.add(_HeaderEntry('Recently used'));
        // Recents may contain custom-emote tokens; keep only Unicode here
        // (tokens still render fine, but the emoji tab is the Unicode home).
        final recentEmojis = recents
            .map((r) {
              final emote = parseEmoteToken(r);
              return emote == null
                  ? UnicodeEmoji(r, '')
                  : UnicodeEmoji(r, emote.name);
            })
            .toList();
        for (var i = 0; i < recentEmojis.length; i += _gridColumns) {
          entries.add(_RowEntry(recentEmojis.sublist(
              i, (i + _gridColumns).clamp(0, recentEmojis.length))));
        }
      }
      for (final group in kUnicodeEmojiGroups.entries) {
        entries.add(_HeaderEntry(group.key));
        for (var i = 0; i < group.value.length; i += _gridColumns) {
          entries.add(_RowEntry(group.value.sublist(
              i, (i + _gridColumns).clamp(0, group.value.length))));
        }
      }
    } else {
      final matches = <UnicodeEmoji>[];
      outer:
      for (final group in kUnicodeEmojiGroups.values) {
        for (final e in group) {
          if (e.name.contains(search)) {
            matches.add(e);
            if (matches.length >= 160) break outer;
          }
        }
      }
      if (matches.isEmpty) {
        return Center(
          child: Text('No matches',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary)),
        );
      }
      for (var i = 0; i < matches.length; i += _gridColumns) {
        entries.add(_RowEntry(
            matches.sublist(i, (i + _gridColumns).clamp(0, matches.length))));
      }
    }

    return ListView.builder(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        switch (entry) {
          case _HeaderEntry():
            return Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4, left: 2),
              child: Text(
                entry.title,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          case _RowEntry():
            return Row(
              children: [
                for (final e in entry.emojis)
                  Expanded(
                    child: _EmojiCell(emoji: e, onSelect: onSelect),
                  ),
                for (var i = entry.emojis.length; i < _gridColumns; i++)
                  const Expanded(child: SizedBox()),
              ],
            );
        }
      },
    );
  }
}

class _EmojiCell extends StatelessWidget {
  final UnicodeEmoji emoji;
  final void Function(String emoji) onSelect;

  const _EmojiCell({required this.emoji, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // A recents entry may be a custom-emote token; render it as an image.
    final emote = parseEmoteToken(emoji.char);
    return HollowPressable(
      onTap: () => onSelect(emoji.char),
      semanticLabel: emoji.name.isEmpty ? 'Emoji ${emoji.char}' : emoji.name,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(3),
      child: Center(
        child: emote != null
            ? EmoteImage(name: emote.name, hash: emote.hash, size: 22)
            : Text(emoji.char, style: const TextStyle(fontSize: 21)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared authoring helpers (also used by the server settings emotes tab)
// ---------------------------------------------------------------------------

/// Pick an image file and process it into an emote blob. Returns null on
/// cancel; shows a toast on processing failure.
Future<emotes_api.ProcessedEmote?> pickAndProcessEmoteImage(
    BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    withData: true,
  );
  final bytes = result?.files.single.bytes;
  if (bytes == null) return null;
  try {
    return await emotes_api.processAndStoreEmote(rawBytes: bytes);
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(
          context, e.toString().replaceFirst('Exception: ', ''),
          type: HollowToastType.error);
    }
    return null;
  }
}

/// Prompt for an emote name (grammar-validated). Returns null on cancel.
Future<String?> promptEmoteName(BuildContext context,
    {required String hash, String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final name = await showHollowDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(
        builder: (ctx, setState) => HollowDialog(
          title: 'Name this emote',
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              EmoteImage(name: 'preview', hash: hash, size: 40),
              const SizedBox(height: HollowSpacing.sm),
              HollowTextField(
                controller: controller,
                hintText: 'emote_name',
                autofocus: true,
                errorText: error,
                onSubmitted: (_) => _submitEmoteName(ctx, controller.text,
                    (msg) => setState(() => error = msg)),
              ),
              const SizedBox(height: HollowSpacing.xs),
              Builder(builder: (context) {
                final hollow = HollowTheme.of(context);
                return Text(
                  'Used as :name: — 2-24 characters: a-z, 0-9, _',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textTertiary),
                );
              }),
            ],
          ),
          actions: [
            HollowButton.ghost(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            HollowButton.filled(
              onPressed: () => _submitEmoteName(ctx, controller.text,
                  (msg) => setState(() => error = msg)),
              child: const Text('Save'),
            ),
          ],
        ),
      );
    },
  );
  controller.dispose();
  return name;
}

final _emoteNameRegex = RegExp(r'^[a-z0-9_]{2,24}$');

void _submitEmoteName(
    BuildContext ctx, String raw, void Function(String) onError) {
  final name = raw.trim().toLowerCase();
  if (!_emoteNameRegex.hasMatch(name)) {
    onError('2-24 characters, only a-z, 0-9 and _');
    return;
  }
  Navigator.pop(ctx, name);
}
