import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/core/providers/help_manifest_provider.dart';
import 'package:hollow/src/core/providers/help_panel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_empty_state.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'guides_models.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';

/// Width of the desktop Help slide-out panel.
const double kHelpPanelWidth = 340;

/// The Help panel's place on the RIGHT edge. It shows and hides instantly: a
/// width animation would re-wrap the chat text on every frame.
class HelpPanelSlider extends StatelessWidget {
  final bool visible;
  const HelpPanelSlider({super.key, required this.visible});

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return const RepaintBoundary(child: _HelpPanelChrome());
  }
}

/// Desktop panel chrome: fixed width, left border, holds the resource center.
class _HelpPanelChrome extends ConsumerWidget {
  const _HelpPanelChrome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    return Container(
      width: kHelpPanelWidth,
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(left: BorderSide(color: hollow.border)),
      ),
      child: HelpResourceCenter(
        onClose: () =>
            ref.read(helpPanelOpenProvider.notifier).state = false,
      ),
    );
  }
}

/// The resource-center body, shared by the desktop slide-out panel and the
/// mobile full-screen route.
class HelpResourceCenter extends ConsumerStatefulWidget {
  /// Shown as an X in the header; null on mobile, where the route has its own
  /// back chrome.
  final VoidCallback? onClose;
  const HelpResourceCenter({super.key, this.onClose});

  @override
  ConsumerState<HelpResourceCenter> createState() =>
      _HelpResourceCenterState();
}

class _HelpResourceCenterState extends ConsumerState<HelpResourceCenter> {
  final _searchController = TextEditingController();
  String _query = '';
  GuidesLesson? _openLesson;
  final Set<String> _expanded = {};
  bool _seededExpansion = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openLessonView(GuidesLesson lesson) =>
      setState(() => _openLesson = lesson);
  void _backToList() => setState(() => _openLesson = null);

  List<GuidesLesson> _searchResults(GuidesManifest manifest) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return [
      for (final m in manifest.modules)
        for (final l in m.lessons)
          if (l.title.toLowerCase().contains(q)) l,
    ];
  }

  Widget _header(HollowTheme hollow) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.lg,
        HollowSpacing.lg,
        HollowSpacing.sm,
        HollowSpacing.md,
      ),
      child: Row(
        children: [
          Icon(LucideIcons.circleHelp,
              size: 18, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Text(
              'Help',
              style: HollowTypography.subheading
                  .copyWith(color: hollow.textPrimary),
            ),
          ),
          if (widget.onClose != null)
            HollowPressable(
              onTap: widget.onClose,
              semanticLabel: 'Close',
              borderRadius:
                  BorderRadius.circular(hollow.radiusMd),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.x,
                  size: 18, color: hollow.textSecondary),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final manifestAsync = ref.watch(helpManifestProvider);

    return SafeArea(
      child: manifestAsync.when(
        loading: () => const Center(child: HollowSpinner.large(delayed: true)),
        error: (_, _) => Column(
          children: [
            _header(hollow),
            Expanded(
              child: HollowEmptyState(
                title: "Help didn't load",
                action: HollowButton.ghost(
                  onPressed: () => ref.invalidate(helpManifestProvider),
                  loading: manifestAsync.isLoading,
                  child: const Text('Try again'),
                ),
              ),
            ),
          ],
        ),
        data: (manifest) {
          // Expand the first module by default, once.
          if (!_seededExpansion && manifest.modules.isNotEmpty) {
            _expanded.add(manifest.modules.first.id);
            _seededExpansion = true;
          }

          if (_openLesson != null) {
            return HelpLessonView(
              lesson: _openLesson!,
              onBack: _backToList,
            );
          }

          final searching = _query.trim().isNotEmpty;
          final results = _searchResults(manifest);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(hollow),

              Padding(
                padding: const EdgeInsets.fromLTRB(
                  HollowSpacing.lg,
                  0,
                  HollowSpacing.lg,
                  HollowSpacing.md,
                ),
                child: HollowTextField(
                  controller: _searchController,
                  hintText: 'Search help…',
                  isDense: true,
                  prefixIcon: Icon(LucideIcons.search,
                      size: 16, color: hollow.textSecondary),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),

              const HollowDivider(),

              Expanded(
                child: searching
                    ? _SearchResults(
                        results: results,
                        onTap: _openLessonView,
                      )
                    : ListView(
                        padding: const EdgeInsets.symmetric(
                          vertical: HollowSpacing.sm,
                        ),
                        children: [
                          for (final m in manifest.modules)
                            _CategorySection(
                              module: m,
                              expanded: _expanded.contains(m.id),
                              onToggle: () => setState(() {
                                _expanded.contains(m.id)
                                    ? _expanded.remove(m.id)
                                    : _expanded.add(m.id);
                              }),
                              onLessonTap: _openLessonView,
                            ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  final List<GuidesLesson> results;
  final ValueChanged<GuidesLesson> onTap;
  const _SearchResults({required this.results, required this.onTap});

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const HollowEmptyState(
        glyph: LucideIcons.searchX,
        title: 'No help articles match that',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      itemCount: results.length,
      itemBuilder: (_, i) => _LessonRow(lesson: results[i], onTap: onTap),
    );
  }
}

class _CategorySection extends StatelessWidget {
  final GuidesModule module;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<GuidesLesson> onLessonTap;

  const _CategorySection({
    required this.module,
    required this.expanded,
    required this.onToggle,
    required this.onLessonTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HollowPressable(
          subtle: true,
          onTap: onToggle,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.lg,
            vertical: HollowSpacing.md,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      module.title,
                      style: HollowTypography.label
                          .copyWith(color: hollow.textPrimary),
                    ),
                    if (module.subtitle != null) ...[
                      const SizedBox(height: HollowSpacing.xxs),
                      Text(
                        module.subtitle!,
                        style: HollowTypography.caption
                            .copyWith(color: hollow.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              AnimatedRotation(
                turns: expanded ? 0.25 : 0.0,
                duration: HollowDurations.fast,
                curve: HollowCurves.subtle,
                child: Icon(LucideIcons.chevronRight,
                    size: 16, color: hollow.textSecondary),
              ),
            ],
          ),
        ),
        if (expanded)
          ...module.lessons.map(
            (l) => _LessonRow(lesson: l, onTap: onLessonTap, inset: true),
          ),
      ],
    );
  }
}

class _LessonRow extends StatelessWidget {
  final GuidesLesson lesson;
  final ValueChanged<GuidesLesson> onTap;
  final bool inset;
  const _LessonRow({
    required this.lesson,
    required this.onTap,
    this.inset = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      subtle: true,
      onTap: () => onTap(lesson),
      padding: EdgeInsets.fromLTRB(
        inset ? HollowSpacing.xl : HollowSpacing.lg,
        HollowSpacing.sm,
        HollowSpacing.lg,
        HollowSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            child: Text(
              lesson.id,
              style: HollowTypography.monoSmall
                  .copyWith(color: hollow.accentText),
            ),
          ),
          const SizedBox(width: HollowSpacing.xs),
          Expanded(
            child: Text(
              lesson.title,
              style:
                  HollowTypography.body.copyWith(color: hollow.textPrimary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// A lesson rendered as ONE scrollable page of stacked sections, with no paging
/// and no arrows. Shared by the desktop panel and the mobile route.
class HelpLessonView extends StatelessWidget {
  final GuidesLesson lesson;
  final VoidCallback onBack;
  const HelpLessonView({
    super.key,
    required this.lesson,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.sm,
            HollowSpacing.md,
            HollowSpacing.lg,
            HollowSpacing.md,
          ),
          child: Row(
            children: [
              HollowPressable(
                onTap: onBack,
                semanticLabel: 'Back',
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                padding: const EdgeInsets.all(HollowSpacing.xs),
                child: Icon(LucideIcons.arrowLeft,
                    size: 18, color: hollow.textSecondary),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Expanded(
                child: Text(
                  lesson.title,
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.textPrimary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const HollowDivider(),

        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(HollowSpacing.lg),
            itemCount: lesson.sections.length,
            separatorBuilder: (_, _) =>
                const SizedBox(height: HollowSpacing.lg),
            itemBuilder: (_, i) => _SectionView(section: lesson.sections[i]),
          ),
        ),
      ],
    );
  }
}

/// One section: optional small inline image, then markdown text.
class _SectionView extends StatelessWidget {
  final GuidesSection section;
  const _SectionView({required this.section});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (section.media != null) ...[
          _InlineImage(asset: section.media!),
          const SizedBox(height: HollowSpacing.sm),
        ],
        HelpMarkdown(text: section.text),
      ],
    );
  }
}

class _InlineImage extends StatelessWidget {
  final String asset;
  const _InlineImage({required this.asset});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusMd);
    return Align(
      alignment: Alignment.centerLeft,
      child: ClipRRect(
        borderRadius: radius,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: hollow.border),
            color: hollow.background,
          ),
          padding: const EdgeInsets.all(HollowSpacing.xs),
          child: Image.asset(
            asset,
            // Small by design — inline icon/control shot, not a hero image.
            height: 48,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => Icon(
              LucideIcons.image,
              size: 28,
              color: hollow.textSecondary.withValues(alpha: 0.4),
            ),
          ),
        ),
      ),
    );
  }
}

/// Markdown body, on the news-post markdown styling.
class HelpMarkdown extends StatelessWidget {
  final String text;
  const HelpMarkdown({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return MarkdownBody(
      data: text,
      shrinkWrap: true,
      selectable: true,
      onTapLink: (text, href, title) {
        if (href != null) {
          launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
        }
      },
      styleSheet: MarkdownStyleSheet(
        p: HollowTypography.body
            .copyWith(color: hollow.textPrimary, height: 1.55),
        strong: HollowTypography.body.copyWith(
          color: hollow.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        code: HollowTypography.mono.copyWith(
          color: hollow.accentText,
          backgroundColor: hollow.background,
        ),
        a: HollowTypography.body.copyWith(
          color: hollow.accent,
          decoration: TextDecoration.underline,
          decorationColor: hollow.accent,
        ),
        listBullet:
            HollowTypography.body.copyWith(color: hollow.textSecondary),
        blockSpacing: 8,
      ),
    );
  }
}
