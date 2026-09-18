import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/room_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_conferences_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/share/paste_link_dialog.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/ui/share/share_card.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';

class HollowLinkCard extends ConsumerWidget {
  final HollowLink link;
  const HollowLinkCard({super.key, required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (link.type) {
      case HollowLinkType.share:
        return _ShareLinkCard(link: link);
      case HollowLinkType.serverInvite:
        return _ServerInviteCard(link: link);
      case HollowLinkType.roomInvite:
        return _RoomInviteCard(link: link);
      case HollowLinkType.recovery:
        return _RecoveryLinkCard(link: link);
      case HollowLinkType.conference:
        return _ConferenceInviteCard(link: link);
      case HollowLinkType.redeem:
        return _RedeemCodeCard(link: link);
    }
  }
}

Widget _cardContainer({
  required HollowTheme hollow,
  required VoidCallback? onTap,
  required Widget child,
}) {
  return ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 400),
    child: HollowPressable(
      onTap: onTap,
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
          child: child,
        ),
      ),
    ),
  );
}

class _ShareLinkCard extends ConsumerWidget {
  final HollowLink link;
  const _ShareLinkCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final shares = ref.watch(shareTabProvider);
    final existing = shares.where((s) => s.shareLink == link.fullUrl).firstOrNull;

    return _cardContainer(
      hollow: hollow,
      onTap: () => _openShareDialog(context),
      child: Row(
        children: [
          Icon(LucideIcons.share2, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  existing != null ? existing.fileName : 'Hollow Share',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (existing != null)
                  Text(
                    '${ShareCard.formatSize(existing.totalSize)}  ·  ${existing.chunksTotal} chunks',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    'Click to download',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (existing != null)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: hollow.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(hollow.radiusXs),
              ),
              child: Text(
                'In shares',
                style: HollowTypography.caption.copyWith(
                  color: hollow.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            HollowButton.outline(
              compact: true,
              onPressed: () => _openShareDialog(context),
              child: const Text('Open'),
            ),
        ],
      ),
    );
  }

  void _openShareDialog(BuildContext context) {
    showHollowDialog(
      context: context,
      builder: (ctx) => PasteLinkDialog(initialLink: link.fullUrl),
    );
  }
}

class _ServerInviteCard extends ConsumerWidget {
  final HollowLink link;
  const _ServerInviteCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final servers = ref.watch(serverListProvider);
    final serverInfo = servers[link.id];
    final alreadyJoined = serverInfo != null;

    return _cardContainer(
      hollow: hollow,
      onTap: alreadyJoined ? null : () => _handleJoin(context, ref),
      child: Row(
        children: [
          Icon(LucideIcons.server, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  alreadyJoined ? serverInfo.name : 'Server Invite',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                if (alreadyJoined)
                  Text(
                    '${serverInfo.memberCount} ${serverInfo.memberCount == 1 ? 'member' : 'members'}  ·  ${serverInfo.channelCount} ${serverInfo.channelCount == 1 ? 'channel' : 'channels'}',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                  )
                else
                  Text(
                    link.id,
                    style: HollowTypography.mono.copyWith(
                      color: hollow.textSecondary,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                if (!alreadyJoined) _RelayHint(relay: link.relay),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          if (alreadyJoined)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xxs,
              ),
              decoration: BoxDecoration(
                color: hollow.success.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(hollow.radiusXs),
              ),
              child: Text(
                'Joined',
                style: HollowTypography.caption.copyWith(
                  color: hollow.success,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            HollowButton.filled(
              compact: true,
              onPressed: () => _handleJoin(context, ref),
              child: const Text('Join'),
            ),
        ],
      ),
    );
  }

  Future<void> _handleJoin(BuildContext context, WidgetRef ref) async {
    if (!await ensureRelayForInvite(context, ref, link)) return;
    if (!context.mounted) return;
    crdt_api.joinServer(serverId: link.id, nsfwConfirmed: false)
        .catchError((_) {});
    HollowToast.show(context, 'Joining server...', type: HollowToastType.info);
  }
}

class _RoomInviteCard extends ConsumerWidget {
  final HollowLink link;
  const _RoomInviteCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return _cardContainer(
      hollow: hollow,
      onTap: () => _handleJoin(context, ref),
      child: Row(
        children: [
          Icon(LucideIcons.messageCircle, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Room Invite',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  link.id,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                _RelayHint(relay: link.relay),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            compact: true,
            onPressed: () => _handleJoin(context, ref),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleJoin(BuildContext context, WidgetRef ref) async {
    if (!await ensureRelayForInvite(context, ref, link)) return;
    ref.read(roomProvider.notifier).join(link.fullUrl);
  }
}

/// A Hollow Shop support code pasted into chat. Renders nothing on a store
/// build, because no shop surface means no redeem surface.
class _RedeemCodeCard extends ConsumerWidget {
  final HollowLink link;
  const _RedeemCodeCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(shopAvailableProvider)) return const SizedBox.shrink();
    final hollow = HollowTheme.of(context);

    return _cardContainer(
      hollow: hollow,
      onTap: () => showRedeemCodeDialog(context, link.id),
      child: Row(
        children: [
          Icon(LucideIcons.gift, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Support code',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Tap to keep it in Hollow',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ConferenceInviteCard extends ConsumerWidget {
  final HollowLink link;
  const _ConferenceInviteCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return _cardContainer(
      hollow: hollow,
      onTap: () => _handleJoin(context, ref),
      child: Row(
        children: [
          Icon(LucideIcons.video, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Conference Invite',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  link.id,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                _RelayHint(relay: link.relay),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            compact: true,
            onPressed: () => _handleJoin(context, ref),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleJoin(BuildContext context, WidgetRef ref) async {
    if (!await ensureRelayForInvite(context, ref, link)) return;
    if (!context.mounted) return;
    if (Platform.isAndroid || Platform.isIOS) {
      // On mobile the lobby lives in the Conferences screen.
      Navigator.of(context, rootNavigator: true).push(hollowMobileRoute(
        builder: (_) => const MobileConferencesRoute(),
      ));
    } else {
      ref.read(conferenceProvider.notifier).openTab();
    }
    unawaited(ref
        .read(conferenceProvider.notifier)
        .requestJoin(link.id)
        .catchError((_) {}));
  }
}

class _RecoveryLinkCard extends ConsumerWidget {
  final HollowLink link;
  const _RecoveryLinkCard({required this.link});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return _cardContainer(
      hollow: hollow,
      onTap: () => showJoinRecoveryPoolDialog(context, prefillLink: link.fullUrl),
      child: Row(
        children: [
          Icon(LucideIcons.lifeBuoy, size: 20, color: hollow.accent),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Recovery Pool Invite',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  link.id,
                  style: HollowTypography.mono.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            compact: true,
            onPressed: () =>
                showJoinRecoveryPoolDialog(context, prefillLink: link.fullUrl),
            child: const Text('Open'),
          ),
        ],
      ),
    );
  }
}

/// Names the relay an invite came from when it is not the one we are on, so a
/// Join that ends in a restart is never a surprise.
class _RelayHint extends ConsumerWidget {
  const _RelayHint({required this.relay});

  final String? relay;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = relay;
    if (target == null ||
        normalizeRelayHost(ref.watch(relayDomainProvider)) == target) {
      return const SizedBox.shrink();
    }
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        'On $target',
        style: HollowTypography.caption.copyWith(color: hollow.textTertiary),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
