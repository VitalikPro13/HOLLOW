import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:url_launcher/url_launcher.dart';

/// Rendered link preview card inside a chat bubble.
///
/// Displays title (bold) + description (muted, 3 lines max) + domain line,
/// with an optional thumbnail on the left. Clicking the card opens the
/// URL in the user's default browser via `url_launcher` — receivers NEVER
/// fetch the URL to render the card, only when the user explicitly taps it.
///
/// Phase 6.75.
class LinkPreviewCard extends StatelessWidget {
  final network_api.LinkPreviewRef preview;

  const LinkPreviewCard({super.key, required this.preview});

  @override
  Widget build(BuildContext context) {
    final hollow = Theme.of(context).extension<HollowTheme>()!;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 400),
      child: HollowPressable(
        onTap: _handleTap,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: EdgeInsets.zero,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          child: Container(
            decoration: BoxDecoration(
              color: hollow.elevated,
              border: Border(
                left: BorderSide(color: hollow.accent, width: 3),
                top: BorderSide(color: hollow.border),
                right: BorderSide(color: hollow.border),
                bottom: BorderSide(color: hollow.border),
              ),
            ),
            padding: const EdgeInsets.all(HollowSpacing.sm),
            child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildThumbnail(hollow),
              const SizedBox(width: HollowSpacing.sm),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_headerLine().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          _headerLine(),
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (preview.title.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          preview.title,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    if (preview.description.isNotEmpty)
                      Text(
                        preview.description,
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          height: 1.3,
                        ),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(HollowTheme hollow) {
    final b64 = preview.thumbWebpB64;
    if (b64 == null || b64.isEmpty) {
      return const SizedBox.shrink();
    }
    try {
      final bytes = base64Decode(b64);
      return ClipRRect(
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        child: Image.memory(
          bytes,
          width: 80,
          height: 80,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (context, error, stack) => const SizedBox.shrink(),
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  /// Header line: "Site Name · domain", or just "domain" if no site name.
  String _headerLine() {
    if (preview.siteName.isNotEmpty && preview.siteName != preview.domain) {
      return preview.domain.isNotEmpty
          ? '${preview.siteName} · ${preview.domain}'
          : preview.siteName;
    }
    return preview.domain;
  }

  Future<void> _handleTap() async {
    final uri = Uri.tryParse(preview.url);
    if (uri == null) return;
    try {
      // mode: externalApplication opens in the default browser on desktop.
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // Silently swallow — user can still copy-paste the URL manually.
    }
  }
}
