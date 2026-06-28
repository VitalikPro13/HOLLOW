import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/ui/settings/storage_section.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/services/app_lock_service.dart';
import 'package:hollow/src/core/shared_tickers.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/rainbow_slider_track.dart';
import 'package:hollow/src/ui/dialogs/device_link_dialog.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/ringtone_clip_editor_dialog.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hollow/src/ui/dialogs/twitch_device_code_dialog.dart';
import 'package:hollow/src/ui/guides/help_panel.dart';
import 'package:hollow/src/ui/mobile/mobile_image_crop_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileSettingsTab extends ConsumerWidget {
  const MobileSettingsTab({super.key});

  void _push(BuildContext context, String title, Widget child) {
    Navigator.of(context).push(
      hollowMobileRoute(
        builder: (_) => _SettingsSubPage(title: title, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final myPeerId = ref.watch(identityProvider).peerId ?? '';
    final profiles = ref.watch(profileProvider);
    final myName = myPeerId.isEmpty ? '' : displayNameFor(profiles, myPeerId);

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.lg,
        HollowSpacing.lg,
        HollowSpacing.lg,
        HollowSpacing.xl,
      ),
      children: [
        Text(
          'Settings',
          style: HollowTypography.heading.copyWith(color: hollow.textPrimary),
        ),
        const SizedBox(height: HollowSpacing.lg),

        // Profile card — tap to edit profile.
        HollowPressable(
          onTap: () => _push(
              context, 'Profile', const _ProfileTab(key: ValueKey('profile'))),
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          child: Container(
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusLg),
              border: Border.all(color: hollow.border),
            ),
            child: Row(
              children: [
                HollowAvatar(peerId: myPeerId, size: 48),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        myName.isEmpty ? 'Profile' : myName,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Name, status, avatar & banner',
                        style: HollowTypography.caption
                            .copyWith(color: hollow.textSecondary),
                      ),
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronRight,
                    size: 18, color: hollow.textSecondary),
              ],
            ),
          ),
        ),
        const SizedBox(height: HollowSpacing.lg),
        Divider(
          color: hollow.textSecondary.withValues(alpha: 0.50),
          height: 1,
        ),
        const SizedBox(height: HollowSpacing.lg),

        _SettingsNavTile(
          icon: LucideIcons.circleHelp,
          title: 'Help',
          subtitle: 'Guides & how-to',
          onTap: () => _push(
              context, 'Help', const HelpResourceCenter()),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.palette,
          title: 'Appearance',
          subtitle: 'Theme, accent, background & layout',
          onTap: () => _push(context, 'Appearance',
              const _AppearanceTab(key: ValueKey('appearance'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.accessibility,
          title: 'Accessibility',
          subtitle: 'Motion, transparency & contrast',
          onTap: () => _push(context, 'Accessibility',
              const _AccessibilityTab(key: ValueKey('accessibility'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.globe,
          title: 'Network',
          subtitle: 'Relay & peer ID',
          onTap: () => _push(context, 'Network',
              const _NetworkTab(key: ValueKey('network'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.mic,
          title: 'Audio & Video',
          subtitle: 'Quality, mic gain & ringtone',
          onTap: () => _push(context, 'Audio & Video',
              const _AudioTab(key: ValueKey('audio'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.hardDrive,
          title: 'Files & Storage',
          subtitle: 'Disk usage, downloads, cache & media',
          onTap: () => _push(context, 'Files & Storage',
              const _StorageTab(key: ValueKey('storage'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.shieldCheck,
          title: 'Security',
          subtitle: 'App lock & recovery phrase',
          onTap: () => _push(context, 'Security',
              const _SecurityTab(key: ValueKey('security'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.smartphone,
          title: 'Devices',
          subtitle: 'Linked devices & multi-device tools',
          onTap: () => _push(context, 'Devices',
              const _DevicesTab(key: ValueKey('devices'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.archive,
          title: 'Backup',
          subtitle: 'Export account & verify proofs',
          onTap: () => _push(context, 'Backup',
              const _BackupTab(key: ValueKey('backup'))),
        ),
        const SizedBox(height: HollowSpacing.sm),
        _SettingsNavTile(
          icon: LucideIcons.info,
          title: 'About',
          subtitle: 'Version, relay status, news & legal',
          onTap: () =>
              _push(context, 'About', const _AboutTab(key: ValueKey('about'))),
        ),

        const SizedBox(height: HollowSpacing.lg),
        Divider(
          color: hollow.textSecondary.withValues(alpha: 0.50),
          height: 1,
        ),
        const SizedBox(height: HollowSpacing.lg),

        // System status — same calm card as the desktop Home (green "All
        // systems operational" when healthy; the active notice + countdown
        // otherwise). Gives mobile a pull-surface for status, since the mobile
        // banner is push-only-for-problems.
        const HomeStatusCard(),

        const SizedBox(height: HollowSpacing.md),

        // Sync stats — same numbers as the desktop Home stats card, so this
        // device can be eyeball-compared against another for sync. DM messages
        // converge across a person's devices; channel messages are lazy-paged
        // per device and intentionally not counted (they'd diverge).
        const _MobileStatsCard(),

        const SizedBox(height: HollowSpacing.md),
        // Relay "Online" counter — mirrors the desktop Home shell's bottom
        // online-users row (relay-reported peers currently connected).
        const _MobileOnlineCounter(),
      ],
    );
  }
}

/// Relay online-users counter — a port of the desktop Home shell's bottom
/// "Online … N" row (users icon + shimmer divider + live count from the relay
/// /server-stats poll).
class _MobileOnlineCounter extends ConsumerWidget {
  const _MobileOnlineCounter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final relayStats = ref.watch(relayStatsProvider);
    return Row(
      children: [
        Icon(LucideIcons.users, size: 13, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.xs),
        Text(
          'Online',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 11,
          ),
        ),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(child: _MobileShimmerLine(hollow: hollow)),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          '${relayStats.onlineUsers}',
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// Compact sync-stats card for the mobile Settings tab. Mirror of the desktop
/// Home `_SyncStatsCard` — locally-knowable counts that converge across a
/// person's devices, for at-a-glance multi-device sync comparison.
class _MobileStatsCard extends ConsumerWidget {
  const _MobileStatsCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final friends = ref.watch(friendsProvider);
    final servers = ref.watch(serverListProvider);
    final devices = ref.watch(myDevicesProvider);
    // Recompute the DM count whenever the DM list changes.
    ref.watch(lastDmMessageProvider);
    final dmCount = ref.watch(_mobileDmCountProvider);

    final friendCount =
        friends.values.where((f) => f.status == 'accepted').length;
    final devicesOnline = devices.where((d) => d.online).length;
    final deviceCount = devices.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.chartColumn, size: 14,
                  color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                'Your Stats',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          _MobileStatRow(
            hollow: hollow,
            icon: LucideIcons.users,
            label: 'Friends',
            value: '$friendCount',
          ),
          const SizedBox(height: HollowSpacing.sm),
          _MobileStatRow(
            hollow: hollow,
            icon: LucideIcons.server,
            label: 'Servers',
            value: '${servers.length}',
          ),
          const SizedBox(height: HollowSpacing.sm),
          _MobileStatRow(
            hollow: hollow,
            icon: LucideIcons.messageSquare,
            label: 'DM messages',
            value: dmCount.maybeWhen(
              data: (n) => '$n',
              orElse: () => '…',
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          _MobileStatRow(
            hollow: hollow,
            icon: LucideIcons.smartphone,
            label: 'Devices',
            value: deviceCount > 1
                ? '$devicesOnline / $deviceCount online'
                : '1',
            valueColor: deviceCount > 1
                ? (devicesOnline == deviceCount
                    ? hollow.success
                    : hollow.warning)
                : hollow.textPrimary,
          ),
        ],
      ),
    );
  }
}

/// DM message count for the mobile stats card (see desktop `_dmMessageCountProvider`).
final _mobileDmCountProvider = FutureProvider.autoDispose<int>((ref) async {
  ref.watch(lastDmMessageProvider);
  try {
    return await storage_api.countAllDmMessages();
  } catch (_) {
    return 0;
  }
});

class _MobileStatRow extends StatelessWidget {
  final HollowTheme hollow;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _MobileStatRow({
    required this.hollow,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 14, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Text(
          label,
          style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
            fontSize: 13,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: HollowTypography.body.copyWith(
            color: valueColor ?? hollow.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
      ],
    );
  }
}

/// Full-screen pushed settings subpage — same chrome as
/// MobileServerSettingsRoute (back arrow + title + divider).
class _SettingsSubPage extends StatelessWidget {
  final String title;
  final Widget child;

  const _SettingsSubPage({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xs,
              ),
              child: Row(
                children: [
                  HollowPressable(
                    onTap: () => Navigator.pop(context),
                    semanticLabel: 'Back',
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(LucideIcons.arrowLeft,
                        size: 20, color: hollow.textPrimary),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      title,
                      style: HollowTypography.heading
                          .copyWith(color: hollow.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: hollow.border, height: 1),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}

class _SettingsNavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SettingsNavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusLg),
      child: Container(
        padding: const EdgeInsets.all(HollowSpacing.md),
        decoration: BoxDecoration(
          color: hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusLg),
          border: Border.all(color: hollow.border),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: hollow.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(hollow.radiusMd),
              ),
              child: Icon(icon, size: 18, color: hollow.accent),
            ),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: HollowTypography.caption
                        .copyWith(color: hollow.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(LucideIcons.chevronRight,
                size: 18, color: hollow.textSecondary),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Profile Tab
// ─────────────────────────────────────────────────

class _ProfileTab extends ConsumerStatefulWidget {
  const _ProfileTab({super.key});

  @override
  ConsumerState<_ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends ConsumerState<_ProfileTab> {
  late final TextEditingController _nameController;
  late final TextEditingController _statusController;
  late final TextEditingController _aboutController;
  bool _saving = false;
  Uint8List? _pendingAvatar;
  Uint8List? _pendingBanner;
  bool _avatarChanged = false;
  bool _bannerChanged = false;
  bool _populated = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController();
    _statusController = TextEditingController();
    _aboutController = TextEditingController();
    _nameController.addListener(_onFieldChanged);
    _statusController.addListener(_onFieldChanged);
    _aboutController.addListener(_onFieldChanged);
    _tryPopulate();
  }

  void _tryPopulate() {
    if (_populated) return;
    final peerId = ref.read(identityProvider).peerId ?? '';
    final profile = ref.read(profileProvider)[peerId];
    if (profile != null) {
      _nameController.text = profile.displayName;
      _statusController.text = profile.status;
      _aboutController.text = profile.aboutMe;
      _populated = true;
    }
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _nameController.dispose();
    _statusController.dispose();
    _aboutController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final bytes = await result.files.first.xFile.readAsBytes();
    if (!mounted) return;

    final ext = result.files.first.extension?.toLowerCase() ?? '';
    if (ext == 'gif') {
      if (bytes.length > 1024 * 1024) {
        HollowToast.show(context, 'GIF must be under 1 MB', type: HollowToastType.error);
        return;
      }
      setState(() { _pendingAvatar = bytes; _avatarChanged = true; });
      return;
    }

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final cropped = isMobile
        ? await showMobileImageCrop(
            context: context, imageBytes: bytes, aspectRatio: 1.0, title: 'Crop Avatar',
          )
        : await showImageCropDialog(
            context: context, imageBytes: bytes, aspectRatio: 1.0, title: 'Crop Avatar',
          );
    if (cropped == null || !mounted) return;

    try {
      final processed = await network_api.processAvatar(rawBytes: cropped);
      if (mounted) setState(() { _pendingAvatar = processed; _avatarChanged = true; });
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed to process', type: HollowToastType.error);
    }
  }

  Future<void> _pickBanner() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final bytes = await result.files.first.xFile.readAsBytes();
    if (!mounted) return;

    final ext = result.files.first.extension?.toLowerCase() ?? '';
    if (ext == 'gif') {
      if (bytes.length > 2 * 1024 * 1024) {
        HollowToast.show(context, 'GIF must be under 2 MB', type: HollowToastType.error);
        return;
      }
      setState(() { _pendingBanner = bytes; _bannerChanged = true; });
      return;
    }

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final cropped = isMobile
        ? await showMobileImageCrop(
            context: context, imageBytes: bytes, aspectRatio: 3.0, title: 'Crop Banner',
          )
        : await showImageCropDialog(
            context: context, imageBytes: bytes, aspectRatio: 3.0, title: 'Crop Banner',
          );
    if (cropped == null || !mounted) return;

    try {
      final processed = await network_api.processBanner(rawBytes: cropped);
      if (mounted) setState(() { _pendingBanner = processed; _bannerChanged = true; });
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed to process', type: HollowToastType.error);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      String twitchUsername = '';
      try {
        twitchUsername = await twitch_api.twitchGetUsername() ?? '';
      } catch (_) {}

      await ref.read(profileProvider.notifier).updateMyProfile(
        displayName: _nameController.text.trim(),
        status: _statusController.text.trim(),
        aboutMe: _aboutController.text.trim(),
        avatarBytes: _avatarChanged ? _pendingAvatar : null,
        bannerBytes: _bannerChanged ? _pendingBanner : null,
        twitchUsername: twitchUsername,
      );

      if (mounted) {
        setState(() { _avatarChanged = false; _bannerChanged = false; });
        HollowToast.show(context, 'Profile updated', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed to update', type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final peerId = ref.watch(identityProvider).peerId ?? '';
    ref.watch(profileProvider);
    if (!_populated) _tryPopulate();
    final bannerBytes = ref.watch(bannerProvider(peerId)).valueOrNull;
    final bannerColor = bannerColorFromId(peerId);

    final previewName = _nameController.text.trim().isNotEmpty
        ? _nameController.text.trim()
        : displayNameFor(ref.watch(profileProvider), peerId);
    final previewStatus = _statusController.text.trim();
    final previewAbout = _aboutController.text.trim();

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        // Profile preview card
        Container(
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Banner (tappable)
              GestureDetector(
                onTap: _pickBanner,
                onLongPress: _bannerChanged || bannerBytes != null
                    ? () => setState(() { _pendingBanner = Uint8List(0); _bannerChanged = true; })
                    : null,
                child: SizedBox(
                  height: 100,
                  width: double.infinity,
                  child: _bannerChanged && _pendingBanner != null && _pendingBanner!.isNotEmpty
                      ? Image.memory(_pendingBanner!, fit: BoxFit.cover)
                      : bannerBytes != null && bannerBytes.isNotEmpty
                          ? AnimatedGifImage(
                              bytes: bannerBytes, height: 100, width: double.infinity, fit: BoxFit.cover,
                              errorWidget: _bannerGradient(bannerColor),
                            )
                          : _bannerGradient(bannerColor),
                ),
              ),

              // Avatar overlapping banner + preview info
              Transform.translate(
                offset: const Offset(0, -32),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
                  child: Column(
                    children: [
                      // Avatar (tappable)
                      GestureDetector(
                        onTap: _pickAvatar,
                        onLongPress: _avatarChanged
                            ? () => setState(() { _pendingAvatar = null; _avatarChanged = false; })
                            : null,
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(hollow.radiusMd + 2),
                            border: Border.all(color: hollow.surface, width: 3),
                          ),
                          child: _avatarChanged && _pendingAvatar != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(hollow.radiusMd - 1),
                                  child: Image.memory(_pendingAvatar!, width: 64, height: 64, fit: BoxFit.cover),
                                )
                              : HollowAvatar(peerId: peerId, size: 64),
                        ),
                      ),

                      const SizedBox(height: HollowSpacing.xs),

                      // Name
                      Text(
                        previewName,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),

                      // Status
                      if (previewStatus.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          previewStatus,
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ],

                      const SizedBox(height: HollowSpacing.sm),
                      Container(height: 1, color: hollow.border),

                      // About me
                      if (previewAbout.isNotEmpty) ...[
                        const SizedBox(height: HollowSpacing.sm),
                        Text('ABOUT ME', style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          fontSize: 9,
                        )),
                        const SizedBox(height: 2),
                        Text(
                          previewAbout,
                          style: HollowTypography.caption.copyWith(
                            color: hollow.textSecondary,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                        ),
                      ],

                      // Peer ID footer
                      if (peerId.length >= 16) ...[
                        const SizedBox(height: HollowSpacing.sm),
                        Text(
                          '${peerId.substring(0, 8)}...${peerId.substring(peerId.length - 8)}',
                          style: HollowTypography.mono.copyWith(
                            color: hollow.textSecondary.withValues(alpha: 0.4),
                            fontSize: 9,
                          ),
                        ),
                        const SizedBox(height: HollowSpacing.xs),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: HollowSpacing.xs),
        Text('Tap banner or avatar to change',
            textAlign: TextAlign.center,
            style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),

        const SizedBox(height: HollowSpacing.xl),

        // Display name
        Text('Display Name', style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: _nameController,
          hintText: 'Display name',
          maxLength: 32,
          showCounter: true,
        ),

        const SizedBox(height: HollowSpacing.lg),

        // Status
        Text('Status', style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: _statusController,
          hintText: 'What are you up to?',
          maxLength: 48,
          showCounter: true,
        ),

        const SizedBox(height: HollowSpacing.lg),

        // About me
        Text('About Me', style: HollowTypography.caption.copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.xs),
        HollowTextField(
          controller: _aboutController,
          hintText: 'Tell people about yourself',
          maxLength: 128,
          showCounter: true,
          maxLines: 3,
        ),

        const SizedBox(height: HollowSpacing.xl),

        // Save
        HollowButton.filled(
          onPressed: _saving ? null : _save,
          expand: true,
          child: Text(_saving ? 'Saving...' : 'Save Profile'),
        ),

        const SizedBox(height: HollowSpacing.xl),

        // Twitch connection
        _TwitchRow(),
      ],
    );
  }

  Widget _bannerGradient(Color color) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: [color, color.withValues(alpha: 0.7)],
        ),
      ),
    );
  }
}

class _TwitchRow extends ConsumerStatefulWidget {
  @override
  ConsumerState<_TwitchRow> createState() => _TwitchRowState();
}

class _TwitchRowState extends ConsumerState<_TwitchRow> {
  bool _connected = false;
  String _username = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final connected = await twitch_api.twitchIsConnected();
      String username = '';
      if (connected) {
        username = await twitch_api.twitchGetUsername() ?? '';
      }
      if (mounted) {
        setState(() { _connected = connected; _username = username; _loading = false; });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _disconnect() async {
    try {
      await twitch_api.twitchDisconnect();
      if (mounted) {
        setState(() { _connected = false; _username = ''; });
        HollowToast.show(context, 'Twitch disconnected', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed', type: HollowToastType.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (_loading) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Row(
        children: [
          Icon(BrandIcons.twitch, size: 20, color: const Color(0xFF9146FF)),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Twitch', style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary, fontWeight: FontWeight.w500,
                )),
                Text(
                  _connected ? _username : 'Not connected',
                  style: HollowTypography.caption.copyWith(
                    color: _connected ? const Color(0xFF9146FF) : hollow.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          if (_connected)
            HollowButton.ghost(
              onPressed: _disconnect,
              compact: true,
              child: const Text('Disconnect'),
            )
          else
            HollowButton.outline(
              onPressed: () {
                showTwitchDeviceCodeDialog(context, onSuccess: () {
                  _check();
                });
              },
              compact: true,
              child: const Text('Connect'),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// System Tab
// ─────────────────────────────────────────────────

class _NetworkTab extends ConsumerStatefulWidget {
  const _NetworkTab({super.key});

  @override
  ConsumerState<_NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends ConsumerState<_NetworkTab> {
  bool _showAddRelay = false;
  String _selectedRelay = '';
  late String _initialRelay;
  final _relayController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initialRelay = ref.read(relayDomainProvider);
    _selectedRelay = _initialRelay;
  }

  @override
  void dispose() {
    _relayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final identity = ref.watch(identityProvider);
    final peerId = identity.peerId ?? '';

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        // ── Peer ID ──
        _SectionLabel(label: 'Peer ID'),
        const SizedBox(height: HollowSpacing.sm),
        HollowPressable(
          onTap: () {
            Clipboard.setData(ClipboardData(text: peerId));
            HollowToast.show(context, 'Peer ID copied', type: HollowToastType.success);
          },
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(peerId,
                      style: HollowTypography.mono.copyWith(
                        color: hollow.accent, fontSize: 11,
                      ),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: HollowSpacing.sm),
                Icon(LucideIcons.copy, size: 16, color: hollow.textSecondary),
              ],
            ),
          ),
        ),

        const SizedBox(height: HollowSpacing.xl),

        // ── Network ──
        _SectionLabel(label: 'Network'),
        const SizedBox(height: HollowSpacing.sm),
        _buildRelaySection(hollow),

        const SizedBox(height: HollowSpacing.xl),
      ],
    );
  }

  Widget _buildRelaySection(HollowTheme hollow) {
    final relays = ref.watch(savedRelayListProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Your relay determines your network. Friends on a different relay won\'t be reachable.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary, fontSize: 11,
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),

        // Relay list
        for (final domain in relays) ...[
          HollowPressable(
            onTap: () => setState(() => _selectedRelay = domain),
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.md, vertical: HollowSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: _selectedRelay == domain
                    ? hollow.accentMuted
                    : hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(
                  color: _selectedRelay == domain
                      ? hollow.accent.withValues(alpha: 0.5)
                      : hollow.border,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _selectedRelay == domain
                        ? LucideIcons.circleCheck
                        : LucideIcons.circle,
                    size: 16,
                    color: _selectedRelay == domain
                        ? hollow.accent
                        : hollow.textSecondary,
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(domain,
                                  style: HollowTypography.bodySmall.copyWith(
                                    color: hollow.textPrimary,
                                  ),
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            if (domain == kDefaultRelayDomain) ...[
                              const SizedBox(width: HollowSpacing.xs),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: hollow.accent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text('Official',
                                    style: HollowTypography.caption.copyWith(
                                      color: hollow.accent,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w600,
                                    )),
                              ),
                            ],
                          ],
                        ),
                        if (domain == _initialRelay)
                          Text('Currently active',
                              style: HollowTypography.caption.copyWith(
                                color: hollow.textSecondary, fontSize: 10,
                              )),
                      ],
                    ),
                  ),
                  if (domain != kDefaultRelayDomain)
                    HollowPressable(
                      onTap: () {
                        ref.read(savedRelayListProvider.notifier).removeRelay(domain);
                        if (_selectedRelay == domain) {
                          setState(() => _selectedRelay = kDefaultRelayDomain);
                        }
                      },
                      semanticLabel: 'Remove relay',
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      padding: const EdgeInsets.all(HollowSpacing.xs),
                      child: Icon(LucideIcons.x, size: 14, color: hollow.textSecondary),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: HollowSpacing.xs),
        ],

        const SizedBox(height: HollowSpacing.sm),

        // Add relay
        if (_showAddRelay) ...[
          Row(
            children: [
              Expanded(
                child: HollowTextField(
                  controller: _relayController,
                  hintText: 'relay.example.com',
                  isDense: true,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                compact: true,
                onPressed: () {
                  final domain = _relayController.text.trim();
                  if (domain.isEmpty) return;
                  if (relays.contains(domain)) {
                    HollowToast.show(context, 'Already in list',
                        type: HollowToastType.error);
                    return;
                  }
                  ref.read(savedRelayListProvider.notifier).addRelay(domain);
                  setState(() {
                    _selectedRelay = domain;
                    _relayController.clear();
                    _showAddRelay = false;
                  });
                },
                child: const Text('Add'),
              ),
              const SizedBox(width: HollowSpacing.xs),
              HollowButton.ghost(
                compact: true,
                onPressed: () => setState(() => _showAddRelay = false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ] else
          HollowButton.ghost(
            compact: true,
            icon: const Icon(LucideIcons.plus, size: 14),
            onPressed: () => setState(() => _showAddRelay = true),
            child: const Text('Add Relay'),
          ),

        // Apply & Close (only when relay changed)
        if (_selectedRelay != _initialRelay) ...[
          const SizedBox(height: HollowSpacing.md),
          HollowButton.filled(
            expand: true,
            onPressed: () async {
              await ref.read(relayDomainProvider.notifier).setDomain(_selectedRelay);
              try {
                await network_api.notifyShutdown();
              } catch (_) {}
              await Future.delayed(const Duration(milliseconds: 200));
              SystemNavigator.pop();
            },
            child: const Text('Apply & Close App'),
          ),
          Text(
            'App will close. Reopen to connect to the new relay.',
            textAlign: TextAlign.center,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 10,
            ),
          ),
        ],

      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Category sub-pages (split from the old monolithic System/Security tabs to
// mirror the desktop category rail). Each composes the already-modular
// section widgets below.
// ─────────────────────────────────────────────────

class _AppearanceTab extends StatelessWidget {
  const _AppearanceTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: const [
        _SectionLabel(label: 'Theme'),
        SizedBox(height: HollowSpacing.sm),
        _ThemeToggleRow(),
        SizedBox(height: HollowSpacing.md),
        _AccentHueSection(),
        SizedBox(height: HollowSpacing.xl),
        _SectionLabel(label: 'Background'),
        SizedBox(height: HollowSpacing.sm),
        _BackgroundSection(),
        SizedBox(height: HollowSpacing.xl),
        _SectionLabel(label: 'Layout'),
        SizedBox(height: HollowSpacing.sm),
        _InvisibleToggleRow(),
        SizedBox(height: HollowSpacing.xl),
      ],
    );
  }
}

class _AccessibilityTab extends StatelessWidget {
  const _AccessibilityTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: const [
        _SectionLabel(label: 'Motion'),
        SizedBox(height: HollowSpacing.sm),
        _ReduceMotionRow(),
        SizedBox(height: HollowSpacing.xl),
        _SectionLabel(label: 'Transparency'),
        SizedBox(height: HollowSpacing.sm),
        _ReduceTransparencyRow(),
        SizedBox(height: HollowSpacing.xl),
      ],
    );
  }
}

class _AudioTab extends StatelessWidget {
  const _AudioTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        _SectionLabel(label: 'Voice & Audio'),
        const SizedBox(height: HollowSpacing.sm),
        _AudioQualityPicker(),
        const SizedBox(height: HollowSpacing.md),
        _MicGainSlider(),
        const SizedBox(height: HollowSpacing.md),
        _AudioProcessingInfo(),
        const SizedBox(height: HollowSpacing.xl),
        _SectionLabel(label: 'Ringtone'),
        const SizedBox(height: HollowSpacing.sm),
        _RingtonePicker(),
        const SizedBox(height: HollowSpacing.md),
        _RingtoneVolumeSlider(),
        const SizedBox(height: HollowSpacing.xl),
      ],
    );
  }
}

class _StorageTab extends StatelessWidget {
  const _StorageTab({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: const [
        _SectionLabel(label: 'Usage'),
        SizedBox(height: HollowSpacing.sm),
        StorageBreakdownView(),
        SizedBox(height: HollowSpacing.xl),
        _SectionLabel(label: 'Cache Limits'),
        SizedBox(height: HollowSpacing.sm),
        _AutoDownloadSlider(),
        SizedBox(height: HollowSpacing.lg),
        _FilesCacheCapSlider(),
        SizedBox(height: HollowSpacing.lg),
        _CacheCapSlider(),
        SizedBox(height: HollowSpacing.xl),
        _SectionLabel(label: 'Media'),
        SizedBox(height: HollowSpacing.sm),
        _ImageQualityPicker(),
        SizedBox(height: HollowSpacing.xl),
      ],
    );
  }
}

class _DevicesTab extends ConsumerWidget {
  const _DevicesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        _SectionLabel(label: 'Your Devices'),
        const SizedBox(height: HollowSpacing.sm),
        const _DevicesSectionMobile(),
        const SizedBox(height: HollowSpacing.xl),
        _SectionLabel(label: 'Link a Device'),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Link another device to this account. Show a code here, then enter it '
          'on your other (empty) device to copy your messages, friends and '
          'profile across. Keep both devices online during the transfer.',
          style: HollowTypography.body
              .copyWith(color: hollow.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: HollowSpacing.sm),
        const _LinkDeviceButton(),
        const SizedBox(height: HollowSpacing.lg),
        Text(
          'If leftover or ghost devices still show as linked, reset the device '
          'list. This permanently removes ALL your other devices (they get '
          'signed out and your friends drop them); only this device remains. '
          'Re-link any device you still want.',
          style: HollowTypography.body
              .copyWith(color: hollow.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: HollowSpacing.sm),
        const _ResetDeviceListButton(),
      ],
    );
  }
}

class _BackupTab extends StatelessWidget {
  const _BackupTab({super.key});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        _SectionLabel(label: 'Account Backup'),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          'Export an encrypted backup of your identity and messages. '
          'To restore it, reinstall and choose "Restore from backup" on '
          'the welcome screen.',
          style: HollowTypography.body
              .copyWith(color: hollow.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: HollowSpacing.sm),
        const _BackupExportButton(),
        if (Platform.isIOS) ...[
          const SizedBox(height: HollowSpacing.xl),
          _SectionLabel(label: 'Push Diagnostics'),
          const SizedBox(height: HollowSpacing.sm),
          const _ExportPushDiagnosticsButton(),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Appearance widgets
// ─────────────────────────────────────────────────

class _ThemeToggleRow extends ConsumerWidget {
  const _ThemeToggleRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final themeMode = ref.watch(themeModeProvider);
    final isDark = themeMode == ThemeMode.dark;

    return Row(
      children: [
        Icon(isDark ? LucideIcons.moon : LucideIcons.sun,
            size: 18, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Text('Dark Mode', style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
          )),
        ),
        Switch(
          value: isDark,
          onChanged: (v) =>
              ref.read(themeModeProvider.notifier).setMode(
                  v ? ThemeMode.dark : ThemeMode.light),
          activeTrackColor: hollow.accent,
          activeColor: Colors.white,
          inactiveTrackColor: hollow.border,
        ),
      ],
    );
  }
}

class _AccentHueSection extends ConsumerWidget {
  const _AccentHueSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final currentHue = ref.watch(accentHueProvider);
    final presets = ref.watch(accentPresetsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label row with color preview
        Row(
          children: [
            Icon(LucideIcons.palette, size: 18, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Text('Accent Color', style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
            )),
            const Spacer(),
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: accentFromHue(currentHue),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.2),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),

        // Rainbow hue slider
        SizedBox(
          height: 28,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 16,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 10,
                elevation: 2,
              ),
              thumbColor: Colors.white,
              overlayShape: SliderComponentShape.noOverlay,
              trackShape: RainbowSliderTrackShape(),
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
            ),
            child: Slider(
              value: currentHue.clamp(0, 359),
              min: 0,
              max: 359,
              onChanged: (value) =>
                  ref.read(accentHueProvider.notifier).setHue(value),
            ),
          ),
        ),

        const SizedBox(height: HollowSpacing.sm),

        // Preset swatches
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            // Default teal
            _MobileColorSwatch(
              hue: defaultAccentHue,
              isSelected: (currentHue - defaultAccentHue).abs() < 1,
              onTap: () => ref.read(accentHueProvider.notifier).setHue(defaultAccentHue),
            ),
            // Saved presets
            for (final hue in presets)
              _MobileColorSwatch(
                hue: hue,
                isSelected: (currentHue - hue).abs() < 1,
                onTap: () => ref.read(accentHueProvider.notifier).setHue(hue),
                onLongPress: () {
                  ref.read(accentPresetsProvider.notifier).removePreset(hue);
                  HollowToast.show(context, 'Preset removed',
                      type: HollowToastType.info);
                },
              ),
            // Save current button
            if (!presets.any((h) => (h - currentHue).abs() < 1) &&
                (currentHue - defaultAccentHue).abs() > 1)
              GestureDetector(
                onTap: () {
                  ref.read(accentPresetsProvider.notifier).addPreset(currentHue);
                  HollowToast.show(context, 'Preset saved',
                      type: HollowToastType.success);
                },
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: hollow.textSecondary.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Icon(LucideIcons.plus, size: 14, color: hollow.textSecondary),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _MobileColorSwatch extends StatelessWidget {
  final double hue;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _MobileColorSwatch({
    required this.hue,
    required this.isSelected,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: accentFromHue(hue),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected
                ? Colors.white
                : Colors.white.withValues(alpha: 0.15),
            width: isSelected ? 2.5 : 1,
          ),
        ),
      ),
    );
  }
}

class _BackgroundSection extends ConsumerWidget {
  const _BackgroundSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final bg = ref.watch(backgroundProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.image, size: 18, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Text('Background', style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
              )),
            ),
            HollowButton.ghost(
              compact: true,
              onPressed: () async {
                final result = await FilePicker.platform.pickFiles(type: FileType.image);
                if (result == null || result.files.isEmpty) return;
                final bytes = await result.files.first.xFile.readAsBytes();
                if (!context.mounted) return;

                final isMobile = Platform.isAndroid || Platform.isIOS;
                final bgAspect = isMobile ? 9.0 / 16.0 : 16.0 / 9.0;
                final cropped = isMobile
                    ? await showMobileImageCrop(
                        context: context,
                        imageBytes: bytes,
                        aspectRatio: bgAspect,
                        title: 'Crop Background',
                      )
                    : await showImageCropDialog(
                        context: context,
                        imageBytes: bytes,
                        aspectRatio: bgAspect,
                        title: 'Crop Background',
                      );
                if (cropped == null) return;
                ref.read(backgroundProvider.notifier).setImage(cropped);
              },
              child: Text(bg.hasBackground ? 'Change' : 'Set Image'),
            ),
            if (bg.hasBackground) ...[
              const SizedBox(width: HollowSpacing.xs),
              HollowButton.ghost(
                compact: true,
                onPressed: () => ref.read(backgroundProvider.notifier).clearImage(),
                child: const Text('Remove'),
              ),
            ],
          ],
        ),

        // Opacity slider (only when background is set)
        if (bg.hasBackground) ...[
          const SizedBox(height: HollowSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Panel Opacity', style: HollowTypography.bodySmall.copyWith(
                color: hollow.textSecondary,
              )),
              Text('${(bg.panelOpacity * 100).round()}%',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.accent, fontWeight: FontWeight.w600,
                  )),
            ],
          ),
          Slider(
            value: bg.panelOpacity.clamp(0.0, 0.92),
            min: 0.0,
            max: 0.92,
            divisions: 23,
            activeColor: hollow.accent,
            inactiveColor: hollow.border,
            onChanged: (v) => ref.read(backgroundProvider.notifier).setOpacity(v),
          ),
        ],
      ],
    );
  }
}

class _ReduceMotionRow extends ConsumerWidget {
  const _ReduceMotionRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final mode =
        ref.watch(reduceMotionProvider).valueOrNull ?? ReduceMotionMode.auto;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.zap, size: 18, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reduce Motion',
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                      )),
                  Text('Auto follows your system setting',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary, fontSize: 11,
                      )),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
        _MobileSegment<ReduceMotionMode>(
          value: mode,
          options: const [
            (ReduceMotionMode.auto, 'Auto'),
            (ReduceMotionMode.on, 'On'),
            (ReduceMotionMode.off, 'Off'),
          ],
          onChanged: (m) => ref.read(reduceMotionProvider.notifier).setMode(m),
        ),
      ],
    );
  }
}

class _ReduceTransparencyRow extends ConsumerWidget {
  const _ReduceTransparencyRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final on = ref.watch(reduceTransparencyProvider).valueOrNull ?? false;

    return Row(
      children: [
        Icon(LucideIcons.square, size: 18, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Reduce Transparency', style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
              )),
              Text('Turn off background blur and glass effects',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary, fontSize: 11,
                  )),
            ],
          ),
        ),
        Switch(
          value: on,
          onChanged: (v) =>
              ref.read(reduceTransparencyProvider.notifier).setEnabled(v),
          activeTrackColor: hollow.accent,
          activeColor: Colors.white,
          inactiveTrackColor: hollow.border,
        ),
      ],
    );
  }
}

/// Horizontal segmented control for a small set of mutually-exclusive options.
class _MobileSegment<T> extends StatelessWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;

  const _MobileSegment({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: hollow.border),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        children: [
          for (final (opt, label) in options)
            Expanded(
              child: HollowPressable(
                onTap: () => onChanged(opt),
                borderRadius: BorderRadius.circular(6),
                child: AnimatedContainer(
                  duration: HollowDurations.fast,
                  alignment: Alignment.center,
                  padding:
                      const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
                  decoration: BoxDecoration(
                    color: opt == value ? hollow.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    label,
                    style: HollowTypography.body.copyWith(
                      color: opt == value
                          ? hollow.textOnAccent
                          : hollow.textSecondary,
                      fontWeight:
                          opt == value ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InvisibleToggleRow extends ConsumerWidget {
  const _InvisibleToggleRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final invisible = ref.watch(invisibleModeProvider);

    return Row(
      children: [
        Icon(LucideIcons.eyeOff, size: 18, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Appear Invisible', style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
              )),
              Text('Show as offline to other users',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary, fontSize: 11,
                  )),
            ],
          ),
        ),
        Switch(
          value: invisible,
          onChanged: (v) =>
              ref.read(invisibleModeProvider.notifier).setInvisible(v),
          activeTrackColor: hollow.accent,
          activeColor: Colors.white,
          inactiveTrackColor: hollow.border,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Files section widgets
// ─────────────────────────────────────────────────

class _ImageQualityPicker extends ConsumerWidget {
  const _ImageQualityPicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncQuality = ref.watch(imageQualityProvider);
    final current = asyncQuality.valueOrNull ?? ImageQuality.balanced;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Image Quality', style: HollowTypography.bodySmall.copyWith(
          color: hollow.textSecondary,
        )),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: ImageQuality.values.map((q) {
            final isSelected = q == current;
            final shortLabel = switch (q) {
              ImageQuality.lossless => 'Lossless',
              ImageQuality.balanced => 'Balanced',
              ImageQuality.small => 'Small',
            };
            return Padding(
              padding: const EdgeInsets.only(right: HollowSpacing.sm),
              child: HollowPressable(
                onTap: () => ref.read(imageQualityProvider.notifier).setQuality(q),
                borderRadius: BorderRadius.circular(20),
                backgroundColor: isSelected ? hollow.accent : hollow.surface,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md, vertical: HollowSpacing.sm,
                ),
                child: Text(shortLabel,
                    style: HollowTypography.caption.copyWith(
                      color: isSelected ? hollow.textOnAccent : hollow.textSecondary,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    )),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(current.description,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11,
            )),
      ],
    );
  }
}

class _AutoDownloadSlider extends ConsumerWidget {
  const _AutoDownloadSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncVal = ref.watch(autoDownloadThresholdProvider);
    final value = asyncVal.valueOrNull ?? 169;

    final label = value >= 1024
        ? '${(value / 1024).toStringAsFixed(1)} GB'
        : '$value MB';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Auto-Download', style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            )),
            Text(label, style: HollowTypography.caption.copyWith(
              color: hollow.accent, fontWeight: FontWeight.w600,
            )),
          ],
        ),
        Slider(
          value: value.toDouble().clamp(34, 2048),
          min: 34,
          max: 2048,
          divisions: 50,
          activeColor: hollow.accent,
          inactiveColor: hollow.border,
          onChanged: (v) =>
              ref.read(autoDownloadThresholdProvider.notifier).setThreshold(v.round()),
        ),
        Text('Files up to this size auto-download',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11,
            )),
      ],
    );
  }
}

class _CacheCapSlider extends ConsumerWidget {
  const _CacheCapSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncVal = ref.watch(vaultCacheCapProvider);
    final value = asyncVal.valueOrNull ?? 1024;

    final label = value >= 1024
        ? '${(value / 1024).toStringAsFixed(1)} GB'
        : '$value MB';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Vault Cache Limit', style: HollowTypography.bodySmall.copyWith(
              color: hollow.textSecondary,
            )),
            Text(label, style: HollowTypography.caption.copyWith(
              color: hollow.accent, fontWeight: FontWeight.w600,
            )),
          ],
        ),
        Slider(
          value: value.toDouble().clamp(256, 10240),
          min: 256,
          max: 10240,
          divisions: 40,
          activeColor: hollow.accent,
          inactiveColor: hollow.border,
          onChanged: (v) =>
              ref.read(vaultCacheCapProvider.notifier).setCap(v.round()),
        ),
        Text('LRU-evicted cache for vault file/video playback',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11,
            )),
      ],
    );
  }
}

class _FilesCacheCapSlider extends ConsumerWidget {
  const _FilesCacheCapSlider();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncVal = ref.watch(filesCacheCapProvider);
    final value = asyncVal.valueOrNull ?? 5120;

    final label = '${(value / 1024).toStringAsFixed(1)} GB';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Downloaded Files Limit',
                style: HollowTypography.bodySmall.copyWith(
                  color: hollow.textSecondary,
                )),
            Text(label, style: HollowTypography.caption.copyWith(
              color: hollow.accent, fontWeight: FontWeight.w600,
            )),
          ],
        ),
        Slider(
          value: value.toDouble().clamp(512, 51200),
          min: 512,
          max: 51200,
          divisions: 99,
          activeColor: hollow.accent,
          inactiveColor: hollow.border,
          onChanged: (v) =>
              ref.read(filesCacheCapProvider.notifier).setCap(v.round()),
        ),
        Text('Oldest downloads are evicted past this; messages stay re-downloadable',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11,
            )),
      ],
    );
  }
}

class _AudioQualityPicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncPreset = ref.watch(audioQualityProvider);
    final current = asyncPreset.valueOrNull ?? AudioQualityPreset.voice;

    const descriptions = {
      AudioQualityPreset.voice: '32 kbps mono — speech',
      AudioQualityPreset.music: '128 kbps stereo — music',
      AudioQualityPreset.hifi: '256 kbps stereo — lossless',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Audio Quality',
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: AudioQualityPreset.values.map((preset) {
            final isSelected = preset == current;
            return Padding(
              padding: const EdgeInsets.only(right: HollowSpacing.sm),
              child: HollowPressable(
                onTap: () => ref
                    .read(audioQualityProvider.notifier)
                    .setPreset(preset),
                borderRadius: BorderRadius.circular(20),
                backgroundColor:
                    isSelected ? hollow.accent : hollow.surface,
                padding: const EdgeInsets.symmetric(
                  horizontal: HollowSpacing.md,
                  vertical: HollowSpacing.sm,
                ),
                child: Text(
                  preset.label,
                  style: HollowTypography.caption.copyWith(
                    color: isSelected
                        ? hollow.textOnAccent
                        : hollow.textSecondary,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          descriptions[current] ?? '',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

class _MicGainSlider extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncGain = ref.watch(micGainProvider);
    final gain = asyncGain.valueOrNull ?? kMicGainDefault;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Microphone Gain',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary)),
            Text('${(gain / kMicGainDisplayUnit * 100).round()}%',
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
        Slider(
          value: gain.clamp(kMicGainMin, kMicGainMax),
          min: kMicGainMin,
          max: kMicGainMax,
          divisions: 83,
          activeColor: hollow.accent,
          inactiveColor: hollow.border,
          onChanged: (v) =>
              ref.read(micGainProvider.notifier).setGain(v),
        ),
        Text(
          'Boosts your outgoing voice (applies live during calls). '
          'A limiter at -3 dB prevents clipping.',
          style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
        ),
      ],
    );
  }
}

class _AudioProcessingInfo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Audio Processing',
            style: HollowTypography.bodySmall
                .copyWith(color: hollow.textSecondary)),
        const SizedBox(height: HollowSpacing.xs),
        _ProcessingRow(label: 'Echo Cancellation', hollow: hollow),
        _ProcessingRow(label: 'Noise Suppression', hollow: hollow),
        _ProcessingRow(label: 'Auto Gain Control', hollow: hollow),
      ],
    );
  }
}

class _ProcessingRow extends StatelessWidget {
  final String label;
  final HollowTheme hollow;
  const _ProcessingRow({required this.label, required this.hollow});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: HollowTypography.bodySmall
                  .copyWith(color: hollow.textPrimary)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.check, size: 14, color: hollow.success),
              const SizedBox(width: 4),
              Text('Auto',
                  style: HollowTypography.caption
                      .copyWith(color: hollow.textSecondary, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingtonePicker extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncPath = ref.watch(ringtonePathProvider);
    final path = asyncPath.valueOrNull;

    String displayName = 'Default';
    if (path != null && path.isNotEmpty) {
      displayName = path.split(Platform.pathSeparator).last;
      if (displayName.length > 30) {
        displayName = '${displayName.substring(0, 27)}...';
      }
    }

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ringtone',
                  style: HollowTypography.bodySmall
                      .copyWith(color: hollow.textSecondary)),
              const SizedBox(height: 2),
              Text(displayName,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                  )),
            ],
          ),
        ),
        if (path != null && path.isNotEmpty) ...[
          HollowPressable(
            onTap: () =>
                ref.read(ringtonePathProvider.notifier).setPath(null),
            semanticLabel: 'Remove ringtone',
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child:
                Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.xs),
          HollowButton.ghost(
            compact: true,
            onPressed: () => showRingtoneClipEditor(context, path),
            child: const Text('Trim'),
          ),
        ],
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          compact: true,
          onPressed: () async {
            final result = await FilePicker.platform.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['mp3', 'wav', 'ogg', 'flac', 'm4a'],
            );
            if (result != null && result.files.single.path != null) {
              final picked = result.files.single.path!;
              ref.read(ringtonePathProvider.notifier).setPath(picked);
              ref.read(ringtoneStartProvider.notifier).setStart(0.0);
              ref.read(ringtoneEndProvider.notifier).setEnd(30.0);
              final probe = AudioPlayer();
              probe.setSource(DeviceFileSource(picked)).then((_) async {
                final dur = await probe.getDuration();
                await probe.dispose();
                if (dur != null && dur.inMilliseconds > 0) {
                  final secs = dur.inMilliseconds / 1000.0;
                  ref
                      .read(ringtoneDurationProvider.notifier)
                      .setDuration(secs);
                  ref
                      .read(ringtoneEndProvider.notifier)
                      .setEnd(secs.clamp(0, 30));
                }
              });
            }
          },
          child: const Text('Choose'),
        ),
      ],
    );
  }
}

class _RingtoneVolumeSlider extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncVol = ref.watch(ringtoneVolumeProvider);
    final volume = asyncVol.valueOrNull ?? 0.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Ringtone Volume',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary)),
            Text('${(volume * 100).round()}%',
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
        Slider(
          value: volume.clamp(0.0, 1.0),
          min: 0.0,
          max: 1.0,
          divisions: 20,
          activeColor: hollow.accent,
          inactiveColor: hollow.border,
          onChanged: (v) =>
              ref.read(ringtoneVolumeProvider.notifier).setVolume(v),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Security Tab
// ─────────────────────────────────────────────────

class _SecurityTab extends ConsumerStatefulWidget {
  const _SecurityTab({super.key});

  @override
  ConsumerState<_SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends ConsumerState<_SecurityTab> {
  bool _hasPassword = false;
  bool _hasOsKeychain = false;
  bool _loading = true;
  bool _appLockBusy = false; // enabling/removing — Argon2id runs (~seconds)
  String? _lockType; // 'pin' | 'password' | null
  bool _canBiometric = false;
  bool _biometricEnabled = false;

  static bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final status = await identity_api.getIdentityProtectionStatus();
      final appLock = AppLockService();
      final lockType = await appLock.getLockType();
      final canBio = await appLock.canUseBiometrics();
      final bioEnabled = await appLock.isBiometricEnabled();
      if (mounted) {
        setState(() {
          _hasPassword = status.hasPassword;
          _hasOsKeychain = status.hasOsKeychain;
          _lockType = lockType;
          _canBiometric = canBio;
          _biometricEnabled = bioEnabled;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        // App Lock section
        _SectionLabel(label: 'App Lock'),
        const SizedBox(height: HollowSpacing.sm),
        Container(
          padding: const EdgeInsets.all(HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.border),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.lock, size: 20, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('App Lock', style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                    )),
                    Text(
                      _hasPassword
                          ? (_lockType == 'pin'
                              ? 'PIN enabled'
                              : 'Password enabled')
                          : 'Not set',
                      style: HollowTypography.caption.copyWith(
                        color: _hasPassword ? hollow.success : hollow.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              if (_appLockBusy)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: hollow.accent,
                  ),
                )
              else
                HollowButton.outline(
                  onPressed: _hasPassword ? _removeAppLock : _enableAppLock,
                  compact: true,
                  child: Text(_hasPassword ? 'Remove' : 'Enable'),
                ),
            ],
          ),
        ),

        // Biometric unlock — only when App Lock is on and the device has an
        // enrolled fingerprint / Face ID.
        if (_isMobilePlatform && _hasPassword && _canBiometric) ...[
          const SizedBox(height: HollowSpacing.md),
          Container(
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.fingerprint,
                    size: 20, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        Platform.isIOS
                            ? 'Face ID / Touch ID'
                            : 'Fingerprint / face unlock',
                        style: HollowTypography.body
                            .copyWith(color: hollow.textPrimary),
                      ),
                      Text(
                        'Unlock without typing your '
                        '${_lockType == 'pin' ? 'PIN' : 'password'}',
                        style: HollowTypography.caption
                            .copyWith(color: hollow.textSecondary),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _biometricEnabled,
                  activeThumbColor: hollow.accent,
                  onChanged: (v) => _toggleBiometric(v),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: HollowSpacing.md),

        // Device protection
        if (Platform.isWindows || Platform.isMacOS) ...[
          Container(
            padding: const EdgeInsets.all(HollowSpacing.md),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.shield, size: 20, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Device Protection', style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary,
                      )),
                      Text(
                        _hasOsKeychain ? 'Enabled' : 'Not set',
                        style: HollowTypography.caption.copyWith(
                          color: _hasOsKeychain ? hollow.success : hollow.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                HollowButton.outline(
                  onPressed: _hasOsKeychain ? _disableKeychain : _enableKeychain,
                  compact: true,
                  child: Text(_hasOsKeychain ? 'Disable' : 'Enable'),
                ),
              ],
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
        ],

        const SizedBox(height: HollowSpacing.xl),

        // Recovery phrase
        _SectionLabel(label: 'Recovery'),
        const SizedBox(height: HollowSpacing.sm),
        _RecoveryPhraseButton(),
        const SizedBox(height: HollowSpacing.xl),
      ],
    );
  }

  Future<void> _enableAppLock() async {
    // Mobile: choose PIN or password. Desktop layouts keep password only.
    final type = _isMobilePlatform ? await _chooseLockType() : 'password';
    if (type == null) return;
    if (!mounted) return;
    final isPin = type == 'pin';
    final secret = await _askSecret(context, confirm: true, isPin: isPin);
    if (secret == null || secret.isEmpty) return;
    if (mounted) setState(() => _appLockBusy = true);
    try {
      await identity_api.enablePasswordProtection(
        password: secret, requireOnLaunch: true,
      );
      final appLock = AppLockService();
      await appLock.setLockType(type);
      await appLock.disableBiometric(); // any old stored secret is stale now
      appLock.sessionSecret = secret;
      await _loadStatus();
      if (mounted) {
        HollowToast.show(context, isPin ? 'PIN set' : 'Password set',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed', type: HollowToastType.error);
    } finally {
      if (mounted) setState(() => _appLockBusy = false);
    }
  }

  Future<void> _removeAppLock() async {
    final isPin = _lockType == 'pin';
    final secret = await _askSecret(context, isPin: isPin);
    if (secret == null || secret.isEmpty) return;
    if (mounted) setState(() => _appLockBusy = true);
    try {
      await identity_api.removePasswordProtection(password: secret);
      await AppLockService().clearAll();
      await _loadStatus();
      if (mounted) {
        HollowToast.show(context, 'App lock removed',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, isPin ? 'Wrong PIN' : 'Wrong password',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _appLockBusy = false);
    }
  }

  Future<void> _toggleBiometric(bool enable) async {
    final appLock = AppLockService();
    if (!enable) {
      await appLock.disableBiometric();
      await _loadStatus();
      return;
    }
    final isPin = _lockType == 'pin';
    // Need the current secret to store behind the biometric gate. Use the
    // one captured this session (set/unlock) or ask for it.
    var secret = appLock.sessionSecret;
    secret ??= await _askSecret(context, isPin: isPin);
    if (secret == null || secret.isEmpty) return;
    // One live prompt so a broken/cancelled sensor never gets trusted.
    final ok = await appLock.promptBiometric();
    if (!ok) {
      if (mounted) {
        HollowToast.show(context, 'Biometric check failed',
            type: HollowToastType.error);
      }
      return;
    }
    await appLock.enableBiometric(secret);
    appLock.sessionSecret = secret;
    await _loadStatus();
    if (mounted) {
      HollowToast.show(context, 'Biometric unlock enabled',
          type: HollowToastType.success);
    }
  }

  /// Bottom sheet: PIN or password?
  Future<String?> _chooseLockType() async {
    final hollow = HollowTheme.of(context);
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: HollowSpacing.sm),
            Container(
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: hollow.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Text('Choose lock type',
                style: HollowTypography.subheading
                    .copyWith(color: hollow.textPrimary)),
            const SizedBox(height: HollowSpacing.md),
            _LockTypeOption(
              icon: LucideIcons.hash,
              title: 'PIN',
              subtitle: '4-8 digits, quick to type',
              onTap: () => Navigator.pop(ctx, 'pin'),
            ),
            _LockTypeOption(
              icon: LucideIcons.keyRound,
              title: 'Password',
              subtitle: 'Anything you like, stronger',
              onTap: () => Navigator.pop(ctx, 'password'),
            ),
            // Biometric is a layer on top of a PIN/password, not a lock type
            // of its own — show it here (grayed out) so it's discoverable.
            _LockTypeOption(
              icon: LucideIcons.fingerprint,
              title: Platform.isIOS
                  ? 'Face ID / Touch ID'
                  : 'Fingerprint / face unlock',
              subtitle: 'Available once a PIN or password is set',
              onTap: null,
            ),
            const SizedBox(height: HollowSpacing.lg),
          ],
        ),
      ),
    );
  }

  Future<void> _enableKeychain() async {
    try {
      await identity_api.enableOsKeychainProtection();
      await _loadStatus();
      if (mounted) HollowToast.show(context, 'Device protection enabled', type: HollowToastType.success);
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed', type: HollowToastType.error);
    }
  }

  Future<void> _disableKeychain() async {
    try {
      await identity_api.disableOsKeychainProtection();
      await _loadStatus();
      if (mounted) HollowToast.show(context, 'Device protection disabled', type: HollowToastType.success);
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed', type: HollowToastType.error);
    }
  }

  Future<String?> _askSecret(BuildContext context,
      {bool confirm = false, bool isPin = false}) async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    final label = isPin ? 'PIN' : 'Password';
    return showHollowDialog<String>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: confirm ? 'Set $label' : 'Enter $label',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowTextField(
              controller: controller,
              hintText: label,
              obscureText: true,
              autofocus: true,
              keyboardType: isPin ? TextInputType.number : null,
              inputFormatters:
                  isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
              maxLength: isPin ? 8 : null,
              showCounter: false,
            ),
            if (confirm) ...[
              const SizedBox(height: HollowSpacing.md),
              HollowTextField(
                controller: confirmController,
                hintText: 'Confirm $label',
                obscureText: true,
                keyboardType: isPin ? TextInputType.number : null,
                inputFormatters:
                    isPin ? [FilteringTextInputFormatter.digitsOnly] : null,
                maxLength: isPin ? 8 : null,
                showCounter: false,
              ),
            ],
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () {
              final pw = controller.text;
              if (pw.isEmpty) return;
              if (isPin && confirm && pw.length < 4) {
                HollowToast.show(ctx, 'PIN must be at least 4 digits',
                    type: HollowToastType.error);
                return;
              }
              if (confirm && pw != confirmController.text) {
                HollowToast.show(ctx, '${label}s do not match',
                    type: HollowToastType.error);
                return;
              }
              Navigator.pop(ctx, pw);
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

class _LockTypeOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  /// Null = disabled (grayed out, not pressable). Used for the
  /// Fingerprint / Face ID entry, which only becomes available once a
  /// PIN or password is set.
  final VoidCallback? onTap;

  const _LockTypeOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final disabled = onTap == null;

    final content = Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.lg,
        vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          Icon(icon,
              size: 20,
              color: disabled ? hollow.textSecondary : hollow.accent),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: HollowTypography.body.copyWith(
                      color: disabled
                          ? hollow.textSecondary
                          : hollow.textPrimary,
                      fontWeight: FontWeight.w600,
                    )),
                Text(subtitle,
                    style: HollowTypography.caption.copyWith(
                      color: disabled
                          ? hollow.textSecondary.withValues(alpha: 0.7)
                          : hollow.textSecondary,
                    )),
              ],
            ),
          ),
          if (!disabled)
            Icon(LucideIcons.chevronRight,
                size: 16, color: hollow.textSecondary),
        ],
      ),
    );

    if (disabled) {
      return Opacity(opacity: 0.55, child: content);
    }
    return HollowPressable(onTap: onTap, subtle: true, child: content);
  }
}

class _RecoveryPhraseButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider);
    final mnemonic = identity.mnemonic;

    if (mnemonic == null || mnemonic.isEmpty) {
      return HollowButton.outline(
        onPressed: () async {
          try {
            final m = await storage_api.getMnemonic();
            if (context.mounted && m != null && m.isNotEmpty) {
              showMnemonicDialog(context, m);
            }
          } catch (e) {
            if (context.mounted) {
              HollowToast.show(context, 'No recovery phrase found',
                  type: HollowToastType.error);
            }
          }
        },
        expand: true,
        icon: const Icon(LucideIcons.key, size: 16),
        child: const Text('Recovery Phrase'),
      );
    }

    return HollowButton.outline(
      onPressed: () => showMnemonicDialog(context, mnemonic),
      expand: true,
      icon: const Icon(LucideIcons.key, size: 16),
      child: const Text('Recovery Phrase'),
    );
  }
}

/// Exports a passphrase-encrypted `.hollow` account backup.
///
/// The Rust `exportBackup` writes to a path it owns, so on mobile we export to
/// a temp file inside the app data dir, read the bytes, hand them to the system
/// file picker (`saveFile(bytes:)` — required on Android/iOS), then delete the
/// temp file. Import is handled by the first-launch welcome dialog.
class _BackupExportButton extends ConsumerStatefulWidget {
  const _BackupExportButton();

  @override
  ConsumerState<_BackupExportButton> createState() =>
      _BackupExportButtonState();
}

class _BackupExportButtonState extends ConsumerState<_BackupExportButton> {
  bool _busy = false;
  bool _includeFiles = false;
  bool _includeVault = false;

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToggleRow(
          label: 'Include downloaded files',
          value: _includeFiles,
          onChanged: _busy ? null : (v) => setState(() => _includeFiles = v),
        ),
        _ToggleRow(
          label: 'Include vault shards',
          value: _includeVault,
          onChanged: _busy ? null : (v) => setState(() => _includeVault = v),
        ),
        const SizedBox(height: HollowSpacing.sm),
        HollowButton.outline(
          onPressed: _busy ? null : _export,
          expand: true,
          icon: _busy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: hollow.accent),
                )
              : const Icon(LucideIcons.download, size: 16),
          child: Text(_busy ? 'Exporting…' : 'Export Backup'),
        ),
      ],
    );
  }

  Future<void> _export() async {
    final passphrase =
        await _askBackupPassphrase(context, 'Set Backup Passphrase');
    if (passphrase == null || !mounted) return;

    setState(() => _busy = true);
    final tmpPath =
        '$hollowDataDir/hollow-backup-export.hollow';
    try {
      await storage_api.exportBackup(
        outputPath: tmpPath,
        includeVault: _includeVault,
        includeFiles: _includeFiles,
        passphrase: passphrase,
      );
      final bytes = await File(tmpPath).readAsBytes();
      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Backup',
        fileName: 'hollow-backup.hollow',
        bytes: bytes,
      );
      // Clean up the temp file regardless of whether the user saved.
      try {
        await File(tmpPath).delete();
      } catch (_) {}
      if (!mounted) return;
      if (savePath == null) return; // user cancelled the save sheet
      final mb = (bytes.length / (1024 * 1024)).toStringAsFixed(1);
      HollowToast.show(context, 'Backup exported ($mb MB)',
          type: HollowToastType.success);
    } catch (e) {
      try {
        await File(tmpPath).delete();
      } catch (_) {}
      if (mounted) {
        HollowToast.show(context, 'Export failed: $e',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Simple label + Switch row used by the backup export options.
class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(label, style: HollowTypography.body.copyWith(
            color: hollow.textPrimary, fontSize: 13,
          )),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeTrackColor: hollow.accent,
          activeColor: Colors.white,
          inactiveTrackColor: hollow.border,
        ),
      ],
    );
  }
}

/// Compact passphrase prompt with confirmation, keyboard-aware via
/// showHollowDialog (which strips/pads viewInsets globally).
Future<String?> _askBackupPassphrase(
    BuildContext context, String title) async {
  final controller = TextEditingController();
  final confirmController = TextEditingController();
  return showHollowDialog<String>(
    context: context,
    builder: (ctx) {
      return HollowDialog(
        title: title,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            HollowTextField(
              controller: controller,
              obscureText: true,
              autofocus: true,
              hintText: 'Enter passphrase',
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowTextField(
              controller: confirmController,
              obscureText: true,
              hintText: 'Confirm passphrase',
            ),
          ],
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(null),
            compact: true,
            child: const Text('Cancel'),
          ),
          const SizedBox(width: HollowSpacing.sm),
          HollowButton.filled(
            onPressed: () {
              final pass = controller.text.trim();
              if (pass.isEmpty) return;
              if (pass != confirmController.text.trim()) {
                HollowToast.show(ctx, 'Passphrases don\'t match',
                    type: HollowToastType.error);
                return;
              }
              Navigator.of(ctx).pop(pass);
            },
            compact: true,
            child: const Text('Encrypt'),
          ),
        ],
      );
    },
  );
}

/// iOS-only: bundle the Notification Service Extension's footprint/metrics log
/// (written into the App Group) + the app's push_debug.log into one text file and
/// save it via the file picker, so it can be shared back for diagnosis. There's
/// no debugger access on TestFlight builds — this is how we read the NSE's
/// runtime memory and whether the on-device fetch+decrypt succeeded.
/// Opens the multi-device link flow in show-code mode (this device has the data;
/// an empty device enters the code to pull a full snapshot). Mirrors the desktop
/// Settings → Security entry.
/// Step 8 — the "Your Devices" list (mobile twin of `_DevicesSection`).
String _shortenPeerIdMobile(String id) =>
    id.length <= 12 ? id : '${id.substring(0, 6)}…${id.substring(id.length - 4)}';

/// Whether a device is "active" — worth showing by default (online / this device /
/// labeled). Offline+unlabeled ghosts from re-link cycles fold behind "Show all".
bool _deviceIsActiveMobile(MyDevice d) =>
    d.online || d.isThisDevice || d.label.isNotEmpty;

class _DevicesSectionMobile extends ConsumerStatefulWidget {
  const _DevicesSectionMobile();
  @override
  ConsumerState<_DevicesSectionMobile> createState() => _DevicesSectionMobileState();
}

class _DevicesSectionMobileState extends ConsumerState<_DevicesSectionMobile> {
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    // Re-pull the device list from the running node's resolver whenever this
    // panel opens. The startup warm-up (event_provider) races node readiness and
    // there's no live listener keeping deviceLinkProvider fresh while Settings is
    // closed — so after an app restart the list would render empty/stale even
    // though the data is persisted in the DB. Refreshing on mount fixes the
    // "devices disappear after restart" bug.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(deviceLinkProvider.notifier).refresh();
      ref.read(deviceLabelProvider.notifier).refresh();
      ref.invalidate(localDevicePeerIdProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final devices = ref.watch(myDevicesProvider);

    if (devices.length <= 1) {
      return Text(
        'Only this device is linked to your account. Link another below to sync '
        'your messages, friends and profile across devices.',
        style: HollowTypography.body.copyWith(color: hollow.textSecondary, fontSize: 12),
      );
    }

    final ghosts = devices.where((d) => !_deviceIsActiveMobile(d)).toList();
    final shown = _showAll
        ? devices
        : devices.where(_deviceIsActiveMobile).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Devices linked to your account. Remove a device you no longer use or '
          'have lost — it can no longer read your messages once removed.',
          style: HollowTypography.body.copyWith(color: hollow.textSecondary, fontSize: 12),
        ),
        const SizedBox(height: HollowSpacing.sm),
        for (final d in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
            child: _DeviceRowMobile(device: d),
          ),
        if (ghosts.isNotEmpty)
          HollowButton.ghost(
            compact: true,
            onPressed: () => setState(() => _showAll = !_showAll),
            child: Text(_showAll
                ? 'Hide old devices'
                : 'Show all (${ghosts.length} offline)'),
          ),
      ],
    );
  }
}

class _DeviceRowMobile extends ConsumerWidget {
  final MyDevice device;
  const _DeviceRowMobile({required this.device});

  Future<void> _rename(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(text: device.label);
    final saved = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Rename device',
        content: HollowTextField(
          controller: controller,
          hintText: 'e.g. My Pixel',
          autofocus: true,
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved == true) {
      await ref
          .read(deviceLabelProvider.notifier)
          .setLabel(device.peerId, controller.text.trim());
    }
  }

  Future<void> _syncFrom(BuildContext context, WidgetRef ref) async {
    final name = device.label.isNotEmpty ? device.label : _shortenPeerIdMobile(device.peerId);
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Sync from this device?',
        content: Text(
          'Pull servers and friends FROM "$name" onto THIS device. Use this if a '
          'server or friend exists on "$name" but is missing here. It only adds '
          'what\'s missing — nothing is removed, and your messages are unaffected.\n\n'
          '"$name" must be online.',
          style: HollowTypography.body.copyWith(color: HollowTheme.of(ctx).textSecondary),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sync now'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!device.online) {
      if (context.mounted) {
        HollowToast.show(context, '"$name" is offline — bring it online first',
            type: HollowToastType.error);
      }
      return;
    }
    try {
      await network_api.requestStateSync(sourceDeviceId: device.peerId);
      if (context.mounted) {
        HollowToast.show(context, 'Syncing from "$name"…', type: HollowToastType.info);
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Sync failed: $e', type: HollowToastType.error);
      }
    }
  }

  Future<void> _remove(BuildContext context, WidgetRef ref) async {
    final name = device.label.isNotEmpty ? device.label : _shortenPeerIdMobile(device.peerId);
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Remove this device?',
        content: Text(
          'This permanently removes "$name" from your account. It will stop '
          'receiving your messages and is removed from your servers. This cannot '
          'be undone from the removed device.',
          style: HollowTypography.body.copyWith(color: HollowTheme.of(ctx).textSecondary),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          HollowButton.danger(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove device'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await network_api.revokeDevice(devicePeerId: device.peerId);
      if (context.mounted) {
        HollowToast.show(context, 'Device removed', type: HollowToastType.success);
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Failed to remove: $e', type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final title = device.label.isNotEmpty ? device.label : _shortenPeerIdMobile(device.peerId);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: hollow.surface,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.smartphone, size: 18, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: HollowTypography.body.copyWith(
                            color: hollow.textPrimary, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (device.isThisDevice) ...[
                      const SizedBox(width: HollowSpacing.xs),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: hollow.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          'This device',
                          style: HollowTypography.caption.copyWith(
                            color: hollow.accent,
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  '${_shortenPeerIdMobile(device.peerId)} · ${device.online ? "online" : "offline"}',
                  style: HollowTypography.caption.copyWith(color: hollow.textSecondary),
                ),
              ],
            ),
          ),
          if (!device.isThisDevice)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Sync servers & friends from this device',
              onPressed: () => _syncFrom(context, ref),
              icon: Icon(LucideIcons.refreshCw, size: 16,
                  color: device.online ? hollow.accent : hollow.textSecondary),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            onPressed: () => _rename(context, ref),
            icon: Icon(LucideIcons.pencil, size: 16, color: hollow.textSecondary),
          ),
          if (!device.isThisDevice)
            IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: () => _remove(context, ref),
              icon: Icon(LucideIcons.trash2, size: 16, color: hollow.error),
            ),
        ],
      ),
    );
  }
}

class _LinkDeviceButton extends StatelessWidget {
  const _LinkDeviceButton();

  @override
  Widget build(BuildContext context) {
    return HollowButton.filled(
      onPressed: () => showDeviceLinkDialog(context, mode: DeviceLinkMode.showCode),
      expand: true,
      icon: const Icon(LucideIcons.smartphone, size: 16),
      child: const Text('Link a device'),
    );
  }
}

class _ResetDeviceListButton extends StatelessWidget {
  const _ResetDeviceListButton();

  @override
  Widget build(BuildContext context) {
    return HollowButton.outline(
      onPressed: () => _reset(context),
      expand: true,
      icon: const Icon(LucideIcons.refreshCw, size: 16),
      child: const Text('Reset Device List'),
    );
  }

  Future<void> _reset(BuildContext context) async {
    final confirmed = await showHollowDialog<bool>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: 'Reset device list?',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This permanently removes ALL your other linked devices, not just '
              'this one. Each is signed out and wiped, and your friends stop '
              'seeing them. Only this device stays. To use another device again, '
              'link it fresh.\n\nUse this to clean up leftover or ghost devices.',
              style: HollowTypography.body.copyWith(
                  color: HollowTheme.of(ctx).textSecondary),
            ),
            const SizedBox(height: HollowSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                HollowButton.ghost(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.danger(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Reset'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    try {
      await network_api.resetDeviceLists();
      if (context.mounted) {
        HollowToast.show(
          context,
          'Device list reset. All other devices were removed.',
          type: HollowToastType.success,
        );
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Reset failed: $e',
            type: HollowToastType.error);
      }
    }
  }
}

class _ExportPushDiagnosticsButton extends StatelessWidget {
  const _ExportPushDiagnosticsButton();

  @override
  Widget build(BuildContext context) {
    return HollowButton.outline(
      onPressed: () => _export(context),
      expand: true,
      icon: const Icon(LucideIcons.fileText, size: 16),
      child: const Text('Export Push Diagnostics'),
    );
  }

  Future<void> _export(BuildContext context) async {
    final buf = StringBuffer();
    buf.writeln('=== Hollow Push Diagnostics ===');
    buf.writeln('Exported: ${DateTime.now().toIso8601String()}');
    buf.writeln('Data dir: $hollowDataDir');
    buf.writeln();

    // App Group container = parent of the (migrated) data dir.
    final container = Directory(hollowDataDir).parent.path;

    void appendFile(String label, String path) {
      buf.writeln('----- $label ($path) -----');
      try {
        final f = File(path);
        if (f.existsSync()) {
          buf.writeln(f.readAsStringSync());
        } else {
          buf.writeln('(not found)');
        }
      } catch (e) {
        buf.writeln('(read error: $e)');
      }
      buf.writeln();
    }

    appendFile('NSE metrics', '$container/push_diag/nse_metrics.log');
    appendFile('App active heartbeat', '$container/push_diag/app_active.txt');
    appendFile('Dart push log', '$hollowDataDir/push_debug.log');
    appendFile('Hollow debug log (tail)', '$hollowDataDir/hollow_debug.log');

    final bytes = Uint8List.fromList(utf8.encode(buf.toString()));
    try {
      final saved = await FilePicker.platform.saveFile(
        dialogTitle: 'Export Push Diagnostics',
        fileName: 'hollow_push_diag.txt',
        bytes: bytes, // required on iOS/Android
      );
      if (context.mounted) {
        HollowToast.show(
          context,
          saved == null ? 'Export cancelled' : 'Diagnostics exported',
          type: saved == null ? HollowToastType.info : HollowToastType.success,
        );
      }
    } catch (e) {
      if (context.mounted) {
        HollowToast.show(context, 'Export failed: $e',
            type: HollowToastType.error);
      }
    }
  }
}

// ─────────────────────────────────────────────────
// About Tab
// ─────────────────────────────────────────────────

class _AboutTab extends ConsumerWidget {
  const _AboutTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final relayStats = ref.watch(relayStatsProvider);
    final newsState = ref.watch(newsProvider);
    final relayDomain = ref.watch(relayDomainProvider);
    // Single source of truth for the app version — same as desktop About
    // (Rust APP_VERSION via getCurrentVersion()), not a hardcoded string.
    final appVersion = ref.watch(updaterProvider).currentVersion;

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        // Logo + name
        Center(
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Image.asset(
                  'assets/hollow_logo_rounded.png',
                  width: 96,
                  height: 96,
                ),
              ),
              const SizedBox(height: HollowSpacing.md),
              Text('Hollow', style: HollowTypography.display.copyWith(
                color: hollow.accent,
              )),
              const SizedBox(height: HollowSpacing.xs),
              Text('Encrypted, distributed messaging',
                  style: HollowTypography.bodySmall.copyWith(
                    color: hollow.textSecondary,
                  )),
            ],
          ),
        ),

        const SizedBox(height: HollowSpacing.xl),

        _SectionLabel(label: 'Info'),
        const SizedBox(height: HollowSpacing.sm),
        _InfoRow(label: 'Version', value: appVersion.isNotEmpty ? appVersion : 'unknown'),
        _InfoRow(label: 'Platform', value: Platform.operatingSystem),
        _InfoRow(label: 'License', value: 'AGPL-3.0'),

        const SizedBox(height: HollowSpacing.xl),

        // Relay stats
        _SectionLabel(label: 'Relay'),
        const SizedBox(height: HollowSpacing.sm),
        Container(
          padding: const EdgeInsets.all(HollowSpacing.md),
          decoration: BoxDecoration(
            color: hollow.surface,
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            border: Border.all(color: hollow.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8, height: 8,
                    decoration: BoxDecoration(
                      color: relayStats.isFresh
                          ? const Color(0xFF4CAF50)
                          : hollow.textSecondary,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(relayDomain,
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary, fontSize: 13,
                          fontWeight: FontWeight.w500)),
                  ),
                  Text('${relayStats.onlineUsers} online',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.accent, fontSize: 11,
                        fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: HollowSpacing.md),
              // Memory bar
              _StatBar(
                label: 'RAM',
                value: relayStats.memLabel,
                progress: relayStats.memUsagePercent,
                color: hollow.accent,
                hollow: hollow,
              ),
              const SizedBox(height: HollowSpacing.sm),
              // Bandwidth bar
              _StatBar(
                label: 'Bandwidth',
                value: relayStats.bandwidthLabel,
                progress: relayStats.bandwidthUsagePercent,
                color: hollow.accent,
                hollow: hollow,
              ),
            ],
          ),
        ),

        const SizedBox(height: HollowSpacing.xl),

        // News
        _SectionLabel(label: 'News'),
        const SizedBox(height: HollowSpacing.sm),
        if (!newsState.hasFetched)
          Padding(
            padding: const EdgeInsets.all(HollowSpacing.lg),
            child: Center(child: SizedBox(
              width: 20, height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2, color: hollow.accent),
            )),
          )
        else if (newsState.posts.isEmpty)
          Text('No news yet',
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary))
        else
          ...newsState.posts.take(3).map((post) => Padding(
            padding: const EdgeInsets.only(bottom: HollowSpacing.md),
            child: GestureDetector(
              onTap: () => _showNewsDialog(context, post, hollow),
              child: Container(
                padding: const EdgeInsets.all(HollowSpacing.md),
                decoration: BoxDecoration(
                  color: hollow.surface,
                  borderRadius: BorderRadius.circular(hollow.radiusMd),
                  border: Border.all(color: hollow.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(post.title,
                              style: HollowTypography.body.copyWith(
                                color: hollow.textPrimary,
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                        ),
                        Text(post.date,
                            style: HollowTypography.caption.copyWith(
                              color: hollow.textSecondary, fontSize: 11)),
                      ],
                    ),
                    const SizedBox(height: HollowSpacing.xs),
                    Text(_plainTeaser(post.body),
                        style: HollowTypography.body.copyWith(
                          color: hollow.textSecondary, fontSize: 12),
                        maxLines: 4, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ),
          )),

        const SizedBox(height: HollowSpacing.xl),

        // Contact
        _SectionLabel(label: 'Contact'),
        const SizedBox(height: HollowSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            onPressed: () {
              Clipboard.setData(
                  const ClipboardData(text: 'feedback@anonlisten.com'));
              HollowToast.show(context, 'Email copied to clipboard',
                  type: HollowToastType.success);
            },
            icon: Icon(LucideIcons.mail, size: 16),
            child: const Text('feedback@anonlisten.com'),
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            onPressed: () => launchUrl(
              Uri.parse('https://anonlisten.com'),
              mode: LaunchMode.externalApplication,
            ),
            icon: Icon(LucideIcons.globe, size: 16),
            child: const Text('anonlisten.com'),
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            onPressed: () => launchUrl(
              Uri.parse('https://github.com/VitalikPro13/HOLLOW'),
              mode: LaunchMode.externalApplication,
            ),
            icon: Icon(BrandIcons.github, size: 16),
            child: const Text('GitHub'),
          ),
        ),

        const SizedBox(height: HollowSpacing.xl),

        // Follow & Support
        Row(
          children: [
            Text('Follow', style: HollowTypography.label.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            )),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(child: _MobileShimmerLine(hollow: hollow)),
            const SizedBox(width: HollowSpacing.sm),
            Text('Support', style: HollowTypography.label.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            )),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),
        Row(
          children: [
            _MobileBrandIcon(
              icon: BrandIcons.youtube,
              color: BrandIconColors.youtube,
              url: 'https://youtube.com/@Anon_Listen',
            ),
            const SizedBox(width: HollowSpacing.sm),
            _MobileBrandIcon(
              icon: BrandIcons.x,
              color: hollow.textPrimary,
              url: 'https://x.com/Anon_Listen',
            ),
            const SizedBox(width: HollowSpacing.sm),
            _MobileBrandIcon(
              icon: BrandIcons.twitch,
              color: BrandIconColors.twitch,
              url: 'https://twitch.tv/AnonListen',
            ),
            const SizedBox(width: HollowSpacing.sm),
            _MobileBrandIcon(
              icon: BrandIcons.kick,
              color: BrandIconColors.kick,
              url: 'https://kick.com/AnonListen',
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(child: _MobileShimmerLine(hollow: hollow)),
            const SizedBox(width: HollowSpacing.sm),
            _MobileBrandIcon(
              icon: BrandIcons.patreon,
              color: hollow.textPrimary,
              url: 'https://patreon.com/AnonListen',
            ),
            const SizedBox(width: HollowSpacing.sm),
            _MobileBrandIcon(
              icon: BrandIcons.kofi,
              color: BrandIconColors.kofi,
              url: 'https://ko-fi.com/AnonListen',
            ),
          ],
        ),

        const SizedBox(height: HollowSpacing.xl),

        // Legal
        _SectionLabel(label: 'Legal'),
        const SizedBox(height: HollowSpacing.sm),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            onPressed: () => _showLegalSheet(context, 'Privacy Policy', 'legal/PRIVACY_POLICY.md'),
            icon: Icon(LucideIcons.shield, size: 16),
            child: const Text('Privacy Policy'),
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            onPressed: () => _showLegalSheet(context, 'Terms of Use', 'legal/TERMS_OF_USE.md'),
            icon: Icon(LucideIcons.scroll, size: 16),
            child: const Text('Terms of Use'),
          ),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Align(
          alignment: Alignment.centerLeft,
          child: HollowButton.ghost(
            onPressed: () {
              showLicensePage(
                context: context,
                applicationName: 'Hollow',
                applicationVersion: 'Alpha',
                applicationIcon: Padding(
                  padding: const EdgeInsets.all(HollowSpacing.md),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      'assets/hollow_logo_rounded.png',
                      width: 48,
                      height: 48,
                    ),
                  ),
                ),
              );
            },
            icon: Icon(LucideIcons.fileText, size: 16),
            child: const Text('Open-Source Licenses'),
          ),
        ),

        const SizedBox(height: HollowSpacing.xl),
      ],
    );
  }

  static void _showLegalSheet(
      BuildContext context, String title, String assetPath) async {
    final hollow = HollowTheme.of(context);
    final text = await rootBundle.loadString(assetPath);
    final lines = text.split('\n');
    final body = lines
        .skipWhile((l) => l.startsWith('# ') || l.trim().isEmpty)
        .join('\n')
        .trim();

    if (!context.mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(hollow.radiusXl)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: hollow.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(HollowSpacing.md),
              child: Text(
                title,
                style: HollowTypography.subheading.copyWith(
                  color: hollow.textPrimary,
                ),
              ),
            ),
            Divider(color: hollow.border, height: 1),
            Expanded(
              child: Markdown(
                data: body,
                controller: scrollController,
                selectable: true,
                padding: const EdgeInsets.all(HollowSpacing.lg),
                onTapLink: (text, href, title) {
                  if (href != null) {
                    launchUrl(Uri.parse(href),
                        mode: LaunchMode.externalApplication);
                  }
                },
                styleSheet: MarkdownStyleSheet(
                  h2: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 16,
                  ),
                  h3: HollowTypography.heading.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 14,
                  ),
                  p: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    height: 1.6,
                  ),
                  listBullet: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                  ),
                  strong: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                  a: HollowTypography.body.copyWith(
                    color: hollow.accent,
                    decoration: TextDecoration.underline,
                    decorationColor: hollow.accent,
                  ),
                  blockSpacing: 12,
                  horizontalRuleDecoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: hollow.border.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showNewsDialog(BuildContext context, NewsPost post, HollowTheme hollow) {
    showHollowDialog(
      context: context,
      builder: (_) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 400, maxHeight: 500),
              padding: const EdgeInsets.all(HollowSpacing.lg),
              decoration: BoxDecoration(
                color: hollow.elevated,
                borderRadius: BorderRadius.circular(hollow.radiusLg),
                border: Border.all(color: hollow.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(post.title,
                            style: HollowTypography.heading.copyWith(
                              color: hollow.textPrimary, fontSize: 16)),
                      ),
                      HollowPressable(
                        onTap: () => Navigator.pop(context),
                        semanticLabel: 'Close',
                        borderRadius: BorderRadius.circular(hollow.radiusSm),
                        padding: const EdgeInsets.all(HollowSpacing.xs),
                        child: Icon(LucideIcons.x, size: 18,
                            color: hollow.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.xs),
                  Text(post.date,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary, fontSize: 11)),
                  const SizedBox(height: HollowSpacing.md),
                  Flexible(
                    child: SingleChildScrollView(
                      child: MarkdownBody(
                        data: post.body,
                        shrinkWrap: true,
                        selectable: true,
                        onTapLink: (text, href, title) {
                          if (href != null) {
                            launchUrl(Uri.parse(href),
                                mode: LaunchMode.externalApplication);
                          }
                        },
                        styleSheet: MarkdownStyleSheet(
                          p: HollowTypography.body.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 13,
                            height: 1.5,
                          ),
                          h2: HollowTypography.heading.copyWith(
                            color: hollow.textPrimary,
                            fontSize: 15,
                          ),
                          h3: HollowTypography.heading.copyWith(
                            color: hollow.textPrimary,
                            fontSize: 14,
                          ),
                          listBullet: HollowTypography.body.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 13,
                          ),
                          strong: HollowTypography.body.copyWith(
                            color: hollow.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                          a: HollowTypography.body.copyWith(
                            color: hollow.accent,
                            fontSize: 13,
                            decoration: TextDecoration.underline,
                            decorationColor: hollow.accent,
                          ),
                          blockSpacing: 8,
                          horizontalRuleDecoration: BoxDecoration(
                            border: Border(
                              top: BorderSide(
                                color: hollow.border.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Strip common markdown markers so the 4-line card teaser reads cleanly
  /// (the full post renders as real markdown in the expanded dialog).
  String _plainTeaser(String body) {
    return body
        .replaceAll(RegExp(r'^#{1,6}\s+', multiLine: true), '')
        .replaceAll(RegExp(r'\*\*(.+?)\*\*'), r'$1')
        .replaceAll(RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)'), r'$1')
        .replaceAll(RegExp(r'`(.+?)`'), r'$1')
        .replaceAll(RegExp(r'^\s*[-*]\s+', multiLine: true), '• ')
        .replaceAll(RegExp(r'\[(.+?)\]\((.+?)\)'), r'$1')
        .trim();
  }
}

class _StatBar extends StatelessWidget {
  final String label;
  final String value;
  final double progress;
  final Color color;
  final HollowTheme hollow;

  const _StatBar({
    required this.label,
    required this.value,
    required this.progress,
    required this.color,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11)),
            Text(value, style: HollowTypography.caption.copyWith(
              color: hollow.textPrimary, fontSize: 11,
              fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: hollow.border,
              valueColor: AlwaysStoppedAnimation(color),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────
// Shared widgets
// ─────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Expanded(child: Divider(color: hollow.border, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
          child: Text(label, style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.0,
          )),
        ),
        Expanded(child: Divider(color: hollow.border, height: 1)),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _InfoRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.sm),
      child: Row(
        children: [
          Text(label, style: HollowTypography.body.copyWith(
            color: hollow.textSecondary,
          )),
          const Spacer(),
          Text(value, style: HollowTypography.body.copyWith(
            color: valueColor ?? hollow.textPrimary,
          )),
        ],
      ),
    );
  }
}

class _MobileShimmerLine extends StatelessWidget {
  final HollowTheme hollow;
  const _MobileShimmerLine({required this.hollow});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: SharedTickers.instance.shimmer,
      builder: (context, value, _) {
        final pos = value * 4.0 - 1.5;
        return Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment(pos - 0.5, 0),
              end: Alignment(pos + 0.5, 0),
              colors: [
                hollow.border,
                hollow.accent.withValues(alpha: 0.6),
                hollow.border,
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MobileBrandIcon extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String url;

  const _MobileBrandIcon({
    required this.icon,
    required this.color,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return GestureDetector(
      onTap: () => launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: hollow.border),
        ),
        child: Icon(icon, size: 20, color: color),
      ),
    );
  }
}
