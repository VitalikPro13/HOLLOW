import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/theme/hollow_theme.dart';
import 'annotation_overlay.dart';

/// Small icon button that toggles the [AnnotationOverlay]. Designed to sit
/// in the title bar next to the window controls.
///
/// On hover an inline text label appears to the left of the icon. We
/// deliberately avoid [Tooltip] because the title bar lives above the
/// [Navigator] and lacks an Overlay ancestor — using Tooltip there blanks
/// the entire window.
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
    // Default to a theme foreground colour so the icon/label stay visible on
    // BOTH themes — hardcoded white vanished on the light-theme title bar.
    final hollow = HollowTheme.of(context);
    final color = widget.color ?? hollow.textSecondary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: () => AnnotationOverlay.toggle(context),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          height: widget.size,
          color: _hovered ? hollow.elevated : Colors.transparent,
          padding: EdgeInsets.symmetric(horizontal: _hovered ? 10 : 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                child: _hovered
                    ? Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          'Annotate',
                          style: TextStyle(
                            color: color,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              SizedBox(
                width: widget.size,
                child: Icon(LucideIcons.pencil, size: 18, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
