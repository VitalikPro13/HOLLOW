import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_chip.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/label_visuals.dart';
import 'package:hollow/src/ui/components/overlay_anchor.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/components/support_glyph.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// How dense a profile renders: the anchored popup, the profile dialog's
/// column, or the phone sheet. All three draw the SAME sections from the same
/// data, so the surfaces cannot drift apart.
enum ProfileCardDensity { compact, full, touch }

/// Width of the profile dialog's identity column; the banner above it is
/// 2.5:1, so 160 tall.
const double kProfileColumnWidth = 400.0;

/// Width of the compact anchored card.
const double kProfileCompactWidth = 300.0;

/// Who someone is, and what you can do with them: banner, avatar, name,
/// status, badges, About, then one primary action and grey icons.
///
/// The HOST owns the frame and passes [dismissHost], so an action that opens
/// another surface closes this one first. [showActions] false leaves the
/// action row out, for a host that owns its own (the showcase editor).
class ProfileIdentityColumn extends ConsumerStatefulWidget {
  final String peerId;
  final ProfileCardDensity density;

  /// The column's width, which sets the banner's height at 2.5:1.
  final double width;
  final VoidCallback dismissHost;
  final String? nickname;
  final String? role;
  final List<crdt_api.LabelFfi>? labels;

  /// Server context: enables Manage member when the local user may use it.
  final String? serverId;

  /// A close button over the banner, for a host with nothing else to close it.
  final VoidCallback? onClose;

  /// An expand button over the banner (the compact card).
  final VoidCallback? onExpand;

  /// Overrides for hosts that navigate differently (the phone pushes routes).
  final VoidCallback? onMessage;
  final VoidCallback? onEditProfile;
  final VoidCallback? onEditShowcase;
  final bool showActions;

  const ProfileIdentityColumn({
    super.key,
    required this.peerId,
    required this.density,
    required this.width,
    required this.dismissHost,
    this.nickname,
    this.role,
    this.labels,
    this.serverId,
    this.onClose,
    this.onExpand,
    this.onMessage,
    this.onEditProfile,
    this.onEditShowcase,
    this.showActions = true,
  });

  @override
  ConsumerState<ProfileIdentityColumn> createState() =>
      _ProfileIdentityColumnState();
}

class _ProfileIdentityColumnState extends ConsumerState<ProfileIdentityColumn> {
  bool get _compact => widget.density == ProfileCardDensity.compact;
  bool get _touch => widget.density == ProfileCardDensity.touch;

  double get _avatarSize => switch (widget.density) {
    ProfileCardDensity.compact => 64,
    ProfileCardDensity.full => 96,
    ProfileCardDensity.touch => 80,
  };

  /// How far the avatar reaches up into the banner.
  double get _avatarOverlap => switch (widget.density) {
    ProfileCardDensity.compact => 32,
    ProfileCardDensity.full => 48,
    ProfileCardDensity.touch => 40,
  };

  double get _ring => _compact ? 3 : 4;

  double get _hPad => widget.density == ProfileCardDensity.full
      ? HollowSpacing.xl
      : HollowSpacing.lg;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final peerId = widget.peerId;
    final profile = ref.watch(profileProvider.select((p) => p[peerId]));
    final isMe = peerId == ref.watch(identityProvider).peerId;
    final isOnline = isMe || identityIsOnline(ref, peerId);
    final master = ref.watch(deviceLinkProvider).identityOf(peerId);
    final isFriend =
        !isMe && ref.watch(friendsProvider)[master]?.status == 'accepted';
    final isVerified = !isMe && ref.watch(isPeerVerifiedProvider(master));
    final localNick = ref.watch(localNicknameProvider)[peerId];

    final displayName = profile?.displayName ?? '';
    final shownName = displayName.isNotEmpty
        ? displayName
        : (peerId.length > 8 ? '${peerId.substring(0, 8)}...' : peerId);
    // Local nickname, then server nickname, then the profile's own name.
    final override = localNick ?? widget.nickname;
    final hasOverride = override != null && override.isNotEmpty;
    final primaryName = hasOverride ? override : shownName;
    final status = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';

    final bannerHeight = widget.width / 2.5;
    // Over a flat surface a control needs no scrim: it would read as a hole.
    final onArt = _bannerBytes(ref, peerId) != null;
    Widget overBanner(IconData icon, String label, double size,
            VoidCallback onPressed) =>
        onArt
            ? MediaScrimIconButton(
                icon: icon, label: label, size: size, onPressed: onPressed)
            : HollowIconButton(
                icon: icon, label: label, size: size, onPressed: onPressed);
    final avatarBox = _avatarSize + _ring * 2;
    final badges = _badges();
    final hasBoard =
        _compact && !ShowcaseBoard.decode(profile?.showcaseBoard).isEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            _Banner(peerId: peerId, width: widget.width, height: bannerHeight),
            if (widget.onClose != null)
              Positioned(
                top: HollowSpacing.md,
                right: HollowSpacing.md,
                child: overBanner(LucideIcons.x, 'Close', _touch ? 44 : 32,
                    widget.onClose!),
              ),
            if (widget.onExpand != null)
              Positioned(
                top: HollowSpacing.sm,
                right: HollowSpacing.sm,
                child: overBanner(LucideIcons.maximize2, 'View full profile',
                    32, widget.onExpand!),
              ),
            Positioned(
              left: _hPad,
              bottom: -(avatarBox - _avatarOverlap),
              child: Container(
                decoration: BoxDecoration(
                  color: hollow.overlay,
                  borderRadius: BorderRadius.circular(hollow.radiusMd + _ring),
                  border: Border.all(color: hollow.overlay, width: _ring),
                ),
                child: HollowAvatar(
                  peerId: peerId,
                  size: _avatarSize,
                  animate: true,
                  semanticLabel: primaryName,
                ),
              ),
            ),
          ],
        ),
        // The corner beside the avatar holds the credential marks, level
        // with the avatar's foot.
        SizedBox(
          height: avatarBox - _avatarOverlap,
          child: Padding(
            padding: EdgeInsets.only(right: _hPad, bottom: HollowSpacing.xs),
            child: Align(
              alignment: Alignment.bottomRight,
              child: _cornerMarks(),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            _hPad,
            HollowSpacing.md,
            _hPad,
            _compact ? HollowSpacing.lg : _hPad,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                primaryName,
                style:
                    (_compact
                            ? HollowTypography.subheading
                            : HollowTypography.heading)
                        .copyWith(color: hollow.textPrimary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (hasOverride)
                Text(
                  shownName,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: HollowSpacing.xs),
              _statusLine(
                hollow,
                isOnline: isOnline,
                isFriend: isFriend,
                isVerified: isVerified,
              ),
              if (status.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  status,
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textSecondary,
                  ),
                  maxLines: _compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (badges.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.md),
                Wrap(
                  spacing: HollowSpacing.xs,
                  runSpacing: HollowSpacing.xs,
                  children: badges,
                ),
              ],
              // On a phone the actions sit right under who this is, above
              // About and the showcase, so they never scroll away.
              if (widget.showActions && _touch) ...[
                const SizedBox(height: HollowSpacing.lg),
                _actions(
                  hollow,
                  master,
                  localNick,
                  isMe: isMe,
                  isFriend: isFriend,
                  isVerified: isVerified,
                ),
              ],
              if (aboutMe.isNotEmpty) ...[
                Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: _compact ? HollowSpacing.lg : HollowSpacing.xl,
                  ),
                  child: const HollowDivider(),
                ),
                const HollowSectionHeader('About me', dense: true),
                Text(
                  aboutMe,
                  style:
                      (_compact
                              ? HollowTypography.bodySmall
                              : HollowTypography.body)
                          .copyWith(color: hollow.textSecondary),
                  maxLines: _compact ? 4 : null,
                  overflow: _compact ? TextOverflow.ellipsis : null,
                ),
              ],
              // The compact card has no room for the boards; it says there
              // is one and opens the full profile to show it.
              if (_compact && widget.onExpand != null && hasBoard) ...[
                const SizedBox(height: HollowSpacing.md),
                HollowButton.ghost(
                  onPressed: widget.onExpand,
                  compact: true,
                  icon: const Icon(LucideIcons.layoutGrid),
                  child: const Text('View showcase'),
                ),
              ],
              if (widget.showActions && !_touch) ...[
                SizedBox(
                  height: _compact ? HollowSpacing.md : HollowSpacing.xl,
                ),
                _actions(
                  hollow,
                  master,
                  localNick,
                  isMe: isMe,
                  isFriend: isFriend,
                  isVerified: isVerified,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusLine(
    HollowTheme hollow, {
    required bool isOnline,
    required bool isFriend,
    required bool isVerified,
  }) {
    final style = HollowTypography.bodySmall.copyWith(
      color: hollow.textSecondary,
    );
    final dot = Text(
      ' · ',
      style: HollowTypography.bodySmall.copyWith(color: hollow.textTertiary),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        StatusDot(
          color: isOnline ? hollow.success : hollow.textSecondary,
          size: 8,
          filled: isOnline,
        ),
        const SizedBox(width: HollowSpacing.xs),
        Text(isOnline ? 'Online' : 'Offline', style: style),
        if (isFriend) ...[dot, Text('Friend', style: style)],
        // Only for a contact whose safety number was confirmed out of band.
        if (isVerified) ...[
          dot,
          Icon(LucideIcons.shieldCheck, size: 14, color: hollow.success),
          const SizedBox(width: HollowSpacing.xxs),
          Text('Verified', style: style),
        ],
      ],
    );
  }

  /// Role first, then labels: facts, so badges.
  List<Widget> _badges() {
    final hollow = HollowTheme.of(context);
    final role = widget.role;
    return [
      if (role != null && role.isNotEmpty)
        HollowBadge(
          roleDisplayName(role),
          leading: _ColorDot(color: profileRoleColor(role, hollow)),
        ),
      for (final label in widget.labels ?? const <crdt_api.LabelFfi>[])
        LabelBadge(label: label),
    ];
  }

  /// Support marks, and the verified Twitch account as a chip that opens it.
  ///
  /// Drawn ONLY from a verified account credential: the `twitch_username`
  /// profile field is a self-declaration any modified client can write.
  Widget? _cornerMarks() {
    final marks = ref.watch(supportMarksProvider(widget.peerId));
    final twitch = ref.watch(twitchLoginProvider(widget.peerId));
    final items = <Widget>[
      if (marks.isNotEmpty)
        SupportMarksChip(peerId: widget.peerId),
      if (twitch != null && twitch.isNotEmpty)
        HollowChip(
          label: twitch,
          semanticLabel: 'Open $twitch on Twitch',
          leading: const Icon(
            BrandIcons.twitch,
            size: 14,
            color: BrandIconColors.twitch,
          ),
          onTap: () => launchUrl(
            Uri.parse('https://twitch.tv/$twitch'),
            mode: LaunchMode.externalApplication,
          ),
        ),
    ];
    if (items.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(width: HollowSpacing.xs),
          items[i],
        ],
      ],
    );
  }

  Widget _actions(
    HollowTheme hollow,
    String master,
    String? localNick, {
    required bool isMe,
    required bool isFriend,
    required bool isVerified,
  }) {
    final compact = _compact;
    if (isMe) {
      return Row(
        children: [
          Expanded(
            child: HollowButton.filled(
              onPressed: widget.onEditProfile ?? _openUserSettings,
              compact: compact,
              touch: _touch,
              expand: true,
              icon: const Icon(LucideIcons.pencil),
              child: const Text('Edit profile'),
            ),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.ghost(
            onPressed:
                widget.onEditShowcase ??
                () => showShowcaseEditorDialog(context, ref),
            compact: compact,
            touch: _touch,
            icon: const Icon(LucideIcons.layoutGrid),
            child: const Text('Edit showcase'),
          ),
        ],
      );
    }

    // Already in their DM on a phone: Message would open a second copy of
    // the chat under this sheet.
    final inTheirDm =
        _touch && ref.watch(selectedPeerProvider) == widget.peerId;
    final Widget? primary = isFriend
        ? (inTheirDm
              ? null
              : HollowButton.filled(
                  onPressed: widget.onMessage ?? () => _openDm(master),
                  compact: compact,
                  touch: _touch,
                  expand: true,
                  icon: const Icon(LucideIcons.messageCircle),
                  child: const Text('Message'),
                ))
        : ProfileFriendAction(
            peerId: widget.peerId,
            compact: compact,
            touch: _touch,
          );
    final iconSize = _touch ? 44.0 : 32.0;
    return Row(
      children: [
        if (primary != null) ...[
          Expanded(child: primary),
          const SizedBox(width: HollowSpacing.sm),
        ] else
          const Spacer(),
        HollowIconButton(
          icon: LucideIcons.tag,
          label: localNick != null ? 'Edit nickname' : 'Set a nickname',
          size: iconSize,
          onPressed: _openNicknameDialog,
        ),
        if (!_touch && _canManageMember()) ...[
          const SizedBox(width: HollowSpacing.xs),
          HollowIconButton(
            icon: LucideIcons.shield,
            label: 'Manage member',
            size: iconSize,
            onPressed: () => _closeThen(
              (nav) => showManageMemberDialog(
                nav,
                serverId: widget.serverId!,
                peerId: master,
              ),
            ),
          ),
        ],
        const SizedBox(width: HollowSpacing.xs),
        Builder(
          builder: (buttonContext) => HollowIconButton(
            icon: LucideIcons.moreHorizontal,
            label: 'More',
            size: iconSize,
            onPressed: () => _touch
                ? _openMoreSheet(master, isVerified: isVerified)
                : _openMoreMenu(buttonContext, master, isVerified: isVerified),
          ),
        ),
      ],
    );
  }

  String get _name => displayNameForPeer(
    ref.read(profileProvider)[widget.peerId],
    widget.peerId,
  );

  /// Everything that can go wrong sits behind More, Block and Report last.
  void _openMoreMenu(
    BuildContext buttonContext,
    String master, {
    required bool isVerified,
  }) {
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null) return;
    final isBlocked = ref.read(blockedUsersProvider).contains(master);
    showHollowMenu(
      context: buttonContext,
      anchor: overlayAnchorOf(
        buttonContext,
        localOffset: Offset(box.size.width, box.size.height),
      ),
      alignEnd: true,
      builder: (_, _) => [
        HollowMenuItem(
          icon: isVerified ? LucideIcons.shieldCheck : LucideIcons.fingerprint,
          label: isVerified ? 'View safety number' : 'Verify contact',
          onTap: () =>
              _closeThen((nav) => showVerifyContactDialog(nav, peerId: master)),
        ),
        HollowMenuItem(
          icon: LucideIcons.copy,
          label: 'Copy user ID',
          onTap: () => _copyUserId(master),
        ),
        const HollowMenuDivider(),
        ..._dangerItems(master, isBlocked),
      ],
    );
  }

  List<HollowMenuItem> _dangerItems(String master, bool isBlocked) => [
    HollowMenuItem(
      icon: LucideIcons.ban,
      label: isBlocked ? 'Unblock' : 'Block',
      isDanger: !isBlocked,
      onTap: isBlocked
          ? () => unblockUser(context, masterId: master)
          : () => _closeThen(
              (nav) => confirmAndBlockUser(
                nav,
                masterId: master,
                displayName: _name,
              ),
            ),
    ),
    HollowMenuItem(
      icon: LucideIcons.flag,
      label: 'Report',
      isDanger: true,
      onTap: () => _closeThen(
        (nav) =>
            showReportUserDialog(nav, masterId: master, displayName: _name),
      ),
    ),
  ];

  /// The phone's More: a sheet over the profile, Block and Report last.
  void _openMoreSheet(String master, {required bool isVerified}) {
    final isBlocked = ref.read(blockedUsersProvider).contains(master);
    final canManage = _canManageMember();
    final name = _name;
    showHollowSheet(
      context: context,
      builder: (sheetContext) {
        void run(VoidCallback action) {
          Navigator.of(sheetContext).pop();
          action();
        }

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HollowSheetTitle(name),
              if (canManage)
                _SheetRow(
                  icon: LucideIcons.shield,
                  label: 'Manage member',
                  onTap: () => run(
                    () => _closeThen(
                      (nav) => showManageMemberDialog(
                        nav,
                        serverId: widget.serverId!,
                        peerId: master,
                      ),
                    ),
                  ),
                ),
              _SheetRow(
                icon: isVerified
                    ? LucideIcons.shieldCheck
                    : LucideIcons.fingerprint,
                label: isVerified ? 'View safety number' : 'Verify contact',
                onTap: () => run(
                  () => _closeThen(
                    (nav) => showVerifyContactDialog(nav, peerId: master),
                  ),
                ),
              ),
              _SheetRow(
                icon: LucideIcons.copy,
                label: 'Copy user ID',
                onTap: () => run(() => _copyUserId(master)),
              ),
              const HollowDivider(),
              _SheetRow(
                icon: LucideIcons.ban,
                label: isBlocked ? 'Unblock' : 'Block',
                danger: !isBlocked,
                onTap: () => run(
                  isBlocked
                      ? () => unblockUser(context, masterId: master)
                      : () => _closeThen(
                          (nav) => confirmAndBlockUser(
                            nav,
                            masterId: master,
                            displayName: name,
                          ),
                        ),
                ),
              ),
              _SheetRow(
                icon: LucideIcons.flag,
                label: 'Report',
                danger: true,
                onTap: () => run(
                  () => _closeThen(
                    (nav) => showReportUserDialog(
                      nav,
                      masterId: master,
                      displayName: name,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: HollowSpacing.sm),
            ],
          ),
        );
      },
    );
  }

  Future<void> _copyUserId(String master) async {
    await Clipboard.setData(ClipboardData(text: master));
    if (mounted) {
      HollowToast.show(
        context,
        'User ID copied',
        type: HollowToastType.success,
      );
    }
  }

  /// Closes the host, then opens [open] from the root navigator: the host's
  /// own context is gone once it closes, and a dialog stacked under a popup
  /// would be hidden by it.
  void _closeThen(void Function(BuildContext nav) open) {
    final nav = Navigator.of(context, rootNavigator: true).context;
    widget.dismissHost();
    open(nav);
  }

  void _openUserSettings() {
    widget.dismissHost();
    openSettings(ref.read, category: SettingsCategory.profile);
  }

  void _openNicknameDialog() {
    final localNick = ref.read(localNicknameProvider)[widget.peerId];
    final peerId = widget.peerId;
    // The phone keeps the sheet; the dialog prompt sits over it.
    if (_touch) {
      showLocalNicknameDialog(
        context,
        ref,
        peerId,
        currentNickname: localNick ?? '',
      );
      return;
    }
    _closeThen(
      (nav) => showLocalNicknameDialog(
        nav,
        ref,
        peerId,
        currentNickname: localNick ?? '',
      ),
    );
  }

  /// The provider writes run BEFORE dismissing, which disposes this widget and
  /// its ref when hosted in the raw-OverlayEntry popup.
  void _openDm(String masterId) {
    openDmConversation(ref, masterId);
    widget.dismissHost();
  }

  /// Whether the local user holds ANY member-management capability here.
  /// Advisory only: the dialog and Rust's `op_allowed` re-check per section.
  bool _canManageMember() {
    final serverId = widget.serverId;
    if (serverId == null) return false;
    final myRole = ref.watch(myRoleProvider(serverId)).valueOrNull ?? 'member';
    final perms = ref.watch(myPermissionsProvider(serverId)).valueOrNull ?? 0;
    final targetRole = widget.role ?? 'member';
    return (canManageRole(myRole, targetRole) &&
            assignableRoles(myRole).isNotEmpty) ||
        (perms & Permission.manageRoles) != 0 ||
        (perms & Permission.manageChannels) != 0;
  }
}

/// A role's colour as a dot inside a badge's 14 px glyph box.
class _ColorDot extends StatelessWidget {
  final Color color;

  const _ColorDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 14,
      child: Center(
        child: Container(
          width: HollowSpacing.sm,
          height: HollowSpacing.sm,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
    );
  }
}

/// An icon button over art (a banner, a wide artwork).
class MediaScrimIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final double size;
  final VoidCallback onPressed;

  const MediaScrimIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.size,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => HollowIconButton(
        icon: icon,
        label: label,
        size: size,
        onMedia: true,
        onPressed: onPressed,
      );
}

/// One row of the phone's More sheet; [danger] tints it for Block and Report.
class _SheetRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;

  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = danger ? hollow.error : hollow.textPrimary;
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      semanticLabel: label,
      padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: danger ? hollow.error : hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Text(
                label,
                style: HollowTypography.bodyTouch.copyWith(
                  color: color,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The banner at a true 2.5:1 for [width], or a flat surface without one.
/// The animated variant off the asset rail when we hold it, else the still
/// from the profile blob; null when there is no banner to show.
Uint8List? _bannerBytes(WidgetRef ref, String peerId) {
  final bytes = watchAnimatedBanner(ref, peerId) ??
      ref.watch(bannerProvider(peerId)).valueOrNull;
  return bytes == null || bytes.isEmpty ? null : bytes;
}

class _Banner extends ConsumerWidget {
  final String peerId;
  final double width;
  final double height;

  const _Banner({
    required this.peerId,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final flat = Container(
      width: width,
      height: height,
      color: hollow.elevated,
    );
    final bytes = _bannerBytes(ref, peerId);
    if (bytes == null) return flat;
    return SizedBox(
      width: width,
      height: height,
      child: AnimatedGifImage(
        bytes: bytes,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorWidget: flat,
      ),
    );
  }
}
