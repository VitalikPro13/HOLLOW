import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_chip_tabs.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/platform_icons.dart';
import 'package:hollow/src/ui/components/showcase_image_stats.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Which showcase block a card was opened from, so it can say why you are
/// looking at this game.
enum GameCardSource { favourite, nowPlaying, shelf }

/// The tap-a-game detail card. PURE DISPLAY off replicated data: art and logos
/// come from the replicated bundle, and a store or social link opens only on an
/// explicit tap. A dialog on desktop, a sheet on a phone.
///
/// [ownerName], [ownerPeerId], [source] and [shelfLabel] describe whose
/// showcase it came from; without them the card shows the game alone.
void showGameCardDialog(
  BuildContext context, {
  required String name,
  int? year,
  required String blurb,
  required Uint8List? coverBytes,
  Uint8List? artBytes,
  required GameDetails details,
  required Map<String, Uint8List> assets,
  String? ownerName,
  String? ownerPeerId,
  GameCardSource source = GameCardSource.favourite,
  String shelfLabel = '',
}) {
  final data = _GameCardData(
    name: name,
    year: year,
    blurb: blurb,
    coverBytes: (coverBytes?.isNotEmpty ?? false) ? coverBytes : null,
    artBytes: (artBytes?.isNotEmpty ?? false) ? artBytes : null,
    details: details,
    assets: assets,
    ownerName: ownerName,
    ownerPeerId: ownerPeerId,
    source: source,
    shelfLabel: shelfLabel,
  );
  if (MediaQuery.sizeOf(context).width <
      HollowDialogSurface.compactBreakpoint) {
    showHollowSheet<void>(
      context: context,
      scrollControlled: true,
      maxHeightFactor: 0.94,
      builder: (_) => _GameCardSheet(data: data),
    );
    return;
  }
  showHollowDialog(
    context: context,
    builder: (_) => _GameCardDialog(data: data),
  );
}

const double _kMainWidth = 600;

/// The room the positioned hairline between the two panes takes.
const double _kHairline = 1;
const double _kPaneWidth = 360;
const double _kCoverWidth = 96;
const double _kCoverHeight = 128;
const double _kPhoneCoverWidth = 72;
const double _kPhoneCoverHeight = 96;

/// The cover's ring in the surface colour, where it overlaps the art.
const double _kCoverRing = 4;

class _GameCardData {
  final String name;
  final int? year;
  final String blurb;
  final Uint8List? coverBytes;
  final Uint8List? artBytes;
  final GameDetails details;
  final Map<String, Uint8List> assets;
  final String? ownerName;
  final String? ownerPeerId;
  final GameCardSource source;
  final String shelfLabel;

  const _GameCardData({
    required this.name,
    required this.year,
    required this.blurb,
    required this.coverBytes,
    required this.artBytes,
    required this.details,
    required this.assets,
    required this.ownerName,
    required this.ownerPeerId,
    required this.source,
    required this.shelfLabel,
  });

  /// The first developer credit, for the line under the title.
  String get developer {
    for (final c in details.companies) {
      if (c.role == 'dev' || c.role == 'devpub') return c.name;
    }
    return '';
  }

  String get dateLabel => details.releaseDate.isNotEmpty
      ? details.releaseDate
      : (year != null ? '$year' : '');

  String get byline =>
      [developer, dateLabel].where((s) => s.isNotEmpty).join(' · ');

  bool get hasFacts =>
      details.metacritic != null ||
      details.steamReviews != null ||
      details.timeToBeat != null;

  bool get hasReason => blurb.isNotEmpty || (ownerName?.isNotEmpty ?? false);

  /// Genre, theme and mode tags, deduped case-insensitively in that order,
  /// because one word often rides two of them.
  List<String> get tags {
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

  List<(String, String)> get stores => [
    for (final (slug, label) in _storeOrder)
      if ((details.stores[slug] ?? '').isNotEmpty)
        (label, details.stores[slug]!),
  ];

  List<(String, String)> get detailRows => [
    if (details.franchise.isNotEmpty) ('Series', details.franchise),
    if (details.platforms.isNotEmpty)
      ('Platforms', details.platforms.map(platformLabel).join(', ')),
    if ((details.achievements ?? 0) > 0)
      ('Achievements', '${details.achievements}'),
  ];

  /// Where the details came from; the publisher's own line is [copyright].
  String get attribution => ownerName?.isNotEmpty ?? false
      ? 'Game details from IGDB and Steam, saved when $ownerName pinned it.'
      : 'Game details from IGDB and Steam.';

  String get copyright => tidyCopyright(details.copyright);
}

const _storeOrder = [
  ('steam', 'Steam'),
  ('gog', 'GOG'),
  ('epicgames', 'Epic Games Store'),
  ('itch', 'itch.io'),
  ('playstation', 'PlayStation'),
  ('xbox', 'Xbox'),
  ('nintendo', 'Nintendo eShop'),
];

Future<void> _open(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

// ------------------------------------------------------------------ desktop

class _GameCardDialog extends StatelessWidget {
  final _GameCardData data;

  const _GameCardDialog({required this.data});

  bool get _hasPane =>
      data.stores.isNotEmpty ||
      data.detailRows.isNotEmpty ||
      data.details.companies.isNotEmpty ||
      data.details.hasRequirements;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    // showHollowDialog adds no SafeArea, so the insets are respected here.
    final safe = MediaQuery.paddingOf(context);
    final maxHeight = (screen.height - safe.vertical - HollowSpacing.xl * 2)
        .clamp(0.0, double.infinity);
    final available = screen.width - HollowSpacing.xl * 2;
    // Side by side when both fit; otherwise the pane moves under the main
    // column, which never squeezes.
    final sideBySide =
        _hasPane && available >= _kMainWidth + _kHairline + _kPaneWidth;
    final width = sideBySide
        ? _kMainWidth + _kHairline + _kPaneWidth
        : _kMainWidth.clamp(0.0, available);

    final main = _MainColumn(
      data: data,
      width: sideBySide ? _kMainWidth : width,
      closeInTitleRow: !sideBySide,
    );
    final Widget content;
    if (!_hasPane) {
      content = main;
    } else if (sideBySide) {
      // The hairline is positioned rather than a row child, so it runs the
      // full height of whichever side is taller without an IntrinsicHeight.
      content = Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: _kMainWidth, child: main),
              const SizedBox(width: _kHairline),
              SizedBox(
                width: _kPaneWidth,
                child: _DetailsPane(data: data, beside: true),
              ),
            ],
          ),
          const Positioned(
            left: _kMainWidth,
            top: 0,
            bottom: 0,
            child: HollowVerticalDivider(),
          ),
          const Positioned(
            top: HollowSpacing.md,
            right: HollowSpacing.md,
            child: _CloseButton(),
          ),
        ],
      );
    } else {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          main,
          const HollowDivider(),
          _DetailsPane(data: data, beside: false),
        ],
      );
    }

    return Padding(
      padding: EdgeInsets.only(top: safe.top, bottom: safe.bottom),
      child: HollowDialogSurface(
        width: width,
        maxWidth: width,
        maxHeight: maxHeight,
        padded: false,
        child: SingleChildScrollView(child: content),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) => HollowIconButton(
    icon: LucideIcons.x,
    label: 'Close',
    onPressed: () => Navigator.of(context).pop(),
  );
}

class _MainColumn extends StatelessWidget {
  final _GameCardData data;
  final double width;

  /// With no pane beside it, the close button sits at the end of the title row.
  final bool closeInTitleRow;

  const _MainColumn({
    required this.data,
    required this.width,
    required this.closeInTitleRow,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final tags = data.tags;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Hero(
          data: data,
          width: width,
          coverWidth: _kCoverWidth,
          coverHeight: _kCoverHeight,
          inset: HollowSpacing.xl,
          trailing: closeInTitleRow ? const _CloseButton() : null,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.xl,
            0,
            HollowSpacing.xl,
            HollowSpacing.xl,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (data.hasReason) ...[
                const SizedBox(height: HollowSpacing.xl),
                _Reason(data: data),
              ],
              if (data.hasFacts) ...[
                const SizedBox(height: HollowSpacing.xl),
                _FactColumns(details: data.details),
              ],
              if (data.details.description.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.xl),
                const HollowDivider(),
                const SizedBox(height: HollowSpacing.xl),
                const HollowSectionHeader('About', dense: true),
                Text(
                  data.details.description,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                  ),
                ),
              ],
              if (tags.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.md),
                _Genres(tags: tags),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _DetailsPane extends StatelessWidget {
  final _GameCardData data;

  /// Beside the main column, the first row keeps clear of the close button.
  final bool beside;

  const _DetailsPane({required this.data, required this.beside});

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      if (data.stores.isNotEmpty)
        _StoreSection(data: data, endInset: beside ? HollowSpacing.xl : 0),
      if (data.detailRows.isNotEmpty)
        _Section(
          title: 'Details',
          child: _KeyValueRows(rows: data.detailRows),
        ),
      if (data.details.companies.isNotEmpty)
        _Section(
          title: 'Made by',
          child: _MadeBy(data: data),
        ),
      if (data.details.hasRequirements)
        _Requirements(details: data.details, touch: false),
    ];
    return Padding(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: HollowSpacing.xl),
            sections[i],
          ],
          const SizedBox(height: HollowSpacing.xl),
          _Attribution(data: data),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------------- phone

class _GameCardSheet extends StatelessWidget {
  final _GameCardData data;

  const _GameCardSheet({required this.data});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final tags = data.tags;
    return SingleChildScrollView(
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Hero(
              data: data,
              width: MediaQuery.sizeOf(context).width,
              coverWidth: _kPhoneCoverWidth,
              coverHeight: _kPhoneCoverHeight,
              inset: HollowSpacing.lg,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HollowSpacing.lg,
                0,
                HollowSpacing.lg,
                HollowSpacing.xl,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (data.hasReason) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    _Reason(data: data),
                  ],
                  if (data.hasFacts) ...[
                    const SizedBox(height: HollowSpacing.lg),
                    _FactRows(details: data.details),
                  ],
                  if (data.stores.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    _StoreSection(data: data, endInset: 0),
                  ],
                  if (data.details.description.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    const HollowDivider(),
                    const SizedBox(height: HollowSpacing.xl),
                    const HollowSectionHeader('About', dense: true),
                    Text(
                      data.details.description,
                      style: HollowTypography.body.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  ],
                  if (tags.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.md),
                    _Genres(tags: tags),
                  ],
                  if (data.detailRows.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    const HollowDivider(),
                    const SizedBox(height: HollowSpacing.xl),
                    _Section(
                      title: 'Details',
                      child: _KeyValueRows(rows: data.detailRows, touch: true),
                    ),
                  ],
                  if (data.details.companies.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    _Section(
                      title: 'Made by',
                      child: _MadeBy(data: data, touch: true),
                    ),
                  ],
                  if (data.details.hasRequirements) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    _Requirements(details: data.details, touch: true),
                  ],
                  const SizedBox(height: HollowSpacing.xl),
                  _Attribution(data: data),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------- pieces

/// The key art at its own 16:9, edge to edge, with the cover overlapping its
/// foot and the title on the surface beside it, always below the art line. No
/// art means no hero: the cover and title start at the top.
class _Hero extends StatelessWidget {
  final _GameCardData data;

  /// The hero's own width, known from the layout, so the art's height is too.
  final double width;
  final double coverWidth;
  final double coverHeight;
  final double inset;
  final Widget? trailing;

  const _Hero({
    required this.data,
    required this.width,
    required this.coverWidth,
    required this.coverHeight,
    required this.inset,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final art = data.artBytes;
    final cover = data.coverBytes;
    final hasTrailing = trailing != null;

    Widget titleRow({double top = 0}) => Padding(
      padding: EdgeInsets.only(top: top),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _TitleBlock(data: data)),
          if (hasTrailing) ...[
            const SizedBox(width: HollowSpacing.sm),
            trailing!,
          ],
        ],
      ),
    );

    if (art == null) {
      return Padding(
        padding: EdgeInsets.only(left: inset, top: inset, right: inset),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (cover != null) ...[
              _Cover(
                bytes: cover,
                width: coverWidth,
                height: coverHeight,
                ringed: false,
              ),
              const SizedBox(width: HollowSpacing.lg),
            ],
            Expanded(child: titleRow()),
          ],
        ),
      );
    }

    final artHeight = width * 9 / 16;
    final image = SizedBox(
      width: width,
      height: artHeight,
      child: Image.memory(
        art,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        semanticLabel: '${data.name} key art',
      ),
    );
    if (cover == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          image,
          Padding(
            padding: EdgeInsets.only(
                left: inset, top: HollowSpacing.lg, right: inset),
            child: titleRow(),
          ),
        ],
      );
    }

    // Half the cover hangs over the art; the title flows below the art line,
    // indented past the cover, and the stack is at least as tall as the cover.
    final overhang = coverHeight / 2;
    final textStart = inset + coverWidth + HollowSpacing.lg;
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            image,
            ConstrainedBox(
              constraints: BoxConstraints(minHeight: overhang),
              child: Padding(
                padding: EdgeInsets.only(left: textStart, right: inset),
                child: titleRow(top: HollowSpacing.md),
              ),
            ),
          ],
        ),
        Positioned(
          left: inset,
          top: artHeight - overhang,
          child: _Cover(
            bytes: cover,
            width: coverWidth,
            height: coverHeight,
            ringed: true,
          ),
        ),
      ],
    );
  }
}

class _Cover extends StatelessWidget {
  final Uint8List bytes;
  final double width;
  final double height;

  /// Over the art the cover carries a ring in the surface colour.
  final bool ringed;

  const _Cover({
    required this.bytes,
    required this.width,
    required this.height,
    required this.ringed,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final image = Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
    if (!ringed) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        child: SizedBox(width: width, height: height, child: image),
      );
    }
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(_kCoverRing),
      decoration: BoxDecoration(
        color: hollow.overlay,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        child: SizedBox.expand(child: image),
      ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  final _GameCardData data;

  const _TitleBlock({required this.data});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final byline = data.byline;
    return Padding(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            data.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
          ),
          if (byline.isNotEmpty)
            Text(
              byline,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

/// Steam's notice as the proxy cut it: games pinned before the proxy kept
/// whole words hold one cut mid-word at 160 characters, so that tail is
/// dropped back to the last whole word.
String tidyCopyright(String text) {
  final s = text.trim();
  if (s.length < 160 || RegExp(r'[.!?)…]$').hasMatch(s)) return s;
  final space = s.lastIndexOf(' ');
  final kept = space > 0 ? s.substring(0, space) : s;
  return '${kept.replaceAll(RegExp(r'[\s,;:]+$'), '')}…';
}

/// Why you are looking at this game: whose showcase it came from, and their
/// line about it.
class _Reason extends StatelessWidget {
  final _GameCardData data;

  const _Reason({required this.data});

  String get _heading {
    final owner = data.ownerName ?? '';
    if (owner.isEmpty) {
      return switch (data.source) {
        GameCardSource.favourite => 'A favourite',
        GameCardSource.nowPlaying => 'Playing it now',
        GameCardSource.shelf =>
          data.shelfLabel.isEmpty
              ? 'On a shelf'
              : 'On the ${data.shelfLabel} shelf',
      };
    }
    return switch (data.source) {
      GameCardSource.favourite => '$owner’s favourite',
      GameCardSource.nowPlaying => '$owner is playing it now',
      GameCardSource.shelf =>
        data.shelfLabel.isEmpty
            ? 'On $owner’s shelf'
            : 'On $owner’s ${data.shelfLabel} shelf',
    };
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final peer = data.ownerPeerId;
    return Row(
      // A lone heading sits level with the avatar; a quote hangs below it.
      crossAxisAlignment: data.blurb.isEmpty
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        if (peer != null && peer.isNotEmpty) ...[
          // At 24 px a frame is noise around a face nobody can read.
          HollowAvatar(peerId: peer, size: 24, frameId: ''),
          const SizedBox(width: HollowSpacing.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _heading,
                style: HollowTypography.label.copyWith(
                  color: hollow.textPrimary,
                ),
              ),
              if (data.blurb.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.xxs),
                Text(
                  '“${data.blurb}”',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
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

/// "Overwhelmingly Positive" → "Overwhelmingly positive": Steam's verdicts are
/// Title Case, the app is sentence case.
String _sentenceCase(String s) =>
    s.isEmpty ? s : s[0] + s.substring(1).toLowerCase();

/// "103k", "1.2M".
String _compactCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}

/// "22 hours", "12.5 hours", "1 hour", "45 minutes".
String _duration(int seconds) {
  if (seconds < 3600) return '${(seconds / 60).round()} minutes';
  final h = seconds / 3600;
  final rounded = h >= 10 ? h.round().toDouble() : (h * 2).round() / 2;
  final text = rounded == rounded.roundToDouble()
      ? '${rounded.round()}'
      : rounded.toStringAsFixed(1);
  return rounded == 1 ? '1 hour' : '$text hours';
}

/// One fact: its label, the value, and an optional quieter line under it.
class _Fact {
  final String label;
  final String value;
  final String sub;

  /// A number or duration reads large; a verdict in words reads at label size.
  final bool large;

  const _Fact(this.label, this.value, {this.sub = '', this.large = true});
}

List<_Fact> _facts(GameDetails d) {
  final ttb = d.timeToBeat;
  final rev = d.steamReviews;
  return [
    if (d.metacritic != null) _Fact('Metacritic', '${d.metacritic}'),
    if (rev != null)
      _Fact(
        'Steam reviews',
        _sentenceCase(rev.label),
        sub: '${rev.percent}% of ${_compactCount(rev.total)}',
        large: false,
      ),
    if (ttb != null)
      ttb.storySeconds != null
          ? _Fact(
              'Time to beat',
              'About ${_duration(ttb.storySeconds!)}',
              sub: ttb.completely != null
                  ? 'Everything: ${_duration(ttb.completely!)}'
                  : '',
            )
          : _Fact(
              'Time to beat',
              'About ${_duration(ttb.completely!)}',
              sub: 'To finish everything',
            ),
  ];
}

/// Desktop: the facts side by side, plain label over value.
class _FactColumns extends StatelessWidget {
  final GameDetails details;

  const _FactColumns({required this.details});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final facts = _facts(details);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < facts.length; i++) ...[
          if (i > 0) const SizedBox(width: HollowSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  facts[i].label,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textTertiary,
                  ),
                ),
                const SizedBox(height: HollowSpacing.xxs),
                Text(
                  facts[i].value,
                  style:
                      (facts[i].large
                              ? HollowTypography.subheading
                              : HollowTypography.label)
                          .copyWith(
                            color: hollow.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                ),
                if (facts[i].sub.isNotEmpty) ...[
                  const SizedBox(height: HollowSpacing.xxs),
                  Text(
                    facts[i].sub,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Phone: the same facts as label and value rows, so nothing shrinks.
class _FactRows extends StatelessWidget {
  final GameDetails details;

  const _FactRows({required this.details});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final facts = _facts(details);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < facts.length; i++) ...[
          if (i > 0) const HollowDivider(),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _kTouchRow),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    facts[i].label,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          facts[i].value,
                          textAlign: TextAlign.end,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textPrimary,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        if (facts[i].sub.isNotEmpty)
                          Text(
                            facts[i].sub,
                            textAlign: TextAlign.end,
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textTertiary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The phone's minimum row height, a comfortable touch target.
const double _kTouchRow = 44;

class _Genres extends StatelessWidget {
  final List<String> tags;

  const _Genres({required this.tags});

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: HollowSpacing.xs,
    runSpacing: HollowSpacing.xs,
    children: [for (final t in tags) HollowBadge(t)],
  );
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [HollowSectionHeader(title, dense: true), child],
  );
}

/// "Get it on": one chip per store, each leaving the app on tap.
class _StoreSection extends StatelessWidget {
  final _GameCardData data;
  final double endInset;

  const _StoreSection({required this.data, required this.endInset});

  @override
  Widget build(BuildContext context) {
    return _Section(
      title: 'Get it on',
      child: Padding(
        padding: EdgeInsets.only(right: endInset),
        child: Wrap(
          spacing: HollowSpacing.sm,
          runSpacing: HollowSpacing.sm,
          children: [
            for (final (label, url) in data.stores)
              HollowChip(
                label: label,
                trailingIcon: LucideIcons.arrowUpRight,
                semanticLabel: 'Open ${data.name} on $label',
                onTap: () => _open(url),
              ),
          ],
        ),
      ),
    );
  }
}

/// Label left, value right, a hairline between rows.
class _KeyValueRows extends StatelessWidget {
  final List<(String, String)> rows;
  final bool touch;

  const _KeyValueRows({required this.rows, this.touch = false});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style = touch ? HollowTypography.body : HollowTypography.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const HollowDivider(),
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: touch ? _kTouchRow : 0),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: touch ? HollowSpacing.sm : HollowSpacing.xs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    rows[i].$1,
                    style: style.copyWith(color: hollow.textSecondary),
                  ),
                  const SizedBox(width: HollowSpacing.lg),
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      textAlign: TextAlign.end,
                      style: style.copyWith(
                        color: hollow.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MadeBy extends StatelessWidget {
  final _GameCardData data;
  final bool touch;

  const _MadeBy({required this.data, this.touch = false});

  @override
  Widget build(BuildContext context) {
    final companies = data.details.companies;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < companies.length; i++) ...[
          if (i > 0)
            SizedBox(height: touch ? HollowSpacing.xs : HollowSpacing.md),
          _CompanyRow(company: companies[i], assets: data.assets, touch: touch),
        ],
      ],
    );
  }
}

/// A company's own site first, then at most two other links, so a long list
/// of socials never crowds the name.
List<Map<String, String>> _visibleLinks(List<Map<String, String>> links) {
  final sorted = [
    ...links.where((l) => l['kind'] == 'official'),
    ...links.where((l) => l['kind'] != 'official'),
  ];
  return sorted.take(3).toList();
}

String _linkName(String kind) => switch (kind) {
  'official' => 'website',
  'twitter' => 'X',
  'youtube' => 'YouTube',
  'twitch' => 'Twitch',
  'facebook' => 'Facebook',
  'instagram' => 'Instagram',
  'discord' => 'Discord',
  'reddit' => 'Reddit',
  'steam' => 'Steam',
  'gog' => 'GOG',
  'epicgames' => 'Epic Games Store',
  'itch' => 'itch.io',
  'bluesky' => 'Bluesky',
  'wikipedia' || 'wikia' => 'wiki',
  _ => 'link',
};

class _CompanyRow extends StatelessWidget {
  final GameCompany company;
  final Map<String, Uint8List> assets;
  final bool touch;

  const _CompanyRow({
    required this.company,
    required this.assets,
    required this.touch,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final logo = company.logoHash.isNotEmpty ? assets[company.logoHash] : null;
    return Row(
      children: [
        SizedBox(
          width: _kLogoSize,
          height: _kLogoSize,
          child: logo != null && logo.isNotEmpty
              ? _Logo(bytes: logo)
              : Icon(
                  LucideIcons.building2,
                  size: 20,
                  color: hollow.textTertiary,
                ),
        ),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                company.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (touch ? HollowTypography.body : HollowTypography.label)
                    .copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
              ),
              Text(
                company.roleLabel,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textTertiary,
                ),
              ),
            ],
          ),
        ),
        for (final link in _visibleLinks(company.links)) ...[
          const SizedBox(width: HollowSpacing.xs),
          HollowIconButton(
            icon: _linkIcon(link['kind'] ?? ''),
            label: '${company.name} ${_linkName(link['kind'] ?? '')}',
            size: touch ? 44 : 32,
            onPressed: () => _open(link['url'] ?? ''),
          ),
        ],
      ],
    );
  }
}

const double _kLogoSize = 32;

/// A company logo from the bundle, kept legible on the pane: a single-ink mark
/// takes the text colour (a black wordmark vanishes in dark mode), and a
/// colourful mark too close to the pane's brightness gets a neutral plate.
class _Logo extends StatelessWidget {
  final Uint8List bytes;

  const _Logo({required this.bytes});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusXs);
    Widget image() =>
        Image.memory(bytes, fit: BoxFit.contain, gaplessPlayback: true);
    return FutureBuilder<ShowcaseImageStats>(
      future: showcaseImageStats(bytes),
      builder: (context, snap) {
        final stats = snap.data;
        // An opaque logo carries its own background and is legible anywhere.
        if (stats == null || !stats.hasTransparency) {
          return ClipRRect(borderRadius: radius, child: image());
        }
        if (stats.isMonochrome) {
          return ColorFiltered(
            colorFilter: ColorFilter.mode(hollow.textPrimary, BlendMode.srcIn),
            child: image(),
          );
        }
        final paneDark = Contrast.relativeLuminance(hollow.overlay) < 0.5;
        final needsPlate = paneDark
            ? stats.avgLuminance < 0.35
            : stats.avgLuminance > 0.75;
        if (!needsPlate) return image();
        return Container(
          padding: const EdgeInsets.all(HollowSpacing.xxs),
          decoration: BoxDecoration(
            color: paneDark ? hollow.textPrimary : hollow.textSecondary,
            borderRadius: radius,
          ),
          child: image(),
        );
      },
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

enum _Tier { minimum, recommended }

/// Steam's requirement text as label and value rows. Its lines read
/// "Processor: Intel Core i5"; a line without that shape stays whole.
List<(String, String)> _requirementRows(String text) {
  final rows = <(String, String)>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final i = line.indexOf(': ');
    if (i > 0 && i <= 24) {
      final key = line.substring(0, i).trim();
      rows.add((
        key == 'OS' || key.startsWith('OS ') ? 'System' : key,
        line.substring(i + 2).trim(),
      ));
    } else {
      rows.add(('', line));
    }
  }
  return rows;
}

class _Requirements extends StatefulWidget {
  final GameDetails details;
  final bool touch;

  const _Requirements({required this.details, required this.touch});

  @override
  State<_Requirements> createState() => _RequirementsState();
}

class _RequirementsState extends State<_Requirements> {
  late _Tier _tier = widget.details.reqMin.isEmpty
      ? _Tier.recommended
      : _Tier.minimum;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final d = widget.details;
    final both = d.reqMin.isNotEmpty && d.reqRec.isNotEmpty;
    final rows = _requirementRows(_tier == _Tier.minimum ? d.reqMin : d.reqRec);
    final tabs = both
        ? HollowChipTabs<_Tier>(
            tabs: const [
              HollowChipTab(value: _Tier.minimum, label: 'Minimum'),
              HollowChipTab(value: _Tier.recommended, label: 'Recommended'),
            ],
            selected: _tier,
            expand: widget.touch,
            onSelected: (t) => setState(() => _tier = t),
          )
        : null;
    final style = widget.touch
        ? HollowTypography.body
        : HollowTypography.bodySmall;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The tabs sit under the title: beside it, the pane is too narrow.
        const HollowSectionHeader('System requirements', dense: true),
        ?tabs,
        const SizedBox(height: HollowSpacing.sm),
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const HollowDivider(),
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: widget.touch ? _kTouchRow : 0,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                vertical: widget.touch ? HollowSpacing.sm : HollowSpacing.xs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (rows[i].$1.isNotEmpty) ...[
                    SizedBox(
                      width: _kReqLabelWidth,
                      child: Text(
                        rows[i].$1,
                        style: style.copyWith(color: hollow.textSecondary),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.md),
                  ],
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      style: style.copyWith(color: hollow.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

const double _kReqLabelWidth = 88;

class _Attribution extends StatelessWidget {
  final _GameCardData data;

  const _Attribution({required this.data});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final style =
        HollowTypography.caption.copyWith(color: hollow.textTertiary);
    final copyright = data.copyright;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (copyright.isNotEmpty) ...[
          Text(copyright, style: style),
          const SizedBox(height: HollowSpacing.sm),
        ],
        Text(data.attribution, style: style),
      ],
    );
  }
}
