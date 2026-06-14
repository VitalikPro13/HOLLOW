import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:hollow/src/core/providers/help_manifest_provider.dart';
import 'package:hollow/src/core/providers/help_panel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'guides_models.dart';

/// Width of the desktop Help slide-out panel.
const double kHelpPanelWidth = 340;

/// Animates the Help panel sliding in/out from the RIGHT edge.
/// Mirrors `_MemberPanelSlider` / `_DockSidebarSlider` in hollow_shell.dart.
class HelpPanelSlider extends StatefulWidget {
  final bool visible;
  const HelpPanelSlider({super.key, required this.visible});

  @override
  State<HelpPanelSlider> createState() => _HelpPanelSliderState();
}

class _HelpPanelSliderState extends State<HelpPanelSlider>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
      value: widget.visible ? 1.0 : 0.0,
    );
    _curved = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.enter,
      reverseCurve: HollowCurves.exit,
    );
  }

  @override
  void didUpdateWidget(HelpPanelSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) {
      _controller.duration = HollowDurations.normal;
      widget.visible ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, child) {
        if (_curved.value == 0.0) return const SizedBox.shrink();
        return ClipRect(
          child: Align(
            alignment: Alignment.centerRight,
            widthFactor: _curved.value,
            child: FadeTransition(opacity: _curved, child: child),
          ),
        );
      },
      child: const RepaintBoundary(child: _HelpPanelChrome()),
    );
  }
}

/// Desktop panel chrome — fixed width, left border, holds the resource center.
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

/// The resource-center body: header + search + collapsed category sections,
/// swapping to an in-place lesson view. Shared by the desktop slide-out panel
/// and the mobile full-screen route.
class HelpResourceCenter extends ConsumerStatefulWidget {
  /// Optional close handler — shown as an X in the header (desktop panel).
  /// Null on mobile (the route has its own back chrome).
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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final manifestAsync = ref.watch(helpManifestProvider);

    return SafeArea(
      child: manifestAsync.when(
        loading: () => const Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
        error: (_, _) => _HelpError(onClose: widget.onClose),
        data: (manifest) {
          // Expand the first module by default, once.
          if (!_seededExpansion && manifest.modules.isNotEmpty) {
            _expanded.add(manifest.modules.first.id);
            _seededExpansion = true;
          }

          // Lesson view takes over the whole body when a lesson is open.
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
              // Header.
              Padding(
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
                        borderRadius:
                            BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(LucideIcons.x,
                            size: 18, color: hollow.textSecondary),
                      ),
                  ],
                ),
              ),

              // Search.
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

              Divider(color: hollow.border, height: 1),

              // Body: search results OR collapsed category sections.
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

/// Error state — honest, with a retry.
class _HelpError extends ConsumerWidget {
  final VoidCallback? onClose;
  const _HelpError({this.onClose});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.circleAlert,
                size: 32, color: hollow.textSecondary.withValues(alpha: 0.5)),
            const SizedBox(height: HollowSpacing.md),
            Text(
              "Couldn't load the help content.",
              textAlign: TextAlign.center,
              style:
                  HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowPressable(
              onTap: () => ref.invalidate(helpManifestProvider),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
                vertical: HollowSpacing.xs,
              ),
              child: Text('Try again',
                  style:
                      HollowTypography.label.copyWith(color: hollow.accent)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Flat search-results list.
class _SearchResults extends StatelessWidget {
  final List<GuidesLesson> results;
  final ValueChanged<GuidesLesson> onTap;
  const _SearchResults({required this.results, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.searchX,
                size: 32, color: hollow.textSecondary.withValues(alpha: 0.4)),
            const SizedBox(height: HollowSpacing.md),
            Text('No help articles match that',
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      itemCount: results.length,
      itemBuilder: (_, i) => _LessonRow(lesson: results[i], onTap: onTap),
    );
  }
}

/// A collapsible module section (category).
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
                      const SizedBox(height: 2),
                      Text(
                        module.subtitle!,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 11,
                        ),
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

/// A single lesson row.
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
              style: HollowTypography.mono
                  .copyWith(color: hollow.accent, fontSize: 11),
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

// ───────────────────────── Lesson view (one scroll) ─────────────────────────

/// A lesson rendered as ONE scrollable page of stacked sections. No paging,
/// no dots, no arrows. Back arrow in the header returns to the list. Shared by
/// the desktop panel and the mobile route.
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
        // Header: back + title.
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
                borderRadius: BorderRadius.circular(hollow.radiusSm),
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
        Divider(color: hollow.border, height: 1),

        // All sections, stacked on one scroll.
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

/// A small inline image (e.g. an icon screenshot), bordered and rounded.
class _InlineImage extends StatelessWidget {
  final String asset;
  const _InlineImage({required this.asset});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusSm);
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

/// Markdown body — reuses the news-post markdown styling.
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
          color: hollow.accent,
          fontSize: 12,
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
