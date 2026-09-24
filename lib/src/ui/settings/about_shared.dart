import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:url_launcher/url_launcher.dart';

/// About-section pieces shared by the desktop About category and the mobile
/// Settings tab.

/// Loads a legal markdown asset without its top-level heading, which the
/// surfaces show in their own header chrome.
Future<String> loadLegalMarkdownBody(String assetPath) async {
  final text = await rootBundle.loadString(assetPath);
  final lines = text.split('\n');
  return lines
      .skipWhile((l) => l.startsWith('# ') || l.trim().isEmpty)
      .join('\n')
      .trim();
}

/// Rendered legal markdown with the Hollow stylesheet: the shared body under
/// the desktop dialog's and the mobile sheet's own shells.
Widget legalMarkdownView(
  HollowTheme hollow,
  String body, {
  ScrollController? controller,
  required EdgeInsets padding,
}) {
  return Markdown(
    data: body,
    controller: controller,
    selectable: true,
    padding: padding,
    onTapLink: (text, href, title) {
      if (href != null) {
        launchUrl(Uri.parse(href), mode: LaunchMode.externalApplication);
      }
    },
    styleSheet: MarkdownStyleSheet(
      h2: HollowTypography.subheading.copyWith(color: hollow.textPrimary),
      h3: HollowTypography.body.copyWith(
        color: hollow.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      p: HollowTypography.body.copyWith(
        color: hollow.textPrimary,
        height: 1.6,
      ),
      listBullet: HollowTypography.body.copyWith(
        color: hollow.textSecondary,
      ),
      strong: HollowTypography.body.copyWith(
        color: hollow.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      a: HollowTypography.body.copyWith(
        color: hollow.accent,
        decoration: TextDecoration.underline,
        decorationColor: hollow.accent,
      ),
      blockSpacing: HollowSpacing.md,
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: hollow.border.withValues(alpha: 0.5),
          ),
        ),
      ),
    ),
  );
}

/// Opens a brand or social URL in the external browser.
void launchBrandUrl(String url) {
  launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Where feedback goes.
const kSupportEmail = 'feedback@anonlisten.com';

/// Copies the feedback email to the clipboard.
void copySupportEmail(BuildContext context) {
  Clipboard.setData(const ClipboardData(text: kSupportEmail));
  HollowToast.show(context, 'Email copied to clipboard',
      type: HollowToastType.success);
}

/// Opens Hollow's website externally.
void openHollowSite() {
  launchUrl(
    Uri.parse('https://hollow.anonlisten.com'),
    mode: LaunchMode.externalApplication,
  );
}

/// Flutter's license page with the Hollow branding.
void showHollowLicensesPage(BuildContext context) {
  showLicensePage(
    context: context,
    applicationName: 'Hollow',
    applicationVersion: 'Beta',
    applicationIcon: Padding(
      padding: const EdgeInsets.all(HollowSpacing.md),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(HollowTheme.of(context).radiusLg),
        child: Image.asset(
          'assets/hollow_logo_rounded.png',
          width: 48,
          height: 48,
        ),
      ),
    ),
  );
}
