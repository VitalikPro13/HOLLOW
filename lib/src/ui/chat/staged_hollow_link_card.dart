import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/share/share_card.dart';

class StagedHollowLinkCard extends ConsumerStatefulWidget {
  final HollowLink link;
  final VoidCallback onDismiss;

  const StagedHollowLinkCard({
    super.key,
    required this.link,
    required this.onDismiss,
  });

  @override
  ConsumerState<StagedHollowLinkCard> createState() =>
      _StagedHollowLinkCardState();
}

class _StagedHollowLinkCardState extends ConsumerState<StagedHollowLinkCard> {
  bool _shareValid = true;
  String? _shareRootHash;

  @override
  void initState() {
    super.initState();
    if (widget.link.type == HollowLinkType.share) {
      _validateShareLink();
    }
  }

  @override
  void didUpdateWidget(StagedHollowLinkCard old) {
    super.didUpdateWidget(old);
    if (old.link.fullUrl != widget.link.fullUrl &&
        widget.link.type == HollowLinkType.share) {
      _shareValid = true;
      _shareRootHash = null;
      _validateShareLink();
    }
  }

  Future<void> _validateShareLink() async {
    try {
      final info =
          await share_api.shareDecodeLink(link: widget.link.fullUrl);
      if (mounted) {
        setState(() {
          _shareValid = true;
          _shareRootHash = info.rootHash;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _shareValid = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = Theme.of(context).extension<HollowTheme>()!;

    final String title;
    final String subtitle;
    final Color subtitleColor;
    final IconData icon;

    switch (widget.link.type) {
      case HollowLinkType.share:
        icon = LucideIcons.share2;
        if (!_shareValid) {
          title = 'Invalid Share Link';
          subtitle = 'This link could not be decoded';
          subtitleColor = hollow.error;
        } else {
          final shares = ref.watch(shareTabProvider);
          final existing = _shareRootHash != null
              ? shares
                  .where((s) => s.rootHash == _shareRootHash)
                  .firstOrNull
              : shares
                  .where((s) => s.shareLink == widget.link.fullUrl)
                  .firstOrNull;
          if (existing != null) {
            title = existing.fileName;
            subtitle =
                '${ShareCard.formatSize(existing.totalSize)}  ·  ${existing.chunksTotal} chunks  ·  In your shares';
            subtitleColor = hollow.success;
          } else {
            title = 'Hollow Share';
            subtitle = 'Valid share link';
            subtitleColor = hollow.textSecondary;
          }
        }
      case HollowLinkType.serverInvite:
        icon = LucideIcons.server;
        final servers = ref.watch(serverListProvider);
        final serverInfo = servers[widget.link.id];
        if (serverInfo != null) {
          title = serverInfo.name;
          subtitle =
              '${serverInfo.memberCount} ${serverInfo.memberCount == 1 ? 'member' : 'members'}  ·  Already joined';
          subtitleColor = hollow.success;
        } else {
          title = 'Server Invite';
          subtitle = 'You haven\'t joined this server';
          subtitleColor = hollow.textSecondary;
        }
      case HollowLinkType.roomInvite:
        icon = LucideIcons.messageCircle;
        title = 'Room Invite';
        subtitle = 'Room: ${widget.link.id}';
        subtitleColor = hollow.textSecondary;
      case HollowLinkType.recovery:
        icon = LucideIcons.lifeBuoy;
        title = 'Recovery Pool Invite';
        subtitle = 'Server: ${widget.link.id}';
        subtitleColor = hollow.textSecondary;
      case HollowLinkType.conference:
        icon = LucideIcons.video;
        title = 'Conference Invite';
        subtitle = 'Meeting: ${widget.link.id}';
        subtitleColor = hollow.textSecondary;
      case HollowLinkType.redeem:
        icon = LucideIcons.gift;
        title = 'Support code';
        subtitle = 'A Hollow Shop code';
        subtitleColor = hollow.textSecondary;
    }

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
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon,
                color: _shareValid ? hollow.accent : hollow.error, size: 20),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: HollowTypography.caption.copyWith(
                    color: _shareValid
                        ? hollow.textPrimary
                        : hollow.error,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: HollowTypography.caption
                      .copyWith(color: subtitleColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          HollowPressable(
            onTap: widget.onDismiss,
            semanticLabel: 'Remove link preview',
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child:
                Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}
