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
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
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
      // A ladder by role: background (chat, dashboard) shows most of the
      // image, surface (sidebars, header) less, elevated (cards, inputs) least.
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
      // Every desktop vertical scrollable gets a reserved scrollbar gutter
      // instead of a thumb painted over its last 10px (issue #54).
      scrollBehavior: const HollowScrollBehavior(),
      home: const HollowShell(),
      builder: (context, child) {
        final Widget body =
            _PointerFocusDismisser(child: child ?? const SizedBox.shrink());

        // Interface scale (issue #20) wraps everything the user thinks of as
        // "the app". The 32px title bar deliberately stays at OS size: on macOS
        // it aligns to native traffic lights drawn at a fixed offset.
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
                        child: UiScale(child: body),
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        }
        // Larger Text (a11y Phase 3): mobile honours OS text scaling to the
        // 2.0× platform max, which the chrome is hardened for. Desktop has no
        // clamp, since full OS scaling already flows through.
        return MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.8,
          maxScaleFactor: 2.0,
          child: UiScale(
            child: Stack(
              children: [
                body,
                const IncomingCallOverlay(),
                // Blanks the screen on ear-hold for any active call, not only
                // while the call sheet is visible; renders nothing.
                const CallProximityController(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Clears a lingering keyboard focus ring when the user switches to the mouse
/// (a11y 2.6). Translucent so it never eats taps, and text fields still focus
/// because their own tap-up fires after this pointer-down.
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
