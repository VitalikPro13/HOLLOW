import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';

/// A link in running content: accent text that sits on the text's own edge.
///
/// Where a ghost button's padding would pull an action off the left edge of
/// the prose above it ("Read the post" under a teaser). An action that stands
/// on its own in a toolbar or a row stays a [HollowButton].
class HollowTextLink extends StatefulWidget {
  final String label;
  final VoidCallback onTap;

  const HollowTextLink(this.label, {super.key, required this.onTap});

  @override
  State<HollowTextLink> createState() => _HollowTextLinkState();
}

class _HollowTextLinkState extends State<HollowTextLink> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Semantics(
      link: true,
      label: widget.label,
      excludeSemantics: true,
      child: HollowFocusRing(
        enabled: true,
        onActivate: widget.onTap,
        borderRadius: BorderRadius.circular(hollow.radiusXs),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: Text(
              widget.label,
              style: HollowTypography.label.copyWith(
                color: hollow.accentText,
                decoration: _hovered ? TextDecoration.underline : null,
                decorationColor: hollow.accentText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
