import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Compose-box staged link preview card, shown above the input bar while the
/// message being typed carries a URL.
///
/// A failed fetch is the CALLER's to handle by not rendering this at all.
/// [onDismiss] clears the staged preview and leaves the URL in the box.
class StagedLinkPreviewCard extends StatelessWidget {
  final String url;
  final network_api.LinkPreviewRef? preview;
  final bool loading;
  final VoidCallback onDismiss;

  const StagedLinkPreviewCard({
    super.key,
    required this.url,
    required this.preview,
    required this.loading,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = Theme.of(context).extension<HollowTheme>()!;

    return Container(
      padding: const EdgeInsets.fromLTRB(
          HollowSpacing.md, HollowSpacing.sm, HollowSpacing.md, 0),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(top: BorderSide(color: hollow.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildThumbnail(hollow),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _titleText(),
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  _subtitleText(),
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          HollowPressable(
            onTap: onDismiss,
            semanticLabel: 'Remove link preview',
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x,
                size: 16, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildThumbnail(HollowTheme hollow) {
    final p = preview;
    if (p != null && p.thumbWebpB64 != null) {
      try {
        final bytes = base64Decode(p.thumbWebpB64!);
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.memory(
            bytes,
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      } catch (_) {
      }
    }
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: hollow.elevated,
        borderRadius: BorderRadius.circular(6),
      ),
      child: loading
          ? Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: hollow.accent,
                ),
              ),
            )
          : Icon(LucideIcons.link2, color: hollow.textSecondary, size: 20),
    );
  }

  String _titleText() {
    final p = preview;
    if (p == null) return loading ? 'Loading preview…' : url;
    if (p.title.isNotEmpty) return p.title;
    if (p.siteName.isNotEmpty) return p.siteName;
    if (p.domain.isNotEmpty) return p.domain;
    return url;
  }

  String _subtitleText() {
    final p = preview;
    if (p == null) return url;
    if (p.siteName.isNotEmpty && p.siteName != p.domain) {
      return p.domain.isNotEmpty ? '${p.siteName} · ${p.domain}' : p.siteName;
    }
    return p.domain.isNotEmpty ? p.domain : url;
  }
}
