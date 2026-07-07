import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/platform_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// The tap-a-game detail card. PURE DISPLAY off replicated data — nothing is
/// fetched: key art, cover, and company logos come from the replicated asset
/// bundle; store/social links open only on explicit tap (a user action).
/// Person-first, NOT a store listing — no price, no screenshots, no join
/// funnels.
///
/// Layout mirrors the profile dialog's panel ensemble: a center panel (key
/// art hero + cover + title + the owner's blurb + description) flanked by a
/// right details panel (platforms with store links, release/achievements,
/// requirements, credits, copyright). The right panel only appears when it
/// has content, so a details-less block still opens a clean card.
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

/// Width of the center panel (matches the profile dialog's center card).
const double _kCenterWidth = 560.0;

/// Width of the flanking details panel.
const double _kSideWidth = 300.0;

/// Gap between panels.
const double _kPanelGap = HollowSpacing.md;

class _GameCardDialog extends StatelessWidget {
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

  /// The shared panel surface — same recipe as the profile dialog's card.
  BoxDecoration _surface(HollowTheme hollow) => BoxDecoration(
        color: hollow.elevated.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(hollow.radiusLg),
        border: Border.all(color: hollow.accent.withValues(alpha: 0.15)),
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
      details.hasRequirements ||
      details.companies.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final maxHeight = (screenSize.height - HollowSpacing.xl * 2)
        .clamp(0.0, double.infinity);

    // Proportional scaling, exactly like the profile dialog: shrink the
    // ensemble before giving up its shape; only tiny windows stack.
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
      content = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            centerPanel,
            const SizedBox(width: _kPanelGap),
            sidePanel(sideWidth),
          ],
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
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

// ── Center panel: hero + identity + the owner's words ─────────────────

class _CenterPanel extends StatelessWidget {
  final String name;
  final int? year;
  final String blurb;
  final Uint8List? coverBytes;
  final Uint8List? artBytes;
  final GameDetails details;

  const _CenterPanel({
    required this.name,
    required this.year,
    required this.blurb,
    required this.coverBytes,
    required this.artBytes,
    required this.details,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final hasCover = coverBytes != null && coverBytes!.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero band with the portrait cover jutting out of it; the title
        // block sits beside the cover, below the art.
        Stack(
          children: [
            Column(
              children: [
                _Hero(artBytes: artBytes, coverBytes: coverBytes),
                // Reserved band the title row bottoms out in; the cover
                // overlaps upward into the hero.
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
                    // Lift the title block toward the key art so it reads
                    // as the cover's counterpart, not a stray footer.
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child:
                          _TitleBlock(name: name, year: year, details: details),
                    ),
                  ),
                ],
              ),
            ),
            // Dismiss affordance over the art — same chip structure as the
            // profile popup's corner button (fixed 26×26, NO pressable
            // padding: hover paint must stay inside the circle).
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
              // The owner's blurb — a centered pull-quote flanked by
              // proper “ ” marks that flow with the text.
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
            ],
          ),
        ),
      ],
    );
  }
}

/// Landscape key art hero. Falls back to a blurred blow-up of the portrait
/// cover (older blocks / games without IGDB artwork), then to a quiet
/// placeholder.
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
          // Settle the art into the panel so the overlapping cover and the
          // title band underneath read as one composition.
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
            if (details.metacritic != null)
              _MetacriticBadge(score: details.metacritic!),
          ],
        ),
      ],
    );
  }
}

class _MetacriticBadge extends StatelessWidget {
  final int score;

  const _MetacriticBadge({required this.score});

  @override
  Widget build(BuildContext context) {
    // Metacritic's own bands: green ≥75, yellow 50-74, red <50.
    final Color color = score >= 75
        ? const Color(0xFF66CC33)
        : score >= 50
            ? const Color(0xFFFFCC33)
            : const Color(0xFFFF4136);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.star, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            '$score',
            style: HollowTypography.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 10.5,
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

// ── Right panel: baked metadata ────────────────────────────────────────

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

    // Release date lives under the title in the center panel — the Info
    // section carries what ISN'T shown elsewhere.
    final facts = <Widget>[
      if (details.genres.isNotEmpty)
        _FactRow(
          icon: LucideIcons.shapes,
          label: 'Genres',
          value: details.genres.take(2).join(', '),
        ),
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

    if (details.hasRequirements) {
      section(
        'System Requirements',
        _Requirements(min: details.reqMin, rec: details.reqRec),
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

/// Which store a platform chip opens: desktop → Steam, consoles/mobile →
/// their own store. Chips without a baked URL render plain (not tappable).
String? _storeUrl(String slug, Map<String, String> stores) => switch (slug) {
      'pc' || 'mac' || 'linux' =>
        stores['steam'] ?? stores['gog'] ?? stores['epicgames'] ?? stores['itch'],
      'playstation' => stores['playstation'],
      'xbox' => stores['xbox'],
      'nintendo' => stores['nintendo'],
      _ => null,
    };

/// A platform chip; tappable when a store URL was baked (opens the browser —
/// a user action, never a display-time fetch).
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

/// Label left, value right — both on one baseline (no ragged wrapping).
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

/// Minimum / Recommended requirements behind selection chips (chips =
/// selection state per the design system; `.filled` is for actions).
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

/// One deduped credit: logo + name + role + social/link icon buttons. Logos
/// are transparent PNGs from the replicated bundle — drawn straight on the
/// panel, never on a white plate.
///
/// Logo slot: fixed 56×32 so names align down the credits column, but the
/// image keeps its NATURAL aspect inside it (BoxFit.contain, left-anchored)
/// — wide wordmark logos render wide, square marks render square, nothing
/// gets crushed into a 30px box.
class _CompanyRow extends StatelessWidget {
  final GameCompany company;
  final Map<String, Uint8List> assets;

  const _CompanyRow({required this.company, required this.assets});

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
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Image.memory(
                      logo,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  )
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

/// A single tap-to-open credit link. Opens the browser (user action) — never
/// a display-time fetch.
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
