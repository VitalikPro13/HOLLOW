import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// Show a Hollow-styled dialog with custom entrance/exit animation.
///
/// Entrance: scale 0.95→1.0 + fade in, 200ms easeOutCubic.
/// Full-screen BackdropFilter blurs everything behind the dialog.
/// Blur animates 0→12 alongside the dialog entrance.
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
              // Blur layer — fades with dialog.
              AnimatedOpacity(
                opacity: animation.value,
                duration: Duration.zero,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                  child: const SizedBox.expand(),
                ),
              ),
              // Dialog content — scale + fade.
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
    pageBuilder: (context, _, _) => builder(context),
  );
}

/// Hollow-styled dialog widget — dark, integrated feel.
///
/// Use with [showHollowDialog] for proper entrance/exit animation.
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

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 600,
            minWidth: 300,
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
                      style: HollowTypography.heading
                          .copyWith(color: hollow.textPrimary),
                    ),
                    const SizedBox(height: HollowSpacing.lg),
                  ],
                  content,
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: HollowSpacing.xl),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        for (int i = 0; i < actions.length; i++) ...[
                          if (i > 0)
                            const SizedBox(width: HollowSpacing.sm),
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
