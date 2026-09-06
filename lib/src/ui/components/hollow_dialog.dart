import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Shows a Hollow-styled dialog: scale and fade in, with a full-screen blur
/// behind it that comes up alongside the entrance.
Future<T?> showHollowDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.08),
    transitionDuration: HollowDurations.normal,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: HollowCurves.enter,
        reverseCurve: Curves.easeIn,
      );

      return AnimatedBuilder(
        animation: curvedAnimation,
        builder: (context, dialogChild) {
          return Stack(
            children: [
              // Reduce Transparency drops the sigma to 0, live.
              ValueListenableBuilder<bool>(
                valueListenable: reduceTransparencyFlag,
                builder: (context, reduce, _) {
                  if (reduce) return const SizedBox.shrink();
                  return RepaintBoundary(
                    child: FadeTransition(
                      opacity: animation,
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  );
                },
              ),
              FadeTransition(
                opacity: curvedAnimation,
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.95, end: 1.0)
                      .animate(curvedAnimation),
                  child: dialogChild,
                ),
              ),
            ],
          );
        },
        child: child,
      );
    },
    pageBuilder: (context, _, _) {
      // Keyboard avoidance for EVERY dialog: pad by the inset so centred
      // content shifts up, and strip viewInsets so a builder cannot double-pad.
      return AnimatedPadding(
        padding: MediaQuery.viewInsetsOf(context),
        duration: const Duration(milliseconds: 100),
        curve: Curves.decelerate,
        child: MediaQuery.removeViewInsets(
          context: context,
          removeLeft: true,
          removeTop: true,
          removeRight: true,
          removeBottom: true,
          child: builder(context),
        ),
      );
    },
  );
}

/// Hollow-styled dialog widget. Use it with [showHollowDialog], which owns the
/// entrance and exit animation.
class HollowDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  const HollowDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusLg);
    final screenSize = MediaQuery.sizeOf(context);
    final screenWidth = screenSize.width;
    final isCompact = screenWidth < 600;
    // Phones span the available width so dialogs feel native; desktop
    // shrink-wraps between 300 and 600.
    final minWidth = isCompact
        ? (screenWidth - HollowSpacing.xl * 2).clamp(0.0, 600.0)
        : 300.0;
    // Capped to the available screen so the Flexible scroll region clamps and
    // the sticky action bar is never pushed off a short display; without it the
    // Column grows unbounded.
    final maxHeight =
        (screenSize.height - HollowSpacing.xl * 2).clamp(0.0, double.infinity);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 600,
            minWidth: minWidth,
            maxHeight: maxHeight,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(HollowSpacing.xl),
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.92),
                borderRadius: radius,
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 16,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (title.isNotEmpty) ...[
                    Text(
                      title,
                      style: HollowTypography.heading
                          .copyWith(color: hollow.textPrimary),
                    ),
                    const SizedBox(height: HollowSpacing.lg),
                  ],
                  Flexible(
                    child: SingleChildScrollView(
                      child: content,
                    ),
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: HollowSpacing.sm,
                        runSpacing: HollowSpacing.sm,
                        children: actions,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
