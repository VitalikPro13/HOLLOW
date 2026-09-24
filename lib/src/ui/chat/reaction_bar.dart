import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';

/// Reactions below a message, one chip each, sorted by count and then by
/// earliest addition. Yours is the selected chip.
class ReactionBar extends StatelessWidget {
  /// Emoji to the peer ids that reacted with it.
  final Map<String, List<String>> reactions;

  /// Highlights this peer's own reactions.
  final String localPeerId;

  /// Null in read-only mode, where the chips render but do not take taps.
  final void Function(String emoji)? onToggleReaction;

  const ReactionBar({
    super.key,
    required this.reactions,
    required this.localPeerId,
    this.onToggleReaction,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Insertion order breaks ties, so equal counts stay chronological.
    final sorted = reactions.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return Padding(
      padding: const EdgeInsets.only(top: HollowSpacing.xs),
      child: Wrap(
        spacing: HollowSpacing.xs,
        runSpacing: HollowSpacing.xs,
        children: [
          for (final entry in sorted)
            _reaction(entry.key, entry.value),
        ],
      ),
    );
  }

  Widget _reaction(String emoji, List<String> reactors) {
    final emote = parseEmoteToken(emoji);
    final toggle = onToggleReaction;
    return HollowChip(
      label: '${reactors.length}',
      selected: reactors.contains(localPeerId),
      onTap: toggle == null ? null : () => toggle(emoji),
      semanticLabel:
          'Reaction ${emote != null ? ':${emote.name}:' : emoji}, ${reactors.length}',
      leading: emote != null
          ? EmoteImage(
              name: emote.name,
              hash: emote.hash,
              size: 16,
              fallbackStyle: HollowTypography.caption,
            )
          : Text(emoji, style: HollowTypography.body),
    );
  }
}
