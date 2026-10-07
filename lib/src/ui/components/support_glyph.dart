import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The support glyph after a display name on chat rows and member lists. On by
/// default; the holder can switch it off through `badge` on their credential.
///
/// Zero layout cost either way, and never on voice or call surfaces, which is
/// the same rule the avatar frames follow.
class SupportNameGlyph extends ConsumerWidget {
  final String peerId;

  /// The box, and the icon inside it two pixels smaller.
  final double size;

  const SupportNameGlyph({super.key, required this.peerId, this.size = 14});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lit = ref.watch(supportBadgeVisibleProvider(peerId));
    if (!lit) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: HollowSpacing.xs),
      child: HollowTooltip(
        message: 'Supports independent artists',
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            LucideIcons.sparkles,
            size: size - 2,
            color: hollow.accentText,
            semanticLabel: 'Supports an artist',
          ),
        ),
      ),
    );
  }
}

/// A verified Twitch account, as a quiet mark after a name in a people list.
/// The handle itself lives on the profile card.
class TwitchNameGlyph extends ConsumerWidget {
  final String peerId;

  const TwitchNameGlyph({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final login = ref.watch(twitchLoginProvider(peerId));
    if (login == null) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: HollowSpacing.xs),
      child: HollowTooltip(
        message: 'Twitch: $login',
        child: Icon(
          BrandIcons.twitch,
          size: 14,
          color: hollow.textTertiary,
          semanticLabel: 'Twitch account $login',
        ),
      ),
    );
  }
}

/// The first line of the tooltip.
String _supportSummary(int pieces) => pieces == 1
    ? 'Bought art from an artist'
    : 'Bought $pieces pieces from artists';

/// One piece as the tooltip names it: artist, then title.
String _supportLine(SupportCredInfo info) {
  if (info.artist != null && info.title != null) {
    return '${info.artist}: ${info.title}';
  }
  if (info.artist != null) return '${info.artist}: a piece';
  if (info.title != null) return 'the artist: ${info.title}';
  return 'a piece by the artist';
}

/// The ONE support badge on a profile card, folding in every credential the
/// profile carries: the icon, a count when there is more than one piece, and
/// the tooltip lists every piece. Monochrome so it never competes with a role
/// colour.
///
/// [touch] makes it open the same list as a sheet: a phone has no hover.
class SupportMarksChip extends ConsumerWidget {
  static const double _touchTarget = 44;

  final String peerId;
  final bool touch;

  const SupportMarksChip({super.key, required this.peerId, this.touch = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final infos = ref.watch(supportMarkInfosProvider(peerId));
    if (infos.isEmpty) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    final color = hollow.accentText;
    final n = infos.length;
    final label = n == 1 ? 'Supports an artist' : 'Supports artists, $n pieces';

    // HollowChip's box (padding, border, a label line), so it stands as tall as
    // the Twitch chip beside it at any text scale.
    final mark = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.sparkles, size: 14, color: color),
          ExcludeSemantics(child: Text('​', style: HollowTypography.label)),
          if (n > 1) ...[
            const SizedBox(width: HollowSpacing.xs),
            Text(
              '×$n',
              style: HollowTypography.micro.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );

    if (touch) {
      return HollowPressable(
        onTap: () => showSupportMarksSheet(context, peerId: peerId),
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        semanticLabel: label,
        // The mark keeps its size and its foot; the target reaches up to a
        // fingertip's height, never past it, as the corner holds no more.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _touchTarget),
          child: Align(
            alignment: Alignment.bottomCenter,
            widthFactor: 1,
            heightFactor: 1,
            child: ExcludeSemantics(child: mark),
          ),
        ),
      );
    }

    return HollowTooltip(
      message: [
        _supportSummary(n),
        for (final info in infos) _supportLine(info),
      ].join('\n'),
      child: Semantics(label: label, child: mark),
    );
  }
}

/// What the support mark means and every piece behind it: the phone's answer
/// to the chip's tooltip.
Future<void> showSupportMarksSheet(BuildContext context,
    {required String peerId}) {
  return showHollowSheet<void>(
    context: context,
    scrollControlled: true,
    maxHeightFactor: kSheetTallHeightFactor,
    builder: (_) => _SupportMarksSheet(peerId: peerId),
  );
}

class _SupportMarksSheet extends ConsumerWidget {
  final String peerId;

  const _SupportMarksSheet({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final infos = ref.watch(supportMarkInfosProvider(peerId));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const HollowSheetTitle('Supports independent artists'),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  HollowSpacing.lg, 0, HollowSpacing.lg, HollowSpacing.sm),
              child: Text(
                infos.length == 1
                    ? 'This piece was bought through the Hollow Shop.'
                    : 'These ${infos.length} pieces were bought through the '
                        'Hollow Shop.',
                style: HollowTypography.body
                    .copyWith(color: hollow.textSecondary),
              ),
            ),
            for (final info in infos)
              HollowListRow(
                touch: true,
                title: info.title ?? 'A piece',
                subtitle: info.artist == null ? null : 'by ${info.artist}',
              ),
          ],
        ),
      ),
    );
  }
}
