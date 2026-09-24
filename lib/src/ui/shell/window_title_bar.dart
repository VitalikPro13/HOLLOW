import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/display_scale_provider.dart';
import 'package:hollow/src/core/providers/window_chrome_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/annotation/annotation_toggle_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

/// The 32 px title bar replacing the native window chrome, for every screen
/// whose own header cannot carry the window (Classic, welcome, the lock). On
/// macOS the native traffic lights stay top-left and the layout works around
/// them.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      height: height,
      color: hollow.opaqueSurface,
      child: Row(
        children: [
          if (Platform.isMacOS) const SizedBox(width: kMacTrafficLightGap),
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          const WindowControls(height: height),
        ],
      ),
    );
  }
}

/// Annotate, the zoom readout and, off macOS, minimise, maximise and close:
/// the same order on every platform, at [height] tall.
///
/// Always drawn at OS size, outside the interface zoom: whatever the zoom is,
/// these stay legible and one click from 100%. With [reportWidth] the width
/// is published so a header underneath can keep its trailing end clear.
class WindowControls extends ConsumerWidget {
  final double height;
  final bool reportWidth;

  const WindowControls({
    super.key,
    required this.height,
    this.reportWidth = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final row = SizedBox(
      height: height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AnnotationToggleButton(),
          const ZoomIndicator(),
          if (!Platform.isMacOS) ...[
            const SizedBox(width: HollowSpacing.xs),
            _MinimizeButton(height: height),
            _MaximizeButton(height: height),
            _CloseButton(height: height),
          ] else
            const SizedBox(width: HollowSpacing.sm),
        ],
      ),
    );
    if (!reportWidth) return row;
    final width = ref.read(windowControlsWidthProvider.notifier);
    return _WidthReporter(
      onWidth: (w) {
        if (width.state != w) width.state = w;
      },
      child: row,
    );
  }
}

/// Centres the macOS traffic lights in a header [height] points tall, or hands
/// them back to AppKit's title bar at 0. Sent after the frame, only on change.
class MacTrafficLights extends StatefulWidget {
  final double height;
  final Widget child;

  const MacTrafficLights({super.key, required this.height, required this.child});

  static const _channel = MethodChannel('hollow/traffic_lights');

  @override
  State<MacTrafficLights> createState() => _MacTrafficLightsState();
}

class _MacTrafficLightsState extends State<MacTrafficLights> {
  double? _sent;

  void _sync() {
    if (!Platform.isMacOS || _sent == widget.height) return;
    final height = widget.height;
    _sent = height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      MacTrafficLights._channel
          .invokeMethod<void>('setHeaderHeight', height)
          .catchError((_) {});
    });
  }

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(MacTrafficLights old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Calls [onWidth] after a frame whenever its child's laid-out width changes,
/// never during layout.
class _WidthReporter extends SingleChildRenderObjectWidget {
  final ValueChanged<double> onWidth;

  const _WidthReporter({required this.onWidth, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderWidthReporter(onWidth);

  @override
  void updateRenderObject(
          BuildContext context, _RenderWidthReporter renderObject) =>
      renderObject.onWidth = onWidth;
}

class _RenderWidthReporter extends RenderProxyBox {
  _RenderWidthReporter(this.onWidth);

  ValueChanged<double> onWidth;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final w = size.width;
    if (w == _reported) return;
    _reported = w;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (attached) onWidth(w);
    });
  }
}

/// Zoom readout, shown only while the interface scale is not 100%.
///
/// It lives with the window controls because they are the one surface
/// OUTSIDE the scale transform: whatever the user has done, this stays legible
/// and one click from 100%. Without it the only way back is a shortcut you
/// must already know.
class ZoomIndicator extends ConsumerWidget {
  const ZoomIndicator({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scale = ref.watch(uiScaleProvider);
    if ((scale - kUiScaleDefault).abs() < 0.001) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);
    // No HollowTooltip here: the controls sit ABOVE the Navigator and have no
    // Overlay ancestor to host one.
    return Padding(
      padding: const EdgeInsets.only(left: HollowSpacing.xs),
      child: HollowPressable(
        semanticLabel:
            'Interface scale ${scalePercentLabel(scale)}, reset to 100%',
        onTap: () => ref.read(uiScaleProvider.notifier).reset(),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.scaling, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            // Fixed chrome band, so a large OS text scale cannot grow it.
            MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Text(
                scalePercentLabel(scale),
                style: HollowTypography.monoSmall.copyWith(
                  color: hollow.textSecondary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Base for window control buttons: no Material ripple, just instant colour.
class _WindowButton extends StatefulWidget {
  final VoidCallback onTap;
  final double height;
  final IconData icon;
  final Color? hoverColor;

  /// The glyph's colour while hovered, for a fill it would vanish into.
  final Color? hoverGlyph;
  final String semanticLabel;

  const _WindowButton({
    required this.onTap,
    required this.height,
    required this.icon,
    required this.semanticLabel,
    this.hoverColor,
    this.hoverGlyph,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Rest colour is the hover colour at zero alpha, NEVER Colors.transparent:
    // that is transparent BLACK, and the lerp flashes through semi-opaque dark.
    final hoverColor = widget.hoverColor ?? hollow.elevated;
    final glyph = _hovering
        ? widget.hoverGlyph ?? hollow.textSecondary
        : hollow.textSecondary;

    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: HollowDurations.fast,
            width: _kWindowButtonWidth,
            height: widget.height,
            color: _hovering ? hoverColor : hoverColor.withValues(alpha: 0.0),
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 16, color: glyph),
          ),
        ),
      ),
    );
  }
}

/// The platform's caption-button width.
const double _kWindowButtonWidth = 46;

class _MinimizeButton extends StatelessWidget {
  final double height;
  const _MinimizeButton({required this.height});

  @override
  Widget build(BuildContext context) => _WindowButton(
        onTap: () => windowManager.minimize(),
        height: height,
        icon: LucideIcons.minus,
        semanticLabel: 'Minimize',
      );
}

class _MaximizeButton extends StatefulWidget {
  final double height;
  const _MaximizeButton({required this.height});

  @override
  State<_MaximizeButton> createState() => _MaximizeButtonState();
}

class _MaximizeButtonState extends State<_MaximizeButton> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _checkMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _checkMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted) setState(() => _isMaximized = maximized);
  }

  @override
  void onWindowMaximize() {
    setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    return _WindowButton(
      onTap: () async {
        if (_isMaximized) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      height: widget.height,
      // Two stacked squares, the restore glyph every desktop draws.
      icon: _isMaximized ? LucideIcons.copy : LucideIcons.square,
      semanticLabel: _isMaximized ? 'Restore' : 'Maximize',
    );
  }
}

class _CloseButton extends StatelessWidget {
  final double height;
  const _CloseButton({required this.height});

  @override
  Widget build(BuildContext context) => _WindowButton(
        onTap: () => windowManager.close(),
        height: height,
        icon: LucideIcons.x,
        hoverColor: const Color(0xFFE81123), // design-ignore: Windows close-button red
        hoverGlyph: Colors.white, // design-ignore: Windows close-button glyph
        semanticLabel: 'Close',
      );
}
