import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';

/// Haven-styled toggle switch — spring physics thumb, smooth track crossfade.
///
/// Track: 36x20px pill. Thumb: 16px circle with subtle shadow.
/// Uses spring animation for satisfying bounce.
class HavenToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const HavenToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<HavenToggle> createState() => _HavenToggleState();
}

class _HavenToggleState extends State<HavenToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _thumbPosition;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      value: widget.value ? 1.0 : 0.0,
    );
    _thumbPosition = CurvedAnimation(
      parent: _controller,
      curve: HavenCurves.spring,
      reverseCurve: HavenCurves.spring,
    );
  }

  @override
  void didUpdateWidget(HavenToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final isDisabled = widget.onChanged == null;

    return GestureDetector(
      onTap: isDisabled
          ? null
          : () => widget.onChanged!(!widget.value),
      child: FadeTransition(
        opacity: AlwaysStoppedAnimation(isDisabled ? 0.4 : 1.0),
        child: MouseRegion(
          cursor: isDisabled
              ? SystemMouseCursors.basic
              : SystemMouseCursors.click,
          child: AnimatedBuilder(
            animation: _thumbPosition,
            builder: (context, _) {
              // Track colors.
              final trackColor = ColorTween(
                begin: haven.border,
                end: haven.accent,
              ).evaluate(_thumbPosition)!;

              // Thumb position: 2px padding on each side.
              // Track: 36x20, Thumb: 16px.
              // Left position: 2 (off) → 18 (on).
              final thumbLeft =
                  2.0 + (_thumbPosition.value * 16.0);

              return SizedBox(
                width: 36,
                height: 20,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: trackColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Stack(
                    children: [
                      Positioned(
                        left: thumbLeft,
                        top: 2,
                        child: Container(
                          width: 16,
                          height: 16,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: 0.15),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
