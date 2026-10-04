import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/services/untrusted_link.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

/// One news post in full, from Home's What's New card.
void showNewsPostDialog(BuildContext context, NewsPost post) {
  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      final hollow = HollowTheme.of(dialogContext);
      return HollowDialog(
        title: post.title,
        showClose: true,
        width: 560,
        scrollable: false,
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
                child: NewsPostBody(markdown: post.body),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// A news post's markdown body.
///
/// The feed is unsigned, so opening a post must make no request: an image
/// renders as its alt text, never fetched, and a link opens only through the
/// untrusted link helper.
class NewsPostBody extends StatelessWidget {
  final String markdown;

  const NewsPostBody({super.key, required this.markdown});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final body = HollowTypography.body.copyWith(color: hollow.textPrimary);
    return MarkdownBody(
      data: markdown,
      selectable: true,
      imageBuilder: (uri, title, alt) => (alt ?? '').isEmpty
          ? const SizedBox.shrink()
          : Text(alt!, style: body.copyWith(color: hollow.textSecondary)),
      onTapLink: (text, href, title) {
        if (href != null) openUntrustedUrl(href).catchError((_) => false);
      },
      styleSheet: MarkdownStyleSheet(
        p: body,
        h2: HollowTypography.subheading.copyWith(color: hollow.textPrimary),
        h3: HollowTypography.label.copyWith(color: hollow.textPrimary),
        listBullet: body.copyWith(color: hollow.textSecondary),
        strong: body.copyWith(fontWeight: FontWeight.w600),
        a: body.copyWith(
          color: hollow.accentText,
          decoration: TextDecoration.underline,
          decorationColor: hollow.accentText,
        ),
        blockSpacing: HollowSpacing.md,
      ),
    );
  }
}
