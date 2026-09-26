import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
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

/// The ONE support badge on a profile card, folding in every credential the
/// profile carries: the icon, a count when there is more than one piece, and
/// the tooltip lists every piece. Monochrome so it never competes with a role
/// colour.
class SupportMarksChip extends ConsumerWidget {
  final String peerId;

  const SupportMarksChip({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final infos = ref.watch(supportMarkInfosProvider(peerId));
    if (infos.isEmpty) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    final color = hollow.accentText;
    final n = infos.length;

    final lines = <String>[
      n == 1 ? 'Bought art from an artist' : 'Bought $n pieces from artists',
      for (final info in infos)
        if (info.artist != null && info.title != null)
          '${info.artist}: ${info.title}'
        else if (info.artist != null)
          '${info.artist}: a piece'
        else if (info.title != null)
          'the artist: ${info.title}'
        else
          'a piece by the artist',
    ];

    return HollowTooltip(
      message: lines.join('\n'),
      child: Semantics(
        label: n == 1
            ? 'Supports an artist'
            : 'Supports artists, $n pieces',
        child: Container(
          height: 20,
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xs),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(hollow.radiusXs),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.sparkles, size: 12, color: color),
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
        ),
      ),
    );
  }
}
