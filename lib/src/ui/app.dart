import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/annotation_mode_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/dialogs/incoming_call_dialog.dart';
import 'package:hollow/src/ui/mobile/call_proximity_controller.dart';
import 'package:hollow/src/ui/shell/hollow_shell.dart';
import 'package:hollow/src/ui/shell/window_title_bar.dart';

/// Global navigator key for showing toasts from providers (no BuildContext).
final hollowNavigatorKey = GlobalKey<NavigatorState>();

class HollowApp extends ConsumerWidget {
  const HollowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final hue = ref.watch(accentHueProvider);
    final isCustomHue = (hue - defaultAccentHue).abs() > 1;
    final bg = ref.watch(backgroundProvider);

    var themeData = themeMode == ThemeMode.dark
        ? HollowThemeData.dark(accentHue: isCustomHue ? hue : null)
        : HollowThemeData.light(accentHue: isCustomHue ? hue : null);

    final reduceTransparency =
        ref.watch(reduceTransparencyProvider).valueOrNull ?? false;

    if (bg.hasBackground && !reduceTransparency) {
      final hollow = themeData.extension<HollowTheme>()!;
      final base = bg.panelOpacity.clamp(0.3, 0.95);
      // background = chat area, home dashboard → more transparent (see image through)
      // surface = sidebars, member panel, channel header → more opaque (darker)
      // elevated = cards, inputs → most opaque
      final bgAlpha = (base * 0.65).clamp(0.15, 0.8);
      final surfaceAlpha = (base * 0.85).clamp(0.4, 0.92);
      final elevatedAlpha = (base * 0.95).clamp(0.5, 0.95);
      final transparentHollow = hollow.copyWith(
        background: hollow.background.withValues(alpha: bgAlpha),
        surface: hollow.surface.withValues(alpha: surfaceAlpha),
        elevated: hollow.elevated.withValues(alpha: elevatedAlpha),
      );
      themeData = themeData.copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        extensions: [transparentHollow],
      );
    }

    final isDesktop =
        Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    return MaterialApp(
      navigatorKey: hollowNavigatorKey,
      title: 'Hollow',
      debugShowCheckedModeBanner: false,
      theme: themeData,
      home: const HollowShell(),
      builder: (context, child) {
        // a11y 2.6: clear the keyboard focus ring as soon as the user reaches
        // for the mouse/touch. Flutter keeps `traditional` highlight mode after
        // a desktop mouse click, so a ring left on the last Tab-focused control
        // would otherwise linger. Demote focus on any pointer-down WHILE rings
        // are showing; text fields re-acquire focus on their own tap-up (which
        // fires after this), so tapping into an input still works.
        child = _PointerFocusDismisser(child: child ?? const SizedBox.shrink());

        if (isDesktop) {
          return Material(
            type: MaterialType.transparency,
            child: Consumer(
              builder: (context, innerRef, _) {
                final annotation = innerRef.watch(annotationModeProvider);
                return Column(
                  children: [
                    if (!annotation) const WindowTitleBar(),
                    Expanded(
                      child: ClipRect(
                        child: child,
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        }
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.8,
          maxScaleFactor: 1.3,
          child: Stack(
            children: [
              child,
              const IncomingCallOverlay(),
              // Global earpiece proximity (mobile): blanks the screen on
              // ear-hold for any active call, not just while the call sheet
              // is visible. Pure side-effect, renders nothing.
              const CallProximityController(),
            ],
          ),
        );
      },
    );
  }
}

/// Clears a lingering keyboard focus ring when the user switches to the mouse
/// (a11y 2.6). Wraps the app body in a translucent [Listener] (so it never eats
/// taps) and, on any pointer-down WHILE the focus highlight is in keyboard mode,
/// unfocuses the current node — which collapses every [HollowFocusRing] to its
/// hidden state. A no-op during pure mouse use (highlight already non-keyboard),
/// and text fields still focus because their own tap-up fires after this.
class _PointerFocusDismisser extends StatelessWidget {
  final Widget child;
  const _PointerFocusDismisser({required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        if (FocusManager.instance.highlightMode ==
            FocusHighlightMode.traditional) {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      },
      child: child,
    );
  }
}
