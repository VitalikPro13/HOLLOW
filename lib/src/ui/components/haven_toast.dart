import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Toast type determines the icon and accent color.
enum HavenToastType { success, error, info }

/// Haven-branded toast notification — slides up from bottom, auto-dismisses.
///
/// Only one toast visible at a time. New toast replaces any existing one.
/// Replaces Material SnackBar everywhere.
class HavenToast {
  HavenToast._();

  static OverlayEntry? _currentEntry;
  static AnimationController? _currentController;

  /// Show a toast at the bottom of the screen.
  static void show(
    BuildContext context,
    String message, {
    HavenToastType type = HavenToastType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    // Dismiss any existing toast immediately.
    _dismiss();

    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    late final AnimationController controller;

    entry = OverlayEntry(
      builder: (context) => _HavenToastWidget(
        message: message,
        type: type,
        onControllerReady: (c) {
          controller = c;
          _currentController = c;

          // Auto-dismiss after duration.
          Future.delayed(duration, () {
            if (entry.mounted) {
              controller.reverse().then((_) {
                if (entry.mounted) entry.remove();
                if (_currentEntry == entry) {
                  _currentEntry = null;
                  _currentController = null;
                }
              });
            }
          });
        },
      ),
    );

    _currentEntry = entry;
    overlay.insert(entry);
  }

  static void _dismiss() {
    if (_currentEntry != null && _currentEntry!.mounted) {
      _currentEntry!.remove();
    }
    _currentController?.dispose();
    _currentEntry = null;
    _currentController = null;
  }
}

class _HavenToastWidget extends StatefulWidget {
  final String message;
  final HavenToastType type;
  final ValueChanged<AnimationController> onControllerReady;

  const _HavenToastWidget({
    required this.message,
    required this.type,
    required this.onControllerReady,
  });

  @override
  State<_HavenToastWidget> createState() => _HavenToastWidgetState();
}

class _HavenToastWidgetState extends State<_HavenToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
      reverseDuration: const Duration(milliseconds: 150),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    ));

    _controller.forward();
    widget.onControllerReady(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  IconData _iconForType(HavenToastType type) {
    return switch (type) {
      HavenToastType.success => LucideIcons.checkCircle,
      HavenToastType.error => LucideIcons.alertCircle,
      HavenToastType.info => LucideIcons.info,
    };
  }

  Color _colorForType(HavenToastType type, HavenTheme haven) {
    return switch (type) {
      HavenToastType.success => haven.success,
      HavenToastType.error => haven.error,
      HavenToastType.info => haven.accent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final iconColor = _colorForType(widget.type, haven);

    return Positioned(
      bottom: 32,
      left: 0,
      right: 0,
      child: Center(
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _opacity,
            child: Material(
              color: Colors.transparent,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 400),
                padding: const EdgeInsets.symmetric(
                  horizontal: HavenSpacing.lg,
                  vertical: HavenSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: haven.elevated,
                  borderRadius: BorderRadius.circular(haven.radiusMd),
                  border: Border.all(color: haven.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconForType(widget.type),
                        size: 18, color: iconColor),
                    const SizedBox(width: HavenSpacing.sm + 2),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: HavenTypography.body
                            .copyWith(color: haven.textPrimary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
