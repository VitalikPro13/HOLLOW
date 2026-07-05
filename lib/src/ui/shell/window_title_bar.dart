import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/ui/annotation/annotation_toggle_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

/// Custom 32px title bar replacing the native window chrome.
///
/// Windows/Linux layout: [Hollow branding] [drag area ──] [✎] [─] [□] [✕]
/// macOS layout (native traffic lights stay top-left, drawn by the OS):
///   [○○○ gap] [✎ Annotate] [drag area ── Hollow ── drag area]
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  /// Width reserved on the left for the macOS native traffic-light buttons so
  /// nothing we draw overlaps them.
  static const double _macTrafficLightGap = 78;

  @override
  Widget build(BuildContext context) {
    if (Platform.isMacOS) {
      return _buildMacOS(context);
    }
    return _buildWindows(context);
  }

  Widget _buildMacOS(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final brandReveal = StartupRevealScope.interval(context, 0.0, 0.15);
    final buttonsReveal = StartupRevealScope.interval(context, 0.08, 0.20);

    // Centered title.
    // Larger Text (a11y P3): the 32px OS title bar is fixed chrome (traffic-
    // light alignment depends on it), so cap the brand label's scale rather
    // than let it clip — the iOS/Android tab-bar norm.
    Widget title = MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: Text(
        'Hollow',
        style: HollowTypography.label.copyWith(
          color: hollow.accent,
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
    if (brandReveal != null) {
      title = FadeTransition(opacity: brandReveal, child: title);
    }

    // Annotate button sits just to the right of the traffic lights.
    Widget annotate = const AnnotationToggleButton();
    if (buttonsReveal != null) {
      annotate = FadeTransition(opacity: buttonsReveal, child: annotate);
    }

    return Container(
      height: 32,
      color: hollow.opaqueBackground,
      child: Stack(
        children: [
          // Full-width drag area underneath everything so the whole bar moves
          // the window (the traffic lights + button capture their own taps).
          const Positioned.fill(child: DragToMoveArea(child: SizedBox.expand())),
          // Centered title (ignores pointer so the drag area still works).
          Center(
            child: IgnorePointer(child: title),
          ),
          // Traffic-light gap + Annotate button on the left.
          Padding(
            padding: const EdgeInsets.only(left: _macTrafficLightGap),
            child: Align(
              alignment: Alignment.centerLeft,
              child: annotate,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWindows(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final brandReveal = StartupRevealScope.interval(context, 0.0, 0.15);
    final buttonsReveal = StartupRevealScope.interval(context, 0.08, 0.20);

    Widget branding = Padding(
      padding: const EdgeInsets.only(left: HollowSpacing.lg),
      // Larger Text (a11y P3): fixed 32px title-bar chrome — cap the brand
      // label scale so it can't clip the band.
      child: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: Text(
          'Hollow',
          style: HollowTypography.label.copyWith(
            color: hollow.accent,
            fontWeight: FontWeight.w700,
            fontSize: 13,
          ),
        ),
      ),
    );

    if (brandReveal != null) {
      branding = FadeTransition(
        opacity: brandReveal,
        child: branding,
      );
    }

    Widget buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AnnotationToggleButton(),
        const SizedBox(width: 4),
        const _MinimizeButton(),
        _MaximizeButton(),
        _CloseButton(),
      ],
    );

    if (buttonsReveal != null) {
      buttons = FadeTransition(
        opacity: buttonsReveal,
        child: buttons,
      );
    }

    return Container(
      height: 32,
      color: hollow.opaqueBackground,
      child: Row(
        children: [
          branding,
          const Expanded(child: DragToMoveArea(child: SizedBox.expand())),
          buttons,
        ],
      ),
    );
  }
}

/// Base for window control buttons — no Material ripple, just instant color.
class _WindowButton extends StatefulWidget {
  final VoidCallback onTap;
  final Color? hoverColor;
  final Widget child;
  final String? semanticLabel;

  const _WindowButton({
    required this.onTap,
    required this.child,
    this.hoverColor,
    this.semanticLabel,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    // Rest color = hover color at zero alpha, NOT Colors.transparent
    // (transparent BLACK — the animated lerp passed through semi-opaque dark,
    // flashing dark on hover/unhover; the close button muddied through
    // dark-red). Same-RGB endpoints make the transition a pure fade.
    final hoverColor = widget.hoverColor ?? hollow.elevated;
    final bgColor =
        _hovering ? hoverColor : hoverColor.withValues(alpha: 0.0);

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
            width: 46,
            height: 32,
            color: bgColor,
            alignment: Alignment.center,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _MinimizeButton extends StatelessWidget {
  const _MinimizeButton();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return _WindowButton(
      onTap: () => windowManager.minimize(),
      semanticLabel: 'Minimize',
      child: Icon(
        LucideIcons.minus,
        size: 16,
        color: hollow.textSecondary,
      ),
    );
  }
}

class _MaximizeButton extends StatefulWidget {
  const _MaximizeButton();

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
    final hollow = HollowTheme.of(context);

    return _WindowButton(
      onTap: () async {
        if (_isMaximized) {
          await windowManager.unmaximize();
        } else {
          await windowManager.maximize();
        }
      },
      semanticLabel: _isMaximized ? 'Restore' : 'Maximize',
      child: Icon(
        _isMaximized ? LucideIcons.columns : LucideIcons.square,
        size: 14,
        color: hollow.textSecondary,
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton();

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return _WindowButton(
      onTap: () => windowManager.close(),
      hoverColor: const Color(0xFFE81123), // Standard red close hover
      semanticLabel: 'Close',
      child: Icon(
        LucideIcons.x,
        size: 16,
        color: hollow.textSecondary,
      ),
    );
  }
}
