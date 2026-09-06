import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Circular bookmark "avatar" for the Saved messages conversation, in place of
/// your own profile picture. Purely decorative: the surrounding row carries the
/// text, so it has no semantics of its own.
class SavedMessagesAvatar extends StatelessWidget {
  final double size;

  const SavedMessagesAvatar({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: hollow.accentMuted,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        LucideIcons.bookmark,
        size: size * 0.5,
        color: hollow.accentText,
      ),
    );
  }
}
