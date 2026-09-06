import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/platform_icons.dart';
import 'package:hollow/src/ui/components/showcase_image_stats.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// The tap-a-game detail card. PURE DISPLAY off replicated data: art and logos
/// come from the replicated bundle, and a store or social link opens only on an
/// explicit tap. Person-first, not a store listing.
///
/// The layout mirrors the profile dialog's panel ensemble, and the right
/// details panel appears only when it has content, so a details-less block
/// still opens a clean card.
void showGameCardDialog(
  BuildContext context, {
  required String name,
  int? year,
  required String blurb,
  required Uint8List? coverBytes,
  Uint8List? artBytes,
  required GameDetails details,
  required Map<String, Uint8List> assets,
}) {
  showHollowDialog(
    context: context,
    builder: (_) => _GameCardDialog(
      name: name,
      year: year,
      blurb: blurb,
      coverBytes: coverBytes,
      artBytes: artBytes,
      details: details,
      assets: assets,
    ),
  );
}

/// Matches the profile dialog's center card.
const double _kCenterWidth = 560.0;

const double _kSideWidth = 300.0;

const double _kPanelGap = HollowSpacing.md;

class _GameCardDialog extends StatefulWidget {
  final String name;
  final int? year;
  final String blurb;
  final Uint8List? coverBytes;
  final Uint8List? artBytes;
  final GameDetails details;
  final Map<String, Uint8List> assets;

  const _GameCardDialog({
    required this.name,
    required this.year,
    required this.blurb,
    required this.coverBytes,
    required this.artBytes,
    required this.details,
    required this.assets,
  });

  @override
  State<_GameCardDialog> createState() => _GameCardDialogState();
}

class _GameCardDialogState extends State<_GameCardDialog> {
  String get name => widget.name;
  int? get year => widget.year;
  String get blurb => widget.blurb;
  Uint8List? get coverBytes => widget.coverBytes;
  Uint8List? get artBytes => widget.artBytes;
  GameDetails get details => widget.details;
  Map<String, Uint8List> get assets => widget.assets;

  /// Probed from the cover at render time, so old boards get it too. Null until
  /// resolved, or when the art is effectively colourless, and the theme accent
  /// stands in.
  Color? _gameAccent;

  @override
  void initState() {
    super.initState();
    final probe = (coverBytes != null && coverBytes!.isNotEmpty)
        ? coverBytes
        : artBytes;
    if (probe != null && probe.isNotEmpty) {
      showcaseImageStats(probe).then((s) {
        if (mounted && s.accent != null) {
          setState(() => _gameAccent = s.accent);
        }
      });
    }
  }

  /// The profile dialog's card recipe, with the border tinted toward the game's
  /// own colour once probed.
  BoxDecoration _surface(HollowTheme hollow) => BoxDecoration(
        color: hollow.elevated.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(hollow.radiusLg),
        border: Border.all(
          color: (_gameAccent ?? hollow.accent).withValues(alpha: 0.18),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      );

  bool get _hasSidePanel =>
      details.platforms.isNotEmpty ||
      details.releaseDate.isNotEmpty ||
      (details.achievements != null && details.achievements! > 0) ||
      details.franchise.isNotEmpty ||
      details.hasRequirements ||
      details.companies.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    // showHollowDialog strips viewInsets and deliberately adds NO SafeArea, so
    // the notch and home-indicator insets are respected here or the hero's
    // close button lands in the unreachable strip.
    final safe = MediaQuery.paddingOf(context);
    final maxHeight =
        (screenSize.height - safe.vertical - HollowSpacing.xl * 2)
            .clamp(0.0, double.infinity);

    // Like the profile dialog: shrink the ensemble before giving up its shape,
    // and stack only on a tiny window.
    final sides = _hasSidePanel ? 1 : 0;
    final columnsWidth = _kCenterWidth + _kSideWidth * sides;
    final gaps = _kPanelGap * sides;
    final available = screenSize.width - HollowSpacing.xl * 2;
    final scale = sides == 0
        ? 1.0
        : ((available - gaps) / columnsWidth).clamp(0.0, 1.0);
    final stacked = sides > 0 && scale < 0.62;
    final centerWidth = stacked || sides == 0
        ? _kCenterWidth.clamp(0.0, available)
        : _kCenterWidth * scale;
    final sideWidth = _kSideWidth * scale;
    final width = stacked
        ? centerWidth
        : centerWidth + (sideWidth + _kPanelGap) * sides;

    final centerPanel = Container(
      width: centerWidth,
      decoration: _surface(hollow),
      clipBehavior: Clip.antiAlias,
      child: _CenterPanel(
        name: name,
        year: year,
        blurb: blurb,
        coverBytes: coverBytes,
        artBytes: artBytes,
        details: details,
        accent: _gameAccent ?? hollow.accent,
      ),
    );

    Widget sidePanel(double w) => Container(
          width: w,
          decoration: _surface(hollow),
          clipBehavior: Clip.antiAlias,
          padding: const EdgeInsets.all(HollowSpacing.md),
          child: _DetailsPanel(name: name, details: details, assets: assets),
        );

    final Widget content;
    if (sides == 0) {
      content = centerPanel;
    } else if (stacked) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          centerPanel,
          const SizedBox(height: _kPanelGap),
          sidePanel(centerWidth),
        ],
      );
    } else {
      // Panels size to their OWN content and are never stretched to each
      // other's height, which leaves a dead band of surface under the shorter
      // one.
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          centerPanel,
          const SizedBox(width: _kPanelGap),
          sidePanel(sideWidth),
        ],
      );
    }

    return Center(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          HollowSpacing.xl,
          HollowSpacing.xl + safe.top,
          HollowSpacing.xl,
          HollowSpacing.xl + safe.bottom,
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(child: content),
          ),
        ),
      ),
    );
  }
}

class _CenterPanel extends StatelessWidget {
  final String name;
  final int? year;
  final String blurb;
  final Uint8List? coverBytes;
  final Uint8List? artBytes;
  final GameDetails details;

  /// The probed dominant colour, or the theme accent until it resolves.
  final Color accent;

  const _CenterPanel({
    required this.name,
    required this.year,
    required this.blurb,
    required this.coverBytes,
    required this.artBytes,
    required this.details,
    required this.accent,
  });

  /// Genre, theme and mode tags, deduped case-insensitively in that priority
  /// order, because one word often rides two of them.
  List<String> get _tags {
    final seen = <String>{};
    final out = <String>[];
    for (final t in [...details.genres, ...details.themes, ...details.modes]) {
      final k = t.trim().toLowerCase();
      if (k.isEmpty || !seen.add(k)) continue;
      out.add(t.trim());
      if (out.length >= 8) break;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasCover = coverBytes != null && coverBytes!.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The portrait cover juts out of the hero band, with the title block
        // beside it and below the art.
        Stack(
          children: [
            Column(
              children: [
                _Hero(artBytes: artBytes, coverBytes: coverBytes),
                // Reserved band the title row bottoms out in, so the cover can
                // overlap upward into the hero.
                SizedBox(height: hasCover ? 64 : 56),
              ],
            ),
            Positioned(
              left: HollowSpacing.lg,
              right: HollowSpacing.lg,
              bottom: 0,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (hasCover) ...[
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(hollow.radiusMd),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.memory(
                        coverBytes!,
                        width: 92,
                        height: 122,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.md),
                  ],
                  Expanded(
                    // Lifted toward the key art so it reads as the cover's
                    // counterpart, not a stray footer.
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child:
                          _TitleBlock(name: name, year: year, details: details),
                    ),
                  ),
                ],
              ),
            ),
            // The profile popup's corner-button chip: a fixed size with NO
            // pressable padding, so hover paint stays inside the circle.
            Positioned(
              top: HollowSpacing.xs + 2,
              right: HollowSpacing.xs + 2,
              child: HollowPressable(
                onTap: () => Navigator.of(context).pop(),
                semanticLabel: 'Close game card',
                borderRadius: BorderRadius.circular(13),
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.4),
                    shape: BoxShape.circle,
                  ),
                  child:
                      const Icon(LucideIcons.x, size: 13, color: Colors.white),
                ),
              ),
            ),
          ],
        ),

        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.lg,
            HollowSpacing.md,
            HollowSpacing.lg,
            HollowSpacing.lg,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The three things a person cites when recommending a game. All
              // baked text, tinted with the game's probed colour.
              if (details.metacritic != null ||
                  details.steamReviews != null ||
                  details.timeToBeat != null) ...[
                _StatStrip(details: details, accent: accent),
                const SizedBox(height: HollowSpacing.md),
              ],

              // The owner's blurb, a centred pull-quote flanked by proper
              // marks that flow with the text.
              if (blurb.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.lg,
                    vertical: HollowSpacing.xs,
                  ),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: '“ ',
                          style: HollowTypography.body.copyWith(
                            color:
                                hollow.textTertiary.withValues(alpha: 0.6),
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            height: 0.9,
                          ),
                        ),
                        TextSpan(
                          text: blurb,
                          style: HollowTypography.body.copyWith(
                            color:
                                hollow.textPrimary.withValues(alpha: 0.92),
                            fontSize: 13.5,
                            fontStyle: FontStyle.italic,
                            height: 1.55,
                          ),
                        ),
                        TextSpan(
                          text: ' ”',
                          style: HollowTypography.body.copyWith(
                            color:
                                hollow.textTertiary.withValues(alpha: 0.6),
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            height: 0.9,
                          ),
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: HollowSpacing.md),
              ],

              if (details.description.isNotEmpty) ...[
                const _SectionLabel('About'),
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  details.description,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 12.5,
                    height: 1.55,
                  ),
                ),
              ],

              // A quiet footer row, so the panel's floor does not end on a
              // wall of prose.
              if (_tags.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.md),
                Wrap(
                  spacing: HollowSpacing.xs + 2,
                  runSpacing: HollowSpacing.xs + 2,
                  children: [
                    for (final t in _tags) _TagChip(label: t, accent: accent),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// A small descriptive tag, washed with the game's own colour while the text
/// stays a theme token.
class _TagChip extends StatelessWidget {
  final String label;
  final Color accent;

  const _TagChip({required this.label, required this.accent});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: accent.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// Landscape key art hero, falling back to a blurred blow-up of the portrait
/// cover and then to a quiet placeholder.
class _Hero extends StatelessWidget {
  final Uint8List? artBytes;
  final Uint8List? coverBytes;

  const _Hero({required this.artBytes, required this.coverBytes});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final art = (artBytes != null && artBytes!.isNotEmpty) ? artBytes : null;
    final cover =
        (coverBytes != null && coverBytes!.isNotEmpty) ? coverBytes : null;

    Widget image;
    if (art != null) {
      image = Image.memory(
        art,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
      );
    } else if (cover != null) {
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Image.memory(
          cover,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        ),
      );
    } else {
      return Container(
        height: 110,
        color: hollow.surface,
        alignment: Alignment.topCenter,
        padding: const EdgeInsets.only(top: HollowSpacing.md),
        child: Icon(
          LucideIcons.gamepad2,
          size: 34,
          color: hollow.textSecondary.withValues(alpha: 0.35),
        ),
      );
    }

    return SizedBox(
      height: 235,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          image,
          // Settles the art into the panel, so the overlapping cover and the
          // title band read as one composition.
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.55, 1.0],
                colors: [
                  Colors.transparent,
                  hollow.elevated.withValues(alpha: 0.65),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final String name;
  final int? year;
  final GameDetails details;

  const _TitleBlock({
    required this.name,
    required this.year,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final dateLabel = details.releaseDate.isNotEmpty
        ? details.releaseDate
        : (year != null ? '$year' : '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 19,
            height: 1.15,
          ),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (dateLabel.isNotEmpty)
              Text(
                dateLabel,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                  fontSize: 11.5,
                ),
              ),
            if (details.franchise.isNotEmpty)
              Text(
                dateLabel.isNotEmpty
                    ? '·  ${details.franchise} series'
                    : '${details.franchise} series',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                  fontSize: 11.5,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Metacritic's own score bands. The raw hues are legible on NEITHER theme, so
/// every use runs through [Contrast.ensureContrast] against the actual panel
/// colour.
Color _scoreBandColor(int score) => score >= 75
    ? const Color(0xFF66CC33)
    : score >= 50
        ? const Color(0xFFFFCC33)
        : const Color(0xFFFF4136);

/// "512431" → "512k", "1200000" → "1.2M".
String _compactCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}

/// The reception strip under the hero: up to three equal tiles washed with the
/// game's probed colour. The Metacritic number is the only coloured value, and
/// it is contrast-corrected against the panel.
class _StatStrip extends StatelessWidget {
  final GameDetails details;
  final Color accent;

  const _StatStrip({required this.details, required this.accent});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final tiles = <Widget>[];

    final mc = details.metacritic;
    if (mc != null) {
      tiles.add(_StatTile(
        icon: LucideIcons.star,
        label: 'Metacritic',
        value: '$mc',
        valueColor: Contrast.ensureContrast(
          _scoreBandColor(mc),
          hollow.elevated,
          targetRatio: 4.5,
        ),
        sub: 'critic score',
        accent: accent,
      ));
    }

    final rev = details.steamReviews;
    if (rev != null) {
      tiles.add(_StatTile(
        icon: LucideIcons.thumbsUp,
        label: 'Steam reviews',
        value: rev.label,
        sub: '${rev.percent}% of ${_compactCount(rev.total)}',
        accent: accent,
      ));
    }

    final ttb = details.timeToBeat;
    if (ttb != null) {
      final story = ttb.storySeconds;
      final full = ttb.completely;
      tiles.add(_StatTile(
        icon: LucideIcons.hourglass,
        label: 'Time to beat',
        value: story != null
            ? '~${TimeToBeat.hoursLabel(story)}'
            : '~${TimeToBeat.hoursLabel(full!)}',
        sub: story != null && full != null
            ? '100%: ~${TimeToBeat.hoursLabel(full)}'
            : (story != null ? 'main story' : '100% completion'),
        accent: accent,
      ));
    }

    if (tiles.isEmpty) return const SizedBox.shrink();
    // IntrinsicHeight bounds the row so stretch can equalise tile heights: a
    // bare stretch sits in the dialog's unbounded-height scroll context, which
    // hands the tiles an infinite height and throws.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: HollowSpacing.sm),
            Expanded(child: tiles[i]),
          ],
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;
  final String sub;
  final Color accent;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
    required this.sub,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm + 2,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: accent.withValues(alpha: 0.24)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            children: [
              Icon(icon, size: 10.5, color: hollow.textTertiary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textTertiary,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    fontSize: 8.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Long verdicts scale down rather than ellipsize: the verdict IS the
          // datum.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: HollowTypography.body.copyWith(
                color: valueColor ?? hollow.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              fontSize: 9.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Text(
      text.toUpperCase(),
      style: HollowTypography.caption.copyWith(
        color: hollow.textTertiary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        fontSize: 10,
      ),
    );
  }
}

class _DetailsPanel extends StatelessWidget {
  final String name;
  final GameDetails details;
  final Map<String, Uint8List> assets;

  const _DetailsPanel({
    required this.name,
    required this.details,
    required this.assets,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final children = <Widget>[];

    void section(String label, Widget body) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: HollowSpacing.lg));
      }
      children
        ..add(_SectionLabel(label))
        ..add(const SizedBox(height: HollowSpacing.sm))
        ..add(body);
    }

    if (details.platforms.isNotEmpty) {
      section(
        'Platforms',
        Wrap(
          spacing: HollowSpacing.xs + 2,
          runSpacing: HollowSpacing.xs + 2,
          children: [
            for (final p in details.platforms)
              _PlatformChip(
                slug: p,
                gameName: name,
                storeUrl: _storeUrl(p, details.stores),
              ),
          ],
        ),
      );
    }

    // The Info section carries only what is NOT shown elsewhere: the title row,
    // the tag footer and the stat strip already have the rest.
    final facts = <Widget>[
      if (details.achievements != null && details.achievements! > 0)
        _FactRow(
          icon: LucideIcons.trophy,
          label: 'Achievements',
          value: '${details.achievements}',
        ),
    ];
    if (facts.isNotEmpty) {
      section(
        'Info',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < facts.length; i++) ...[
              if (i > 0) const SizedBox(height: HollowSpacing.xs + 2),
              facts[i],
            ],
          ],
        ),
      );
    }

    if (details.companies.isNotEmpty) {
      section(
        'Credits',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < details.companies.length; i++) ...[
              if (i > 0) const SizedBox(height: HollowSpacing.sm + 2),
              _CompanyRow(company: details.companies[i], assets: assets),
            ],
          ],
        ),
      );
    }

    // Store-page utility rather than showcase material, so it is a collapsed
    // expander at the panel's floor instead of a wall of text that dictates the
    // dialog's height.
    if (details.hasRequirements) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(height: HollowSpacing.lg));
      }
      children.add(
        _SysReqSection(min: details.reqMin, rec: details.reqRec),
      );
    }

    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children,
        const SizedBox(height: HollowSpacing.lg),
        if (details.copyright.isNotEmpty) ...[
          Text(
            details.copyright,
            style: HollowTypography.caption.copyWith(
              color: hollow.textTertiary,
              fontSize: 9.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
        ],
        Text(
          'Game data from IGDB & Steam',
          style: HollowTypography.caption.copyWith(
            color: hollow.textTertiary.withValues(alpha: 0.7),
            fontSize: 9.5,
          ),
        ),
      ],
    );
  }
}

/// Which store a platform chip opens. A chip with no baked URL renders plain
/// and is not tappable.
String? _storeUrl(String slug, Map<String, String> stores) => switch (slug) {
      'pc' || 'mac' || 'linux' =>
        stores['steam'] ?? stores['gog'] ?? stores['epicgames'] ?? stores['itch'],
      'playstation' => stores['playstation'],
      'xbox' => stores['xbox'],
      'nintendo' => stores['nintendo'],
      _ => null,
    };

/// A platform chip, tappable when a store URL was baked. Opening the browser is
/// a user action, never a display-time fetch.
class _PlatformChip extends StatelessWidget {
  final String slug;
  final String gameName;
  final String? storeUrl;

  const _PlatformChip({
    required this.slug,
    required this.gameName,
    required this.storeUrl,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final tappable = storeUrl != null && storeUrl!.isNotEmpty;

    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PlatformIcon(slug: slug, size: 12, color: hollow.textSecondary),
          const SizedBox(width: 5),
          Text(
            platformLabel(slug),
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: 4),
            Icon(
              LucideIcons.arrowUpRight,
              size: 10,
              color: hollow.textTertiary,
            ),
          ],
        ],
      ),
    );

    if (!tappable) return chip;
    return HollowPressable(
      onTap: () async {
        final uri = Uri.tryParse(storeUrl!);
        if (uri == null) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      semanticLabel: 'Open $gameName store page for ${platformLabel(slug)}',
      borderRadius: BorderRadius.circular(999),
      child: chip,
    );
  }
}

/// Label left, value right, both on one baseline.
class _FactRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _FactRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Icon(icon, size: 13, color: hollow.textTertiary),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          label,
          style: HollowTypography.caption.copyWith(
            color: hollow.textTertiary,
            fontSize: 11,
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.end,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.caption.copyWith(
              color: hollow.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}

/// The System Requirements block behind a closed-by-default expander: nobody
/// opens a friend's showcase to spec-check a GPU, but the answer is one tap
/// away for whoever does.
class _SysReqSection extends StatefulWidget {
  final String min;
  final String rec;

  const _SysReqSection({required this.min, required this.rec});

  @override
  State<_SysReqSection> createState() => _SysReqSectionState();
}

class _SysReqSectionState extends State<_SysReqSection> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HollowPressable(
          onTap: () => setState(() => _open = !_open),
          semanticLabel:
              '${_open ? 'Hide' : 'Show'} system requirements',
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              const Expanded(child: _SectionLabel('System Requirements')),
              Icon(
                _open ? LucideIcons.chevronUp : LucideIcons.chevronDown,
                size: 13,
                color: hollow.textTertiary,
              ),
            ],
          ),
        ),
        if (_open) ...[
          const SizedBox(height: HollowSpacing.sm),
          _Requirements(min: widget.min, rec: widget.rec),
        ],
      ],
    );
  }
}

/// Minimum and Recommended requirements behind selection chips, which are the
/// design system's selection state; `.filled` is for actions.
class _Requirements extends StatefulWidget {
  final String min;
  final String rec;

  const _Requirements({required this.min, required this.rec});

  @override
  State<_Requirements> createState() => _RequirementsState();
}

class _RequirementsState extends State<_Requirements> {
  late bool _showRec = widget.min.isEmpty;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final both = widget.min.isNotEmpty && widget.rec.isNotEmpty;
    final body = _showRec ? widget.rec : widget.min;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (both) ...[
          Row(
            children: [
              _ReqTab(
                label: 'Minimum',
                selected: !_showRec,
                onTap: () => setState(() => _showRec = false),
              ),
              const SizedBox(width: HollowSpacing.xs),
              _ReqTab(
                label: 'Recommended',
                selected: _showRec,
                onTap: () => setState(() => _showRec = true),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.sm),
        ],
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(HollowSpacing.sm + 2),
          decoration: BoxDecoration(
            color: hollow.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: hollow.border),
          ),
          child: Text(
            body,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 10.5,
              height: 1.55,
            ),
          ),
        ),
      ],
    );
  }
}

class _ReqTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ReqTab({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      semanticLabel: '$label requirements',
      borderRadius: BorderRadius.circular(999),
      backgroundColor: selected ? hollow.accent.withValues(alpha: 0.14) : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        label,
        style: HollowTypography.caption.copyWith(
          color: selected ? hollow.accentText : hollow.textTertiary,
          fontWeight: FontWeight.w600,
          fontSize: 10.5,
        ),
      ),
    );
  }
}

/// One deduped credit: logo, name, role and link buttons, the logos being
/// transparent PNGs from the replicated bundle.
///
/// A one-shot pixel probe classifies each logo, because drawn straight on the
/// panel a black wordmark vanishes in dark mode: single-ink marks are re-tinted
/// to the theme's text colour, and a colourful mark whose luminance sits too
/// close to the panel's gets a small neutral plate.
///
/// The logo slot is fixed so names align down the column, but the image keeps
/// its NATURAL aspect inside it rather than being crushed to fit.
class _CompanyRow extends StatelessWidget {
  final GameCompany company;
  final Map<String, Uint8List> assets;

  const _CompanyRow({required this.company, required this.assets});

  Widget _logoImage(HollowTheme hollow, Uint8List logo) {
    Widget plain() => ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.memory(logo, fit: BoxFit.contain, gaplessPlayback: true),
        );

    return FutureBuilder<ShowcaseImageStats>(
      future: showcaseImageStats(logo),
      builder: (context, snap) {
        final stats = snap.data;
        if (stats == null) return plain(); // probe pending — resolves in ms

        // An opaque logo carries its own background and is legible on any
        // panel, and an srcIn tint on one would paint the whole rectangle a
        // single colour.
        if (!stats.hasTransparency) return plain();

        if (stats.isMonochrome) {
          return ColorFiltered(
            colorFilter:
                ColorFilter.mode(hollow.textPrimary, BlendMode.srcIn),
            child: Image.memory(
              logo,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          );
        }

        final panelDark = Contrast.relativeLuminance(hollow.elevated) < 0.5;
        final needsPlate = panelDark
            ? stats.avgLuminance < 0.35 // dark colorful mark on dark panel
            : stats.avgLuminance > 0.75; // pale colorful mark on light panel
        if (!needsPlate) return plain();
        return Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: panelDark
                ? const Color(0xFFEDEDED)
                : const Color(0xFF26262B),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Image.memory(
            logo,
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final logo = company.logoHash.isNotEmpty ? assets[company.logoHash] : null;
    return Row(
      children: [
        SizedBox(
          width: 56,
          height: 32,
          child: Align(
            alignment: Alignment.centerLeft,
            child: logo != null && logo.isNotEmpty
                ? _logoImage(hollow, logo)
                : Icon(
                    LucideIcons.building2,
                    size: 18,
                    color: hollow.textTertiary,
                  ),
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                company.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              Text(
                company.roleLabel,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                  fontSize: 9.5,
                ),
              ),
            ],
          ),
        ),
        for (final link in company.links)
          _LinkButton(
            kind: link['kind'] ?? '',
            url: link['url'] ?? '',
            company: company.name,
          ),
      ],
    );
  }
}

/// A single tap-to-open credit link. Opening the browser is a user action,
/// never a display-time fetch.
class _LinkButton extends StatelessWidget {
  final String kind;
  final String url;
  final String company;

  const _LinkButton({
    required this.kind,
    required this.url,
    required this.company,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    if (url.isEmpty) return const SizedBox.shrink();
    return HollowPressable(
      onTap: () async {
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      },
      semanticLabel: 'Open $company on $kind',
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      padding: const EdgeInsets.all(HollowSpacing.xs),
      child: Icon(_linkIcon(kind), size: 14, color: hollow.textSecondary),
    );
  }
}

IconData _linkIcon(String kind) => switch (kind) {
      'twitter' => BrandIcons.x,
      'youtube' => BrandIcons.youtube,
      'twitch' => BrandIcons.twitch,
      'facebook' => BrandIcons.facebook,
      'instagram' => BrandIcons.instagram,
      'discord' => BrandIcons.discord,
      'reddit' => BrandIcons.reddit,
      'steam' => BrandIcons.steam,
      'gog' => BrandIcons.gog,
      'epicgames' => BrandIcons.epicGames,
      'itch' => BrandIcons.itch,
      'bluesky' => BrandIcons.bluesky,
      'wikipedia' || 'wikia' => BrandIcons.wikipedia,
      'official' => LucideIcons.globe,
      _ => LucideIcons.link,
    };
