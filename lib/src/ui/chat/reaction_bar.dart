import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// Displays emoji reaction pills below a message.
/// Tapping a pill toggles the current user's reaction.
/// Sorted by count descending, then by earliest addition (chronological).
class ReactionBar extends StatelessWidget {
  /// Emoji -> list of peer IDs who reacted.
  final Map<String, List<String>> reactions;

  /// The current user's peer ID, to highlight their reactions.
  final String localPeerId;

  /// Called when the user taps a reaction pill to toggle it.
  /// Null in read-only mode (archive viewer) — pills render but aren't tappable.
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

    final hollow = HollowTheme.of(context);

    // Sort by count descending. Entries maintain insertion order for tie-breaking.
    final sorted = reactions.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: sorted.map((entry) {
          final emoji = entry.key;
          final reactors = entry.value;
          final isMine = reactors.contains(localPeerId);
          final emote = parseEmoteToken(emoji);

          return HollowPressable(
            onTap: onToggleReaction != null
                ? () => onToggleReaction!(emoji)
                : null,
            semanticLabel:
                'Reaction ${emote != null ? ':${emote.name}:' : emoji}, ${reactors.length}',
            borderRadius: BorderRadius.circular(12),
            padding: EdgeInsets.zero,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: isMine
                    ? hollow.accent.withValues(alpha: 0.15)
                    : hollow.elevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isMine
                      ? hollow.accent.withValues(alpha: 0.4)
                      : hollow.border,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (emote != null)
                    EmoteImage(
                      name: emote.name,
                      hash: emote.hash,
                      size: 17,
                      fallbackStyle: const TextStyle(fontSize: 11),
                    )
                  else
                    Text(emoji, style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 3),
                  Text(
                    reactors.length.toString(),
                    style: HollowTypography.caption.copyWith(
                      color: isMine ? hollow.accent : hollow.textSecondary,
                      fontSize: 11,
                      fontWeight: isMine ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
