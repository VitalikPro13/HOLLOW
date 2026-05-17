import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/animations/startup_reveal.dart';
import 'package:hollow/src/ui/annotation/annotation_toggle_button.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';

/// Custom 32px title bar replacing the native Windows chrome.
///
/// Layout: [Hollow branding] [drag area ────────] [─] [□] [✕]
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final brandReveal = StartupRevealScope.interval(context, 0.0, 0.15);
    final buttonsReveal = StartupRevealScope.interval(context, 0.08, 0.20);

    Widget branding = Padding(
      padding: const EdgeInsets.only(left: HollowSpacing.lg),
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
      branding = FadeTransition(
        opacity: brandReveal,
        child: branding,
      );
    }

    Widget buttons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (Platform.isMacOS || Platform.isWindows) const AnnotationToggleButton(),
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

  const _WindowButton({
    required this.onTap,
    required this.child,
    this.hoverColor,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final bgColor = _hovering
        ? (widget.hoverColor ?? hollow.elevated)
        : Colors.transparent;

    return MouseRegion(
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
      child: Icon(
        LucideIcons.x,
        size: 16,
        color: hollow.textSecondary,
      ),
    );
  }
}
