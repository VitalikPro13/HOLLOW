import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// Long-press wrapper with accent-tint highlight + full-width hit target.
/// Used by the mobile chat route and the mobile archive viewers.
class LongPressMessage extends StatefulWidget {
  final Widget child;
  final VoidCallback onLongPress;

  const LongPressMessage({
    super.key,
    required this.child,
    required this.onLongPress,
  });

  @override
  State<LongPressMessage> createState() => _LongPressMessageState();
}

class _LongPressMessageState extends State<LongPressMessage> {
  bool _pressing = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (_) => setState(() => _pressing = true),
      onLongPress: () {
        setState(() => _pressing = false);
        widget.onLongPress();
      },
      onLongPressCancel: () => setState(() => _pressing = false),
      onLongPressEnd: (_) => setState(() => _pressing = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: _pressing ? hollow.accent.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: widget.child,
      ),
    );
  }
}
