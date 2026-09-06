import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

enum HollowToastType { success, error, info }

/// Hollow-branded toast, replacing Material's SnackBar everywhere. Only one is
/// visible at a time, and a new one replaces it.
class HollowToast {
  HollowToast._();

  static OverlayEntry? _currentEntry;

  /// Shows a toast at the bottom of the screen.
  ///
  /// [overlayState] is REQUIRED from non-widget code, where the only handle is
  /// the Navigator key: `Overlay.of(navKey.currentContext)` throws, because the
  /// Navigator's own context has no Overlay ancestor. Omitted, the Overlay
  /// resolves from [context].
  static void show(
    BuildContext context,
    String message, {
    HollowToastType type = HollowToastType.info,
    Duration duration = const Duration(seconds: 3),
    OverlayState? overlayState,
  }) {
    _dismiss();

    final overlay = overlayState ?? Overlay.of(context);
    late final OverlayEntry entry;
    late final AnimationController controller;

    entry = OverlayEntry(
      builder: (context) => _HollowToastWidget(
        message: message,
        type: type,
        onControllerReady: (c) {
          controller = c;
          Future.delayed(duration, () {
            if (entry.mounted) {
              controller.reverse().then((_) {
                if (entry.mounted) entry.remove();
                if (_currentEntry == entry) {
                  _currentEntry = null;
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
    _currentEntry = null;
  }
}

class _HollowToastWidget extends StatefulWidget {
  final String message;
  final HollowToastType type;
  final ValueChanged<AnimationController> onControllerReady;

  const _HollowToastWidget({
    required this.message,
    required this.type,
    required this.onControllerReady,
  });

  @override
  State<_HollowToastWidget> createState() => _HollowToastWidgetState();
}

class _HollowToastWidgetState extends State<_HollowToastWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 200),
      reverseDuration: HollowDurations.animationsDisabled ? Duration.zero : const Duration(milliseconds: 150),
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

  IconData _iconForType(HollowToastType type) {
    return switch (type) {
      HollowToastType.success => LucideIcons.checkCircle,
      HollowToastType.error => LucideIcons.alertCircle,
      HollowToastType.info => LucideIcons.info,
    };
  }

  Color _colorForType(HollowToastType type, HollowTheme hollow) {
    return switch (type) {
      HollowToastType.success => hollow.success,
      HollowToastType.error => hollow.error,
      HollowToastType.info => hollow.accent,
    };
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final iconColor = _colorForType(widget.type, hollow);
    // Above the keyboard, and on phones above the bottom nav and its gesture
    // inset, so a toast never covers the nav icons.
    final media = MediaQuery.of(context);
    final isMobileLayout = media.size.width < 600;
    final navClearance =
        isMobileLayout ? 56 + media.viewPadding.bottom : 0.0;
    final bottom = 32 + media.viewInsets.bottom + navClearance;

    return Positioned(
      bottom: bottom,
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
                  horizontal: HollowSpacing.lg,
                  vertical: HollowSpacing.md,
                ),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border: Border.all(color: hollow.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_iconForType(widget.type),
                        size: 18, color: iconColor),
                    const SizedBox(width: HollowSpacing.sm + 2),
                    Flexible(
                      child: Text(
                        widget.message,
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary),
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
