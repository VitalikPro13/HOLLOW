import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The one surface Welcome and the first-run link steps share, so moving
/// between them reads as one flow: a fixed-width dialog on desktop, the whole
/// screen on a phone with [bottom] in reach of a thumb.
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

  static bool isPhone(BuildContext context) =>
      HollowDialogSurface.isCompact(context);

  @override
  Widget build(BuildContext context) {
    final phone = isPhone(context);
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
        child: Padding(
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
              Expanded(child: SingleChildScrollView(child: body)),
              if (bottom != null) ...[
                const SizedBox(height: HollowSpacing.lg),
                bottom!,
              ],
            ],
          ),
        ),
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
    if (WelcomeFrame.isPhone(context)) {
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
    final phone = WelcomeFrame.isPhone(context);
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
