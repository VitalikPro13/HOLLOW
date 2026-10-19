import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/emote_image.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';

/// Reactions below a message, one chip each, sorted by count and then by
/// earliest addition. Yours is the selected chip. A blocked person's
/// reactions are neither shown nor counted.
class ReactionBar extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(blockedUsersProvider);
    final links = ref.watch(deviceLinkProvider);
    final shown = blocked.isEmpty
        ? reactions
        : {
            for (final e in reactions.entries)
              if (e.value
                      .where((id) => !blocked.contains(links.identityOf(id)))
                      .toList()
                  case final kept when kept.isNotEmpty)
                e.key: kept,
          };
    if (shown.isEmpty) return const SizedBox.shrink();

    // Insertion order breaks ties, so equal counts stay chronological.
    final sorted = shown.entries.toList()
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
