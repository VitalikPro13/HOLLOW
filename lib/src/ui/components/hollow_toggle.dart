import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Hollow-styled toggle switch — spring physics thumb, smooth track crossfade.
///
/// Track: 36x20px pill. Thumb: 16px circle with subtle shadow.
/// Uses spring animation for satisfying bounce.
class HollowToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const HollowToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  State<HollowToggle> createState() => _HollowToggleState();
}

class _HollowToggleState extends State<HollowToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _thumbPosition;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 200),
      value: widget.value ? 1.0 : 0.0,
    );
    _thumbPosition = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.spring,
      reverseCurve: HollowCurves.spring,
    );
  }

  @override
  void didUpdateWidget(HollowToggle oldWidget) {
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
    final hollow = HollowTheme.of(context);
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
                begin: hollow.border,
                end: hollow.accent,
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
