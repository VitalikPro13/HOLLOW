import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/settings/about_shared.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// About category of the desktop Settings dialog: app identity, contact,
/// follow/support brand links, and legal documents.
class AboutTab extends StatelessWidget {
  const AboutTab({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: HollowSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // App identity row
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/hollow_logo_rounded.png',
                  width: 72,
                  height: 72,
                ),
              ),
              const SizedBox(width: HollowSpacing.lg),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Hollow',
                    style: HollowTypography.heading.copyWith(
                      color: hollow.textPrimary,
                      fontSize: 24,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Alpha Version',
                    style: HollowTypography.body.copyWith(
                      color: hollow.accent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'by AnonListen',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: HollowSpacing.xl),
          _aboutDivider(hollow),
          const SizedBox(height: HollowSpacing.lg),

          // Contact
          _aboutSectionLabel('Contact', hollow),
          const SizedBox(height: HollowSpacing.sm),
          aboutLinkButton(
            onPressed: () => copySupportEmail(context),
            icon: LucideIcons.mail,
            label: 'feedback@anonlisten.com',
          ),
          const SizedBox(height: HollowSpacing.xs),
          aboutLinkButton(
            onPressed: openAnonListenSite,
            icon: LucideIcons.globe,
            label: 'anonlisten.com',
          ),

          const SizedBox(height: HollowSpacing.lg),
          _aboutDivider(hollow),
          const SizedBox(height: HollowSpacing.lg),

          // Follow & Support — header with shimmer line
          _aboutShimmerLabel('Follow', 'Support', hollow),
          const SizedBox(height: HollowSpacing.md),

          // Follow & Support — icons with shimmer separator
          Row(
            children: [
              const _BrandIcon(
                icon: BrandIcons.youtube,
                color: BrandIconColors.youtube,
                tooltip: 'YouTube',
                url: 'https://youtube.com/@Anon_Listen',
              ),
              const SizedBox(width: HollowSpacing.sm),
              _BrandIcon(
                icon: BrandIcons.x,
                color: hollow.textPrimary,
                tooltip: 'X',
                url: 'https://x.com/Anon_Listen',
              ),
              const SizedBox(width: HollowSpacing.sm),
              const _SvgBrandIcon(
                asset: 'assets/tiktok-solo-icon.svg',
                tooltip: 'TikTok',
                url: 'https://tiktok.com/@AnonListen',
              ),
              const SizedBox(width: HollowSpacing.sm),
              const _BrandIcon(
                icon: BrandIcons.twitch,
                color: BrandIconColors.twitch,
                tooltip: 'Twitch',
                url: 'https://twitch.tv/AnonListen',
              ),
              const SizedBox(width: HollowSpacing.sm),
              const _BrandIcon(
                icon: BrandIcons.kick,
                color: BrandIconColors.kick,
                tooltip: 'Kick',
                url: 'https://kick.com/AnonListen',
              ),

              const SizedBox(width: HollowSpacing.sm),
              Expanded(child: ShimmerDividerLine(hollow: hollow)),
              const SizedBox(width: HollowSpacing.sm),

              _BrandIcon(
                icon: BrandIcons.patreon,
                color: hollow.textPrimary,
                tooltip: 'Patreon',
                url: 'https://patreon.com/AnonListen',
              ),
              const SizedBox(width: HollowSpacing.sm),
              const _BrandIcon(
                icon: BrandIcons.kofi,
                color: BrandIconColors.kofi,
                tooltip: 'Ko-Fi',
                url: 'https://ko-fi.com/AnonListen',
              ),
            ],
          ),

          const SizedBox(height: HollowSpacing.lg),
          _aboutDivider(hollow),
          const SizedBox(height: HollowSpacing.lg),

          // Legal
          _aboutSectionLabel('Legal', hollow),
          const SizedBox(height: HollowSpacing.sm),
          aboutLinkButton(
            onPressed: () => _showLegalDocument(
              context,
              title: 'Privacy Policy',
              assetPath: 'legal/PRIVACY_POLICY.md',
            ),
            icon: LucideIcons.shield,
            label: 'Privacy Policy',
          ),
          const SizedBox(height: HollowSpacing.xs),
          aboutLinkButton(
            onPressed: () => _showLegalDocument(
              context,
              title: 'Terms of Use',
              assetPath: 'legal/TERMS_OF_USE.md',
            ),
            icon: LucideIcons.scroll,
            label: 'Terms of Use',
          ),
          const SizedBox(height: HollowSpacing.xs),
          aboutLinkButton(
            onPressed: () => showHollowLicensesPage(context),
            icon: LucideIcons.fileText,
            label: 'Open-Source Licenses',
          ),
        ],
      ),
    );
  }

  static Widget _aboutSectionLabel(String text, HollowTheme hollow) {
    return Text(
      text,
      style: HollowTypography.label.copyWith(
        color: hollow.textSecondary,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
      ),
    );
  }

  static Widget _aboutDivider(HollowTheme hollow) {
    return Container(height: 1, color: hollow.border.withValues(alpha: 0.5));
  }

  static Widget _aboutShimmerLabel(
      String left, String right, HollowTheme hollow) {
    final style = HollowTypography.label.copyWith(
      color: hollow.textSecondary,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
    );
    return Row(
      children: [
        Text(left, style: style),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(child: ShimmerDividerLine(hollow: hollow)),
        const SizedBox(width: HollowSpacing.sm),
        Text(right, style: style),
      ],
    );
  }
}

void _showLegalDocument(
  BuildContext context, {
  required String title,
  required String assetPath,
}) async {
  final hollow = HollowTheme.of(context);
  final body = await loadLegalMarkdownBody(assetPath);

  if (!context.mounted) return;

  showHollowDialog(
    context: context,
    builder: (ctx) => Material(
      color: Colors.transparent,
      child: Center(
        child: Container(
          width: 640,
          height: 520,
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: HollowTypography.heading.copyWith(
                          color: hollow.textPrimary,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    HollowPressable(
                      onTap: () => Navigator.of(ctx).pop(),
                      semanticLabel: 'Close',
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Icon(LucideIcons.x, size: 18,
                            color: hollow.textSecondary),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(height: 1, color: hollow.border.withValues(alpha: 0.5)),
              // Body — rendered markdown
              Expanded(
                child: legalMarkdownView(
                  hollow,
                  body,
                  padding: const EdgeInsets.all(24),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Hover shell shared by the icon-font and SVG brand icons: tooltip +
/// hover-tinted AnimatedContainer + AnimatedScale around the icon.
class _BrandHoverBox extends StatefulWidget {
  final String tooltip;
  final String url;
  final Widget Function(bool hovering, HollowTheme hollow) iconBuilder;

  const _BrandHoverBox({
    required this.tooltip,
    required this.url,
    required this.iconBuilder,
  });

  @override
  State<_BrandHoverBox> createState() => _BrandHoverBoxState();
}

class _BrandHoverBoxState extends State<_BrandHoverBox> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => launchBrandUrl(widget.url),
          child: AnimatedContainer(
            duration: HollowDurations.fast,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              // Zero-alpha rest color, not Colors.transparent (transparent
              // BLACK — the lerp flashed dark on hover/unhover).
              color: _hovering
                  ? hollow.elevated
                  : hollow.elevated.withValues(alpha: 0.0),
              borderRadius: BorderRadius.circular(hollow.radiusSm),
            ),
            child: AnimatedScale(
              scale: _hovering ? 1.15 : 1.0,
              duration: HollowDurations.fast,
              child: widget.iconBuilder(_hovering, hollow),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String tooltip;
  final String url;

  const _BrandIcon({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    return _BrandHoverBox(
      tooltip: tooltip,
      url: url,
      iconBuilder: (hovering, hollow) => Icon(
        icon,
        size: 20,
        semanticLabel: tooltip,
        color: hovering ? color : hollow.textSecondary,
      ),
    );
  }
}

class _SvgBrandIcon extends StatelessWidget {
  final String asset;
  final String tooltip;
  final String url;

  const _SvgBrandIcon({
    required this.asset,
    required this.tooltip,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    return _BrandHoverBox(
      tooltip: tooltip,
      url: url,
      iconBuilder: (hovering, hollow) => SvgPicture.asset(
        asset,
        width: 20,
        height: 20,
        semanticsLabel: tooltip,
        colorFilter: hovering
            ? null
            : ColorFilter.mode(hollow.textSecondary, BlendMode.srcIn),
      ),
    );
  }
}
