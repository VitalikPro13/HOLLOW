import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
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
      padding: const EdgeInsets.only(left: 4),
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

/// The ONE support badge on a profile card, folding in every credential the
/// profile carries: the compact card shows the icon and a count, the full one
/// spells the artist out, and the tooltip lists every piece on both. Monochrome
/// so it never competes with a role colour.
class SupportMarksChip extends ConsumerWidget {
  final String peerId;
  final bool compact;

  const SupportMarksChip({
    super.key,
    required this.peerId,
    required this.compact,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final infos = ref.watch(supportMarkInfosProvider(peerId));
    if (infos.isEmpty) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    final color = hollow.accentText;
    final n = infos.length;
    final artists = <String>{
      for (final info in infos)
        if (info.artist != null) info.artist!,
    };

    // The compact card carries only the count: 300 px has no room for a
    // sentence beside the avatar's overhang.
    final String label;
    if (compact) {
      label = n > 1 ? '×$n' : '';
    } else if (n == 1) {
      label = 'Supported ${infos.first.artist ?? 'the artist'}';
    } else if (artists.length == 1) {
      label = 'Supported ${artists.first} ×$n';
    } else {
      label = 'Supported $n artists';
    }

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
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 5 : 8,
            vertical: compact ? 3 : 3,
          ),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.sparkles, size: compact ? 12 : 12, color: color),
              if (label.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w600,
                    fontSize: compact ? 10 : 11,
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
