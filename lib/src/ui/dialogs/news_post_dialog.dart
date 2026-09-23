import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

/// One news post in full, from Home's What's New card.
void showNewsPostDialog(BuildContext context, NewsPost post) {
  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);
      final body = HollowTypography.body.copyWith(color: hollow.textPrimary);
      return HollowDialog(
        title: post.title,
        showClose: true,
        width: 560,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              post.date,
              style: HollowTypography.caption
                  .copyWith(color: hollow.textTertiary),
            ),
            const SizedBox(height: HollowSpacing.md),
            Flexible(
              child: SingleChildScrollView(
                child: MarkdownBody(
                  data: post.body,
                  selectable: true,
                  onTapLink: (text, href, title) {
                    if (href != null) {
                      launchUrl(Uri.parse(href),
                          mode: LaunchMode.externalApplication);
                    }
                  },
                  styleSheet: MarkdownStyleSheet(
                    p: body,
                    h2: HollowTypography.subheading
                        .copyWith(color: hollow.textPrimary),
                    h3: HollowTypography.label
                        .copyWith(color: hollow.textPrimary),
                    listBullet: body.copyWith(color: hollow.textSecondary),
                    strong: body.copyWith(fontWeight: FontWeight.w600),
                    a: body.copyWith(
                      color: hollow.accentText,
                      decoration: TextDecoration.underline,
                      decorationColor: hollow.accentText,
                    ),
                    blockSpacing: HollowSpacing.md,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
