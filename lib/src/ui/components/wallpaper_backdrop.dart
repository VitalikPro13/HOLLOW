import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_theme.dart';

/// The user's wallpaper behind [child], under the ONE dim Darken asks for.
///
/// [child] sees [HollowTheme.overWallpaper], so its canvases add nothing and
/// every screen sits on the same dim (#144). A backdrop inside another one
/// adds nothing. A sheet or dialog opened from under it has no picture
/// behind it and takes [opaqueThemeOf].
class WallpaperBackdrop extends ConsumerWidget {
  final Widget child;

  const WallpaperBackdrop({super.key, required this.child});

  /// The dim layer, for tests.
  static const dimKey = Key('wallpaper-dim');

  /// The theme from under the see-through one, or null outside a backdrop.
  static ThemeData? opaqueThemeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_WallpaperScope>()?.opaque;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (context.getInheritedWidgetOfExactType<_WallpaperScope>() != null) {
      return child;
    }
    final bg = ref.watch(backgroundProvider);
    final theme = Theme.of(context);
    final hollow = HollowTheme.of(context);
    final reduceTransparency =
        ref.watch(reduceTransparencyProvider).valueOrNull ?? false;
    final picture = bg.hasBackground && !reduceTransparency;
    // ONE shape whatever the state: [child] is the app's shell, and a change
    // of its ancestors would remount it (and restart the node). Reduce
    // transparency paints the opaque canvas instead of the picture, so a
    // canvas a screen leaves unpainted never shows black.
    return _WallpaperScope(
      opaque: theme,
      child: Theme(
        data: picture
            ? theme.copyWith(
                scaffoldBackgroundColor: Colors.transparent,
                extensions: [
                  for (final e in theme.extensions.values)
                    e is HollowTheme ? hollow.overWallpaper(bg.panelOpacity) : e,
                ],
              )
            : theme,
        child: Stack(
          // The child is laid out exactly as without a backdrop.
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: picture
                  ? ColoredBox(
                      color: HollowColors.mediaBlack,
                      child: Image.memory(
                        bg.imageBytes!,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        width: double.infinity,
                        height: double.infinity,
                      ),
                    )
                  : bg.hasBackground
                      ? ColoredBox(color: hollow.opaqueBackground)
                      : const SizedBox.shrink(),
            ),
            Positioned.fill(
              child: picture
                  ? ColoredBox(
                      key: dimKey,
                      color: hollow.opaqueBackground.withValues(
                          alpha: HollowTheme.wallpaperDim(bg.panelOpacity)),
                    )
                  : const SizedBox.shrink(),
            ),
            child,
          ],
        ),
      ),
    );
  }
}

class _WallpaperScope extends InheritedWidget {
  final ThemeData opaque;
  const _WallpaperScope({required this.opaque, required super.child});

  @override
  bool updateShouldNotify(_WallpaperScope old) => old.opaque != opaque;
}
