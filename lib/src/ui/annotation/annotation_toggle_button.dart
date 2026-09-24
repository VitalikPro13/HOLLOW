import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';
import 'annotation_overlay.dart';

/// Small icon button that toggles the [AnnotationOverlay], first among the
/// window controls.
///
/// The hover label is inline rather than a [Tooltip]: the window controls live
/// above the [Navigator] with no Overlay ancestor, and a Tooltip there blanks
/// the entire window. It floats to the button's LEFT, over the drag area,
/// because everything else in the controls sits to its right.
class AnnotationToggleButton extends StatefulWidget {
  final double size;
  final Color? color;

  const AnnotationToggleButton({super.key, this.size = 32, this.color});

  @override
  State<AnnotationToggleButton> createState() => _AnnotationToggleButtonState();
}

class _AnnotationToggleButtonState extends State<AnnotationToggleButton> {
  bool _hovered = false;

  void _toggle() => AnnotationOverlay.toggle(context);

  @override
  Widget build(BuildContext context) {
    // A theme foreground colour, so the icon and label stay visible on BOTH
    // themes; hardcoded white vanishes on the light title bar.
    final hollow = HollowTheme.of(context);
    final color = widget.color ?? hollow.textSecondary;
    final radius = BorderRadius.circular(hollow.radiusMd);
    return Semantics(
      button: true,
      label: 'Annotate the screen',
      child: HollowFocusRing(
        onActivate: _toggle,
        borderRadius: radius,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: _toggle,
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
                  decoration: BoxDecoration(
                    color: _hovered
                        ? hollow.elevated
                        : hollow.elevated.withValues(alpha: 0.0),
                    borderRadius: radius,
                  ),
                  child: Icon(LucideIcons.pencil, size: 16, color: color),
                ),
                Positioned(
                  right: widget.size + HollowSpacing.xs,
                  top: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: AnimatedOpacity(
                        opacity: _hovered ? 1 : 0,
                        duration: HollowDurations.fast,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: HollowSpacing.sm,
                              vertical: HollowSpacing.xs,
                            ),
                            decoration: BoxDecoration(
                              color: hollow.overlay,
                              borderRadius: radius,
                            ),
                            child: Text(
                              'Annotate',
                              style: HollowTypography.caption
                                  .copyWith(color: hollow.textPrimary),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
