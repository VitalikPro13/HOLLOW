import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Shows a Hollow-styled dialog: a scale and fade in over the flat [HollowTheme.scrim].
Future<T?> showHollowDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: 'Dismiss',
    barrierColor: HollowTheme.of(context).scrim,
    transitionDuration: HollowDurations.normal,
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: HollowCurves.enter,
        reverseCurve: HollowCurves.exit,
      );
      return FadeTransition(
        opacity: curvedAnimation,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.96, end: 1.0).animate(curvedAnimation),
          child: child,
        ),
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

/// Asks one yes-or-no question: ghost Cancel beside one filled confirm, or a
/// danger confirm when [destructive]. Resolves true only on the confirm.
Future<bool> showHollowConfirm({
  required BuildContext context,
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
  String cancelLabel = 'Cancel',
}) async {
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: title,
      content: HollowDialogText(message),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelLabel),
        ),
        destructive
            ? HollowButton.danger(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(confirmLabel),
              )
            : HollowButton.filled(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(confirmLabel),
              ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// The body prose of a dialog: `body` in `textSecondary`.
class HollowDialogText extends StatelessWidget {
  final String text;

  const HollowDialogText(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: HollowTypography.body
          .copyWith(color: HollowTheme.of(context).textSecondary),
    );
  }
}

/// The one dialog frame: overlay surface, radius, hairline and shadow, centred
/// with its margin and width policy. [HollowDialog] is built on it; a dialog
/// whose layout is its own (a hero, a crop canvas, a two-pane window) uses it
/// directly and never draws a frame of its own.
class HollowDialogSurface extends StatelessWidget {
  final Widget child;

  /// A fixed desktop width. Phones always span the screen minus the margin.
  final double? width;

  /// Without [width], the dialog shrink-wraps between [minWidth] and this.
  final double maxWidth;
  final double minWidth;

  /// A height cap below the screen's; the screen's always applies.
  final double? maxHeight;

  /// False for content that runs to the frame's edge (a hero image, a crop
  /// canvas, a pane layout); the child is clipped to the radius instead.
  final bool padded;

  const HollowDialogSurface({
    super.key,
    required this.child,
    this.width,
    this.maxWidth = 600,
    this.minWidth = 300,
    this.maxHeight,
    this.padded = true,
  });

  /// Below this width a dialog spans the screen and takes the sheet radius.
  static const compactBreakpoint = 600.0;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final isCompact = screenSize.width < compactBreakpoint;
    final radius =
        BorderRadius.circular(isCompact ? hollow.radiusXl : hollow.radiusLg);
    final available =
        (screenSize.width - HollowSpacing.xl * 2).clamp(0.0, double.infinity);

    final double min;
    final double max;
    if (isCompact) {
      min = available.clamp(0.0, maxWidth);
      max = min;
    } else if (width != null) {
      min = width!.clamp(0.0, available);
      max = min;
    } else {
      max = maxWidth.clamp(0.0, available);
      min = minWidth.clamp(0.0, max);
    }
    // Capped to the screen so a Flexible scroll region inside clamps and a
    // sticky action row is never pushed off a short display.
    final screenMaxHeight =
        (screenSize.height - HollowSpacing.xl * 2).clamp(0.0, double.infinity);
    final effectiveMaxHeight = maxHeight == null
        ? screenMaxHeight
        : maxHeight!.clamp(0.0, screenMaxHeight);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: min,
            maxWidth: max,
            maxHeight: effectiveMaxHeight,
          ),
          child: Material(
            type: MaterialType.transparency,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: hollow.overlay,
                borderRadius: radius,
                border: Border.all(color: hollow.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: padded
                  ? Padding(
                      padding: const EdgeInsets.all(HollowSpacing.xl),
                      child: child,
                    )
                  : ClipRRect(borderRadius: radius, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

/// The standard dialog: title, scrolling content and the action row. Use it
/// with [showHollowDialog], which owns the entrance and exit.
///
/// Actions: ghost Cancel, then ONE filled confirm (danger only when it
/// destroys something), primary last. A dialog with nothing to confirm has no
/// Cancel; it takes [showClose] instead.
class HollowDialog extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  /// Ghost actions at the leading edge of the action row, away from the
  /// confirm (a "Forgot password" link, a "Reset" beside Save).
  final List<Widget> leadingActions;

  /// A close button at the title's trailing edge.
  final bool showClose;

  final double? width;
  final double maxWidth;

  const HollowDialog({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.leadingActions = const [],
    this.showClose = false,
    this.width,
    this.maxWidth = 600,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowDialogSurface(
      width: width,
      maxWidth: maxWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty || showClose) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: HollowTypography.heading
                        .copyWith(color: hollow.textPrimary),
                  ),
                ),
                if (showClose) ...[
                  const SizedBox(width: HollowSpacing.sm),
                  const HollowDialogCloseButton(),
                ],
              ],
            ),
            const SizedBox(height: HollowSpacing.lg),
          ],
          Flexible(
            child: SingleChildScrollView(
              child: content,
            ),
          ),
          if (actions.isNotEmpty || leadingActions.isNotEmpty) ...[
            const SizedBox(height: HollowSpacing.xl),
            Row(
              children: [
                for (var i = 0; i < leadingActions.length; i++) ...[
                  if (i > 0) const SizedBox(width: HollowSpacing.sm),
                  leadingActions[i],
                ],
                if (leadingActions.isNotEmpty)
                  const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      alignment: WrapAlignment.end,
                      spacing: HollowSpacing.sm,
                      runSpacing: HollowSpacing.sm,
                      children: actions,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The dialog close button: a ghost X that pops the route. Only on a dialog
/// with nothing to confirm; a dialog with a Cancel never also shows it.
class HollowDialogCloseButton extends StatelessWidget {
  final VoidCallback? onPressed;

  const HollowDialogCloseButton({super.key, this.onPressed});

  @override
  Widget build(BuildContext context) {
    return HollowTooltip(
      message: 'Close',
      child: HollowButton.ghost(
        compact: true,
        semanticLabel: 'Close',
        onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
        child: const Icon(LucideIcons.x, size: 16),
      ),
    );
  }
}
