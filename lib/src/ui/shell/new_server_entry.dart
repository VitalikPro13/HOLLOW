import 'package:flutter/widgets.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// A newly created server's icon arriving in the strip: a fade and a small
/// scale, the popover motion, played once on first build.
class NewServerEntry extends StatefulWidget {
  final Widget child;

  const NewServerEntry({super.key, required this.child});

  @override
  State<NewServerEntry> createState() => _NewServerEntryState();
}

class _NewServerEntryState extends State<NewServerEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.normal,
    );
    _curved = CurvedAnimation(parent: _controller, curve: HollowCurves.enter);
    _controller.forward();
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: HollowMotion.popoverScale, end: 1.0)
            .animate(_curved),
        child: widget.child,
      ),
    );
  }
}
