import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_focus_ring.dart';

/// Hollow-styled toggle switch, with a spring thumb and a track crossfade.
class HollowToggle extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// Names what this switch controls; the on/off state announces itself through
  /// the toggled semantic.
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

  static const double _width = 36;
  static const double _height = 20;
  static const double _touchTarget = 48;

  static bool get _isTouch =>
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;

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

    void toggle() => widget.onChanged!(!widget.value);

    Widget visual = HollowFocusRing(
      enabled: !isDisabled,
      borderRadius: BorderRadius.circular(10),
      onActivate: isDisabled ? null : toggle,
      child: FadeTransition(
        opacity: AlwaysStoppedAnimation(isDisabled ? 0.4 : 1.0),
        child: AnimatedBuilder(
          animation: _thumbPosition,
          builder: (context, _) {
            final thumbLeft = 2.0 + (_thumbPosition.value * 16.0);

            return SizedBox(
              width: _width,
              height: _height,
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
    );

    // A finger needs 48 px; the switch keeps its size and the hit area grows.
    if (_isTouch) {
      visual = Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: (_touchTarget - _width) / 2,
          vertical: (_touchTarget - _height) / 2,
        ),
        child: visual,
      );
    }

    return MergeSemantics(
      // The semantic onTap mirrors the gesture, so Voice Control can flip it.
      child: Semantics(
        toggled: widget.value,
        enabled: !isDisabled,
        label: widget.semanticLabel,
        onTap: isDisabled ? null : toggle,
        child: MouseRegion(
          cursor:
              isDisabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: isDisabled ? null : toggle,
            child: visual,
          ),
        ),
      ),
    );
  }
}
