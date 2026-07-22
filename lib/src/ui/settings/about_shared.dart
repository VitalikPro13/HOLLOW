import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:url_launcher/url_launcher.dart';

/// About-section pieces shared by the desktop About category and the mobile
/// Settings tab: legal-document markdown rendering, the contact/legal link
/// buttons, and the open-source licenses page.

/// Load a legal markdown asset and strip the top-level heading (# Title) —
/// the surfaces show the title in their own header chrome.
Future<String> loadLegalMarkdownBody(String assetPath) async {
  final text = await rootBundle.loadString(assetPath);
  final lines = text.split('\n');
  return lines
      .skipWhile((l) => l.startsWith('# ') || l.trim().isEmpty)
      .join('\n')
      .trim();
}

/// Rendered legal markdown with the Hollow stylesheet. The desktop dialog and
/// mobile bottom sheet differ only in their shell — this is the shared body.
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
      h2: HollowTypography.heading.copyWith(
        color: hollow.textPrimary,
        fontSize: 16,
      ),
      h3: HollowTypography.heading.copyWith(
        color: hollow.textPrimary,
        fontSize: 14,
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
        fontWeight: FontWeight.w700,
      ),
      a: HollowTypography.body.copyWith(
        color: hollow.accent,
        decoration: TextDecoration.underline,
        decorationColor: hollow.accent,
      ),
      blockSpacing: 12,
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

/// Left-aligned ghost link button — the About sections' one link shape.
Widget aboutLinkButton({
  required VoidCallback onPressed,
  required IconData icon,
  required String label,
}) {
  return Align(
    alignment: Alignment.centerLeft,
    child: HollowButton.ghost(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      child: Text(label),
    ),
  );
}

/// Open a brand/social URL in the external browser.
void launchBrandUrl(String url) {
  launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
}

/// Copy the feedback email to the clipboard (Contact section).
void copySupportEmail(BuildContext context) {
  Clipboard.setData(const ClipboardData(text: 'feedback@anonlisten.com'));
  HollowToast.show(context, 'Email copied to clipboard',
      type: HollowToastType.success);
}

/// Open the AnonListen website externally (Contact section).
void openAnonListenSite() {
  launchUrl(
    Uri.parse('https://anonlisten.com'),
    mode: LaunchMode.externalApplication,
  );
}

/// Flutter's license page with the Hollow branding (Legal section).
void showHollowLicensesPage(BuildContext context) {
  showLicensePage(
    context: context,
    applicationName: 'Hollow',
    applicationVersion: 'Beta',
    applicationIcon: Padding(
      padding: const EdgeInsets.all(HollowSpacing.md),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image.asset(
          'assets/hollow_logo_rounded.png',
          width: 48,
          height: 48,
        ),
      ),
    ),
  );
}
