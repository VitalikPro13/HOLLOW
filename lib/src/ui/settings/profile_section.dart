import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/avatar_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/core/providers/twitch_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/twitch_device_code_dialog.dart';
import 'package:hollow/src/ui/settings/profile_locations_card.dart';
import 'package:hollow/src/ui/settings/settings_shared.dart';
import 'package:hollow/src/ui/shop/owned_art_panel.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Profile category of the desktop Settings dialog: live preview card,
/// avatar/banner management, edit fields, Twitch connection, and the explicit
/// Save button (Profile is the one category with deferred commit — everything
/// else auto-saves). The edit state (pending images, dirty flag, live text)
/// stays on the dialog state so it survives switching categories; this widget
/// renders it and reports interactions back through callbacks.

/// Deterministic banner color from peer ID (shifted hue from avatar).
Color _bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360; // Shift hue from avatar
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

class ProfileSection extends ConsumerWidget {
  final String localPeerId;
  final TextEditingController displayNameController;
  final TextEditingController statusController;
  final TextEditingController aboutMeController;
  final String liveDisplayName;
  final String liveStatus;
  final Uint8List? pendingAvatarBytes;
  final Uint8List? pendingBannerBytes;
  final bool avatarChanged;
  final bool bannerChanged;
  final bool profileDirty;
  final bool savingProfile;
  final bool avatarProcessing;
  final bool bannerProcessing;

  /// Pending avatar frame ID (issue #54): null = unchanged, '' = cleared.
  final String? pendingFrameId;
  final bool frameChanged;

  final VoidCallback onPickAvatar;
  final VoidCallback onClearAvatar;
  final VoidCallback onPickBanner;
  final VoidCallback onClearBanner;
  final VoidCallback onPickFrame;
  final VoidCallback onClearFrame;
  final VoidCallback onSaveProfile;
  final VoidCallback onAboutMeChanged;

  const ProfileSection({
    super.key,
    required this.localPeerId,
    required this.displayNameController,
    required this.statusController,
    required this.aboutMeController,
    required this.liveDisplayName,
    required this.liveStatus,
    required this.pendingAvatarBytes,
    required this.pendingBannerBytes,
    required this.avatarChanged,
    required this.bannerChanged,
    required this.profileDirty,
    required this.savingProfile,
    required this.avatarProcessing,
    required this.bannerProcessing,
    required this.pendingFrameId,
    required this.frameChanged,
    required this.onPickAvatar,
    required this.onClearAvatar,
    required this.onPickBanner,
    required this.onClearBanner,
    required this.onPickFrame,
    required this.onClearFrame,
    required this.onSaveProfile,
    required this.onAboutMeChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return SingleChildScrollView(
      key: const ValueKey('profile'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Profile preview card + image buttons
              SizedBox(
                width: 200,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildPreviewCard(hollow, ref),
                    // Image management (below card)
                    const SizedBox(height: HollowSpacing.md),
                    _buildAvatarRow(hollow, ref),
                    const SizedBox(height: HollowSpacing.xs),
                    _buildBannerRow(hollow, ref),
                    const SizedBox(height: HollowSpacing.xs),
                    _buildFrameRow(hollow, ref),
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.lg),
              // Edit fields
              Expanded(child: _buildEditFields()),
            ],
          ),

          const SizedBox(height: HollowSpacing.xl),
          Container(height: 1, color: hollow.border),
          const SizedBox(height: HollowSpacing.xl),

          // ── Connections ──
          const SettingsSectionLabel(label: 'CONNECTIONS'),
          const SizedBox(height: HollowSpacing.sm),
          TwitchConnectionRow(hollow: hollow),

          // Profile keeps an explicit Save button — text fields and cropped
          // images benefit from a single commit, unlike the auto-saving toggles
          // in the other categories.
          const SizedBox(height: HollowSpacing.xl),
          Align(
            alignment: Alignment.centerRight,
            child: HollowButton.filled(
              onPressed: (profileDirty && !savingProfile) ? onSaveProfile : null,
              icon: const Icon(LucideIcons.check, size: 16),
              child: Text(savingProfile
                  ? 'Saving...'
                  : (profileDirty ? 'Save profile' : 'Saved')),
            ),
          ),

          // ── Profiles on this computer (issue #47) ── below the Save commit
          // so it can't read as part of the deferred profile-edit form: switch
          // and erase are immediate, confirmed actions. Desktop-only.
          const SizedBox(height: HollowSpacing.xl),
          Container(height: 1, color: hollow.border),
          const SizedBox(height: HollowSpacing.xl),
          const ProfileLocationsCard(),

          // Art you own (Hollow Shop). Last, below the profile switcher: it
          // is a library, not part of the deferred profile-edit form, and
          // wearing something from it saves immediately.
          const SizedBox(height: HollowSpacing.xl),
          Container(height: 1, color: hollow.border),
          const SizedBox(height: HollowSpacing.lg),
          const OwnedArtPanel(),
        ],
      ),
    );
  }

  Widget _buildPreviewCard(HollowTheme hollow, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildPreviewBanner(hollow, ref),
          // Avatar overlapping banner
          Transform.translate(
            offset: const Offset(0, -28),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md,
              ),
              child: _buildPreviewIdentity(hollow, ref),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewBanner(HollowTheme hollow, WidgetRef ref) {
    final bannerColor = _bannerColorFromId(localPeerId);
    // 80 is this preview column's 200 width / 2.5, the one ratio every user
    // banner surface, the banner cropper and Rust's 1200x480 storage share.
    const bannerHeight = 80.0;
    final fallback = Container(
      height: bannerHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
        ),
      ),
    );
    final savedBanner = watchAnimatedBanner(ref, localPeerId) ??
        ref.watch(bannerProvider(localPeerId)).valueOrNull;
    final displayBanner = bannerChanged ? pendingBannerBytes : savedBanner;
    Widget banner = fallback;
    if (displayBanner != null && displayBanner.isNotEmpty) {
      banner = SizedBox(
        height: bannerHeight,
        width: double.infinity,
        child: AnimatedGifImage(
          bytes: displayBanner,
          height: bannerHeight,
          width: double.infinity,
          fit: BoxFit.cover,
          errorWidget: fallback,
        ),
      );
    }
    if (!bannerProcessing) return banner;
    return Stack(
      children: [
        banner,
        Positioned(
          top: HollowSpacing.xs,
          right: HollowSpacing.xs,
          child: _processingSpinner(hollow),
        ),
      ],
    );
  }

  /// Small non-blocking spinner shown on a preview while the picked image is
  /// being WebP-encoded in Rust (the preview already shows the cropped bytes).
  Widget _processingSpinner(HollowTheme hollow) {
    return SizedBox(
      width: 14,
      height: 14,
      child: CircularProgressIndicator(
        strokeWidth: 2,
        color: hollow.textSecondary,
      ),
    );
  }

  Widget _buildPreviewIdentity(HollowTheme hollow, WidgetRef ref) {
    final previewName = liveDisplayName.trim().isNotEmpty
        ? liveDisplayName.trim()
        : displayNameForPeer(
            ref.watch(profileProvider.select((p) => p[localPeerId])),
            localPeerId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Avatar with border
        Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(hollow.radiusMd + 2),
                border: Border.all(
                  color: hollow.surface,
                  width: 3,
                ),
              ),
              child: HollowAvatar(
                peerId: localPeerId,
                size: 56,
                imageBytes: avatarChanged ? pendingAvatarBytes : null,
                frameId: frameChanged ? (pendingFrameId ?? '') : null,
                animate: true,
              ),
            ),
            if (avatarProcessing)
              Positioned(
                right: 0,
                bottom: 0,
                child: _processingSpinner(hollow),
              ),
          ],
        ),

        const SizedBox(height: HollowSpacing.xs),

        // Display name
        Text(
          previewName,
          style: HollowTypography.subheading.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),

        // Status
        if (liveStatus.trim().isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.xxs),
          Text(
            liveStatus.trim(),
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 10,
              fontStyle: FontStyle.italic,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],

        const SizedBox(height: HollowSpacing.sm),
        Container(height: 1, color: hollow.border),

        // About Me preview
        if (aboutMeController.text.trim().isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'ABOUT ME',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              fontSize: 9,
            ),
          ),
          const SizedBox(height: HollowSpacing.xxs),
          Text(
            aboutMeController.text.trim(),
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 10,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
          ),
        ],

        // Peer ID footer
        const SizedBox(height: HollowSpacing.sm),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              LucideIcons.copy,
              size: 8,
              color: hollow.textSecondary.withValues(alpha: 0.35),
            ),
            const SizedBox(width: 3),
            Text(
              localPeerId.length > 16
                  ? localPeerId.substring(localPeerId.length - 8)
                  : localPeerId,
              style: HollowTypography.mono.copyWith(
                color: hollow.textSecondary.withValues(alpha: 0.35),
                fontSize: 8,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildAvatarRow(HollowTheme hollow, WidgetRef ref) {
    final savedAvatar = ref.watch(avatarProvider)[localPeerId];
    // An ANIMATED avatar counts even when the still cache is cold: HollowAvatar
    // paints the rail blob and never asks for the still, so `avatarProvider`
    // stays empty for exactly the people who most obviously have an avatar.
    final savedAnimated = isProfileAnimHash(ref.watch(
        profileProvider.select((p) => p[localPeerId]?.avatarAnim ?? '')));
    final hasAvatar = avatarChanged
        ? (pendingAvatarBytes != null && pendingAvatarBytes!.isNotEmpty)
        : (savedAnimated || (savedAvatar != null && savedAvatar.isNotEmpty));
    return _ImageRow(
      label: 'Avatar',
      onPick: onPickAvatar,
      onClear: hasAvatar ? onClearAvatar : null,
      hollow: hollow,
    );
  }

  Widget _buildBannerRow(HollowTheme hollow, WidgetRef ref) {
    final savedBanner = watchAnimatedBanner(ref, localPeerId) ??
        ref.watch(bannerProvider(localPeerId)).valueOrNull;
    final hasBanner = bannerChanged
        ? (pendingBannerBytes != null && pendingBannerBytes!.isNotEmpty)
        : (savedBanner != null && savedBanner.isNotEmpty);
    return _ImageRow(
      label: 'Banner',
      onPick: onPickBanner,
      onClear: hasBanner ? onClearBanner : null,
      hollow: hollow,
    );
  }

  /// Avatar frame (issue #54). Reads the SAVED frame when nothing is pending,
  /// so Clear only offers itself when there is a frame to clear.
  Widget _buildFrameRow(HollowTheme hollow, WidgetRef ref) {
    final saved = ref.watch(
        profileProvider.select((p) => p[localPeerId]?.avatarFrame ?? ''));
    final current = frameChanged ? (pendingFrameId ?? '') : saved;
    return _ImageRow(
      label: 'Frame',
      icon: LucideIcons.frame,
      onPick: onPickFrame,
      onClear: current.isNotEmpty ? onClearFrame : null,
      hollow: hollow,
    );
  }

  Widget _buildEditFields() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SettingsSectionLabel(label: 'DISPLAY NAME'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: displayNameController,
          hintText: 'Enter a display name',
          autofocus: true,
          maxLength: 32,
        ),

        const SizedBox(height: HollowSpacing.lg),

        const SettingsSectionLabel(label: 'STATUS'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: statusController,
          hintText: 'What are you up to?',
          maxLength: 48,
        ),

        const SizedBox(height: HollowSpacing.lg),

        const SettingsSectionLabel(label: 'ABOUT ME'),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: aboutMeController,
          hintText: 'Tell us about yourself',
          maxLines: 3,
          maxLength: 128,
          onChanged: (_) => onAboutMeChanged(),
        ),
      ],
    );
  }
}

/// Image row: "Avatar -------- [trash]" or "Banner -------- [trash]"
class _ImageRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final HollowTheme hollow;

  const _ImageRow({
    required this.label,
    this.icon = LucideIcons.image,
    required this.onPick,
    this.onClear,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        HollowPressable(
          onTap: onPick,
          subtle: true,
          padding: const EdgeInsets.symmetric(
            horizontal: HollowSpacing.sm,
            vertical: HollowSpacing.xxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: hollow.accent),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                label,
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        Expanded(
          child: Container(
            height: 1,
            color: hollow.border,
          ),
        ),
        const SizedBox(width: HollowSpacing.xs),
        AnimatedOpacity(
          opacity: onClear != null ? 1.0 : 0.25,
          duration: const Duration(milliseconds: 150),
          child: HollowPressable(
            onTap: onClear,
            subtle: true,
            padding: const EdgeInsets.all(HollowSpacing.xxs + 1),
            semanticLabel: 'Remove $label',
            child: Icon(
              LucideIcons.trash2,
              size: 13,
              color: onClear != null ? hollow.error : hollow.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

// ── Twitch Connection Widget ──────────────────────────────────────

/// Connect, verify and disconnect a Twitch account.
///
/// Public because it is what the widget test drives: every state it can be in
/// (busy, verified, connected but not verified, disconnected) is one this row
/// paints, and the rest of Settings > Profile needs a running node to pump.
class TwitchConnectionRow extends ConsumerStatefulWidget {
  final HollowTheme hollow;

  const TwitchConnectionRow({super.key, required this.hollow});

  @override
  ConsumerState<TwitchConnectionRow> createState() =>
      _TwitchConnectionRowState();
}

class _TwitchConnectionRowState extends ConsumerState<TwitchConnectionRow> {
  bool _connected = false;
  String? _userId;
  String? _username;
  bool _loading = true;
  /// A verify or a disconnect is in flight: both talk to the shop, so the
  /// buttons say so rather than looking dead.
  bool _busy = false;
  /// The login on our verified credential, or null when we hold none. This is
  /// what the purple chip draws, so the row says which of the two states we
  /// are in rather than only whether a token exists.
  String? _verifiedLogin;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    try {
      final ffi = ref.read(twitchFfiProvider);
      final connected = await ffi.isConnected();
      final userId = connected ? await ffi.userId() : null;
      final username = connected ? await ffi.username() : null;
      if (mounted) {
        setState(() {
          _connected = connected;
          _userId = userId;
          _username = username;
          _verifiedLogin = _myVerifiedLogin();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The verified login on OUR profile row, read the same way every viewer
  /// reads it.
  String? _myVerifiedLogin() {
    final me = ref.read(identityProvider).peerId;
    if (me == null) return null;
    return ref.read(twitchLoginProvider(me));
  }

  /// Ask the shop to verify the connected account and wear the credential.
  ///
  /// Every outcome is visible: a spinner while it runs, a toast on a refusal
  /// with the shop's own sentence, and the login on the row when it lands.
  Future<void> _verifyAccount() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final outcome = await ref.read(twitchFfiProvider).verifyOwner();
      if (!mounted) return;
      setState(() {
        _verifiedLogin = outcome.verified ? outcome.login : null;
        _busy = false;
      });
      if (outcome.verified) {
        HollowToast.show(context, 'Twitch verified as ${outcome.login}',
            type: HollowToastType.success);
      } else {
        HollowToast.show(context, outcome.message, type: HollowToastType.error);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      HollowToast.show(context, 'Could not verify Twitch: $e',
          type: HollowToastType.error);
    }
  }

  /// Connect, then verify.
  ///
  /// The connection alone proves nothing to anybody else: what a viewer sees
  /// is the CREDENTIAL, so the sign in runs straight into the verify rather
  /// than leaving the account connected and unverified. The old per-server
  /// `setTwitchUsername` writes are gone with it; a self-declared handle is
  /// not rendered by any new client.
  Future<void> _connect() async {
    if (!mounted) return;
    showTwitchDeviceCodeDialog(context, onSuccess: () async {
      await _checkConnection();
      await _verifyAccount();
    });
  }

  Future<void> _disconnect() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // Rust drops the account credential and republishes BEFORE it wipes the
      // token: the credential is a 90-day fact everyone verifies offline, so
      // the token alone going away would leave a verified chip behind.
      await ref.read(twitchFfiProvider).disconnect();
      if (mounted) {
        setState(() {
          _connected = false;
          _userId = null;
          _username = null;
          _verifiedLogin = null;
          _busy = false;
        });
        HollowToast.show(context, 'Twitch disconnected',
            type: HollowToastType.info);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        HollowToast.show(context, 'Failed to disconnect: $e',
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;

    if (_loading) {
      return const SizedBox(height: 36);
    }

    return Row(
      children: [
        const Icon(BrandIcons.twitch, size: 18, color: Color(0xFF9146FF)),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Twitch',
                style: HollowTypography.body
                    .copyWith(color: hollow.textPrimary),
              ),
              if (_verifiedLogin != null)
                Text(
                  'Verified as $_verifiedLogin',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 10,
                  ),
                )
              else if (_connected && (_username != null || _userId != null))
                Text(
                  _username != null
                      ? 'Connected as $_username, not verified yet'
                      : 'Connected (ID: ${_userId!.length > 12 ? '${_userId!.substring(0, 12)}...' : _userId!})',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 10,
                  ),
                )
              else
                Text(
                  'Connect to wear a verified Twitch mark and join Twitch-verified servers',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: HollowSpacing.md),
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_connected) ...[
          // Connected but not verified: the account is signed in and the mark
          // is one press away, so offer it rather than making them disconnect
          // and start again.
          if (_verifiedLogin == null)
            HollowButton.outline(
              onPressed: _verifyAccount,
              compact: true,
              child: const Text('Verify'),
            ),
          HollowButton.ghost(
            onPressed: _disconnect,
            compact: true,
            child: const Text('Disconnect'),
          ),
        ] else
          HollowButton.outline(
            onPressed: _connect,
            compact: true,
            child: const Text('Connect'),
          ),
      ],
    );
  }
}
