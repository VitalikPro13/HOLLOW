import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart'
    show profileRoleColor, showLocalNicknameDialog;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

Color bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360;
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

void showMobileProfileSheet(
  BuildContext context, {
  required String peerId,
  String? role,
  List<crdt_api.LabelFfi>? labels,
}) {
  showHollowSheet(
    context: context,
    scrollControlled: true,
    // Room above the sheet to tap it closed.
    maxHeightFactor: 0.9,
    builder: (_) => MobileProfileSheet(
      peerId: peerId,
      role: role,
      labels: labels,
    ),
  );
}

class MobileProfileSheet extends ConsumerWidget {
  final String peerId;
  final String? role;
  final List<crdt_api.LabelFfi>? labels;

  const MobileProfileSheet({
    super.key,
    required this.peerId,
    this.role,
    this.labels,
  });

  void _openChat(BuildContext context, WidgetRef ref) {
    final nav = Navigator.of(context, rootNavigator: true);
    final container = ProviderScope.containerOf(context, listen: false);
    Navigator.of(context).pop();
    ref.read(selectedPeerProvider.notifier).state = peerId;
    nav
        .push(
      hollowMobileRoute(
        settings: const RouteSettings(name: MobileChatRoute.routeName),
        builder: (_) => MobileChatRoute(peerId: peerId),
      ),
    )
        .then((_) {
      // The sheet is gone by now, so this uses the captured container rather
      // than `ref`.
      if (container.read(selectedPeerProvider) == peerId) {
        container.read(selectedPeerProvider.notifier).state = null;
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final profiles = ref.watch(profileProvider);
    final profile = profiles[peerId];
    final localNicknames = ref.watch(localNicknameProvider);
    final localNick = localNicknames[peerId];
    final name = localNick ?? displayNameFor(profiles, peerId);
    // The friend's OWN display name, never folded through the local nickname,
    // or the subtitle under a nickname is a duplicate of it.
    final profileName = (profile != null && profile.displayName.isNotEmpty)
        ? profile.displayName
        : (peerId.length > 8 ? '${peerId.substring(0, 8)}...' : peerId);
    final isOnline = identityIsOnline(ref, peerId);
    final bannerBytes = watchAnimatedBanner(ref, peerId) ??
        ref.watch(bannerProvider(peerId)).valueOrNull;
    final bannerColor = bannerColorFromId(peerId);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';
    final isMe = peerId == myPeerId;
    final friends = ref.watch(friendsProvider);
    final friendInfo = friends[peerId];
    // The verified credential or nothing: the profile's own `twitch_username`
    // is only a self-declaration.
    final verifiedTwitch = ref.watch(twitchLoginProvider(peerId));
    final board = ShowcaseBoard.decode(profile?.showcaseBoard);

    // The drag handle stays OUTSIDE the scrollable, or a long showcase leaves
    // no way to dismiss it: the inner scroll eats the drag gesture.
    return SafeArea(
      child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
      child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The height TRACKS the sheet's width at 2.5:1, the ratio every user
        // banner surface shares. Only the HEIGHT is a target, so an older 3:1
        // banner still decodes at its own aspect instead of being squashed
        // before BoxFit.cover sees it.
        LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
            final height = width / 2.5;
            final fallback = Container(height: height, color: bannerColor);
            return SizedBox(
              height: height,
              width: double.infinity,
              child: bannerBytes != null && bannerBytes.isNotEmpty
                  ? AnimatedGifImage(
                      bytes: bannerBytes,
                      height: height,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorWidget: fallback,
                    )
                  : fallback,
            );
          },
        ),

        Transform.translate(
          offset: const Offset(0, -36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border: Border.all(color: hollow.overlay, width: 3),
                ),
                child: HollowAvatar(peerId: peerId, size: 72, semanticLabel: name),
              ),
              const SizedBox(height: HollowSpacing.sm),

              if (localNick != null) ...[
                Text(localNick, style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary,
                )),
                Text(profileName, style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                )),
              ] else
                Text(name, style: HollowTypography.heading.copyWith(
                  color: hollow.textPrimary,
                )),

              const SizedBox(height: HollowSpacing.xs),

              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  StatusDot(
                    color: isOnline ? hollow.success : hollow.textSecondary,
                    size: 8, 
                    filled: isOnline,
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  Text(
                    isOnline ? 'Online' : 'Offline',
                    style: HollowTypography.body.copyWith(
                      color: isOnline ? hollow.success : hollow.textSecondary,
                    ),
                  ),
                ],
              ),

              // Every role shows, Member included.
              if (role != null && role!.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.sm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.md,
                    vertical: HollowSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: profileRoleColor(role!, hollow).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(hollow.radiusXs),
                  ),
                  child: Text(
                    roleDisplayName(role!),
                    style: HollowTypography.bodySmall.copyWith(
                      color: profileRoleColor(role!, hollow),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],

              if (labels != null && labels!.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Wrap(
                    spacing: HollowSpacing.xs,
                    runSpacing: HollowSpacing.xs,
                    alignment: WrapAlignment.center,
                    children: labels!.map((label) {
                      final color = _parseLabelColor(label.color);
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: HollowSpacing.sm,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(hollow.radiusXs),
                          border: Border.all(color: color.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          label.name,
                          style: HollowTypography.caption.copyWith(
                            color: color,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],

              if (verifiedTwitch != null) ...[
                const SizedBox(height: HollowSpacing.sm),
                HollowPressable(
                  onTap: () => launchUrl(
                    Uri.parse('https://twitch.tv/$verifiedTwitch'),
                    mode: LaunchMode.externalApplication,
                  ),
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(BrandIcons.twitch, size: 14, color: Color(0xFF9146FF)), // design-ignore: Twitch brand colour
                      const SizedBox(width: HollowSpacing.xs),
                      Text(
                        verifiedTwitch,
                        style: HollowTypography.bodySmall.copyWith(
                          color: const Color(0xFF9146FF), // design-ignore: Twitch brand colour
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              if (profile?.status != null && profile!.status.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.sm),
                Text(
                  profile.status,
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],

              if (profile?.aboutMe != null && profile!.aboutMe.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Text(
                    profile.aboutMe,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textSecondary,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],

              // Stacked on mobile, left side first.
              if (!board.isEmpty) ...[
                const SizedBox(height: HollowSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (board.hasLeft)
                        ShowcaseBoardColumn(peerId: peerId, blocks: board.left),
                      if (board.hasLeft && board.hasRight)
                        const SizedBox(height: HollowSpacing.sm),
                      if (board.hasRight)
                        ShowcaseBoardColumn(peerId: peerId, blocks: board.right),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: HollowSpacing.lg),

              if (isMe) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: HollowButton.outline(
                    onPressed: () => showShowcaseEditorDialog(context, ref),
                    icon: const Icon(LucideIcons.layoutGrid, size: 16),
                    expand: true,
                    child: const Text('Edit showcase'),
                  ),
                ),
                const SizedBox(height: HollowSpacing.sm),
              ],

              if (!isMe) ...[
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: HollowSpacing.xl),
                  child: Column(
                    children: [
                      // Already in their DM: Message would open a second copy
                      // of the chat underneath this sheet.
                      if (friendInfo?.status == 'accepted' &&
                          ref.watch(selectedPeerProvider) != peerId)
                        Padding(
                          padding:
                              const EdgeInsets.only(bottom: HollowSpacing.sm),
                          child: HollowButton.filled(
                            onPressed: () => _openChat(context, ref),
                            icon: const Icon(LucideIcons.messageCircle),
                            expand: true,
                            child: const Text('Message'),
                          ),
                        ),
                      _FriendActionRow(peerId: peerId),
                      const SizedBox(height: HollowSpacing.sm),
                      _ProfileActionStrip(
                        peerId: peerId,
                        name: name,
                        hasNickname: localNick != null,
                        onNickname: () => _showNicknameDialog(context, ref),
                        onVerify: (master) => _openVerify(context, master),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: HollowSpacing.md),
            ],
          ),
        ),
      ],
    ),
              ),
            ),
          ],
        ),
    );
  }

  /// Pops this sheet before pushing the verify screen, or it stays mounted
  /// underneath and reappears on the way back. The root navigator is captured
  /// first, because popping invalidates this context.
  void _openVerify(BuildContext context, String masterId) {
    final navContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();
    showVerifyContactDialog(navContext, peerId: masterId);
  }

  void _showNicknameDialog(BuildContext context, WidgetRef ref) {
    showLocalNicknameDialog(context, ref, peerId,
        currentNickname: ref.read(localNicknameProvider)[peerId] ?? '');
  }
}

Color _parseLabelColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length == 6) {
    return Color(int.parse('FF$cleaned', radix: 16));
  }
  if (cleaned.length == 8) {
    return Color(int.parse(cleaned, radix: 16));
  }
  return const Color(0xFF78909C);
}

class _FriendActionRow extends ConsumerStatefulWidget {
  final String peerId;

  const _FriendActionRow({required this.peerId});

  @override
  ConsumerState<_FriendActionRow> createState() => _FriendActionRowState();
}

class _FriendActionRowState extends ConsumerState<_FriendActionRow> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action,
      {required String done, required String failed}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(context, friendlyError(e, fallback: failed),
            type: HollowToastType.error);
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    HollowToast.show(context, done, type: HollowToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    final peerId = widget.peerId;
    final friends = ref.watch(friendsProvider);
    final friendInfo = friends[peerId];
    final notifier = ref.read(friendsProvider.notifier);

    // A `declined` row is a sticky reject tombstone, neither pending nor
    // accepted, so it reads as no row at all and the person can be re-added.
    if (friendInfo == null ||
        (friendInfo.status != 'pending' && friendInfo.status != 'accepted')) {
      return HollowButton.ghost(
        onPressed: () => _run(() => notifier.sendRequest(peerId),
            done: 'Friend request sent',
            failed: "Couldn't send the request. Try again."),
        loading: _busy,
        icon: const Icon(LucideIcons.userPlus, size: 16),
        expand: true,
        child: const Text('Add friend'),
      );
    }

    if (friendInfo.status == 'pending' && friendInfo.direction == 'incoming') {
      return HollowButton.filled(
        onPressed: () => _run(() => notifier.acceptRequest(peerId),
            done: 'Friend request accepted',
            failed: "Couldn't accept the request. Try again."),
        loading: _busy,
        icon: const Icon(LucideIcons.check, size: 16),
        expand: true,
        child: const Text('Accept request'),
      );
    }

    if (friendInfo.status == 'pending') {
      return const HollowButton.ghost(
        onPressed: null,
        icon: Icon(LucideIcons.clock, size: 16),
        expand: true,
        child: Text('Request sent'),
      );
    }

    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.checkCheck, size: 14, color: hollow.success),
          const SizedBox(width: HollowSpacing.xs),
          Text('Friends', style: HollowTypography.bodySmall.copyWith(
            color: hollow.success,
          )),
        ],
      ),
    );
  }
}

/// Nickname and verification as icons, everything that could go wrong behind
/// More: one row, so the sheet's one primary action stays the obvious one.
class _ProfileActionStrip extends ConsumerWidget {
  final String peerId;
  final String name;
  final bool hasNickname;
  final VoidCallback onNickname;
  final void Function(String master) onVerify;

  const _ProfileActionStrip({
    required this.peerId,
    required this.name,
    required this.hasNickname,
    required this.onNickname,
    required this.onVerify,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Block, report and verification key on the MASTER identity.
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final verified = ref.watch(isPeerVerifiedProvider(master));
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        HollowIconButton(
          icon: LucideIcons.tag,
          label: hasNickname ? 'Edit nickname' : 'Set nickname',
          size: 44,
          onPressed: onNickname,
        ),
        const SizedBox(width: HollowSpacing.sm),
        HollowIconButton(
          icon: verified ? LucideIcons.shieldCheck : LucideIcons.shield,
          label: verified ? 'Verified, view safety number' : 'Verify contact',
          size: 44,
          color: verified ? HollowTheme.of(context).success : null,
          onPressed: () => onVerify(master),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Builder(
          builder: (buttonContext) => HollowIconButton(
            icon: LucideIcons.moreHorizontal,
            label: 'More',
            size: 44,
            onPressed: () => _openMenu(buttonContext, ref, master),
          ),
        ),
      ],
    );
  }

  void _openMenu(BuildContext buttonContext, WidgetRef ref, String master) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final isBlocked = ref.read(blockedUsersProvider).contains(master);
    showHollowMenu(
      context: buttonContext,
      anchor: overlayAnchorOf(buttonContext,
          localOffset: Offset(box.size.width, box.size.height)),
      alignEnd: true,
      builder: (_, _) => [
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
