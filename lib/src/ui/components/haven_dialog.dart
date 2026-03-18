import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:haven/src/theme/haven_spacing.dart';
import 'package:haven/src/theme/haven_theme.dart';
import 'package:haven/src/theme/haven_typography.dart';
import 'package:haven/src/ui/animations/haven_curves.dart';

/// Show a Haven-styled dialog with custom entrance/exit animation.
///
/// Entrance: scale 0.95→1.0 + fade in, 200ms easeOutCubic.
/// Full-screen BackdropFilter blurs everything behind the dialog.
/// Blur animates 0→12 alongside the dialog entrance.
Future<T?> showHavenDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.08),
    transitionDuration: const Duration(milliseconds: 200),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: HavenCurves.enter,
        reverseCurve: Curves.easeIn,
      );

      final blurValue =
          Tween<double>(begin: 0, end: 12).animate(curvedAnimation);

      return AnimatedBuilder(
        animation: blurValue,
        builder: (context, _) {
          return BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: blurValue.value,
              sigmaY: blurValue.value,
            ),
            child: FadeTransition(
              opacity: curvedAnimation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.95, end: 1.0)
                    .animate(curvedAnimation),
                child: child,
              ),
            ),
          );
        },
      );
    },
    pageBuilder: (context, _, _) => builder(context),
  );
}

/// Haven-styled dialog widget — dark, integrated feel.
///
/// Use with [showHavenDialog] for proper entrance/exit animation.
class HavenDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  const HavenDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final haven = HavenTheme.of(context);
    final radius = BorderRadius.circular(haven.radiusLg);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HavenSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 600,
            minWidth: 300,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(HavenSpacing.xl),
              decoration: BoxDecoration(
                color: haven.elevated.withValues(alpha: 0.92),
                borderRadius: radius,
                border: Border.all(
                  color: haven.accent.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 24,
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
                      style: HavenTypography.heading
                          .copyWith(color: haven.textPrimary),
                    ),
                    const SizedBox(height: HavenSpacing.lg),
                  ],
                  content,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: HavenSpacing.xl),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (int i = 0; i < actions.length; i++) ...[
                          if (i > 0)
                            const SizedBox(width: HavenSpacing.sm),
                          actions[i],
                        ],
                      ],
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
