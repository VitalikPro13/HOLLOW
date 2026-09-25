import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/settings/settings_catalog.dart';
import 'package:hollow/src/ui/settings/settings_pages.dart';
import 'package:hollow/src/ui/settings/settings_place_frame.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

export 'package:hollow/src/ui/settings/settings_place_frame.dart'
    show kSettingsRailWidth, kSettingsPageMaxWidth, SettingsRailItem;

/// Settings as a place: it takes the centre like the Shop or the Archive, so
/// the dock and header (and a call's controls) stay in reach.
///
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

  /// Escape clears a search before it closes Settings.
  bool _onEscape() {
    if (_query.isEmpty) return false;
    _search.clear();
    setState(() => _query = '');
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final category = ref.watch(settingsCategoryProvider);
    final searching = _query.trim().isNotEmpty;

    return SettingsPlaceFrame(
      rail: _Rail(
        active: searching ? null : category,
        search: _search,
        onQuery: (q) => setState(() => _query = q),
        onSelect: _go,
      ),
      page: searching
          ? _SearchResults(query: _query.trim(), onOpen: _go)
          : KeyedSubtree(
              key: ValueKey(category),
              child: settingsPageFor(category),
            ),
      scroll: _scroll,
      closeLabel: 'Close settings',
      closeTooltip: 'Close settings (Esc)',
      onClose: () => setShellTab(ref.read, null),
      onEscape: _onEscape,
      bottomBar: const _UnsavedProfileBar(),
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
    Widget item(SettingsCategory c) => SettingsRailItem(
          icon: c.icon,
          label: c.label,
          selected: c == active,
          onTap: () => onSelect(c),
        );

    return SettingsRail(
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // The title sits on the search box's edge, which heads the column;
            // the group labels stay over the icons they name.
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
        ],
      ),
      children: [
        for (final g in SettingsGroup.values) ...[
          SettingsRailGroupLabel(g.label),
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
    return SettingsUnsavedBar(
      message: 'You have unsaved profile changes',
      saving: draft.saving,
      onReset: () => ref.read(profileDraftProvider.notifier).reset(),
      onSave: () async {
        try {
          await ref.read(profileDraftProvider.notifier).save();
          if (context.mounted) {
            HollowToast.show(context, 'Profile saved',
                type: HollowToastType.success);
          }
        } catch (e) {
          if (context.mounted) {
            HollowToast.show(context, friendlyError(e,
                    fallback: "Couldn't save your profile. Try again."),
                type: HollowToastType.error);
          }
        }
      },
    );
  }
}
