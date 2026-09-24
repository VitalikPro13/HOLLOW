import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/saved_messages_provider.dart';
import 'package:hollow/src/core/providers/showcase_assets_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/panel_resize_handle.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/profile_dialog.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/shell/friends_bar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

const double _kAvatarSize = 72;

/// The ring of panel colour that lifts the avatar off the banner.
const double _kAvatarRing = HollowSpacing.xs;

/// The person you are talking to, on the right of a DM, built like a server's
/// member panel and sharing its width and seam.
///
/// Identity first, then what they chose to share, then whether you have
/// verified them. Block and Report wait in the More menu, never at rest.
class DmProfilePanel extends ConsumerWidget {
  final String peerId;

  const DmProfilePanel({super.key, required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final width = ref.watch(memberPanelWidthProvider);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PanelResizeHandle(
          label: 'Resize the profile panel',
          panelOnRight: true,
          width: width,
          onResize: (w) =>
              ref.read(memberPanelWidthProvider.notifier).setWidth(w),
          onReset: () => ref.read(memberPanelWidthProvider.notifier).reset(),
        ),
        SizedBox(width: width, child: _Panel(peerId: peerId, width: width)),
      ],
    );
  }
}

class _Panel extends ConsumerWidget {
  final String peerId;
  final double width;

  const _Panel({required this.peerId, required this.width});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    // Block, report, verification and the profile all key on the MASTER.
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    final localNick = ref.watch(localNicknameProvider)[peerId];
    final savedId = ref.watch(savedMessagesPeerIdProvider);
    final isSaved = savedId != null && master == savedId;
    final verifiedTwitch = ref.watch(twitchLoginProvider(peerId));

    final profileName = displayNameForPeer(profile, peerId);
    final hasNick = localNick != null && localNick.isNotEmpty;
    final status = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    final board = ShowcaseBoard.decode(profile?.showcaseBoard);
    final nowPlaying = [...board.left, ...board.right]
        .where((b) => b.type == ShowcaseBlockType.nowPlaying)
        .firstOrNull;

    final bannerHeight = width / 2.5;
    final avatarTop = bannerHeight - _kAvatarSize / 2 - _kAvatarRing;

    final sections = <Widget>[
      if (aboutMe.isNotEmpty)
        _Section(
          title: 'About Me',
          child: Text(
            aboutMe,
            style: HollowTypography.body.copyWith(color: hollow.textPrimary),
          ),
        ),
      if (nowPlaying != null)
        _Section(
          title: 'Now Playing',
          child: ShowcaseGameRow(
            block: nowPlaying,
            assets:
                ref.watch(showcaseAssetsProvider(peerId)).valueOrNull ??
                    const {},
          ),
        ),
      if (!isSaved) _Section(title: 'Encryption', child: _Verification(master)),
    ];

    return ColoredBox(
      color: hollow.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: bannerHeight + _kAvatarSize / 2 + _kAvatarRing,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: bannerHeight,
                  child: _Banner(peerId: peerId, height: bannerHeight),
                ),
                Positioned(
                  left: HollowSpacing.lg - _kAvatarRing,
                  top: avatarTop,
                  child: _RingedAvatar(peerId: peerId),
                ),
                if (!isSaved)
                  Positioned(
                    right: HollowSpacing.md,
                    top: bannerHeight + HollowSpacing.sm,
                    child: _Actions(peerId: peerId, master: master),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                HollowSpacing.lg, HollowSpacing.md, HollowSpacing.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasNick ? localNick : profileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: HollowTypography.heading
                      .copyWith(color: hollow.textPrimary),
                ),
                if (hasNick)
                  Text(
                    profileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textTertiary),
                  ),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: HollowSpacing.xs),
                  Text(
                    status,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.bodySmall
                        .copyWith(color: hollow.textSecondary),
                  ),
                ],
                // VERIFIED accounts only: the profile's own `twitch_username`
                // is a self-declaration and draws nothing.
                if (verifiedTwitch != null) ...[
                  const SizedBox(height: HollowSpacing.sm),
                  _TwitchBadge(login: verifiedTwitch),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(HollowSpacing.lg,
                  HollowSpacing.xl, HollowSpacing.lg, HollowSpacing.lg),
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0) const SizedBox(height: HollowSpacing.xl),
                  sections[i],
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(HollowSpacing.md, 0,
                HollowSpacing.md, HollowSpacing.md),
            child: HollowButton.ghost(
              expand: true,
              onPressed: () => showProfileDialog(context, peerId: peerId),
              child: const Text('View full profile'),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [HollowSectionHeader(title, dense: true), child],
      );
}

/// The person's banner, or a flat tone of their colour when they have none.
class _Banner extends ConsumerWidget {
  final String peerId;
  final double height;

  const _Banner({required this.peerId, required this.height});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = watchAnimatedBanner(ref, peerId) ??
        ref.watch(bannerProvider(peerId)).valueOrNull;
    final hsl = HSLColor.fromColor(colorFromId(peerId));
    final flat = ColoredBox(
      color: hsl.withSaturation(0.35).withLightness(0.28).toColor(),
    );
    if (bytes == null || bytes.isEmpty) return flat;
    return AnimatedGifImage(
      bytes: bytes,
      height: height,
      width: double.infinity,
      fit: BoxFit.cover,
      errorWidget: flat,
    );
  }
}

class _RingedAvatar extends ConsumerWidget {
  final String peerId;

  const _RingedAvatar({required this.peerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final online = identityIsOnline(ref, peerId);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          padding: const EdgeInsets.all(_kAvatarRing),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
          ),
          child: HollowAvatar(peerId: peerId, size: _kAvatarSize, animate: true),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.all(_kAvatarRing - 1),
            decoration:
                BoxDecoration(color: hollow.surface, shape: BoxShape.circle),
            child: StatusDot(
              color: online ? hollow.success : hollow.textSecondary,
              size: HollowSpacing.md,
              filled: online,
              semanticLabel: online ? 'Online' : 'Offline',
            ),
          ),
        ),
      ],
    );
  }
}

/// Nickname, mute and the More menu. Block and Report live in the menu.
class _Actions extends ConsumerWidget {
  final String peerId;
  final String master;

  const _Actions({required this.peerId, required this.master});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localNick = ref.watch(localNicknameProvider)[peerId];
    final notifying = ref.watch(notificationSettingsProvider
        .select((s) => s.dmEnabled[peerId] ?? true));
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HollowIconButton(
          icon: LucideIcons.tag,
          label: (localNick?.isNotEmpty ?? false)
              ? 'Edit nickname'
              : 'Set nickname',
          onPressed: () => showLocalNicknameDialog(context, ref, peerId,
              currentNickname: localNick ?? ''),
        ),
        const SizedBox(width: HollowSpacing.xs),
        HollowIconButton(
          icon: notifying ? LucideIcons.bell : LucideIcons.bellOff,
          label: notifying ? 'Mute notifications' : 'Unmute notifications',
          selected: !notifying,
          onPressed: () => ref
              .read(notificationSettingsProvider.notifier)
              .setDmEnabled(peerId, !notifying),
        ),
        const SizedBox(width: HollowSpacing.xs),
        Builder(
          builder: (buttonContext) => HollowIconButton(
            icon: LucideIcons.moreHorizontal,
            label: 'More',
            onPressed: () => _openMenu(buttonContext, ref),
          ),
        ),
      ],
    );
  }

  void _openMenu(BuildContext buttonContext, WidgetRef ref) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final profile = ref.read(profileProvider)[peerId];
    final name = displayNameForPeer(profile, peerId);
    final isFriend = ref.read(friendsProvider)[peerId]?.status == 'accepted';
    final isBlocked = ref.read(blockedUsersProvider).contains(master);
    showHollowMenu(
      context: buttonContext,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(box.size.width, box.size.height)),
      alignEnd: true,
      builder: (menuContext, _) => [
        HollowMenuItem(
          icon: LucideIcons.copy,
          label: 'Copy user ID',
          onTap: () async {
            await Clipboard.setData(ClipboardData(text: master));
            if (buttonContext.mounted) {
              HollowToast.show(buttonContext, 'User ID copied',
                  type: HollowToastType.success);
            }
          },
        ),
        if (isFriend)
          HollowMenuItem(
            icon: LucideIcons.userMinus,
            label: 'Remove friend',
            onTap: () async {
              final yes = await showHollowConfirm(
                context: buttonContext,
                title: 'Remove $name as a friend?',
                message: 'Your messages stay. You can add each other again.',
                confirmLabel: 'Remove',
                destructive: true,
              );
              if (yes && buttonContext.mounted) {
                await removeFriendAndTidy(buttonContext, ref, peerId);
              }
            },
          ),
        const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.ban,
          label: isBlocked ? 'Unblock' : 'Block',
          isDanger: !isBlocked,
          onTap: isBlocked
              ? () => unblockUser(buttonContext, masterId: master)
              : () => confirmAndBlockUser(buttonContext,
                  masterId: master, displayName: name),
        ),
        HollowMenuItem(
          icon: LucideIcons.flag,
          label: 'Report',
          isDanger: true,
          onTap: () => showReportUserDialog(buttonContext,
              masterId: master, displayName: name),
        ),
      ],
    );
  }
}

/// Encrypted is a given; whether you have checked it is the one thing to do.
class _Verification extends ConsumerWidget {
  final String master;

  const _Verification(this.master);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final verified = ref.watch(isPeerVerifiedProvider(master));
    void open() => showVerifyContactDialog(context, peerId: master);
    return Row(
      children: [
        Icon(
          verified ? LucideIcons.shieldCheck : LucideIcons.shield,
          size: 20,
          color: verified ? hollow.success : hollow.textSecondary,
        ),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                verified ? 'Verified' : 'Not verified yet',
                style: HollowTypography.label.copyWith(
                    color: verified ? hollow.success : hollow.textPrimary),
              ),
              Text(
                'End-to-end encrypted',
                style: HollowTypography.caption
                    .copyWith(color: hollow.textTertiary),
              ),
            ],
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        verified
            ? HollowButton.ghost(
                compact: true,
                onPressed: open,
                child: const Text('View'),
              )
            : HollowButton.outline(
                compact: true,
                onPressed: open,
                child: const Text('Verify'),
              ),
      ],
    );
  }
}

class _TwitchBadge extends StatelessWidget { // design-ignore: Twitch brand mark, drawn only from a verified credential
  final String login;

  const _TwitchBadge({required this.login});

  @override
  Widget build(BuildContext context) { // design-ignore: Twitch's brand purple, rendered only from a verified credential
    const purple = Color(0xFF9146FF); // design-ignore: Twitch brand colour
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      onTap: () => launchUrl(
        Uri.parse('https://twitch.tv/$login'),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm,
          vertical: HollowSpacing.xxs,
        ),
        decoration: BoxDecoration(
          color: purple.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(hollow.radiusXs),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(BrandIcons.twitch, size: 14, color: purple),
            const SizedBox(width: HollowSpacing.xs),
            Text(
              login,
              style: HollowTypography.caption.copyWith(
                color: purple,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
