import 'dart:io' show Platform;

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';

/// The app locks itself to portrait, so only the platforms that lock need any
/// of the SystemChrome work below.
bool get isMobileMediaPlatform => Platform.isAndroid || Platform.isIOS;

/// Restores the app-wide portrait lock and the normal system UI.
///
/// Called from the surface's `dispose` AND from the `.then()` of the route that
/// opened it, the way `mobile_image_crop_route.dart` does: neither alone is
/// guaranteed to run before the next push.
void restoreAppOrientation() {
  if (!isMobileMediaPlatform) return;
  SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

/// What the two fullscreen media surfaces share: the rotation unlock on mobile,
/// and on desktop an OS-window fullscreen that is left exactly as it was found.
mixin FullscreenMediaChrome<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  FullscreenNotifier? _fullscreen;

  /// Whether THIS surface is the one that put the window in fullscreen. A user
  /// who was already in F11 fullscreen stays there when the surface closes.
  bool _enteredFullscreen = false;

  bool _forcedLandscape = false;
  Size? _contentSize;

  bool get forcedLandscape => _forcedLandscape;

  /// Call from `initState`. [contentSize] decides whether rotation is offered:
  /// unknown or portrait media stays portrait.
  void beginFullscreenMedia(Size? contentSize) {
    _contentSize = contentSize;
    // Captured here because reading a provider in `dispose` is unsafe.
    _fullscreen = ref.read(fullscreenProvider.notifier);
    if (!isMobileMediaPlatform) return;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations(_allowedOrientations());
  }

  /// New media on the SAME surface: landscape content unlocks rotation,
  /// portrait content locks it back.
  void updateFullscreenMediaSize(Size? contentSize) {
    if (_contentSize == contentSize) return;
    _contentSize = contentSize;
    if (!isMobileMediaPlatform || _forcedLandscape) return;
    SystemChrome.setPreferredOrientations(_allowedOrientations());
  }

  /// Call from `dispose`.
  void endFullscreenMedia() {
    if (_enteredFullscreen) {
      _enteredFullscreen = false;
      _fullscreen?.exit();
    }
    restoreAppOrientation();
  }

  /// True while THIS surface is the one holding the window fullscreen.
  bool get enteredFullscreen => _enteredFullscreen;

  Future<void> enterWindowFullscreen() async {
    final notifier = _fullscreen;
    if (notifier == null) return;
    _enteredFullscreen = await notifier.enter();
  }

  /// Leaves the fullscreen and hands the window back: whatever happens to it
  /// afterwards, including the user's own F11, is no longer this surface's to
  /// undo.
  Future<void> exitWindowFullscreen() async {
    _enteredFullscreen = false;
    await _fullscreen?.exit();
  }

  /// Forces landscape for someone with the OS rotation lock on, and back.
  void toggleForcedLandscape() {
    if (!isMobileMediaPlatform) return;
    setState(() => _forcedLandscape = !_forcedLandscape);
    SystemChrome.setPreferredOrientations(_forcedLandscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : _allowedOrientations());
  }

  List<DeviceOrientation> _allowedOrientations() {
    final size = _contentSize;
    final landscape = size != null && size.width > size.height;
    if (!landscape) return const [DeviceOrientation.portraitUp];
    return const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ];
  }
}

/// Forces landscape on a phone whose OS rotation lock is on.
class MediaRotateButton extends StatelessWidget {
  final bool landscape;
  final VoidCallback onTap;

  const MediaRotateButton({
    super.key,
    required this.landscape,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MediaChromeButton(
      icon: LucideIcons.rotateCw,
      label: landscape ? 'Back to portrait' : 'Rotate to landscape',
      onTap: onTap,
    );
  }
}

/// One shape for every control in a media surface's corner.
class MediaChromeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const MediaChromeButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      semanticLabel: label,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      backgroundColor: hollow.elevated.withValues(alpha: 0.8),
      padding: const EdgeInsets.all(HollowSpacing.sm),
      child: Icon(icon, color: hollow.textPrimary, size: 20),
    );
  }
}

/// Double click read from raw pointer downs, leaving single taps to the child.
///
/// The video player claims the tap for play and pause, and the gesture arena
/// has no way to express "both", so this listens outside it.
class DoubleClickListener extends StatefulWidget {
  final VoidCallback onDoubleClick;
  final Widget child;

  const DoubleClickListener({
    super.key,
    required this.onDoubleClick,
    required this.child,
  });

  @override
  State<DoubleClickListener> createState() => _DoubleClickListenerState();
}

class _DoubleClickListenerState extends State<DoubleClickListener> {
  Duration? _lastDown;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        final last = _lastDown;
        if (last != null && event.timeStamp - last <= kDoubleTapTimeout) {
          _lastDown = null;
          widget.onDoubleClick();
          return;
        }
        _lastDown = event.timeStamp;
      },
      child: widget.child,
    );
  }
}
