import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers/gif_provider.dart';
import '../../core/providers/member_panel_provider.dart';
import '../../core/providers/server_provider.dart';
import '../../core/providers/sticker_provider.dart';
import '../../core/services/gif_thumb_cache.dart';
import '../../rust/api/gifs.dart' as gifs_api;
import '../../rust/api/stickers.dart' as stickers_api;
import '../../theme/hollow_spacing.dart';
import '../../theme/hollow_theme.dart';
import '../../theme/hollow_typography.dart';
import '../components/animated_gif_image.dart';
import '../components/edge_scroll_row.dart';
import '../components/hollow_button.dart';
import '../components/hollow_pressable.dart';
import '../components/hollow_text_field.dart';
import '../components/hollow_toast.dart';
import 'emote_image.dart';
import 'gif_picker.dart' show GifMenuItem, showGifMenu;

/// Pick an image file and process it at STICKER bounds (≤512px, ≤512 KB,
/// alpha preserved, animation kept). Returns null on cancel; toasts on a
/// processing failure. Shared with the server-settings authoring UI.
///
/// Unlike `pickAndNameEmote` there is NO name prompt: an emote is typed as
/// `:name:` so its name is its identity, while a sticker is only ever picked
/// visually. Naming is optional and happens later, on the pack.
Future<stickers_api.ProcessedSticker?> pickAndProcessSticker(
    BuildContext context) async {
  final result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    withData: true,
  );
  final bytes = result?.files.single.bytes;
  if (bytes == null) return null;
  try {
    return await stickers_api.processAndStoreSticker(rawBytes: bytes);
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, e.toString().replaceFirst('Exception: ', ''),
          type: HollowToastType.error);
    }
    return null;
  }
}

/// The sticker picker (issue #29, asset-rail Phase 5): the user's own vault,
/// the server's pack, the KLIPY sticker catalog, and recents.
///
/// A pick hands the caller an `[a:s:hash:w:h]` wire token — opaque to the
/// caller, exactly like emoji and GIF picks — and the composer inserts it at
/// the cursor. Several in one message tile into a mosaic (see [ChatAssetRun]).
///
/// [serverId] adds the Server tab and feeds the KLIPY content-rating clamp.
///
/// PLACEMENT IS PROVISIONAL. This ships behind its own composer button while
/// the button row gets rethought, so everything lives in [StickerPickerBody]
/// and the overlay below is a thin host — folding this panel into the emoji
/// or GIF picker later is a change of host, not of picker.
void showStickerPicker({
  required BuildContext context,
  required Offset anchorPosition,
  required void Function(String token) onSelect,
  String? serverId,
}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  // Removal guard — same rapid-double-fire protection as the other pickers.
  var removed = false;
  void teardown() {
    if (removed) return;
    removed = true;
    entry.remove();
    entry.dispose();
  }

  entry = OverlayEntry(
    builder: (ctx) => _StickerPickerOverlay(
      anchorPosition: anchorPosition,
      serverId: serverId,
      onSelect: onSelect,
      onDismiss: teardown,
    ),
  );

  overlay.insert(entry);
}

class _StickerPickerOverlay extends StatelessWidget {
  final Offset anchorPosition;
  final void Function(String token) onSelect;
  final VoidCallback onDismiss;
  final String? serverId;

  const _StickerPickerOverlay({
    required this.anchorPosition,
    required this.onSelect,
    required this.onDismiss,
    this.serverId,
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
      top = (anchorPosition.dy + 30).clamp(
          8.0, (screenSize.height - pickerHeight - 8).clamp(8.0, double.infinity));
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
                // Deliberately NOT dismissing on pick: a mosaic is several
                // stickers in one message, so the panel stays open the way
                // the emoji picker does.
                child: StickerPickerBody(
                  onSelect: onSelect,
                  serverId: serverId,
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

/// Browse modes. Mine/Server/Recent are entirely local — only KLIPY talks to
/// the proxy, and only while that tab is showing.
enum StickerPickerTab { mine, server, klipy, recent }

/// One grid entry, whatever its source. Local stickers already have their
/// bytes (or will pull them over the asset rail); KLIPY rows carry the
/// catalog item until they are picked.
@immutable
class _Cell {
  final String hash;
  final int w;
  final int h;
  final String label;
  final String? pack;

  /// Non-null for a KLIPY row that has not been downloaded yet.
  final gifs_api.GifItem? remote;

  const _Cell({
    required this.hash,
    required this.w,
    required this.h,
    this.label = '',
    this.pack,
    this.remote,
  });

  String get key => remote?.id ?? hash;
}

class StickerPickerBody extends ConsumerStatefulWidget {
  final void Function(String token) onSelect;

  /// Server the composer belongs to, when there is one: adds the Server tab
  /// and clamps the KLIPY content rating for servers not flagged NSFW.
  final String? serverId;

  const StickerPickerBody({super.key, required this.onSelect, this.serverId});

  @override
  ConsumerState<StickerPickerBody> createState() => _StickerPickerBodyState();
}

class _StickerPickerBodyState extends ConsumerState<StickerPickerBody> {
  final _searchController = TextEditingController();
  String _search = '';
  int _querySeq = 0;

  late StickerPickerTab _tab =
      widget.serverId != null ? StickerPickerTab.server : StickerPickerTab.mine;

  bool _loading = false;
  String? _error;
  List<gifs_api.GifItem> _remote = const [];
  String? _pickingKey;

  /// Selected pack on the Mine tab; null = all.
  String? _packFilter;

  /// Non-null while the inline rename field is open. Inline rather than a
  /// dialog because the picker is a raw OverlayEntry — a dialog route renders
  /// BEHIND it (the same trap the GIF picker's list names hit).
  String? _renamingPack;
  final _packNameController = TextEditingController();

  /// Search only ever drives the KLIPY tab — the local tabs filter in place.
  bool get _networkView => _tab == StickerPickerTab.klipy;

  /// Rating for the next KLIPY request: the user's setting, clamped for a
  /// server that is not flagged NSFW. `ref.read` — called from callbacks.
  String get _rating {
    final rating = ref.read(gifRatingProvider);
    final sid = widget.serverId;
    if (sid == null) return rating;
    final nsfw = ref.read(serverIsNsfwProvider(sid)).valueOrNull ?? false;
    return clampGifRating(rating, serverAllowsNsfw: nsfw);
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q == _search) return;
      setState(() => _search = q);
      if (_networkView) _runQuery();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _packNameController.dispose();
    super.dispose();
  }

  void _selectTab(StickerPickerTab tab) {
    if (_tab == tab) return;
    setState(() {
      _tab = tab;
      _error = null;
    });
    // Bumps the seq either way, so a KLIPY reply still in flight can never
    // land on a local tab (the GIF picker's late-reply bug, avoided here).
    if (tab == StickerPickerTab.klipy) {
      _runQuery();
    } else {
      _querySeq++;
      if (_loading) setState(() => _loading = false);
    }
  }

  void _runQuery() {
    final q = _search;
    // ALWAYS bump: this is what cancels whatever is in flight.
    final seq = ++_querySeq;
    final catalog = ref.read(stickerCatalogProvider);
    final rating = _rating;

    // A warm page renders with no spinner frame at all.
    final warm = catalog.peek(q, 1, rating);
    if (warm != null) {
      setState(() {
        _remote = warm.items;
        _loading = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    // The debounce re-checks the seq BEFORE issuing the request — a
    // superseded query must never reach the proxy (its rate valve counts
    // every hit), not merely have its result dropped.
    Future<gifs_api.GifPage?> run() async {
      if (q.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted || seq != _querySeq) return null;
      }
      return catalog.page(q, 1, rating);
    }

    run().then((p) {
      if (!mounted || seq != _querySeq || p == null) return;
      setState(() {
        _remote = p.items;
        _loading = false;
      });
    }).catchError((_) {
      if (!mounted || seq != _querySeq) return;
      setState(() {
        _loading = false;
        _error = 'Search failed — check your connection';
      });
    });
  }

  // ── Picking ─────────────────────────────────────────────────────────

  Future<void> _pick(_Cell cell) async {
    if (_pickingKey != null) return;
    final remote = cell.remote;
    if (remote == null) {
      _emit(cell.hash, cell.w, cell.h);
      return;
    }
    setState(() => _pickingKey = cell.key);
    try {
      final stored = await stickers_api.stickerFetchAndStore(
        id: remote.id,
        sourceUrl: remote.fullUrl,
      );
      if (!mounted) return;
      _emit(stored.hash, stored.w, stored.h);
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context, e.toString().replaceFirst('Exception: ', ''),
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _pickingKey = null);
    }
  }

  void _emit(String hash, int w, int h) {
    ref
        .read(stickerRecentsProvider.notifier)
        .noteUsed(RecentSticker(hash: hash, w: w, h: h));
    // Built in Dart, not through `stickers_api.stickerToken` — that is a
    // SYNC FFI call, and a sync bridge call throws outright when the bridge
    // is not up. The grammar is dual-defined anyway (assetTokenRegex here,
    // parse_asset_token in Rust); the GIF picker composes its token the same
    // way.
    widget.onSelect('[a:s:$hash:$w:$h]');
  }

  /// Save a KLIPY sticker into the personal vault. Downloading it IS the
  /// import: the transcode produces a content-addressed local blob, so from
  /// then on it never touches the network again — the same rule FFZ emotes
  /// follow. The STORED dimensions come from the transcode, not from the
  /// catalog row (the encoder may have scaled it down).
  Future<void> _saveToVault(_Cell cell, String pack) async {
    final remote = cell.remote;
    if (remote == null) return;
    try {
      final stored = await stickers_api.stickerFetchAndStore(
        id: remote.id,
        sourceUrl: remote.fullUrl,
      );
      await stickers_api.addPersonalSticker(
        pack: pack,
        hash: stored.hash,
        name: _clipLabel(cell.label),
        animated: stored.animated,
        w: stored.w,
        h: stored.h,
        source: 'klipy:${remote.id}',
      );
      ref.invalidate(personalStickersProvider);
      if (mounted) HollowToast.show(context, 'Saved to your stickers');
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context, e.toString().replaceFirst('Exception: ', ''),
            type: HollowToastType.error);
      }
    }
  }

  String _clipLabel(String raw) {
    final max = ref.read(stickerLimitsProvider).labelChars;
    final t = raw.trim();
    return t.length > max ? t.substring(0, max) : t;
  }

  Future<void> _uploadOwnSticker() async {
    final processed = await pickAndProcessSticker(context);
    if (processed == null || !mounted) return;
    try {
      await stickers_api.addPersonalSticker(
        pack: _packFilter ?? '',
        hash: processed.hash,
        name: '',
        animated: processed.animated,
        w: processed.w,
        h: processed.h,
        source: 'upload',
      );
      ref.invalidate(personalStickersProvider);
    } catch (e) {
      if (mounted) {
        HollowToast.show(
            context, e.toString().replaceFirst('Exception: ', ''),
            type: HollowToastType.error);
      }
    }
  }

  // ── Build ───────────────────────────────────────────────────────────

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
            hintText: _networkView ? 'Search KLIPY' : 'Search your stickers…',
            isDense: true,
            prefixIcon: const Icon(LucideIcons.search, size: 14),
            // Desktop only: on mobile the autofocus summons the keyboard
            // right over the sheet.
            autofocus: !(Platform.isAndroid || Platform.isIOS),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.sm, vertical: 6),
          child: EdgeScrollRow(
            children: [
              if (widget.serverId != null)
                _tabChip(hollow, StickerPickerTab.server, 'Server'),
              _tabChip(hollow, StickerPickerTab.mine, 'Mine'),
              _tabChip(hollow, StickerPickerTab.klipy, 'KLIPY'),
              _tabChip(hollow, StickerPickerTab.recent, 'Recent'),
            ],
          ),
        ),
        Divider(height: 1, color: hollow.border),
        Expanded(child: _content(hollow)),
        if (_networkView) _poweredBy(hollow),
      ],
    );
  }

  Widget _poweredBy(HollowTheme hollow) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          'Powered by KLIPY',
          style: HollowTypography.caption
              .copyWith(color: hollow.textTertiary, fontSize: 9),
        ),
      );

  Widget _tabChip(HollowTheme hollow, StickerPickerTab tab, String label) {
    final selected = _tab == tab;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: HollowPressable(
        onTap: () => _selectTab(tab),
        semanticLabel: '$label stickers tab',
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        padding: EdgeInsets.zero,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? hollow.accent.withValues(alpha: 0.15) : null,
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(
              color:
                  selected ? hollow.accent.withValues(alpha: 0.4) : hollow.border,
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
      ),
    );
  }

  Widget _content(HollowTheme hollow) {
    switch (_tab) {
      case StickerPickerTab.server:
        return _serverTab(hollow);
      case StickerPickerTab.mine:
        return _mineTab(hollow);
      case StickerPickerTab.klipy:
        return _klipyTab(hollow);
      case StickerPickerTab.recent:
        return _recentTab(hollow);
    }
  }

  bool _matches(String label, String pack) =>
      _search.isEmpty ||
      label.toLowerCase().contains(_search) ||
      pack.toLowerCase().contains(_search);

  Widget _serverTab(HollowTheme hollow) {
    final all = ref.watch(serverStickersProvider(widget.serverId!)).valueOrNull ??
        const <stickers_api.ServerSticker>[];
    final cells = [
      for (final s in all)
        if (_matches(s.name, s.pack))
          _Cell(hash: s.hash, w: s.w, h: s.h, label: s.name, pack: s.pack),
    ];
    if (cells.isEmpty) {
      return _emptyHint(
          hollow,
          all.isEmpty
              ? 'No server stickers yet.\nAdmins add them in Server Settings.'
              : 'No matches');
    }
    return _grid(hollow, cells);
  }

  Widget _mineTab(HollowTheme hollow) {
    final all = ref.watch(personalStickersProvider).valueOrNull ??
        const <stickers_api.PersonalSticker>[];
    final packs = <String>{for (final s in all) s.pack}.toList()..sort();
    // A pack that was emptied or renamed away must not stay selected.
    final filter = packs.contains(_packFilter) ? _packFilter : null;
    final cells = [
      for (final s in all)
        if (_matches(s.name, s.pack) && (filter == null || s.pack == filter))
          _Cell(hash: s.hash, w: s.w, h: s.h, label: s.name, pack: s.pack),
    ];
    return Column(
      children: [
        if (_renamingPack != null)
          _packNameField(hollow)
        else if (packs.length > 1 || packs.any((p) => p.isNotEmpty))
          Padding(
            padding: const EdgeInsets.fromLTRB(
                HollowSpacing.sm, HollowSpacing.xs, HollowSpacing.sm, 0),
            child: EdgeScrollRow(
              height: 26,
              semanticLabel: 'sticker packs',
              children: [
                _packChip(hollow, null, 'All', filter),
                for (final p in packs)
                  _packChip(hollow, p, p.isEmpty ? 'Ungrouped' : p, filter),
              ],
            ),
          ),
        Expanded(
          child: cells.isEmpty
              ? _emptyHint(
                  hollow,
                  all.isEmpty
                      ? 'Your stickers work in every chat.\nUpload artwork, or save some\nfrom the KLIPY tab.'
                      : 'No matches')
              : _grid(hollow, cells, removable: true),
        ),
        Padding(
          padding: const EdgeInsets.all(HollowSpacing.sm),
          child: HollowButton.ghost(
            icon: const Icon(LucideIcons.imagePlus, size: 14),
            onPressed: _uploadOwnSticker,
            child: Text(filter == null || filter.isEmpty
                ? 'Upload sticker'
                : 'Upload to “$filter”'),
          ),
        ),
      ],
    );
  }

  Widget _packChip(
      HollowTheme hollow, String? pack, String label, String? filter) {
    final selected = filter == pack;
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: GestureDetector(
        onSecondaryTapDown: pack == null || pack.isEmpty
            ? null
            : (d) => _packMenu(pack, d.globalPosition),
        onLongPressStart: pack == null || pack.isEmpty
            ? null
            : (d) => _packMenu(pack, d.globalPosition),
        child: HollowPressable(
          onTap: () => setState(() => _packFilter = pack),
          semanticLabel: 'Show $label',
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: EdgeInsets.zero,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                fontSize: 11,
                color: selected ? hollow.accentText : hollow.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Inline pack rename. Renaming ONTO an existing pack merges into it —
  /// Rust does that rather than failing a unique constraint, and it is the
  /// only sane reading of the action.
  Widget _packNameField(HollowTheme hollow) {
    Future<void> submit() async {
      final from = _renamingPack;
      final to = _packNameController.text.trim();
      setState(() => _renamingPack = null);
      if (from == null || to.isEmpty || to == from) return;
      try {
        await stickers_api.renamePersonalStickerPack(from: from, to: to);
        ref.invalidate(personalStickersProvider);
        if (mounted && _packFilter == from) {
          setState(() => _packFilter = to);
        }
      } catch (e) {
        if (mounted) {
          HollowToast.show(
              context, e.toString().replaceFirst('Exception: ', ''),
              type: HollowToastType.error);
        }
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.sm, HollowSpacing.xs, HollowSpacing.sm, 0),
      child: Row(
        children: [
          Expanded(
            child: HollowTextField(
              controller: _packNameController,
              hintText: 'Pack name',
              isDense: true,
              autofocus: true,
              maxLength: ref.read(stickerLimitsProvider).labelChars,
              showCounter: false,
              onSubmitted: (_) => submit(),
            ),
          ),
          const SizedBox(width: 4),
          HollowPressable(
            onTap: submit,
            semanticLabel: 'Save pack name',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.check, size: 15, color: hollow.accentText),
          ),
          HollowPressable(
            onTap: () => setState(() => _renamingPack = null),
            semanticLabel: 'Cancel rename',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(4),
            child: Icon(LucideIcons.x, size: 15, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }

  void _packMenu(String pack, Offset globalPosition) {
    showGifMenu(
      context,
      globalPosition,
      header: pack,
      items: [
        GifMenuItem(
          icon: LucideIcons.pencil,
          label: 'Rename pack',
          onTap: () => setState(() {
            _renamingPack = pack;
            _packNameController.text = pack;
          }),
        ),
        GifMenuItem(
          icon: LucideIcons.trash2,
          label: 'Delete pack',
          danger: true,
          onTap: () async {
            try {
              await stickers_api.removePersonalStickerPack(pack: pack);
              ref.invalidate(personalStickersProvider);
              if (mounted && _packFilter == pack) {
                setState(() => _packFilter = null);
              }
            } catch (_) {
              if (mounted) {
                HollowToast.show(context, 'Could not delete pack',
                    type: HollowToastType.error);
              }
            }
          },
        ),
      ],
    );
  }

  Widget _recentTab(HollowTheme hollow) {
    final recents = ref.watch(stickerRecentsProvider);
    if (recents.isEmpty) {
      return _emptyHint(hollow, 'Stickers you send show up here.');
    }
    return _grid(
      hollow,
      [for (final r in recents) _Cell(hash: r.hash, w: r.w, h: r.h)],
      recent: true,
    );
  }

  Widget _klipyTab(HollowTheme hollow) {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
              strokeWidth: 2, color: hollow.textTertiary),
        ),
      );
    }
    final err = _error;
    if (err != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(err,
                textAlign: TextAlign.center,
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary)),
            const SizedBox(height: HollowSpacing.sm),
            HollowButton.ghost(
                onPressed: _runQuery, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_remote.isEmpty) {
      return _emptyHint(hollow, 'No stickers found');
    }
    return _grid(
      hollow,
      [
        for (final item in _remote)
          _Cell(
            hash: '',
            w: item.w,
            h: item.h,
            label: item.title,
            remote: item,
          ),
      ],
      savable: true,
    );
  }

  Widget _emptyHint(HollowTheme hollow, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.lg),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              height: 1.5,
            ),
          ),
        ),
      );

  Widget _grid(
    HollowTheme hollow,
    List<_Cell> cells, {
    bool removable = false,
    bool savable = false,
    bool recent = false,
  }) {
    return GridView.builder(
      padding: const EdgeInsets.all(HollowSpacing.sm),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 76,
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
      ),
      itemCount: cells.length,
      itemBuilder: (context, i) {
        final cell = cells[i];
        return _StickerCell(
          key: ValueKey(cell.key),
          cell: cell,
          picking: _pickingKey == cell.key,
          enabled: _pickingKey == null,
          onTap: () => _pick(cell),
          onMenu: (pos) => _menuFor(cell, pos,
              removable: removable, savable: savable, recent: recent),
        );
      },
    );
  }

  void _menuFor(
    _Cell cell,
    Offset globalPosition, {
    required bool removable,
    required bool savable,
    required bool recent,
  }) {
    final items = <GifMenuItem>[
      if (savable)
        GifMenuItem(
          icon: LucideIcons.bookmarkPlus,
          label: 'Save to my stickers',
          onTap: () => _saveToVault(cell, _packFilter ?? ''),
        ),
      if (recent)
        GifMenuItem(
          icon: LucideIcons.x,
          label: 'Remove from recent',
          onTap: () =>
              ref.read(stickerRecentsProvider.notifier).remove(cell.hash),
        ),
      if (removable)
        GifMenuItem(
          icon: LucideIcons.trash2,
          label: 'Delete sticker',
          danger: true,
          onTap: () async {
            try {
              await stickers_api.removePersonalSticker(
                  pack: cell.pack ?? '', hash: cell.hash);
              ref.invalidate(personalStickersProvider);
            } catch (e) {
              if (mounted) {
                HollowToast.show(context, 'Could not remove sticker',
                    type: HollowToastType.error);
              }
            }
          },
        ),
    ];
    showGifMenu(
      context,
      globalPosition,
      header: cell.label.isEmpty ? 'Sticker' : cell.label,
      items: items,
    );
  }
}

// ---------------------------------------------------------------------------
// One grid cell
// ---------------------------------------------------------------------------

class _StickerCell extends ConsumerStatefulWidget {
  final _Cell cell;
  final bool picking;
  final bool enabled;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;

  const _StickerCell({
    super.key,
    required this.cell,
    required this.picking,
    required this.enabled,
    required this.onTap,
    required this.onMenu,
  });

  @override
  ConsumerState<_StickerCell> createState() => _StickerCellState();
}

class _StickerCellState extends ConsumerState<_StickerCell> {
  Uint8List? _still;
  Uint8List? _sm;
  bool _stillRequested = false;
  bool _smRequested = false;
  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    if (widget.cell.remote != null) _loadStill();
  }

  @override
  void didUpdateWidget(covariant _StickerCell old) {
    super.didUpdateWidget(old);
    if (old.cell.key != widget.cell.key) {
      _still = null;
      _sm = null;
      _stillRequested = false;
      _smRequested = false;
      if (widget.cell.remote != null) _loadStill();
    }
  }

  void _loadStill() {
    final remote = widget.cell.remote;
    if (remote == null || _stillRequested) return;
    _stillRequested = true;
    final id = remote.id;
    GifThumbCache.instance.load(remote.stillUrl).then((bytes) {
      if (!mounted || widget.cell.remote?.id != id || bytes == null) return;
      setState(() => _still = bytes);
    }).catchError((_) {});
  }

  void _loadSm() {
    final remote = widget.cell.remote;
    if (remote == null || _smRequested) return;
    _smRequested = true;
    final id = remote.id;
    GifThumbCache.instance.load(remote.smUrl).then((bytes) {
      if (!mounted || widget.cell.remote?.id != id || bytes == null) return;
      setState(() => _sm = bytes);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final label = widget.cell.label.trim();
    final semantic = label.isEmpty ? 'Insert sticker' : 'Insert sticker $label';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onSecondaryTapDown: (d) => widget.onMenu(d.globalPosition),
        onLongPressStart: (d) => widget.onMenu(d.globalPosition),
        child: HollowPressable(
          onTap: widget.enabled ? widget.onTap : null,
          semanticLabel: semantic,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.all(2),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _image(hollow),
              if (widget.picking)
                Container(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _image(HollowTheme hollow) {
    // LOCAL: the bytes are (or will be) a content-addressed blob — the same
    // widget the chat uses, so a missing hash pulls itself over the asset
    // rail and flips in when it lands.
    if (widget.cell.remote == null) {
      return ChatAssetImage(
        kind: 's',
        hash: widget.cell.hash,
        aspect: widget.cell.w / widget.cell.h,
        width: 68,
        height: 68,
      );
    }

    // REMOTE: a catalog thumbnail. Stills by default; the hovered cell (or
    // every visible one under autoplay) swaps to the animated variant, and
    // AnimatedGifImage freezes itself under reduce-motion.
    final focused = ref.watch(windowFocusedProvider);
    final wantsAnim =
        focused && (ref.watch(gifAutoplayProvider) || _hovering);
    if (wantsAnim) _loadSm();

    final sm = _sm;
    final still = _still;
    if (wantsAnim && sm != null) {
      return AnimatedGifImage(bytes: sm, fit: BoxFit.contain);
    }
    if (still != null) {
      return Image.memory(
        still,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusSm),
      ),
    );
  }
}
