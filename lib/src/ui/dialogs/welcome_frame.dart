import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The one surface Welcome and the first-run link steps share, so moving
/// between them reads as one flow: a fixed-width dialog on desktop, the whole
/// screen on a phone or tablet. At phone width [bottom] sits in reach of a
/// thumb; wider, the steps stand as one centred column.
class WelcomeFrame extends StatelessWidget {
  /// Null for a step with no header (the first run's own hero).
  final String? title;

  /// Shows a back arrow before [title].
  final VoidCallback? onBack;

  /// Keeps the arrow in place but inert while a step is busy.
  final bool backEnabled;

  final Widget body;

  /// Follows [body] on desktop; pinned to the foot of the screen on a phone.
  final Widget? bottom;

  const WelcomeFrame({
    super.key,
    this.title,
    this.onBack,
    this.backEnabled = true,
    required this.body,
    this.bottom,
  });

  static const double width = 440;

  /// The whole screen and touch-size controls: every phone and tablet at any
  /// width or orientation (they keep the phone shell after it too), and a
  /// desktop window narrowed to phone width.
  static bool fullScreen(BuildContext context) =>
      _touchPlatform || HollowDialogSurface.isCompact(context);

  /// The device in hand is a phone, for copy that names it. Read from the
  /// display, not the window: the interface scale shrinks [MediaQuery]'s
  /// size, and a tablet's split-screen or freeform window can be phone-sized.
  static bool onPhone(BuildContext context) {
    if (!_touchPlatform) return false;
    final display = View.of(context).display;
    return (display.size / display.devicePixelRatio).shortestSide <
        HollowDialogSurface.compactBreakpoint;
  }

  static bool get _touchPlatform =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final phone = fullScreen(context);
    final header = title == null
        ? null
        : _Header(title: title!, onBack: onBack, backEnabled: backEnabled);

    if (!phone) {
      return HollowDialogSurface(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (header != null) ...[
              header,
              const SizedBox(height: HollowSpacing.lg),
            ],
            Flexible(child: SingleChildScrollView(child: body)),
            if (bottom != null) ...[
              const SizedBox(height: HollowSpacing.xl),
              bottom!,
            ],
          ],
        ),
      );
    }

    // A first-run surface, not a dialog over something: nothing is behind it
    // worth showing, so it takes the screen. Its fields need the Material
    // that HollowDialogSurface gives them on desktop.
    final hollow = HollowTheme.of(context);
    final surface = hollow.background;
    return Material(color: surface, // design-ignore: full-screen first run
      child: SafeArea(
        child: HollowDialogSurface.isCompact(context)
            ? _thumbColumn(header)
            : _centredColumn(header),
      ),
    );
  }

  /// A tablet, or a phone on its side: one column at the dialog's width,
  /// centred, scrolling whole when the screen is short.
  Widget _centredColumn(Widget? header) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(HollowSpacing.xl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: width),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (header != null) ...[
                      header,
                      const SizedBox(height: HollowSpacing.lg),
                    ],
                    body,
                    if (bottom != null) ...[
                      const SizedBox(height: HollowSpacing.xl),
                      bottom!,
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _thumbColumn(Widget? header) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.xl,
        HollowSpacing.lg,
        HollowSpacing.xl,
        HollowSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null) ...[
            header,
            const SizedBox(height: HollowSpacing.lg),
          ],
          // [bottom] sits at the foot while everything fits and scrolls with
          // the body when it does not (large text, the relay field open).
          // Built whole, never lazily, so every control can be found.
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      body,
                      if (bottom != null)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: HollowSpacing.lg),
                            bottom!,
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The action row of a Welcome step: trailing and [HollowSpacing.sm] apart on
/// desktop, full width and stacked on a phone, primary last either way.
class WelcomeActions extends StatelessWidget {
  final List<Widget> children;

  /// Quiet text at the row's leading edge (desktop) or above it (phone).
  final Widget? lead;

  const WelcomeActions({super.key, required this.children, this.lead});

  @override
  Widget build(BuildContext context) {
    if (WelcomeFrame.fullScreen(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lead != null) ...[
            Center(child: lead!),
            const SizedBox(height: HollowSpacing.md),
          ],
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: HollowSpacing.sm),
            children[i],
          ],
        ],
      );
    }
    return Row(
      children: [
        if (lead != null) Expanded(child: lead!) else const Spacer(),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0 || lead != null) const SizedBox(width: HollowSpacing.sm),
          children[i],
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback? onBack;
  final bool backEnabled;

  const _Header({required this.title, this.onBack, required this.backEnabled});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final phone = WelcomeFrame.fullScreen(context);
    return Row(
      children: [
        if (onBack != null) ...[
          HollowIconButton(
            icon: LucideIcons.arrowLeft,
            label: 'Back',
            size: phone ? 44 : 32,
            onPressed: backEnabled ? onBack : null,
          ),
          const SizedBox(width: HollowSpacing.xs),
        ],
        Expanded(
          child: Text(
            title,
            style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
          ),
        ),
      ],
    );
  }
}
