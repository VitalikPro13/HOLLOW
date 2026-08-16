import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/providers/gif_library_provider.dart';
import '../../core/providers/gif_provider.dart';
import '../../core/providers/member_panel_provider.dart';
import '../../core/providers/server_provider.dart';
import '../../core/services/gif_thumb_cache.dart';
import '../../rust/api/gifs.dart' as gifs_api;
import '../../rust/api/network.dart' as network_api;
import '../../theme/hollow_spacing.dart';
import '../../theme/hollow_theme.dart';
import '../../theme/hollow_typography.dart';
import '../components/animated_gif_image.dart';
import '../components/hollow_button.dart';
import '../components/hollow_pressable.dart';
import '../components/hollow_text_field.dart';
import '../components/hollow_toast.dart';
import '../components/edge_scroll_row.dart';
import '../components/overlay_anchor.dart';

/// The GIF picker (issue #26): Popular / Favourites / Recent plus search
/// through the Hollow website's no-log Klipy proxy, sharing chrome with the
/// emoji picker. A pick downloads the full source, re-encodes it into a
/// ≤480px content-addressed WebP blob (Rust `gif_fetch_and_store`) and hands
/// the caller an `[a:g:hash:w:h]` wire token — callers treat it as an opaque
/// string, exactly like emoji picks.
/// [serverId] is the server the composer belongs to, when there is one. It
/// only feeds the content-rating clamp (a server not flagged NSFW caps
/// results at pg-13); DMs and conferences pass null and use the user's own
/// setting.
void showGifPicker({
  required BuildContext context,
  required Offset anchorPosition,
  required void Function(String token) onSelect,
  String? serverId,
}) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  // Removal guard — same rapid-double-fire protection as the emoji picker.
  var removed = false;
  void teardown() {
    if (removed) return;
    removed = true;
    entry.remove();
    entry.dispose();
  }

  entry = OverlayEntry(
    builder: (ctx) => _GifPickerOverlay(
      anchorPosition: anchorPosition,
      serverId: serverId,
      // A pick SENDS and the panel STAYS OPEN, mirroring the sticker picker
      // (issue #36) — picking used to tear the overlay down here, which made
      // sending two GIFs two round trips through the composer button.
      onSelect: onSelect,
      onDismiss: teardown,
    ),
  );

  overlay.insert(entry);
}

class _GifPickerOverlay extends StatelessWidget {
  final Offset anchorPosition;
  final void Function(String token) onSelect;
  final VoidCallback onDismiss;
  final String? serverId;

  const _GifPickerOverlay({
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
                child: GifPickerBody(onSelect: onSelect, serverId: serverId),
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

/// Browse modes shown when the search field is empty. Popular is the default
/// (and the only one that talks to the proxy); the other two read the local
/// [gifLibraryProvider].
enum GifPickerTab { popular, favorites, recent }

class GifPickerBody extends ConsumerStatefulWidget {
  final void Function(String token) onSelect;

  /// Server the composer belongs to, when there is one — feeds the content
  /// rating clamp only (see [showGifPicker]).
  final String? serverId;

  const GifPickerBody({super.key, required this.onSelect, this.serverId});

  @override
  ConsumerState<GifPickerBody> createState() => _GifPickerBodyState();
}

class _GifPickerBodyState extends ConsumerState<GifPickerBody> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final _listNameController = TextEditingController();
  String _search = '';
  int _querySeq = 0;

  GifPickerTab _tab = GifPickerTab.popular;

  /// Selected favourites list; null = All.
  String? _collectionId;

  /// Non-null while the inline list-name field is open: '' = creating a new
  /// list, otherwise the id of the list being renamed. Inline rather than a
  /// dialog because the picker is a raw OverlayEntry — a dialog route renders
  /// BEHIND it.
  String? _listEditId;

  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  List<gifs_api.GifItem> _items = const [];
  int _page = 1;
  bool _hasNext = false;
  String? _pickingId;
  double _scrollOffset = 0;

  static const _maxPages = 5; // bounds the non-lazy masonry

  /// True when the grid is showing proxy results rather than the local
  /// library — search always wins over the selected tab.
  bool get _networkView => _search.isNotEmpty || _tab == GifPickerTab.popular;

  /// Rating for the next request: the user's setting, clamped for a server
  /// that is not flagged NSFW. `ref.read` — this is called from callbacks,
  /// and build() listens for changes separately.
  String get _rating {
    final rating = ref.read(gifRatingProvider);
    final sid = widget.serverId;
    if (sid == null) return rating;
    final nsfw = ref.read(serverIsNsfwProvider(sid)).valueOrNull ?? false;
    return clampGifRating(rating, serverAllowsNsfw: nsfw);
  }

  /// Release-visible diagnostics (hollow_debug.log). Never logs query TEXT —
  /// only lengths/counts/timings.
  static void _dbg(String msg) {
    try {
      network_api.logFromDart(message: '[HOLLOW-GIF-UI] $msg').catchError((_) {});
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q == _search) return;
      setState(() => _search = q);
      _runQuery();
    });
    _scrollController.addListener(() {
      final pos = _scrollController.position;
      // maxScrollExtent > 0: content that FITS the viewport must never
      // auto-paginate (pixels 0 > -300 is true on every tick — that
      // avalanches into pages of thumbnail downloads nobody asked for).
      if (pos.maxScrollExtent > 0 &&
          pos.pixels > pos.maxScrollExtent - 300) {
        _loadMore();
      }
      // Visibility gates use full-viewport margins — 40px granularity is
      // plenty, and it keeps scrolling from rebuilding every cell per frame.
      if ((pos.pixels - _scrollOffset).abs() > 40) {
        setState(() => _scrollOffset = pos.pixels);
      }
    });
    _runQuery();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _listNameController.dispose();
    super.dispose();
  }

  void _selectTab(GifPickerTab tab) {
    // While searching, even the ALREADY-selected tab is a real action: it is
    // how you leave the search.
    final searching = _search.isNotEmpty;
    if (_tab == tab && !searching) return;
    setState(() {
      _tab = tab;
      _collectionId = null;
      _listEditId = null;
      _scrollOffset = 0;
    });
    _resetScroll();
    if (searching) {
      // Clearing the field fires the controller listener, which sets _search
      // and runs the query against the tab assigned above — calling
      // _runQuery here too would issue a second, immediately-superseded one.
      _searchController.clear();
    } else {
      // Bumps the seq either way, so a Popular request still in flight can
      // never land on top of a library view.
      _runQuery();
    }
  }

  void _resetScroll() {
    // The controller is shared across the tab views and keeps its offset —
    // jump after the new view has attached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) _scrollController.jumpTo(0);
    });
  }

  void _runQuery() {
    final q = _search;
    // ALWAYS bump: this is what cancels whatever is in flight.
    final seq = ++_querySeq;
    if (!_networkView) {
      if (_loading || _error != null) {
        setState(() {
          _loading = false;
          _error = null;
        });
      }
      return;
    }
    final catalog = ref.read(gifCatalogProvider);
    final rating = _rating;
    final t0 = DateTime.now();

    // A warm cache page (trending is prefetched at boot) renders with no
    // spinner frame at all — the plan's "opening must never show a spinner".
    final warm = catalog.peek(q, 1, rating);
    if (warm != null) {
      _dbg('query seq=$seq len=${q.length} WARM ${warm.items.length} items');
      setState(() {
        _applyFirstPage(warm);
        _loading = false;
        _error = null;
      });
      return;
    }

    _dbg('query seq=$seq len=${q.length} cold start');
    setState(() {
      _loading = true;
      _error = null;
    });
    // The debounce re-checks the seq BEFORE issuing the request — a
    // superseded query must never reach the proxy (its rate valve counts
    // every hit), not just have its result dropped.
    Future<gifs_api.GifPage?> run() async {
      if (q.isNotEmpty) {
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted || seq != _querySeq) return null;
      }
      return catalog.page(q, 1, rating);
    }

    run().then((p) {
      if (p != null) {
        _dbg('query seq=$seq done ${p.items.length} items in '
            '${DateTime.now().difference(t0).inMilliseconds}ms '
            '(current seq=$_querySeq mounted=$mounted)');
      }
      if (!mounted || seq != _querySeq || p == null) return;
      setState(() {
        _applyFirstPage(p);
        _loading = false;
      });
    }).catchError((e) {
      _dbg('query seq=$seq ERROR in '
          '${DateTime.now().difference(t0).inMilliseconds}ms: '
          '${e.runtimeType} (current seq=$_querySeq mounted=$mounted)');
      if (!mounted || seq != _querySeq) return;
      setState(() {
        _loading = false;
        _error = 'Search failed. Check your connection';
      });
    });
  }

  void _applyFirstPage(gifs_api.GifPage p) {
    _items = p.items;
    _page = 1;
    _hasNext = p.hasNext;
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    _scrollOffset = 0;
    if (p.items.isEmpty &&
        p.backoffUntil * 1000 > DateTime.now().millisecondsSinceEpoch) {
      _error = 'GIF search is busy. Try again in a moment';
    } else {
      _error = null;
    }
  }

  void _loadMore() {
    if (!_networkView) return; // the library grids are complete as rendered
    if (_loadingMore || _loading || !_hasNext || _page >= _maxPages) return;
    final seq = _querySeq;
    final next = _page + 1;
    setState(() => _loadingMore = true);
    ref.read(gifCatalogProvider).page(_search, next, _rating).then((p) {
      if (!mounted || seq != _querySeq) return;
      setState(() {
        _loadingMore = false;
        _page = next;
        _hasNext = p.hasNext && next < _maxPages;
        final seen = _items.map((e) => e.id).toSet();
        _items = [..._items, ...p.items.where((e) => !seen.contains(e.id))];
      });
    }).catchError((_) {
      if (!mounted || seq != _querySeq) return;
      setState(() => _loadingMore = false);
    });
  }

  Future<void> _pick(gifs_api.GifItem item) async {
    if (_pickingId != null) return;
    _dbg('pick start');
    final t0 = DateTime.now();
    setState(() => _pickingId = item.id);
    try {
      // sourceUrl matters only in direct mode, and only for a favourite
      // whose variants are no longer in Rust's session registry. Proxy mode
      // ignores it outright and builds its own URL.
      final stored = await gifs_api.gifFetchAndStore(
          id: item.id, sourceUrl: item.fullUrl);
      _dbg('pick ok in ${DateTime.now().difference(t0).inMilliseconds}ms');
      ref.read(gifLibraryProvider.notifier).noteUsed(item);
      if (!mounted) return;
      widget.onSelect('[a:g:${stored.hash}:${stored.w}:${stored.h}]');
    } catch (e) {
      _dbg('pick ERROR in ${DateTime.now().difference(t0).inMilliseconds}ms: '
          '$e');
      if (!mounted) return;
      HollowToast.show(context, 'Could not add GIF',
          type: HollowToastType.error);
    } finally {
      // The panel now SURVIVES the pick, so this has to be cleared on the
      // success path too — it used to ride out on the teardown, and leaving
      // it set would freeze every later pick behind `if (_pickingId != null)`.
      if (mounted) setState(() => _pickingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Rating changes (Settings, or a clamp resolving once the server's NSFW
    // flag loads) must re-issue the current query — results are cached per
    // rating, so the old grid would otherwise just sit there. ref.listen
    // belongs in build(); registering it in initState silently no-ops. The
    // re-query is deferred a frame because _runQuery calls setState and a
    // listener can fire inside someone else's build.
    void requery(_, __) => WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _runQuery();
        });
    ref.listen(gifRatingProvider, requery);
    if (widget.serverId != null) {
      ref.listen(serverIsNsfwProvider(widget.serverId!), requery);
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.sm, HollowSpacing.sm, HollowSpacing.sm, 0),
          child: HollowTextField(
            controller: _searchController,
            // Attribution: KLIPY asks for this exact placeholder.
            hintText: 'Search KLIPY',
            isDense: true,
            prefixIcon: const Icon(LucideIcons.search, size: 14),
            // Desktop only — on mobile the autofocus summons the software
            // keyboard right over the sheet.
            autofocus: !(Platform.isAndroid || Platform.isIOS),
          ),
        ),
        // The tabs stay PUT while searching — they just lose their selected
        // state (see _tabChip). A row that vanishes under you as you type
        // moves the content beneath it and hides where you came from.
        _tabRow(hollow),
        Divider(height: 1, color: hollow.border),
        Expanded(child: _content(hollow)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            'Powered by KLIPY',
            style: HollowTypography.caption
                .copyWith(color: hollow.textTertiary, fontSize: 10),
          ),
        ),
      ],
    );
  }

  Widget _tabRow(HollowTheme hollow) {
    // Scrollable so a larger-text setting can never overflow the 360px
    // panel; with three short labels it never actually scrolls, and
    // EdgeScrollRow shows nothing until it does.
    return EdgeScrollRow(
      height: 34,
      semanticLabel: 'tabs',
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm, vertical: 5),
      children: [
        _tabChip(hollow, GifPickerTab.popular, 'Popular'),
        const SizedBox(width: 4),
        _tabChip(hollow, GifPickerTab.favorites, 'Favourites'),
        const SizedBox(width: 4),
        _tabChip(hollow, GifPickerTab.recent, 'Recent'),
      ],
    );
  }

  Widget _tabChip(HollowTheme hollow, GifPickerTab tab, String label) {
    // Searching is its own view, so NOTHING is selected while the field has
    // text — tapping a tab is how you get back out (see _selectTab).
    final selected = _tab == tab && _search.isEmpty;
    return HollowPressable(
      onTap: () => _selectTab(tab),
      semanticLabel: '$label GIFs tab',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
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
    );
  }

  Widget _content(HollowTheme hollow) {
    if (!_networkView) {
      return _tab == GifPickerTab.favorites
          ? _favoritesView(hollow)
          : _recentView(hollow);
    }
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
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style:
                  HollowTypography.caption.copyWith(color: hollow.textTertiary),
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowButton.ghost(
              compact: true,
              icon: const Icon(LucideIcons.rotateCcw, size: 14),
              onPressed: _runQuery,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (_items.isEmpty) return _emptyHint(hollow, 'No GIFs found');
    return _grid(hollow, _items);
  }

  // --- Favourites -----------------------------------------------------------

  Widget _favoritesView(HollowTheme hollow) {
    final library = ref.watch(gifLibraryProvider);
    final base = ref.watch(gifProxyUrlProvider);
    final saved = library.favoritesIn(_collectionId);
    return Column(
      children: [
        _listChips(hollow, library),
        Expanded(
          child: saved.isEmpty
              ? _emptyHint(
                  hollow,
                  _collectionId == null
                      ? 'No favourites yet\nTap the star on any GIF to keep it here'
                      : 'This list is empty\nRight-click a favourite to add it')
              : _grid(hollow, [for (final g in saved) g.toItem(base)],
                  inFavorites: true),
        ),
      ],
    );
  }

  Widget _listChips(HollowTheme hollow, GifLibrary library) {
    if (_listEditId != null) return _listNameField(hollow);
    // EdgeScrollRow, not a bare horizontal ListView: past a handful of lists
    // the chips overflow the 360px panel, and on a desktop with a plain
    // wheel mouse a bare scroller has no affordance and no gesture — the
    // extra lists were simply unreachable. Arrows + wheel-to-pan appear only
    // while there IS overflow.
    return EdgeScrollRow(
      height: 34,
      semanticLabel: 'lists',
      padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm, vertical: 5),
      children: [
          _listChip(hollow, null, 'All'),
          for (final c in library.collections) ...[
            const SizedBox(width: 4),
            _listChip(hollow, c.id, c.name),
          ],
          const SizedBox(width: 4),
          HollowPressable(
            onTap: () {
              _listNameController.text = '';
              setState(() => _listEditId = '');
            },
            semanticLabel: 'New favourites list',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: EdgeInsets.zero,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                border: Border.all(color: hollow.border),
              ),
              child: Icon(LucideIcons.plus,
                  size: 12, color: hollow.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _listChip(HollowTheme hollow, String? id, String name) {
    final selected = _collectionId == id;
    Widget chip = HollowPressable(
      onTap: () => setState(() => _collectionId = id),
      semanticLabel: 'Show $name favourites',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: EdgeInsets.zero,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? hollow.accent.withValues(alpha: 0.15) : null,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(
            color:
                selected ? hollow.accent.withValues(alpha: 0.4) : hollow.border,
          ),
        ),
        child: Text(
          name,
          style: HollowTypography.caption.copyWith(
            color: selected ? hollow.accentText : hollow.textSecondary,
            fontSize: 11,
          ),
        ),
      ),
    );
    if (id == null) return chip;
    return GestureDetector(
      onSecondaryTapDown: (d) => _showListMenu(id, name, d.globalPosition),
      onLongPressStart: (d) => _showListMenu(id, name, d.globalPosition),
      child: chip,
    );
  }

  Widget _listNameField(HollowTheme hollow) {
    final creating = _listEditId!.isEmpty;
    void commit() {
      final notifier = ref.read(gifLibraryProvider.notifier);
      final name = _listNameController.text;
      if (creating) {
        final id = notifier.createCollection(name);
        setState(() {
          _listEditId = null;
          if (id != null) _collectionId = id;
        });
      } else {
        notifier.renameCollection(_listEditId!, name);
        setState(() => _listEditId = null);
      }
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.sm, 4, HollowSpacing.sm, 4),
      child: Row(
        children: [
          Expanded(
            child: HollowTextField(
              controller: _listNameController,
              hintText: creating ? 'New list name' : 'Rename list',
              isDense: true,
              autofocus: true,
              maxLength: kMaxGifListNameLength,
              onSubmitted: (_) => commit(),
            ),
          ),
          const SizedBox(width: 4),
          HollowPressable(
            onTap: commit,
            semanticLabel: creating ? 'Create list' : 'Rename list',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(6),
            child: Icon(LucideIcons.check, size: 14, color: hollow.accentText),
          ),
          HollowPressable(
            onTap: () => setState(() => _listEditId = null),
            semanticLabel: 'Cancel',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(6),
            child: Icon(LucideIcons.x, size: 14, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }

  void _showListMenu(String id, String name, Offset globalPosition) {
    final notifier = ref.read(gifLibraryProvider.notifier);
    showGifMenu(
      context,
      globalPosition,
      header: name,
      items: [
        GifMenuItem(
          icon: LucideIcons.pencil,
          label: 'Rename list',
          onTap: () {
            _listNameController.text = name;
            setState(() => _listEditId = id);
          },
        ),
        GifMenuItem(
          icon: LucideIcons.trash2,
          label: 'Delete list',
          danger: true,
          onTap: () {
            notifier.deleteCollection(id);
            setState(() {
              if (_collectionId == id) _collectionId = null;
            });
          },
        ),
      ],
    );
  }

  // --- Recent ---------------------------------------------------------------

  Widget _recentView(HollowTheme hollow) {
    final recents = ref.watch(gifLibraryProvider).visibleRecents;
    final base = ref.watch(gifProxyUrlProvider);
    if (recents.isEmpty) {
      return _emptyHint(
          hollow, 'Nothing here yet\nGIFs you send show up here');
    }
    return _grid(hollow, [for (final g in recents) g.toItem(base)],
        inRecents: true);
  }

  // --- Shared grid ----------------------------------------------------------

  static const _gap = 4.0;

  Widget _grid(
    HollowTheme hollow,
    List<gifs_api.GifItem> items, {
    bool inFavorites = false,
    bool inRecents = false,
  }) {
    return LayoutBuilder(builder: (context, constraints) {
      final colW =
          (constraints.maxWidth - HollowSpacing.sm * 2 - _gap) / 2;
      final viewport = constraints.maxHeight;

      // Masonry from known aspect ratios — nothing reflows when bytes land.
      final colTops = [0.0, 0.0];
      final cols = [<Widget>[], <Widget>[]];
      for (final item in items) {
        final aspect = (item.w / item.h).clamp(0.6, 2.5);
        final cellH = colW / aspect;
        final c = colTops[0] <= colTops[1] ? 0 : 1;
        final top = colTops[c];
        // "Visible viewport + ~1 row" gate — this is what autoplays.
        final visible = top < _scrollOffset + viewport + cellH &&
            top + cellH > _scrollOffset - cellH;
        // Stills load only near the viewport (±1 screen) — an off-screen
        // tail of 30-150 cells must not open downloads at picker-open.
        final nearViewport = top < _scrollOffset + viewport * 2 &&
            top + cellH > _scrollOffset - viewport;
        cols[c].add(Padding(
          padding: const EdgeInsets.only(bottom: _gap),
          child: _GifCell(
            key: ValueKey(item.id),
            item: item,
            width: colW,
            height: cellH,
            visible: visible,
            nearViewport: nearViewport,
            picking: _pickingId == item.id,
            enabled: _pickingId == null,
            onTap: () => _pick(item),
            onMenu: (pos) => _showCellMenu(item, pos,
                inFavorites: inFavorites, inRecents: inRecents),
          ),
        ));
        colTops[c] = top + cellH + _gap;
      }

      return SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(HollowSpacing.sm),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: Column(children: cols[0])),
                const SizedBox(width: _gap),
                Expanded(child: Column(children: cols[1])),
              ],
            ),
            if (_loadingMore)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: hollow.textTertiary),
                ),
              ),
          ],
        ),
      );
    });
  }

  void _showCellMenu(
    gifs_api.GifItem item,
    Offset globalPosition, {
    required bool inFavorites,
    required bool inRecents,
  }) {
    final library = ref.read(gifLibraryProvider);
    final notifier = ref.read(gifLibraryProvider.notifier);
    final fav = library.isFavorite(item.id);
    final title = item.title.trim();
    showGifMenu(
      context,
      globalPosition,
      header: title.isEmpty ? 'GIF' : title,
      items: [
        GifMenuItem(
          icon: fav ? LucideIcons.starOff : LucideIcons.star,
          label: fav ? 'Remove from favourites' : 'Add to favourites',
          danger: fav,
          onTap: () => notifier.toggleFavorite(item),
        ),
        // Lists sort FAVOURITES, so they only appear once the GIF is one.
        if (fav)
          for (final c in library.collections)
            GifMenuItem(
              icon: c.gifIds.contains(item.id)
                  ? LucideIcons.check
                  : LucideIcons.listPlus,
              label: c.name,
              onTap: () => notifier.setInCollection(
                  c.id, item.id, !c.gifIds.contains(item.id)),
            ),
        if (fav && library.collections.isEmpty && inFavorites)
          GifMenuItem(
            icon: LucideIcons.plus,
            label: 'New list…',
            onTap: () {
              _listNameController.text = '';
              setState(() => _listEditId = '');
            },
          ),
        if (inRecents)
          GifMenuItem(
            icon: LucideIcons.trash2,
            label: 'Remove from recent',
            danger: true,
            onTap: () => notifier.removeRecent(item.id),
          ),
      ],
    );
  }

  Widget _emptyHint(HollowTheme hollow, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.md),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Anchored menu — inserted as an OverlayEntry ON TOP of the root overlay. The
// picker is itself a raw OverlayEntry above the navigator's routes, so a
// dialog route would render BEHIND it (same trap as the emote context menu).
// ---------------------------------------------------------------------------

class GifMenuItem {
  final IconData icon;
  final String label;
  final bool danger;
  final VoidCallback onTap;

  const GifMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });
}

void showGifMenu(
  BuildContext context,
  Offset globalPosition, {
  required String header,
  required List<GifMenuItem> items,
}) {
  if (items.isEmpty) return;
  final position = overlayPositionOf(context, globalPosition);
  final hollow = HollowTheme.of(context);
  const menuWidth = 200.0;
  final screen = MediaQuery.of(context).size;
  final left = position.dx.clamp(8.0, (screen.width - menuWidth - 8).clamp(8.0, double.infinity));
  final maxTop = (screen.height - 56 - items.length * 30.0).clamp(8.0, double.infinity);
  final top = position.dy.clamp(8.0, maxTop);

  final overlay = Overlay.of(context);
  late OverlayEntry entry;
  // Same double-remove guard as the picker itself.
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
                      blurRadius: 12),
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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final item in items)
                          HollowPressable(
                            onTap: () {
                              dismiss();
                              item.onTap();
                            },
                            semanticLabel: item.label,
                            borderRadius:
                                BorderRadius.circular(hollow.radiusSm),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 6),
                            child: Row(
                              children: [
                                Icon(item.icon,
                                    size: 14,
                                    color: item.danger
                                        ? hollow.error
                                        : hollow.textSecondary),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    item.label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: HollowTypography.label.copyWith(
                                      color: item.danger
                                          ? hollow.error
                                          : hollow.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
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
// Grid cell: still thumbnail, animating to the sm variant on hover (desktop)
// or while in the viewport (mobile). Reduce-motion is handled inside
// AnimatedGifImage; stills always render.
// ---------------------------------------------------------------------------

class _GifCell extends ConsumerStatefulWidget {
  final gifs_api.GifItem item;
  final double width;
  final double height;
  final bool visible;
  final bool nearViewport;
  final bool picking;
  final bool enabled;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;

  const _GifCell({
    super.key,
    required this.item,
    required this.width,
    required this.height,
    required this.visible,
    required this.nearViewport,
    required this.picking,
    required this.enabled,
    required this.onTap,
    required this.onMenu,
  });

  @override
  ConsumerState<_GifCell> createState() => _GifCellState();
}

class _GifCellState extends ConsumerState<_GifCell> {
  Uint8List? _still;
  Uint8List? _sm;
  bool _stillRequested = false;
  bool _smRequested = false;
  bool _hovering = false;

  static bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (widget.nearViewport) _loadStill();
  }

  @override
  void didUpdateWidget(covariant _GifCell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.id != widget.item.id) {
      _still = null;
      _sm = null;
      _stillRequested = false;
      _smRequested = false;
    }
    if (widget.nearViewport && !_stillRequested) _loadStill();
  }

  void _loadStill() {
    _stillRequested = true;
    final id = widget.item.id;
    GifThumbCache.instance.load(widget.item.stillUrl).then((bytes) {
      if (!mounted || widget.item.id != id || bytes == null) return;
      setState(() => _still = bytes);
    }).catchError((_) {});
  }

  void _loadSm() {
    if (_smRequested) return;
    _smRequested = true;
    final id = widget.item.id;
    GifThumbCache.instance.load(widget.item.smUrl).then((bytes) {
      if (!mounted || widget.item.id != id || bytes == null) return;
      setState(() => _sm = bytes);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final focused = ref.watch(windowFocusedProvider);
    final isFavorite = ref.watch(
        gifLibraryProvider.select((l) => l.isFavorite(widget.item.id)));
    // AUTOPLAY (default): anything actually in the viewport animates, on
    // every platform. Bounded on three sides — only VISIBLE cells (not the
    // ±1-screen still-preload margin), only while the window is focused, and
    // AnimatedGifImage freezes itself under reduce-motion.
    //
    // OFF falls back to hover-to-play, which on mobile means stills only —
    // that IS the point, since the setting's real cost is data: autoplay
    // fetches the animated variant for everything on screen where hover
    // fetches one. Either way the still paints first and the animation swaps
    // in as it lands.
    final wantsAnim =
        focused && (ref.watch(gifAutoplayProvider) ? widget.visible : _hovering);
    if (wantsAnim) _loadSm();

    final Widget image;
    final sm = _sm;
    final still = _still;
    if (wantsAnim && sm != null) {
      image = AnimatedGifImage(
        bytes: sm,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
      );
    } else if (still != null) {
      image = Image.memory(
        still,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, _, _) => Container(color: hollow.elevated),
      );
    } else {
      image = Container(color: hollow.elevated);
    }

    final title = widget.item.title.trim();
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onSecondaryTapDown: (d) => widget.onMenu(d.globalPosition),
        onLongPressStart: (d) => widget.onMenu(d.globalPosition),
        child: HollowPressable(
          onTap: widget.enabled ? widget.onTap : null,
          semanticLabel: title.isEmpty ? 'Insert GIF' : 'Insert GIF $title',
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: EdgeInsets.zero,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: SizedBox(
              width: widget.width,
              height: widget.height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  image,
                  // Always visible once favourited, so the grid shows at a
                  // glance what is saved; otherwise hover-only on desktop.
                  if (isFavorite || _hovering || _isMobile)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: _star(hollow, isFavorite),
                    ),
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
        ),
      ),
    );
  }

  Widget _star(HollowTheme hollow, bool isFavorite) {
    // Material's star pair rather than Lucide: neither Lucide nor Atlas ships
    // a FILLED star, and filled-vs-outline is the whole signal here (same
    // reasoning as the composer's "GIF" text badge, which exists because
    // neither set has a GIF glyph).
    return HollowPressable(
      onTap: () => ref
          .read(gifLibraryProvider.notifier)
          .toggleFavorite(widget.item),
      semanticLabel:
          isFavorite ? 'Remove GIF from favourites' : 'Add GIF to favourites',
      borderRadius: BorderRadius.circular(999),
      padding: EdgeInsets.zero,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(
          isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
          size: 16,
          color: isFavorite ? hollow.accent : Colors.white,
        ),
      ),
    );
  }
}
