import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/ui/dialogs/showcase_editor.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/dm_navigation.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/local_nickname_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/verified_peers_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/core/role_hierarchy.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/rust/api/twitch.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/components/status_dot.dart';
import 'package:hollow/src/ui/components/support_glyph.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/dialogs/user_settings_dialog.dart';
import 'package:hollow/src/ui/dialogs/verify_contact_dialog.dart';
import 'package:hollow/src/ui/settings/manage_member_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

/// Rendering density for [ProfileCardBody].
///
/// `compact` is the anchored hover popup (mini card); `full` is the wide
/// profile dialog. Both render the SAME sections from the same data so the
/// two surfaces can never drift apart visually — full is simply roomier.
enum ProfileCardDensity { compact, full }

/// Deterministic banner color from peer ID (shifted hue from avatar).
Color _bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360;
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

/// The shared profile card content: banner + avatar + identity header +
/// merged chip row + about + actions + peer-id footer.
///
/// This is ALWAYS the self-contained center card. Showcase boards are
/// separate flanking panels owned by the profile dialog — never columns
/// inside this card.
///
/// The HOST owns the outer container (popup card / dialog surface) and passes
/// [dismissHost] so buttons that open other dialogs can close it first.
/// [onExpand] (compact only) shows the "View full profile" affordance.
class ProfileCardBody extends ConsumerStatefulWidget {
  final String peerId;
  final String? nickname;
  final String? role;
  final String? twitchUsername;
  final List<crdt_api.LabelFfi>? labels;

  /// Server context (member panel / channel chat). Enables the permission-
  /// gated Manage Member action; null in DM/self contexts.
  final String? serverId;
  final ProfileCardDensity density;
  final VoidCallback dismissHost;
  final VoidCallback? onExpand;

  const ProfileCardBody({
    super.key,
    required this.peerId,
    required this.density,
    required this.dismissHost,
    this.nickname,
    this.role,
    this.twitchUsername,
    this.labels,
    this.serverId,
    this.onExpand,
  });

  @override
  ConsumerState<ProfileCardBody> createState() => _ProfileCardBodyState();
}

class _ProfileCardBodyState extends ConsumerState<ProfileCardBody> {
  String? _resolvedTwitchUsername;

  bool get _compact => widget.density == ProfileCardDensity.compact;

  @override
  void initState() {
    super.initState();
    _resolvedTwitchUsername = widget.twitchUsername;
    if (_resolvedTwitchUsername == null || _resolvedTwitchUsername!.isEmpty) {
      _resolveTwitchUsername();
    }
  }

  Future<void> _resolveTwitchUsername() async {
    try {
      final localPeerId = ref.read(identityProvider).peerId;
      if (widget.peerId == localPeerId) {
        final username = await twitchGetUsername();
        if (mounted && username != null && username.isNotEmpty) {
          setState(() => _resolvedTwitchUsername = username);
          return;
        }
      }
      // Fallback: check profile DB for any peer's Twitch username
      final profiles = ref.read(profileProvider);
      final profile = profiles[widget.peerId];
      if (mounted && profile != null && profile.twitchUsername.isNotEmpty) {
        setState(() => _resolvedTwitchUsername = profile.twitchUsername);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final profile = ref.watch(profileProvider.select((p) => p[widget.peerId]));
    final localPeerId = ref.watch(identityProvider).peerId;
    final isMe = widget.peerId == localPeerId;
    final isOnline = isMe || identityIsOnline(ref, widget.peerId);
    final master = ref.watch(deviceLinkProvider).identityOf(widget.peerId);
    final isFriendAccepted =
        !isMe && ref.watch(friendsProvider)[master]?.status == 'accepted';

    final displayName = profile?.displayName ?? '';
    final status = profile?.status ?? '';
    final aboutMe = profile?.aboutMe ?? '';
    final localNick = ref.watch(localNicknameProvider)[widget.peerId];

    final shownName = displayName.isNotEmpty
        ? displayName
        : (widget.peerId.length > 8
            ? '${widget.peerId.substring(0, 8)}...'
            : widget.peerId);
    // Priority: local nickname → server nickname → profile name.
    final primaryOverride = localNick ?? widget.nickname;
    final hasOverride = primaryOverride != null && primaryOverride.isNotEmpty;
    final primaryName = hasOverride ? primaryOverride : shownName;

    // Density metrics. The full card is deliberately GENEROUS — showcase
    // panels flank it, so it has to carry real presence on a desktop screen.
    // Both banner heights are their host's width / 2.5, which is the ONE
    // ratio every user banner surface, the banner cropper and Rust's
    // 1200x480 storage agree on: 300 (kProfileCardPopupWidth) and 560
    // (kProfileDialogCenterWidth). Change a host width and this moves with it.
    final bannerHeight = _compact ? 120.0 : 224.0;
    final avatarSize = _compact ? 64.0 : 110.0;
    final ringWidth = _compact ? 3.0 : 4.0;
    final avatarOverhang = _compact ? 30.0 : 48.0;
    final hPad = _compact ? HollowSpacing.md : HollowSpacing.lg;
    // The avatar ring must read as a cutout of the HOST surface.
    final ringColor = _compact ? hollow.surface : hollow.elevated;

    final chips = _buildChips(hollow);
    final twitchChip = _twitchChip();
    // The support badge (design 5.6, amended 2026-09-02): ONE chip for every
    // credential the profile carries, worn or not, in the band under the
    // banner before the integration chip. The compact card gets the icon
    // alone so it never runs into the avatar's overhang; the full card
    // spells the artist out.
    final marks = ref.watch(supportMarksProvider(widget.peerId));
    final cornerChips = <Widget>[
      if (marks.isNotEmpty)
        SupportMarksChip(peerId: widget.peerId, compact: _compact),
      if (twitchChip != null) twitchChip,
    ];
    // Compact only needs to know WHETHER a board exists (for the hint);
    // the dialog decodes and renders the actual blocks.
    final hasBoard = _compact &&
        !ShowcaseBoard.decode(profile?.showcaseBoard).isEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Header: banner with the avatar breaking its bottom edge ──
        Stack(
          clipBehavior: Clip.none,
          children: [
            _Banner(
              peerId: widget.peerId,
              height: bannerHeight,
              fallbackColor: _bannerColorFromId(widget.peerId),
            ),
            if (_compact && widget.onExpand != null)
              Positioned(
                top: HollowSpacing.xs + 2,
                right: HollowSpacing.xs + 2,
                child: HollowPressable(
                  onTap: widget.onExpand,
                  semanticLabel: 'View full profile',
                  borderRadius: BorderRadius.circular(13),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      LucideIcons.maximize2,
                      size: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              )
            else if (!_compact)
              // The full dialog's counterpart of the popup's expand arrows:
              // same chip, inward arrows, closes the dialog.
              Positioned(
                top: HollowSpacing.xs + 2,
                right: HollowSpacing.xs + 2,
                child: HollowPressable(
                  onTap: widget.dismissHost,
                  semanticLabel: 'Close profile',
                  borderRadius: BorderRadius.circular(13),
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      LucideIcons.minimize2,
                      size: 13,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: hPad,
              bottom: -avatarOverhang,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius:
                      BorderRadius.circular(hollow.radiusMd + ringWidth),
                  border: Border.all(color: ringColor, width: ringWidth),
                ),
                child: HollowAvatar(
                  peerId: widget.peerId,
                  size: avatarSize,
                  animate: true,
                  semanticLabel: primaryName,
                ),
              ),
            ),
          ],
        ),

        // ── Corner band (both densities): the integration chip alone owns
        // the space right of the avatar, directly under the banner. Action
        // buttons live below About Me, never up here.
        SizedBox(
          height: avatarOverhang + (_compact ? 8 : 20),
          child: cornerChips.isEmpty
              ? null
              : Padding(
                  padding: EdgeInsets.only(
                    right: hPad,
                    top: HollowSpacing.xs + 2,
                  ),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < cornerChips.length; i++) ...[
                          if (i > 0) const SizedBox(width: HollowSpacing.xs),
                          cornerChips[i],
                        ],
                      ],
                    ),
                  ),
                ),
        ),

        // ── Identity block: left-aligned name / presence / status ──
        Padding(
          padding: EdgeInsets.symmetric(horizontal: hPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                primaryName,
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: _compact ? 15 : 22,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (hasOverride)
                Text(
                  shownName,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: _compact ? 11 : 12,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: HollowSpacing.xs),
              Row(
                children: [
                  StatusDot(
                    color: isOnline ? hollow.success : hollow.textSecondary,
                    size: _compact ? 7 : 8,
                    filled: isOnline,
                  ),
                  const SizedBox(width: HollowSpacing.xs),
                  Text(
                    isOnline ? 'Online' : 'Offline',
                    style: HollowTypography.caption.copyWith(
                      color:
                          isOnline ? hollow.success : hollow.textSecondary,
                      fontSize: _compact ? 11 : 12,
                    ),
                  ),
                  // Issue 1-D: the badge only ever appears for a contact whose
                  // safety number the user confirmed out of band. Carries an
                  // ICON as well as colour so it is not colour-only.
                  if (!isMe && ref.watch(isPeerVerifiedProvider(widget.peerId))) ...[
                    const SizedBox(width: HollowSpacing.sm),
                    Icon(LucideIcons.shieldCheck,
                        size: _compact ? 11 : 12, color: hollow.success),
                    const SizedBox(width: HollowSpacing.xxs),
                    Text(
                      'Verified',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.success,
                        fontSize: _compact ? 11 : 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  // Friends state lives up here (the action area only shows
                  // a friend BUTTON for the not-yet-friends states).
                  if (isFriendAccepted) ...[
                    const SizedBox(width: HollowSpacing.sm),
                    Icon(LucideIcons.userCheck,
                        size: _compact ? 11 : 12, color: hollow.success),
                    const SizedBox(width: HollowSpacing.xxs),
                    Text(
                      'Friends',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.success,
                        fontSize: _compact ? 11 : 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
              if (status.isNotEmpty) ...[
                const SizedBox(height: HollowSpacing.xs),
                Text(
                  status,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: _compact ? 11 : 12,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: _compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],

              // ── One merged chip row: role + labels ──
              if (chips.isNotEmpty) ...[
                SizedBox(
                    height:
                        _compact ? HollowSpacing.sm : HollowSpacing.sm + 4),
                Wrap(
                  spacing: HollowSpacing.xs,
                  runSpacing: HollowSpacing.xs,
                  children: chips,
                ),
              ],

              SizedBox(
                  height:
                      _compact ? HollowSpacing.sm + 2 : HollowSpacing.md + 2),
              Container(height: 1, color: hollow.border),

              // ── About ──
              ..._aboutSection(hollow, aboutMe),

              // ── Actions (full): below About Me ──
              if (!_compact) ...[
                const SizedBox(height: HollowSpacing.md + 2),
                if (isMe)
                  Wrap(
                    spacing: HollowSpacing.sm,
                    runSpacing: HollowSpacing.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: _buildSelfActions(),
                  )
                else
                  ..._memberActions(hollow, master, localNick,
                      isFriendAccepted: isFriendAccepted),
              ],

              // ── Showcase hint (compact): the mini card stays mini ──
              if (_compact && widget.onExpand != null && hasBoard) ...[
                const SizedBox(height: HollowSpacing.sm),
                Center(
                  child: HollowPressable(
                    onTap: widget.onExpand,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    padding: const EdgeInsets.symmetric(
                      horizontal: HollowSpacing.sm,
                      vertical: HollowSpacing.xxs,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.sparkles,
                            size: 11, color: hollow.accentText),
                        const SizedBox(width: HollowSpacing.xs),
                        Text(
                          'View showcase',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.accentText,
                            fontWeight: FontWeight.w600,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              // ── Actions (compact): one primary + a utility icon strip ──
              if (_compact) ...[
                const SizedBox(height: HollowSpacing.sm),
                if (isMe)
                  HollowButton.outline(
                    onPressed: _openUserSettings,
                    compact: true,
                    expand: true,
                    icon: const Icon(LucideIcons.pencil),
                    child: const Text('Edit Profile'),
                  )
                else
                  ..._memberActions(hollow, master, localNick,
                      isFriendAccepted: isFriendAccepted),
              ],
            ],
          ),
        ),

        // ── Peer ID footer ──
        SizedBox(height: _compact ? HollowSpacing.sm : HollowSpacing.lg),
        _PeerIdFooter(peerId: widget.peerId, compact: _compact),
        SizedBox(height: _compact ? 4 : HollowSpacing.md + 2),
      ],
    );
  }

  /// The ABOUT ME header + text, or [] when empty.
  List<Widget> _aboutSection(HollowTheme hollow, String aboutMe) {
    if (aboutMe.isEmpty) return const [];
    return [
      SizedBox(height: _compact ? HollowSpacing.sm + 2 : HollowSpacing.md + 2),
      Text(
        'ABOUT ME',
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontSize: _compact ? 9 : 10,
        ),
      ),
      const SizedBox(height: HollowSpacing.xxs),
      Text(
        aboutMe,
        style: _compact
            ? HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              )
            : HollowTypography.body.copyWith(
                color: hollow.textSecondary,
                fontSize: 13,
                height: 1.45,
              ),
        maxLines: _compact ? 4 : null,
        overflow: _compact ? TextOverflow.ellipsis : null,
      ),
    ];
  }

  // Role + labels + Twitch merged into a single species of chip.
  List<Widget> _buildChips(HollowTheme hollow) {
    final chips = <Widget>[];
    // Every power role shows — Member included, for consistency.
    final role = widget.role;
    if (role != null && role.isNotEmpty) {
      chips.add(_ProfileChip(
        text: role[0].toUpperCase() + role.substring(1),
        color: profileRoleColor(role, hollow),
        compact: _compact,
      ));
    }
    for (final label in widget.labels ?? const <crdt_api.LabelFfi>[]) {
      chips.add(_ProfileChip(
        text: label.name,
        color: parseProfileLabelColor(label.color),
        // Access labels (channel-gating, staff-assigned) carry a shield so
        // they read differently from cosmetic tags.
        icon: label.access ? LucideIcons.shieldCheck : null,
        compact: _compact,
      ));
    }
    return chips;
  }

  /// The Twitch integration chip — placed in the corner band under the
  /// banner (not in the role/label row): integrations get their own spot.
  Widget? _twitchChip() {
    final twitch = _resolvedTwitchUsername;
    if (twitch == null || twitch.isEmpty) return null;
    return _ProfileChip(
      text: twitch,
      color: const Color(0xFF9146FF),
      icon: BrandIcons.twitch,
      compact: _compact,
      onTap: () {
        launchUrl(
          Uri.parse('https://twitch.tv/$twitch'),
          mode: LaunchMode.externalApplication,
        );
      },
    );
  }

  void _openUserSettings() {
    final navContext = Navigator.of(context, rootNavigator: true).context;
    widget.dismissHost();
    showUserSettingsDialog(navContext);
  }

  void _openNicknameDialog(String? localNick) {
    final peerId = widget.peerId;
    final navContext = Navigator.of(context, rootNavigator: true).context;
    widget.dismissHost();
    showLocalNicknameDialog(
      navContext,
      ref,
      peerId,
      currentNickname: localNick ?? '',
    );
  }

  /// Blocking opens a confirm dialog — dismiss the host (hover popup /
  /// profile dialog) first, like the nickname flow, so the dialog isn't
  /// stacked under a transient popup. The helper reads providers through the
  /// nav context's container, so it survives this widget's disposal.
  void _openBlockConfirm(String masterId) {
    final name = displayNameForPeer(
        ref.read(profileProvider)[widget.peerId], widget.peerId);
    final navContext = Navigator.of(context, rootNavigator: true).context;
    widget.dismissHost();
    confirmAndBlockUser(navContext, masterId: masterId, displayName: name);
  }

  void _openReportDialog(String masterId) {
    final name = displayNameForPeer(
        ref.read(profileProvider)[widget.peerId], widget.peerId);
    final navContext = Navigator.of(context, rootNavigator: true).context;
    widget.dismissHost();
    showReportUserDialog(navContext, masterId: masterId, displayName: name);
  }

  /// Same host-dismiss pattern as nickname/block/report: the hover popup is
  /// transient and would sit on top of (or vanish out from under) the verify
  /// screen. Capture the root nav context BEFORE dismissing, since dismissing
  /// disposes this widget's own context.
  void _openVerifyDialog(String masterId) {
    final navContext = Navigator.of(context, rootNavigator: true).context;
    widget.dismissHost();
    showVerifyContactDialog(navContext, peerId: masterId);
  }

  /// The provider writes run BEFORE dismissing — dismissing disposes this
  /// widget (and its ref) when hosted in the raw-OverlayEntry popup.
  void _openDm(String masterId) {
    openDmConversation(ref, masterId);
    widget.dismissHost();
  }

  void _openManageMember(String masterId, String serverId) {
    final navContext = Navigator.of(context, rootNavigator: true).context;
    widget.dismissHost();
    showManageMemberDialog(navContext, serverId: serverId, peerId: masterId);
  }

  /// Whether the local user holds ANY member-management capability over this
  /// profile in [ProfileCardBody.serverId] (advisory UI gating — the dialog
  /// and Rust `op_allowed` re-check per section).
  bool _canManageMember() {
    final serverId = widget.serverId;
    if (serverId == null) return false;
    final myRole = ref.watch(myRoleProvider(serverId)).valueOrNull ?? 'member';
    final perms =
        ref.watch(myPermissionsProvider(serverId)).valueOrNull ?? 0;
    final targetRole = widget.role ?? 'member';
    return (canManageRole(myRole, targetRole) &&
            assignableRoles(myRole).isNotEmpty) ||
        (perms & Permission.manageRoles) != 0 ||
        (perms & Permission.manageChannels) != 0;
  }

  /// Self, full density: showcase + profile editors side by side.
  List<Widget> _buildSelfActions() {
    return [
      // Opens ON TOP of the profile dialog — saving updates it live.
      HollowButton.ghost(
        onPressed: () => showShowcaseEditorDialog(context, ref),
        compact: true,
        icon: const Icon(LucideIcons.layoutGrid),
        child: const Text('Edit Showcase'),
      ),
      HollowButton.outline(
        onPressed: _openUserSettings,
        compact: true,
        icon: const Icon(LucideIcons.pencil),
        child: const Text('Edit Profile'),
      ),
    ];
  }

  /// Actions for someone else's card, both densities: ONE primary button
  /// (Message for friends, otherwise the friend-state action) over a strip
  /// of tooltipped utility icons — the card stays a profile, not a button
  /// stack.
  List<Widget> _memberActions(
    HollowTheme hollow,
    String master,
    String? localNick, {
    required bool isFriendAccepted,
  }) {
    final isBlocked = ref.watch(blockedUsersProvider).contains(master);
    final isVerified = ref.watch(isPeerVerifiedProvider(master));
    return [
      // Primary slot: Message for friends (mirroring the mobile profile
      // sheet's gate), else Add Friend / Accept Request / Request Sent.
      if (isFriendAccepted)
        HollowButton.filled(
          onPressed: () => _openDm(master),
          compact: _compact,
          expand: true,
          icon: const Icon(LucideIcons.messageCircle),
          child: const Text('Message'),
        )
      else
        ProfileFriendAction(peerId: widget.peerId, expand: true),
      SizedBox(height: _compact ? HollowSpacing.sm : HollowSpacing.md),
      // Utility strip: every icon carries a tooltip AND a semantic label
      // (icon-only controls always need purpose labels).
      Row(
        children: [
          _cardIconAction(
            hollow,
            icon: localNick != null ? LucideIcons.pencil : LucideIcons.tag,
            tooltip: localNick != null ? 'Edit nickname' : 'Set nickname',
            onTap: () => _openNicknameDialog(localNick),
          ),
          _iconGap(),
          _cardIconAction(
            hollow,
            icon: isVerified ? LucideIcons.shieldCheck : LucideIcons.shield,
            tooltip:
                isVerified ? 'Verified: view safety number' : 'Verify contact',
            color: isVerified ? hollow.success : null,
            onTap: () => _openVerifyDialog(master),
          ),
          if (_canManageMember()) ...[
            _iconGap(),
            _cardIconAction(
              hollow,
              icon: LucideIcons.userCog,
              tooltip: 'Manage member',
              onTap: () => _openManageMember(master, widget.serverId!),
            ),
          ],
          _iconGap(),
          _cardIconAction(
            hollow,
            icon: LucideIcons.ban,
            tooltip: isBlocked ? 'Unblock' : 'Block',
            color: hollow.error,
            onTap: isBlocked
                ? () => unblockUser(context, masterId: master)
                : () => _openBlockConfirm(master),
          ),
          _iconGap(),
          _cardIconAction(
            hollow,
            icon: LucideIcons.flag,
            tooltip: 'Report',
            color: hollow.error,
            onTap: () => _openReportDialog(master),
          ),
        ],
      ),
    ];
  }

  Widget _iconGap() =>
      SizedBox(width: _compact ? HollowSpacing.xs : HollowSpacing.sm);

  /// One square in the utility strip. Neutral border for every action —
  /// intent rides the icon tint (error for block/report) so the strip reads
  /// as one calm row instead of competing outlined buttons.
  Widget _cardIconAction(
    HollowTheme hollow, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
  }) {
    return Expanded(
      child: HollowTooltip(
        message: tooltip,
        child: HollowPressable(
          semanticLabel: tooltip,
          onTap: onTap,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          child: Container(
            height: _compact ? 30.0 : 34.0,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: _compact ? 14 : 15,
              color: color ?? hollow.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Banner image with deterministic-gradient fallback.
class _Banner extends ConsumerWidget {
  final String peerId;
  final double height;
  final Color fallbackColor;

  const _Banner({
    required this.peerId,
    required this.height,
    required this.fallbackColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gradient = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [fallbackColor, fallbackColor.withValues(alpha: 0.7)],
    );
    // The animated variant off the asset rail when we hold it, else the
    // still from the profile blob (see [watchAnimatedBanner]).
    final bannerBytes = watchAnimatedBanner(ref, peerId) ??
        ref.watch(bannerProvider(peerId)).valueOrNull;
    if (bannerBytes != null && bannerBytes.isNotEmpty) {
      return SizedBox(
        height: height,
        width: double.infinity,
        child: AnimatedGifImage(
          bytes: bannerBytes,
          height: height,
          width: double.infinity,
          fit: BoxFit.cover,
          errorWidget: Container(
            height: height,
            decoration: BoxDecoration(gradient: gradient),
          ),
        ),
      );
    }
    return Container(
      height: height,
      decoration: BoxDecoration(gradient: gradient),
    );
  }
}

/// A single tinted chip — role, label, and connection all share this shape.
class _ProfileChip extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool compact;
  final VoidCallback? onTap;

  const _ProfileChip({
    required this.text,
    required this.color,
    required this.compact,
    this.icon,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final chip = Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 6 : HollowSpacing.sm,
        vertical: compact ? 2 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(hollow.radiusSm),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: compact ? 11 : 12, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: HollowTypography.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              fontSize: compact ? 10 : 11,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
      button: true,
      label: 'Open $text on Twitch',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: chip),
      ),
    );
  }
}

/// Tap-to-copy peer ID footer.
class _PeerIdFooter extends StatelessWidget {
  final String peerId;
  final bool compact;

  const _PeerIdFooter({required this.peerId, required this.compact});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final shortId = peerId.length > 16
        ? (compact
            ? peerId.substring(peerId.length - 8)
            : '${peerId.substring(0, 8)}...${peerId.substring(peerId.length - 8)}')
        : peerId;
    final faded =
        hollow.textSecondary.withValues(alpha: compact ? 0.35 : 0.5);
    return GestureDetector(
      onTap: () {
        Clipboard.setData(ClipboardData(text: peerId));
        HollowToast.show(
          context,
          'Peer ID copied',
          type: HollowToastType.success,
          duration: const Duration(seconds: 1),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.copy, size: compact ? 8 : 10, color: faded),
            const SizedBox(width: 3),
            Text(
              shortId,
              style: HollowTypography.mono.copyWith(
                color: faded,
                fontSize: compact ? 8 : 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// State-aware friend action — Add / Accept / Pending / Friends.
class ProfileFriendAction extends ConsumerWidget {
  final String peerId;
  final bool expand;

  const ProfileFriendAction({
    super.key,
    required this.peerId,
    this.expand = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final friendInfo = ref.watch(friendsProvider)[peerId];

    // A `declined` row (a sticky reject tombstone) is neither pending nor
    // accepted — treat it like no row at all: show "Add Friend", so the
    // person can be re-added and never renders as an accepted friend.
    if (friendInfo == null ||
        (friendInfo.status != 'pending' && friendInfo.status != 'accepted')) {
      return HollowButton.outline(
        // Success feedback is the button itself flipping to "Request Sent"
        // (provider refresh); failure needs an explicit toast.
        onPressed: () async {
          try {
            await ref.read(friendsProvider.notifier).sendRequest(peerId);
          } catch (_) {
            if (context.mounted) {
              HollowToast.show(context, 'Could not send request',
                  type: HollowToastType.error);
            }
          }
        },
        compact: true,
        expand: expand,
        icon: const Icon(LucideIcons.userPlus),
        child: const Text('Add Friend'),
      );
    }

    if (friendInfo.status == 'pending') {
      if (friendInfo.direction == 'incoming') {
        return HollowButton.filled(
          onPressed: () async {
            try {
              await ref.read(friendsProvider.notifier).acceptRequest(peerId);
            } catch (_) {
              if (context.mounted) {
                HollowToast.show(context, 'Could not accept request',
                    type: HollowToastType.error);
              }
            }
          },
          compact: true,
          expand: expand,
          icon: const Icon(LucideIcons.check),
          child: const Text('Accept Request'),
        );
      }
      return HollowButton.ghost(
        onPressed: null,
        compact: true,
        expand: expand,
        icon: Icon(LucideIcons.clock, color: hollow.textSecondary),
        child: Text(
          'Request Sent',
          style: TextStyle(color: hollow.textSecondary),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xs),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(LucideIcons.userCheck, size: 14, color: hollow.success),
          const SizedBox(width: HollowSpacing.xs),
          Text(
            'Friends',
            style: HollowTypography.body.copyWith(
              color: hollow.success,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

Color parseProfileLabelColor(String hex) {
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length == 6) {
    return Color(int.parse('FF$cleaned', radix: 16));
  }
  if (cleaned.length == 8) {
    return Color(int.parse(cleaned, radix: 16));
  }
  return const Color(0xFF78909C);
}

/// Role badge color.
Color profileRoleColor(String role, HollowTheme hollow) {
  return switch (role) {
    'owner' => hollow.warning,
    'admin' => const Color(0xFFA78BFA),
    'moderator' =>
      Color.lerp(hollow.warning, hollow.error, 0.5) ?? hollow.warning,
    _ => hollow.textSecondary,
  };
}

/// Show a dialog to set/edit/clear a local nickname for a peer.
void showLocalNicknameDialog(
  BuildContext context,
  WidgetRef ref,
  String peerId, {
  String currentNickname = '',
}) {
  showHollowDialog(
    context: context,
    builder: (ctx) => _LocalNicknameDialog(
      peerId: peerId,
      currentNickname: currentNickname,
    ),
  );
}

class _LocalNicknameDialog extends ConsumerStatefulWidget {
  final String peerId;
  final String currentNickname;

  const _LocalNicknameDialog({
    required this.peerId,
    required this.currentNickname,
  });

  @override
  ConsumerState<_LocalNicknameDialog> createState() =>
      _LocalNicknameDialogState();
}

class _LocalNicknameDialogState extends ConsumerState<_LocalNicknameDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentNickname);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final nickname = _controller.text.trim();
    try {
      await ref.read(localNicknameProvider.notifier).setNickname(
            widget.peerId,
            nickname,
          );
    } catch (_) {
      if (mounted) {
        HollowToast.show(context, 'Could not save nickname',
            type: HollowToastType.error);
      }
      return;
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 300,
          padding: const EdgeInsets.all(HollowSpacing.xl),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusLg),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set Nickname',
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: HollowSpacing.xs),
              Text(
                'Only visible to you',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: HollowSpacing.md),
              HollowTextField(
                controller: _controller,
                hintText: 'Nickname (leave empty to clear)',
                maxLength: 32,
                autofocus: true,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: HollowSpacing.lg),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HollowButton.ghost(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.filled(
                    onPressed: _save,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
