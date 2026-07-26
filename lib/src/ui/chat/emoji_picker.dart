import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
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
  _saveRecents(recents);
}

void _removeRecentEmoji(String emoji) {
  final recents = _recentsCache;
  if (recents == null || !recents.remove(emoji)) return;
  _saveRecents(recents);
}

void _saveRecents(List<String> recents) {
  // try/catch AND catchError: an uninitialized bridge throws SYNCHRONOUSLY
  // (before a Future exists), which .catchError alone can't intercept.
  try {
    storage_api
        .saveSetting(key: _recentsKey, value: jsonEncode(recents))
        .catchError((_) {});
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Emote cell context menu (right-click / long-press)
// ---------------------------------------------------------------------------

/// Small anchored menu for removing an emote from a personal collection.
/// Deliberately a menu, not a dialog: the picker stays open behind it and
/// the single destructive item doubles as the confirmation step.
///
/// Inserted as an OverlayEntry ON TOP of the root overlay — the picker
/// itself is a raw OverlayEntry above the navigator's routes, so a dialog
/// route would render BEHIND it.
void _showEmoteContextMenu(
  BuildContext context,
  Offset globalPosition, {
  required String header,
  required String actionLabel,
  required VoidCallback onAction,
}) {
  final position = overlayPositionOf(context, globalPosition);
  final hollow = HollowTheme.of(context);
  const menuWidth = 200.0;
  final screen = MediaQuery.of(context).size;
  final left = position.dx.clamp(8.0, screen.width - menuWidth - 8);
  final top = position.dy.clamp(8.0, screen.height - 96);

  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  // Same double-remove guard as the picker itself: a stray second dismiss
  // before the removal frame builds out must not crash.
  var removed = false;
  void dismiss() {
    if (removed) return;
    removed = true;
    entry.remove();
    entry.dispose();
  }

  entry = OverlayEntry(
    builder: (ctx) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: dismiss,
            onSecondaryTap: dismiss,
            behavior: HitTestBehavior.opaque,
            child: const SizedBox.expand(),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: menuWidth,
              decoration: BoxDecoration(
                color: hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(color: hollow.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                    child: Text(
                      header,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: HollowTypography.caption
                          .copyWith(color: hollow.textTertiary),
                    ),
                  ),
                  Divider(height: 1, color: hollow.border),
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: HollowPressable(
                      onTap: () {
                        dismiss();
                        onAction();
                      },
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 6),
                      child: Row(
                        children: [
                          Icon(LucideIcons.trash2, size: 14, color: hollow.error),
                          const SizedBox(width: 8),
                          Text(
                            actionLabel,
                            style: HollowTypography.label
                                .copyWith(color: hollow.error),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
  overlay.insert(entry);
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

  void _removeRecent(String raw) {
    _removeRecentEmoji(raw);
    setState(() => _recents = List.of(_recentsCache ?? const []));
  }

  void _runFfzSearch() {
    final q = _search;
    final seq = ++_ffzQuerySeq;
    setState(() {
      _ffzLoading = true;
      _ffzError = null;
    });
    // Empty search = the curated popular list; an older proxy without the
    // curated mode answers [] — fall back to the FFZ global sets.
    final future = q.isEmpty
        ? emotes_api.ffzCurated().then((rows) async =>
            rows.isNotEmpty ? rows : await emotes_api.ffzGlobal())
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
            // Desktop only: type-to-search immediately. On mobile the
            // autofocus summons the software keyboard right over the picker
            // sheet — search focuses on tap instead.
            autofocus: !(Platform.isAndroid || Platform.isIOS),
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
          onRemoveRecent: _removeRecent,
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
                      } catch (e) {
                        if (mounted) {
                          HollowToast.show(context, 'Could not remove emote',
                              type: HollowToastType.error);
                        }
                      }
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
    final named = await pickAndNameEmote(context);
    if (named == null || !mounted) return;
    try {
      await emotes_api.addPersonalEmote(
        name: named.name,
        hash: named.processed.hash,
        animated: named.processed.animated,
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
    final cell = HollowPressable(
      onTap: () =>
          _select(emotes_api.emoteToken(name: name, hash: hash)),
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
    if (onRemove == null) return cell;
    void menu(Offset position) => _showEmoteContextMenu(
          context,
          position,
          header: ':$name:',
          actionLabel: 'Remove from my emotes',
          onAction: onRemove,
        );
    return GestureDetector(
      onSecondaryTapUp: (d) => menu(d.globalPosition),
      onLongPressStart: (d) => menu(d.globalPosition),
      child: cell,
    );
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
  final bool recents;
  _RowEntry(this.emojis, {this.recents = false});
}

class _UnicodeGrid extends StatelessWidget {
  final String search;
  final List<String> recents;
  final void Function(String emoji) onSelect;
  final void Function(String emoji) onRemoveRecent;

  const _UnicodeGrid({
    required this.search,
    required this.recents,
    required this.onSelect,
    required this.onRemoveRecent,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final List<_GridEntry> entries;

    if (search.isEmpty) {
      entries = _browseEntries();
    } else {
      final matches = _searchMatches();
      if (matches.isEmpty) {
        return Center(
          child: Text('No matches',
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary)),
        );
      }
      entries = <_GridEntry>[];
      _addEmojiRows(entries, matches);
    }

    return ListView.builder(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index];
        switch (entry) {
          case _HeaderEntry():
            return _headerTile(hollow, entry);
          case _RowEntry():
            return _rowTile(entry);
        }
      },
    );
  }

  /// Splits [emojis] into fixed-width rows and appends them to [entries].
  void _addEmojiRows(
      List<_GridEntry> entries, List<UnicodeEmoji> emojis,
      {bool recents = false}) {
    for (var i = 0; i < emojis.length; i += _gridColumns) {
      entries.add(_RowEntry(
          emojis.sublist(i, (i + _gridColumns).clamp(0, emojis.length)),
          recents: recents));
    }
  }

  /// Entries for the no-search browse view: recents (if any) + all groups.
  List<_GridEntry> _browseEntries() {
    final entries = <_GridEntry>[];
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
      _addEmojiRows(entries, recentEmojis, recents: true);
    }
    for (final group in kUnicodeEmojiGroups.entries) {
      entries.add(_HeaderEntry(group.key));
      _addEmojiRows(entries, group.value);
    }
    return entries;
  }

  /// Emojis whose name contains [search], capped at 160 matches.
  List<UnicodeEmoji> _searchMatches() {
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
    return matches;
  }

  Widget _headerTile(HollowTheme hollow, _HeaderEntry entry) {
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
  }

  Widget _rowTile(_RowEntry entry) {
    return Row(
      children: [
        for (final e in entry.emojis)
          Expanded(
            child: _EmojiCell(
              emoji: e,
              onSelect: onSelect,
              onRemove: entry.recents
                  ? () => onRemoveRecent(e.char)
                  : null,
            ),
          ),
        for (var i = entry.emojis.length; i < _gridColumns; i++)
          const Expanded(child: SizedBox()),
      ],
    );
  }
}

class _EmojiCell extends StatelessWidget {
  final UnicodeEmoji emoji;
  final void Function(String emoji) onSelect;
  /// Recents cells only: remove this entry from the recently-used list.
  final VoidCallback? onRemove;

  const _EmojiCell({
    required this.emoji,
    required this.onSelect,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // A recents entry may be a custom-emote token; render it as an image.
    final emote = parseEmoteToken(emoji.char);
    final cell = HollowPressable(
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
    if (onRemove == null) return cell;
    void menu(Offset position) => _showEmoteContextMenu(
          context,
          position,
          header: emote != null ? ':${emote.name}:' : emoji.char,
          actionLabel: 'Remove from recents',
          onAction: onRemove!,
        );
    return GestureDetector(
      onSecondaryTapUp: (d) => menu(d.globalPosition),
      onLongPressStart: (d) => menu(d.globalPosition),
      child: cell,
    );
  }
}

// ---------------------------------------------------------------------------
// Shared authoring helpers (also used by the server settings emotes tab)
// ---------------------------------------------------------------------------

/// Pick an image file and prompt for a name while the emote is processed in
/// the background: the name dialog opens instantly with the raw picked bytes
/// as preview, the Rust WebP encode runs in a tracked never-throwing future
/// (the preview swaps to the processed result when it lands), and Save awaits
/// the in-flight processing. Returns null on cancel; shows a toast on
/// processing failure.
Future<({emotes_api.ProcessedEmote processed, String name})?> pickAndNameEmote(
    BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    withData: true,
  );
  final bytes = result?.files.single.bytes;
  if (bytes == null) return null;

  Object? processError;
  // Listener-less after the dialog closes, so late updates are no-ops.
  final processedHash = ValueNotifier<String?>(null);
  final processing = emotes_api
      .processAndStoreEmote(rawBytes: bytes)
      .then<emotes_api.ProcessedEmote?>((p) {
    processedHash.value = p.hash;
    return p;
  }).catchError((Object e) {
    processError = e;
    return null;
  });

  if (!context.mounted) return null;
  final name = await _promptEmoteNameImpl(
    context,
    preview: ValueListenableBuilder<String?>(
      valueListenable: processedHash,
      builder: (ctx, hash, _) => hash != null
          ? EmoteImage(name: 'preview', hash: hash, size: 40)
          : Image.memory(
              bytes,
              width: 40,
              height: 40,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (ctx, _, _) => Icon(LucideIcons.imageOff,
                  size: 24, color: HollowTheme.of(ctx).textTertiary),
            ),
    ),
    processing: processing,
  );
  if (name == null) return null; // cancelled
  if (name.isEmpty) {
    // Sentinel from the dialog: Save was pressed but processing failed.
    if (context.mounted) {
      HollowToast.show(
          context, '$processError'.replaceFirst('Exception: ', ''),
          type: HollowToastType.error);
    }
    return null;
  }
  final processed = await processing;
  if (processed == null) return null;
  return (processed: processed, name: name);
}

/// Prompt for an emote name (grammar-validated). Returns null on cancel.
Future<String?> promptEmoteName(BuildContext context,
    {required String hash, String initial = ''}) {
  return _promptEmoteNameImpl(
    context,
    preview: EmoteImage(name: 'preview', hash: hash, size: 40),
    initial: initial,
  );
}

final _emoteNameRegex = RegExp(r'^[a-z0-9_]{2,24}$');

/// Shared name dialog. When [processing] is set, Save awaits it under a
/// spinner and pops '' if it resolved null (= failed) — the caller toasts;
/// pop(null) means the user cancelled.
Future<String?> _promptEmoteNameImpl(
  BuildContext context, {
  required Widget preview,
  String initial = '',
  Future<Object?>? processing,
}) async {
  final controller = TextEditingController(text: initial);
  final name = await showHollowDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      var saving = false;
      return StatefulBuilder(
        builder: (ctx, setState) {
          final hollow = HollowTheme.of(ctx);
          Future<void> submit() async {
            if (saving) return;
            final name = controller.text.trim().toLowerCase();
            if (!_emoteNameRegex.hasMatch(name)) {
              setState(() => error = '2-24 characters, only a-z, 0-9 and _');
              return;
            }
            if (processing != null) {
              setState(() => saving = true);
              final ok = await processing;
              if (!ctx.mounted) return;
              if (ok == null) {
                Navigator.pop(ctx, '');
                return;
              }
            }
            if (ctx.mounted) Navigator.pop(ctx, name);
          }

          return HollowDialog(
            title: 'Name this emote',
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                preview,
                const SizedBox(height: HollowSpacing.sm),
                HollowTextField(
                  controller: controller,
                  hintText: 'emote_name',
                  autofocus: true,
                  errorText: error,
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  'Used as :name: — 2-24 characters: a-z, 0-9, _',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textTertiary),
                ),
              ],
            ),
            actions: [
              HollowButton.ghost(
                onPressed: saving ? null : () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              HollowButton.filled(
                onPressed: saving ? null : submit,
                child: saving
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: hollow.textSecondary),
                      )
                    : const Text('Save'),
              ),
            ],
          );
        },
      );
    },
  );
  controller.dispose();
  return name;
}
