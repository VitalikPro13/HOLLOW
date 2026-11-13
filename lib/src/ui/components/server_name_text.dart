import 'package:flutter/widgets.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';

/// A server's name as every list shows it: ellipsized, with the NSFW badge
/// beside it when the owner flagged the server 18+. The badge never ellipsizes.
class ServerNameText extends StatelessWidget {
  final String name;
  final bool isNsfw;
  final TextStyle? style;
  final int maxLines;

  const ServerNameText(
    this.name, {
    super.key,
    required this.isNsfw,
    this.style,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final text = Text(
      name,
      style: style,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
    if (!isNsfw) return text;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: text),
        const SizedBox(width: HollowSpacing.sm),
        const NsfwBadge(),
      ],
    );
  }
}

/// The one mark of a server its owner flagged 18+. Screen readers hear the
/// phone's own word for it, never the letters.
class NsfwBadge extends StatelessWidget {
  const NsfwBadge({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
        label: 'Age-restricted',
        excludeSemantics: true,
        child: const HollowBadge('NSFW', kind: HollowBadgeKind.error),
      );
}
