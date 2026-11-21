import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/annotation_mode_provider.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/core/services/os_call_service.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';
import 'package:hollow/src/ui/components/snapshot_paste.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/mobile/channel_on_screen_route.dart';
import 'package:hollow/src/ui/mobile/mobile_incoming_call.dart';
import 'package:hollow/src/ui/mobile/call_proximity_controller.dart';
import 'package:hollow/src/ui/shell/hollow_shell.dart';
import 'package:hollow/src/ui/shell/window_title_bar.dart';
import 'package:window_manager/window_manager.dart';

/// Global navigator key for showing toasts from providers (no BuildContext).
final hollowNavigatorKey = GlobalKey<NavigatorState>();

class HollowApp extends ConsumerWidget {
  const HollowApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final hue = ref.watch(accentHueProvider);
    final isCustomHue = (hue - defaultAccentHue).abs() > 1;
    final themeData = themeMode == ThemeMode.dark
        ? HollowThemeData.dark(accentHue: isCustomHue ? hue : null)
        : HollowThemeData.light(accentHue: isCustomHue ? hue : null);
    // A wallpaper's see-through theme is applied by `WallpaperBackdrop`, only
    // to the pages the picture sits behind.

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
      actions: hollowAppActions(),
      home: const HollowHome(),
      navigatorObservers: [routesAboveHome, pageRouteObserver],
      builder: (context, child) {
        final Widget body =
            _PointerFocusDismisser(child: child ?? const SizedBox.shrink());

        // Interface scale (issue #20) wraps everything the user thinks of as
        // "the app". The window controls deliberately stay at OS size, so the
        // zoom readout is always legible and one click from 100%.
        if (isDesktop) {
          return DesktopWindowFrame(child: _IdleActivity(child: body));
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
                // The phone answers full screen; the desktop card is for
                // windows.
                const MobileIncomingCallOverlay(),
                // Blanks the screen on ear-hold for any active call, not only
                // while the call sheet is visible; renders nothing.
                const CallProximityController(),
                // Tells the OS we are in a call (CallKit, Telecom); renders
                // nothing.
                const _OsCallMount(),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The desktop window around the app: the interface zoom, and the window
/// chrome, either the 32 px title bar or, in Dock mode, the controls floating
/// over the header's trailing end.
///
/// The controls deliberately stay at OS size, so the zoom readout is always
/// legible and one click from 100%.
class DesktopWindowFrame extends ConsumerWidget {
  final Widget child;
  const DesktopWindowFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chrome = !ref.watch(annotationModeProvider) &&
        !ref.watch(fullscreenProvider);
    // Welcome, the password prompt and the lock cover keep the title bar,
    // since nothing on them can move the window.
    final dockChrome = chrome &&
        dockHeaderCanOwnChrome &&
        ref.watch(dockOwnsWindowChromeProvider) &&
        ref.watch(identityProvider.select((i) => i.peerId != null)) &&
        !ref.watch(appLockedProvider);
    final controlsWidth = ref.watch(windowControlsWidthProvider);
    final scale = ref.watch(uiScaleProvider);
    return Material( // design-ignore: the root host above the Navigator, where the window chrome and every overlay host render outside any route
      type: MaterialType.transparency,
      child: LayoutBuilder(builder: (context, constraints) {
        // The header's height once the zoom has scaled it, in window pixels.
        final headerHeight =
            kDockHeaderHeight * effectiveUiScale(scale, constraints.biggest);
        return MacTrafficLights(
          height: dockChrome ? headerHeight : 0,
          child: Stack(
          children: [
            Column(
              children: [
                if (chrome && !dockChrome) const WindowTitleBar(),
                Expanded(child: ClipRect(child: UiScale(child: child))),
              ],
            ),
            // A dialog's scrim covers the header, which is the title bar here:
            // the strip above it keeps the window movable, as a native title
            // bar stays usable above a modal. Translucent, so a plain click
            // still reaches the scrim and dismisses what it should.
            if (dockChrome)
              Positioned(
                top: 0,
                left: 0,
                right: controlsWidth,
                height: headerHeight,
                child: ValueListenableBuilder<int>(
                  valueListenable: routesAboveHome,
                  builder: (context, above, _) => above == 0
                      ? const SizedBox.shrink()
                      : const DragToMoveArea(child: SizedBox.expand()),
                ),
              ),
            if (dockChrome)
              Positioned(
                top: 0,
                right: 0,
                child: WindowControls(height: headerHeight, reportWidth: true),
              ),
          ],
          ),
        );
      }),
    );
  }
}

/// How many routes (dialogs, menus, pushed pages) sit above the home route.
final routesAboveHome = _RoutesAboveHome();

class _RoutesAboveHome extends NavigatorObserver implements ValueListenable<int> {
  final _count = ValueNotifier<int>(0);
  int _depth = 0;
  bool _scheduled = false;

  /// Observers fire mid-build, so listeners hear the change after the frame.
  void _move(int delta) {
    _depth = (_depth + delta).clamp(0, 1 << 20);
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _count.value = _depth;
    });
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) _move(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _move(-1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _move(-1);

  @override
  int get value => _count.value;

  @override
  void addListener(VoidCallback listener) => _count.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _count.removeListener(listener);
}

/// Stamps the desktop idle clock on any pointer activity, above the Navigator
/// so a dialog's own pointers count too. A plain field write, never provider
/// state: a mouse move must not rebuild anything.
class _IdleActivity extends StatelessWidget {
  final Widget child;
  const _IdleActivity({required this.child});

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => IdleClock.stamp(),
      onPointerMove: (_) => IdleClock.stamp(),
      onPointerHover: (_) => IdleClock.stamp(),
      onPointerSignal: (_) => IdleClock.stamp(),
      child: child,
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

/// Keeps the OS call mirror alive for the app's life (#154).
class _OsCallMount extends ConsumerWidget {
  const _OsCallMount();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(osCallServiceProvider);
    return const SizedBox.shrink();
  }
}
