import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/annotation_mode_provider.dart';
import 'package:hollow/src/ui/app.dart' show hollowNavigatorKey;

import 'annotation_canvas.dart';
import 'annotation_controller.dart';
import 'annotation_toolbar.dart';

/// Self-contained transparent overlay that lets the user draw freehand
/// strokes, straight lines and arrows on top of every app on their screen.
/// Toggled via [AnnotationOverlay.toggle].
///
/// While active the Hollow main window is reconfigured to be transparent,
/// full-screen and always-on-top (via [_macAnnotationChannel]), and the
/// chat UI is hidden via [annotationModeProvider]. The annotation
/// [OverlayEntry] then naturally covers the entire desktop, so the user can
/// annotate over PowerPoint / Keynote / a browser / anything else — the
/// strokes are captured by screen-share and by the recording.
///
/// Keyboard: Esc to close, ⌘Z / Ctrl+Z to undo, ⇧⌘Z / Ctrl+⇧Z redo.
class AnnotationOverlay {
  AnnotationOverlay._();

  static const MethodChannel _macAnnotationChannel =
      MethodChannel('FlutterWebRTC.Method');

  static OverlayEntry? _entry;
  static AnnotationController? _controller;

  /// Whether the overlay is currently shown.
  static bool get isShown => _entry != null;

  /// Toggle the overlay open/closed.
  static void toggle(BuildContext context) {
    if (isShown) {
      hide();
    } else {
      show(context);
    }
  }

  /// Show the overlay. Reconfigures the main window to take over the screen
  /// transparently and then inserts the drawing overlay into the root
  /// [Overlay]. Falls back to the global [hollowNavigatorKey] when invoked
  /// from a context (e.g. title-bar button) above the [Navigator].
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
        await _macAnnotationChannel.invokeMethod<bool>('hollowMacEnterAnnotationMode');
      } catch (e) {
        debugPrint('[annotation] enter mode failed: $e');
      }
    }

    _setAnnotationMode(true);
  }

  /// Hide the overlay, dispose the controller, restore window state.
  static Future<void> hide() async {
    _entry?.remove();
    _entry = null;
    _controller?.dispose();
    _controller = null;

    if (Platform.isMacOS) {
      try {
        await _macAnnotationChannel.invokeMethod<bool>('hollowMacExitAnnotationMode');
      } catch (e) {
        debugPrint('[annotation] exit mode failed: $e');
      }
    }

    _setAnnotationMode(false);
  }

  /// Set the annotation-mode flag via the long-lived [ProviderContainer]
  /// reachable from the global navigator key. We can't rely on a
  /// [WidgetRef] passed in from the title bar because the title bar widget
  /// is removed from the tree while annotation mode is active.
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
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
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
            // Drawing surface. Opaque hit-test so input doesn't leak through
            // to whatever's behind, but visually transparent.
            AnnotationCanvas(controller: widget.controller),
            // Toolbar pinned to top-center.
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
