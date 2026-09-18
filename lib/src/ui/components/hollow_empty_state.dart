import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';

/// What a list shows when it has nothing in it.
///
/// One honest line about what is true now, an optional second line teaching
/// what will fill the space, and at most one action. Not a shrug, not a joke,
/// and never a bare blank pane.
///
/// [glyph] is the slot Holly takes when the art exists. Until then it holds a
/// quiet icon, or nothing.
class HollowEmptyState extends StatelessWidget {
  /// What is true now, in one sentence. "No messages yet", not "Nothing here!".
  final String title;

  /// What fills this space, or how. One sentence.
  final String? description;

  /// At most one, and only when there is something the person can actually do.
  final Widget? action;

  final IconData? glyph;

  const HollowEmptyState({
    super.key,
    required this.title,
    this.description,
    this.action,
    this.glyph,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (glyph != null) ...[
              Icon(glyph, size: _glyphSize, color: hollow.textTertiary),
              const SizedBox(height: HollowSpacing.md),
            ],
            Text(
              title,
              textAlign: TextAlign.center,
              style: HollowTypography.body.copyWith(color: hollow.textSecondary),
            ),
            if (description != null) ...[
              const SizedBox(height: HollowSpacing.xs),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: HollowSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

const double _glyphSize = 24;
