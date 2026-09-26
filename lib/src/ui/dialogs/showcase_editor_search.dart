import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor_draft.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Width of the search popover on desktop.
const double kGameSearchWidth = 400;

/// Opens game search as a popover hanging off [anchor] (overlay space, from
/// `overlayAnchorOf`): the one layer the editor ever puts on top of itself.
/// [alignEnd] makes [anchor] the panel's top-right corner.
Future<PickedGame?> showGameSearchPopover(
  BuildContext context, {
  required Offset anchor,
  bool alignEnd = false,
}) async {
  PickedGame? picked;
  await showHollowMenu(
    context: context,
    anchor: anchor,
    alignEnd: alignEnd,
    minWidth: kGameSearchWidth,
    maxWidth: kGameSearchWidth,
    builder: (menuContext, _) => [
      HollowMenuCustom(
        Builder(
          builder: (inner) => GameSearchPanel(
            resultsMaxHeight: 312,
            onPick: (game) {
              picked = game;
              HollowMenuScope.dismiss(inner);
            },
          ),
        ),
      ),
    ],
  );
  return picked;
}

/// Game search on a phone: a sheet holding the same panel.
Future<PickedGame?> showGameSearchSheet(BuildContext context) {
  return showHollowSheet<PickedGame>(
    context: context,
    scrollControlled: true,
    maxHeightFactor: 0.9,
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: GameSearchPanel(
        touch: true,
        onPick: (game) => Navigator.of(sheetContext).pop(game),
      ),
    ),
  );
}

/// A search field and IGDB results; choosing one hands back its basics at
/// once, and the heavy download happens after (see [bakeGame]).
class GameSearchPanel extends StatefulWidget {
  final ValueChanged<PickedGame> onPick;
  final bool touch;

  /// Caps the results list when the host gives the panel no height of its
  /// own (the popover); null lets the list take what the host gives.
  final double? resultsMaxHeight;

  const GameSearchPanel({
    super.key,
    required this.onPick,
    this.touch = false,
    this.resultsMaxHeight,
  });

  @override
  State<GameSearchPanel> createState() => _GameSearchPanelState();
}

class _GameSearchPanelState extends State<GameSearchPanel> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<showcase_api.GameSearchResult> _results = const [];
  bool _searching = false;
  bool _failed = false;

  /// The last COMPLETED query, so "no games found" speaks only about what is
  /// in the field now and never flashes during the debounce.
  String _searchedFor = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
    setState(() {});
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _failed = false;
        _searchedFor = '';
      });
      return;
    }
    setState(() {
      _searching = true;
      _failed = false;
    });
    try {
      final results = await showcase_api.showcaseGameSearch(query: query);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
        _searchedFor = query;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _failed = true;
      });
    }
  }

  void _pick(showcase_api.GameSearchResult game) => widget.onPick(
    PickedGame(
      id: game.id.toInt(),
      name: game.name,
      year: game.year,
      coverUrl: game.coverUrl,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final query = _controller.text.trim();
    final pad = widget.touch ? HollowSpacing.lg : HollowSpacing.sm;
    final Widget body;
    if (_searching) {
      body = const Padding(
        padding: EdgeInsets.all(HollowSpacing.xl),
        child: Center(child: HollowSpinner.medium()),
      );
    } else if (_failed) {
      body = const HollowEmptyState(
        dense: true,
        title: 'Search is not reachable right now',
        description: 'Check your connection and try again.',
      );
    } else if (query.isEmpty) {
      body = const HollowEmptyState(dense: true, title: 'Type a game’s name');
    } else if (_results.isEmpty && _searchedFor == query) {
      body = HollowEmptyState(
        dense: true,
        title: 'No games found for “$query”',
        description: 'Check the spelling or try a shorter name.',
      );
    } else {
      body = ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _results.length,
        itemBuilder: (context, i) {
          final game = _results[i];
          final kind = game.gameType;
          return HollowListRow(
            touch: widget.touch,
            flush: false,
            leading: _Thumb(url: game.coverUrl),
            title: game.name,
            subtitle: game.year?.toString(),
            trailing: kind != null && kind != 'Main Game'
                ? HollowBadge(kind)
                : null,
            onTap: () => _pick(game),
          );
        },
      );
    }
    return Padding(
      padding: EdgeInsets.all(pad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HollowTextField(
            controller: _controller,
            hintText: 'Find a game',
            autofocus: true,
            prefixIcon: Icon(
              LucideIcons.search,
              size: 16,
              color: hollow.textSecondary,
            ),
            onChanged: _onChanged,
            onSubmitted: (q) {
              _debounce?.cancel();
              if (_results.isNotEmpty && _searchedFor == q.trim()) {
                _pick(_results.first);
              } else {
                _search(q);
              }
            },
          ),
          const SizedBox(height: HollowSpacing.sm),
          if (widget.resultsMaxHeight != null)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.resultsMaxHeight!),
              child: body,
            )
          else
            Flexible(child: body),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.sm,
              HollowSpacing.sm,
              HollowSpacing.sm,
              HollowSpacing.xxs,
            ),
            child: Text(
              'Game data from IGDB',
              style: HollowTypography.caption.copyWith(
                color: hollow.textTertiary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A result's cover, fetched from the Hollow CDN while authoring only.
class _Thumb extends StatelessWidget {
  final String? url;

  const _Thumb({required this.url});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final fallback = Container(
      width: 32,
      height: 43,
      color: hollow.elevated,
      child: Icon(LucideIcons.gamepad2, size: 14, color: hollow.textTertiary),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusXs),
      child: url == null
          ? fallback
          : Image.network(
              url!,
              width: 32,
              height: 43,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => fallback,
            ),
    );
  }
}
