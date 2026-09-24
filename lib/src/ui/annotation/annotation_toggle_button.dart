import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'annotation_overlay.dart';

/// Small icon button that toggles the [AnnotationOverlay], sitting in the title
/// bar next to the window controls.
///
/// The hover label is inline rather than a [Tooltip]: the title bar lives above
/// the [Navigator] with no Overlay ancestor, and a Tooltip there blanks the
/// entire window.
class AnnotationToggleButton extends StatefulWidget {
  final double size;
  final Color? color;

  const AnnotationToggleButton({super.key, this.size = 32, this.color});

  @override
  State<AnnotationToggleButton> createState() => _AnnotationToggleButtonState();
}

class _AnnotationToggleButtonState extends State<AnnotationToggleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // A theme foreground colour, so the icon and label stay visible on BOTH
    // themes; hardcoded white vanishes on the light title bar.
    final hollow = HollowTheme.of(context);
    final color = widget.color ?? hollow.textSecondary;
    // The label floats left of the button instead of widening it, so hover
    // never shoves the title bar's other controls.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => AnnotationOverlay.toggle(context),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: HollowDurations.fast,
              curve: HollowCurves.subtle,
              width: widget.size,
              height: widget.size,
              // Zero-alpha rest colour, not Colors.transparent, which is
              // transparent BLACK and makes the hover lerp flash dark.
              color: _hovered
                  ? hollow.elevated
                  : hollow.elevated.withValues(alpha: 0.0),
              child: Icon(LucideIcons.pencil, size: 16, color: color),
            ),
            Positioned(
              right: widget.size,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _hovered ? 1 : 0,
                  duration: HollowDurations.fast,
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.only(left: HollowSpacing.sm),
                    color: hollow.elevated,
                    child: Text(
                      'Annotate',
                      style: HollowTypography.caption.copyWith(
                        color: color,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
