import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';

/// Haven-styled tooltip — dark, compact, fast.
///
/// Appears after 400ms hover delay. Fades in 100ms + slides from 4px offset.
/// Replaces Material Tooltip everywhere.
class HavenTooltip extends StatefulWidget {
  final String message;
  final Widget child;
  final bool preferBelow;

  const HavenTooltip({
    super.key,
    required this.message,
    required this.child,
    this.preferBelow = true,
  });

  @override
  State<HavenTooltip> createState() => _HavenTooltipState();
}

class _HavenTooltipState extends State<HavenTooltip>
    with SingleTickerProviderStateMixin {
  OverlayEntry? _entry;
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;

  bool _hovering = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
      reverseDuration: const Duration(milliseconds: 80),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _offset = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    ));
  }

  @override
  void dispose() {
    _hideTooltip();
    _controller.dispose();
    super.dispose();
  }

  void _showTooltip() {
    if (_entry != null) return;

    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;
    final position = renderBox.localToGlobal(Offset.zero);

    _entry = OverlayEntry(
      builder: (context) {
        final haven = HavenTheme.of(context);

        return Positioned(
          left: position.dx + size.width / 2,
          top: widget.preferBelow
              ? position.dy + size.height + 6
              : null,
          bottom: widget.preferBelow
              ? null
              : MediaQuery.of(context).size.height -
                  position.dy +
                  6,
          child: FractionalTranslation(
            translation: const Offset(-0.5, 0),
            child: FadeTransition(
              opacity: _opacity,
              child: SlideTransition(
                position: _offset,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: HavenSpacing.sm + 2,
                      vertical: HavenSpacing.xs + 2,
                    ),
                    decoration: BoxDecoration(
                      color: haven.elevated,
                      borderRadius:
                          BorderRadius.circular(haven.radiusSm),
                      border: Border.all(color: haven.border),
                    ),
                    child: Text(
                      widget.message,
                      style: HavenTypography.caption.copyWith(
                        color: haven.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );

    Overlay.of(context).insert(_entry!);
    _controller.forward();
  }

  void _hideTooltip() {
    if (_entry == null) return;
    _controller.reverse().then((_) {
      _entry?.remove();
      _entry = null;
    });
  }

  void _onHoverStart() {
    _hovering = true;
    Future.delayed(const Duration(milliseconds: 400), () {
      if (_hovering && mounted) _showTooltip();
    });
  }

  void _onHoverEnd() {
    _hovering = false;
    _hideTooltip();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onHoverStart(),
      onExit: (_) => _onHoverEnd(),
      child: widget.child,
    );
  }
}
