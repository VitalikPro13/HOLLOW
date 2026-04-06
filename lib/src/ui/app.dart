import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/shell/hollow_shell.dart';

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

    if (bg.hasBackground) {
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

    return MaterialApp(
      navigatorKey: hollowNavigatorKey,
      title: 'Hollow',
      debugShowCheckedModeBanner: false,
      theme: themeData,
      home: const HollowShell(),
    );
  }
}
