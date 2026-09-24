import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';

/// The one bottom sheet: the floating surface, the sheet radius on its top
/// corners, and the drag handle, so no call site styles its own.
///
/// [scrollControlled] lets the sheet grow past Flutter's 9/16 height cap, for
/// content that can be tall (an emoji grid, a long action list); the builder
/// then bounds itself, usually with a `ConstrainedBox` on a share of the
/// screen height.
///
/// [handle] is false only when the builder places [HollowSheetHandle] itself,
/// as a `DraggableScrollableSheet` must, so the handle drags with the content.
///
/// [maxHeightFactor] caps the WHOLE sheet, handle included, at that share of
/// the screen height.
Future<T?> showHollowSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool scrollControlled = false,
  double? maxHeightFactor,
  bool handle = true,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useRootNavigator = false,
  RouteSettings? routeSettings,
}) {
  final hollow = HollowTheme.of(context);
  return showModalBottomSheet<T>(
    context: context,
    // The surface is painted inside the builder from the sheet's own context,
    // so a theme change while the sheet is open repaints it too.
    backgroundColor: Colors.transparent,
    barrierColor: hollow.scrim,
    isScrollControlled: scrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useRootNavigator: useRootNavigator,
    routeSettings: routeSettings,
    clipBehavior: Clip.antiAlias,
    sheetAnimationStyle: _sheetMotion(),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
    ),
    builder: (sheetContext) {
      final sheet = ColoredBox(
        color: HollowTheme.of(sheetContext).overlay,
        child: handle
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const HollowSheetHandle(),
                  Flexible(child: builder(sheetContext)),
                ],
              )
            : builder(sheetContext),
      );
      if (maxHeightFactor == null) return sheet;
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * maxHeightFactor,
        ),
        child: sheet,
      );
    },
  );
}

/// Read per open, so Reduce motion reaches the next sheet. A reverse curve runs
/// backwards, so the enter curve doubles as the easing-in exit. A drag still
/// tracks the finger: the route rebinds to the raw controller while dragging.
AnimationStyle _sheetMotion() {
  if (HollowDurations.animationsDisabled) return AnimationStyle.noAnimation;
  return AnimationStyle(
    curve: HollowCurves.enter,
    reverseCurve: HollowCurves.enter,
    duration: HollowDurations.normal,
    reverseDuration: HollowDurations.fast,
  );
}

/// The grab bar at the top of a sheet, with the gap below it.
class HollowSheetHandle extends StatelessWidget {
  const HollowSheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      child: Center(
        child: Container(
          width: _handleWidth,
          height: _handleHeight,
          decoration: BoxDecoration(
            color: hollow.border,
            borderRadius: BorderRadius.circular(HollowRadius.pill),
          ),
        ),
      ),
    );
  }
}

const double _handleWidth = 32;
const double _handleHeight = 4;
