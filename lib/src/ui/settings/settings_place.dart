import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/theme/hollow_shadows.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_catalog.dart';
import 'package:hollow/src/ui/settings/settings_pages.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The rail's width, a navigation sidebar's (design language 5.2).
const double kSettingsRailWidth = 240;

/// The page column's widest, set by the prose in its rows.
const double kSettingsPageMaxWidth = 720;

/// Where the rail's visible edge starts: the title, the search box and the
/// item fills all line up on it.
const double _railEdgeInset = HollowSpacing.md;

const _pagePadding = EdgeInsets.fromLTRB(
  HollowSpacing.xxl,
  HollowSpacing.xl,
  HollowSpacing.xxxl,
  HollowSpacing.xxxl + HollowSpacing.xxxl,
);

/// Settings as a place: it takes the centre like the Shop or the Archive, so
/// the dock and header (and a call's controls) stay in reach.
///
/// On a wide window the rail and its page centre as a PAIR, the rail's chrome
/// running out to the left edge; below that width the pair hugs the left edge.
/// Either way every region touches an edge of the window.
class SettingsPlace extends ConsumerStatefulWidget {
  const SettingsPlace({super.key});

  @override
  ConsumerState<SettingsPlace> createState() => _SettingsPlaceState();
}

class _SettingsPlaceState extends ConsumerState<SettingsPlace> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _go(SettingsCategory category) {
    ref.read(settingsCategoryProvider.notifier).state = category;
    _search.clear();
    setState(() => _query = '');
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return KeyEventResult.ignored;
    }
    // Escape leaves the innermost layer first: a search, then Settings.
    if (_query.isNotEmpty) {
      _search.clear();
      setState(() => _query = '');
    } else {
      setShellTab(ref.read, null);
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final category = ref.watch(settingsCategoryProvider);
    final searching = _query.trim().isNotEmpty;

    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: LayoutBuilder(builder: (context, constraints) {
        // Centre what the eye reads as the block: from the rail's left edge
        // (title, search box) to the page column's end, so the gaps either
        // side measure the same.
        const visible = kSettingsRailWidth -
            _railEdgeInset +
            HollowSpacing.xxl +
            kSettingsPageMaxWidth;
        final bleed = ((constraints.maxWidth - visible) / 2 - _railEdgeInset)
            .clamp(0.0, double.infinity)
            .floorToDouble();
        return ColoredBox(
          color: hollow.background,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (bleed > 0) SizedBox(width: bleed, child: ColoredBox(color: hollow.surface)),
              _Rail(
                active: searching ? null : category,
                search: _search,
                onQuery: (q) => setState(() => _query = q),
                onSelect: _go,
              ),
              Expanded(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: FocusTraversalGroup(
                        policy: ReadingOrderTraversalPolicy(),
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: _pagePadding,
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                  maxWidth: kSettingsPageMaxWidth),
                              child: searching
                                  ? _SearchResults(
                                      query: _query.trim(), onOpen: _go)
                                  : KeyedSubtree(
                                      key: ValueKey(category),
                                      child: settingsPageFor(category),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: HollowSpacing.lg,
                      right: HollowSpacing.lg,
                      child: HollowIconButton(
                        icon: LucideIcons.x,
                        label: 'Close settings',
                        tooltip: 'Close settings (Esc)',
                        onPressed: () => setShellTab(ref.read, null),
                      ),
                    ),
                    Positioned(
                      left: HollowSpacing.xxl,
                      right: HollowSpacing.xxxl,
                      bottom: HollowSpacing.lg,
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                              maxWidth: kSettingsPageMaxWidth),
                          child: const _UnsavedProfileBar(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

class _Rail extends StatelessWidget {
  final SettingsCategory? active;
  final TextEditingController search;
  final ValueChanged<String> onQuery;
  final ValueChanged<SettingsCategory> onSelect;

  const _Rail({
    required this.active,
    required this.search,
    required this.onQuery,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    Widget item(SettingsCategory c) => Padding(
          padding: const EdgeInsets.only(bottom: HollowSpacing.xxs),
          child: SettingsRailItem(
            icon: c.icon,
            label: c.label,
            selected: c == active,
            onTap: () => onSelect(c),
          ),
        );
    Widget group(String label) => Padding(
          padding: const EdgeInsets.fromLTRB(
              HollowSpacing.md, HollowSpacing.md, HollowSpacing.md, HollowSpacing.xs),
          child: Text(
            label,
            style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
          ),
        );

    return Container(
      width: kSettingsRailWidth,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(right: BorderSide(color: hollow.border)),
      ),
      child: FocusTraversalGroup(
        policy: ReadingOrderTraversalPolicy(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              // The title sits on the search box's edge, which heads the
              // column; the group labels stay over the icons they name.
              padding: const EdgeInsets.fromLTRB(
                  HollowSpacing.md, HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.md),
              child: Text(
                'Settings',
                style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
              child: HollowTextField(
                controller: search,
                hintText: 'Search settings',
                isDense: true,
                prefixIcon:
                    Icon(LucideIcons.search, size: 16, color: hollow.textSecondary),
                onChanged: onQuery,
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                    HollowSpacing.md, 0, HollowSpacing.md, HollowSpacing.lg),
                children: [
                  for (final g in SettingsGroup.values) ...[
                    group(g.label),
                    for (final c in SettingsCategory.values)
                      if (c.group == g) item(c),
                  ],
                  const Padding(
                    padding: EdgeInsets.symmetric(
                        vertical: HollowSpacing.sm, horizontal: HollowSpacing.md),
                    child: HollowDivider(),
                  ),
                  for (final c in SettingsCategory.values)
                    if (c.group == null) item(c),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One entry in a settings rail: a grey icon and the page's name. The page on
/// screen takes a surface fill and brighter text, nothing else.
class SettingsRailItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const SettingsRailItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      selected: selected,
      child: HollowPressable(
        onTap: onTap,
        subtle: true,
        backgroundColor: selected ? hollow.elevated : null,
        hoverColor: hollow.elevated,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        // 32 tall: the whole rail fits a 768 px laptop screen unscrolled.
        padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.md,
            vertical: HollowSpacing.xs + HollowSpacing.xxs),
        child: Row(
          children: [
            Icon(icon, size: 16, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: HollowTypography.label.copyWith(
                  color: selected ? hollow.textPrimary : hollow.textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  final String query;
  final ValueChanged<SettingsCategory> onOpen;

  const _SearchResults({required this.query, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hits = [
      for (final c in SettingsCategory.values)
        if (c.label.toLowerCase().contains(query.toLowerCase()))
          SettingsSearchEntry(c.label, c),
      for (final e in kSettingsSearchIndex)
        if (e.matches(query) && e.label != e.category.label) e,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Results',
            style: HollowTypography.heading.copyWith(color: hollow.textPrimary)),
        const SizedBox(height: HollowSpacing.md),
        if (hits.isEmpty)
          const HollowEmptyState(
            dense: true,
            title: 'No setting matches that',
            description: 'Try a shorter word.',
          )
        else
          for (final e in hits)
            HollowPressable(
              onTap: () => onOpen(e.category),
              subtle: true,
              hoverColor: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md, vertical: HollowSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.label,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary)),
                  Text(e.category.label,
                      style: HollowTypography.bodySmall
                          .copyWith(color: hollow.textSecondary)),
                ],
              ),
            ),
      ],
    );
  }
}

/// The one reminder that Profile holds unsaved edits, on every Settings page
/// until they are saved or reset.
class _UnsavedProfileBar extends ConsumerWidget {
  const _UnsavedProfileBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(profileDraftProvider);
    if (!draft.dirty) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.lg, HollowSpacing.sm, HollowSpacing.sm, HollowSpacing.sm),
      decoration: BoxDecoration(
        color: hollow.overlay,
        borderRadius: BorderRadius.circular(hollow.radiusLg),
        border: Border.all(color: hollow.border),
        boxShadow: HollowShadows.float,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'You have unsaved profile changes',
              style: HollowTypography.body.copyWith(color: hollow.textPrimary),
            ),
          ),
          HollowButton.ghost(
            onPressed: draft.saving
                ? null
                : () => ref.read(profileDraftProvider.notifier).reset(),
            child: const Text('Reset'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            loading: draft.saving,
            onPressed: () async {
              try {
                await ref.read(profileDraftProvider.notifier).save();
                if (context.mounted) {
                  HollowToast.show(context, 'Profile saved',
                      type: HollowToastType.success);
                }
              } catch (e) {
                if (context.mounted) {
                  HollowToast.show(context, 'Could not save your profile: $e',
                      type: HollowToastType.error);
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
