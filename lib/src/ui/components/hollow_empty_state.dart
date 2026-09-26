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

  /// A list inside a card or a section, where a centred pane would float:
  /// start-aligned, no padding of its own, one step smaller, never a glyph.
  final bool dense;

  const HollowEmptyState({
    super.key,
    required this.title,
    this.description,
    this.action,
    this.glyph,
    this.dense = false,
  }) : assert(!dense || glyph == null, 'a dense empty state takes no glyph');

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final align = dense ? TextAlign.start : TextAlign.center;

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment:
          dense ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        if (glyph != null) ...[
          Icon(glyph, size: _glyphSize, color: hollow.textTertiary),
          const SizedBox(height: HollowSpacing.md),
        ],
        Text(
          title,
          textAlign: align,
          style: (dense ? HollowTypography.bodySmall : HollowTypography.body)
              .copyWith(color: hollow.textSecondary),
        ),
        if (description != null) ...[
          const SizedBox(height: HollowSpacing.xs),
          Text(
            description!,
            textAlign: align,
            style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
          ),
        ],
        if (action != null) ...[
          SizedBox(height: dense ? HollowSpacing.sm : HollowSpacing.lg),
          action!,
        ],
      ],
    );

    // A one-line dense state is only as wide as its text, so a centring parent
    // would centre it; claiming the width keeps it on the start edge.
    if (dense) {
      return Align(
        alignment: AlignmentDirectional.topStart,
        heightFactor: 1,
        child: column,
      );
    }
    final padded = Padding(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      child: column,
    );
    // A pane can be shorter than its state (a phone's expression panel is only
    // keyboard-high), so a bounded one scrolls rather than clipping the text.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!constraints.hasBoundedHeight) return Center(child: padded);
        return SingleChildScrollView(
          primary: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(child: padded),
          ),
        );
      },
    );
  }
}

const double _glyphSize = 24;
