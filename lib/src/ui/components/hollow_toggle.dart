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

  /// Screen-reader label describing what this switch controls (e.g. "Reduce
  /// motion"). The on/off state is announced automatically via the toggled
  /// semantic; the label gives it a name.
  final String? semanticLabel;

  const HollowToggle({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  @override
  State<HollowToggle> createState() => _HollowToggleState();
}

class _HollowToggleState extends State<HollowToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _thumbPosition;
  late Animation<Color?> _trackColorAnimation;

  static const _thumbShadow = BoxShadow(
    color: Color.fromRGBO(0, 0, 0, 0.15),
    blurRadius: 2,
    offset: Offset(0, 1),
  );

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled
          ? Duration.zero
          : const Duration(milliseconds: 200),
      value: widget.value ? 1.0 : 0.0,
    );
    _thumbPosition = CurvedAnimation(
      parent: _controller,
      curve: HollowCurves.spring,
      reverseCurve: HollowCurves.spring,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final hollow = HollowTheme.of(context);
    _trackColorAnimation = ColorTween(
      begin: hollow.border,
      end: hollow.accent,
    ).animate(_thumbPosition);
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
    final isDisabled = widget.onChanged == null;

    return MergeSemantics(
      child: Semantics(
        // Switch role: announces on/off state via `toggled`. The semantic onTap
        // mirrors the gesture so Voice Control can flip it.
        toggled: widget.value,
        enabled: !isDisabled,
        label: widget.semanticLabel,
        onTap: isDisabled ? null : () => widget.onChanged!(!widget.value),
        child: GestureDetector(
          onTap: isDisabled ? null : () => widget.onChanged!(!widget.value),
          child: FadeTransition(
            opacity: AlwaysStoppedAnimation(isDisabled ? 0.4 : 1.0),
            child: MouseRegion(
              cursor: isDisabled
                  ? SystemMouseCursors.basic
                  : SystemMouseCursors.click,
              child: AnimatedBuilder(
                animation: _thumbPosition,
                builder: (context, _) {
                  final thumbLeft = 2.0 + (_thumbPosition.value * 16.0);

                  return SizedBox(
                    width: 36,
                    height: 20,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: _trackColorAnimation.value,
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
                              decoration: const BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [_thumbShadow],
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
        ),
      ),
    );
  }
}
