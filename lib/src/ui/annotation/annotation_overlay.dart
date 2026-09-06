import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/annotation_mode_provider.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;
import 'package:window_manager/window_manager.dart';

import 'annotation_canvas.dart';
import 'annotation_controller.dart';
import 'annotation_toolbar.dart';

class AnnotationOverlay {
  AnnotationOverlay._();

  static const MethodChannel _nativeChannel =
      MethodChannel('FlutterWebRTC.Method');

  static OverlayEntry? _entry;
  static AnnotationController? _controller;

  // Saved Windows state for restore.
  static bool _wasMaximized = false;

  static bool get isShown => _entry != null;

  static void toggle(BuildContext context) {
    if (isShown) {
      hide();
    } else {
      show(context);
    }
  }

  static Future<void> show(BuildContext context) async {
    if (isShown) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true) ??
        hollowNavigatorKey.currentState?.overlay;
    if (overlay == null) return;

    _controller = AnnotationController();

    _entry = OverlayEntry(
      builder: (_) => _AnnotationOverlayLayer(
        controller: _controller!,
        onClose: hide,
      ),
    );
    overlay.insert(_entry!);

    if (Platform.isMacOS) {
      try {
        await _nativeChannel.invokeMethod<bool>('hollowMacEnterAnnotationMode');
      } catch (e) {
        debugPrint('[annotation] enter mode failed: $e');
      }
    } else if (Platform.isWindows || Platform.isLinux) {
      await _enterWindowsAnnotation();
    }

    _setAnnotationMode(true);
  }

  static Future<void> hide() async {
    _entry?.remove();
    _entry = null;
    _controller?.dispose();
    _controller = null;

    if (Platform.isMacOS) {
      try {
        await _nativeChannel.invokeMethod<bool>('hollowMacExitAnnotationMode');
      } catch (e) {
        debugPrint('[annotation] exit mode failed: $e');
      }
    } else if (Platform.isWindows || Platform.isLinux) {
      await _exitWindowsAnnotation();
    }

    _setAnnotationMode(false);
  }

  static Future<void> _enterWindowsAnnotation() async {
    try {
      _wasMaximized = await windowManager.isMaximized();
      if (!Platform.isLinux) {
        await windowManager.setSkipTaskbar(true);
        await windowManager.setBackgroundColor(Colors.transparent);
      }
      await windowManager.setAlwaysOnTop(true);
      if (!_wasMaximized) {
        await windowManager.maximize();
      }
    } catch (e) {
      debugPrint('[annotation] enter failed: $e');
    }
  }

  static Future<void> _exitWindowsAnnotation() async {
    try {
      if (!Platform.isLinux) {
        await windowManager.setBackgroundColor(const Color(0xFF0D0F14));
        await windowManager.setSkipTaskbar(false);
      }
      await windowManager.setAlwaysOnTop(false);
      if (!_wasMaximized) {
        await windowManager.unmaximize();
      }
    } catch (e) {
      debugPrint('[annotation] exit failed: $e');
    }
  }

  /// Sets the annotation-mode flag through the long-lived [ProviderContainer]
  /// behind the global navigator key: a [WidgetRef] from the title bar is no
  /// use, because that widget leaves the tree while annotation mode is on.
  static void _setAnnotationMode(bool active) {
    final ctx = hollowNavigatorKey.currentContext;
    if (ctx == null) {
      debugPrint('[annotation] navigator context missing; mode flag not set');
      return;
    }
    try {
      final container = ProviderScope.containerOf(ctx);
      container.read(annotationModeProvider.notifier).state = active;
    } catch (e) {
      debugPrint('[annotation] could not set mode=$active: $e');
    }
  }
}

class _AnnotationOverlayLayer extends StatefulWidget {
  final AnnotationController controller;
  final VoidCallback onClose;

  const _AnnotationOverlayLayer({
    required this.controller,
    required this.onClose,
  });

  @override
  State<_AnnotationOverlayLayer> createState() =>
      _AnnotationOverlayLayerState();
}

class _AnnotationOverlayLayerState extends State<_AnnotationOverlayLayer> {
  final FocusNode _focus = FocusNode(skipTraversal: true);

  @override
  void initState() {
    super.initState();
    // Grab focus so keyboard shortcuts (Esc, Undo) reach us.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final isMeta = HardwareKeyboard.instance.isMetaPressed;
    // AltGr registers as Ctrl+Alt on Windows — don't treat it as Ctrl.
    final isCtrl = HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyZ && (isMeta || isCtrl)) {
      if (isShift) {
        widget.controller.redo();
      } else {
        widget.controller.undo();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Opaque to hit-testing so input cannot leak through to what is
            // behind, while staying visually transparent.
            AnnotationCanvas(controller: widget.controller),
            Positioned(
              top: 16,
              left: 0,
              right: 0,
              child: Center(
                child: AnnotationToolbar(
                  controller: widget.controller,
                  onClose: widget.onClose,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
