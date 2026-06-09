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
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/shared_tickers.dart';
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
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/ringtone_clip_editor_dialog.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:hollow/src/ui/dialogs/twitch_device_code_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_image_crop_route.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class MobileSettingsTab extends ConsumerStatefulWidget {
  const MobileSettingsTab({super.key});

  @override
  ConsumerState<MobileSettingsTab> createState() => _MobileSettingsTabState();
}

class _MobileSettingsTabState extends ConsumerState<MobileSettingsTab> {
  int _selectedTab = 0;

  static const _tabs = ['Profile', 'System', 'Security', 'About'];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Tab bar
        Padding(
          padding: const EdgeInsets.fromLTRB(
            HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.lg, HollowSpacing.sm,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (int i = 0; i < _tabs.length; i++) ...[
                  if (i > 0) const SizedBox(width: HollowSpacing.sm),
                  _PillTab(
                    label: _tabs[i],
                    isSelected: i == _selectedTab,
                    onTap: () => setState(() => _selectedTab = i),
                  ),
                ],
              ],
            ),
          ),
        ),

        // Content
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _buildTab(_selectedTab),
          ),
        ),
      ],
    );
  }

  Widget _buildTab(int index) {
    return switch (index) {
      0 => const _ProfileTab(key: ValueKey('profile')),
      1 => const _SystemTab(key: ValueKey('system')),
      2 => const _SecurityTab(key: ValueKey('security')),
      3 => const _AboutTab(key: ValueKey('about')),
      _ => const SizedBox.shrink(),
    };
  }
}

class _PillTab extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _PillTab({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.lg, vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected ? hollow.accent : hollow.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected ? hollow.accent : hollow.border,
          ),
        ),
        child: Text(
          label,
          style: HollowTypography.body.copyWith(
            color: isSelected ? Colors.white : hollow.textSecondary,
            fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
          ),
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

class _SystemTab extends ConsumerStatefulWidget {
  const _SystemTab({super.key});

  @override
  ConsumerState<_SystemTab> createState() => _SystemTabState();
}

class _SystemTabState extends ConsumerState<_SystemTab> {
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

        // ── Appearance ──
        _SectionLabel(label: 'Appearance'),
        const SizedBox(height: HollowSpacing.sm),
        const _ThemeToggleRow(),
        const SizedBox(height: HollowSpacing.md),
        const _AccentHueSection(),
        const SizedBox(height: HollowSpacing.md),
        const _BackgroundSection(),
        const SizedBox(height: HollowSpacing.md),
        const _AnimationsToggleRow(),
        const SizedBox(height: HollowSpacing.md),
        const _InvisibleToggleRow(),

        const SizedBox(height: HollowSpacing.xl),

        // ── Voice & Audio ──
        _SectionLabel(label: 'Voice & Audio'),
        const SizedBox(height: HollowSpacing.sm),
        _AudioQualityPicker(),
        const SizedBox(height: HollowSpacing.md),
        _MicGainSlider(),
        const SizedBox(height: HollowSpacing.md),
        _AudioProcessingInfo(),

        const SizedBox(height: HollowSpacing.xl),

        // ── Files ──
        _SectionLabel(label: 'Files'),
        const SizedBox(height: HollowSpacing.sm),
        const _ImageQualityPicker(),
        const SizedBox(height: HollowSpacing.md),
        const _CacheCapSlider(),

        const SizedBox(height: HollowSpacing.xl),

        // ── Ringtone ──
        _SectionLabel(label: 'Ringtone'),
        const SizedBox(height: HollowSpacing.sm),
        _RingtonePicker(),
        const SizedBox(height: HollowSpacing.md),
        _RingtoneVolumeSlider(),

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
                  width: 28,
                  height: 28,
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
        width: 28,
        height: 28,
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

class _AnimationsToggleRow extends ConsumerWidget {
  const _AnimationsToggleRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final asyncVal = ref.watch(disableAnimationsProvider);
    final disabled = asyncVal.valueOrNull ?? false;

    return Row(
      children: [
        Icon(LucideIcons.zap, size: 18, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Disable Animations', style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
              )),
              Text('Turn off UI transitions and effects',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary, fontSize: 11,
                  )),
            ],
          ),
        ),
        Switch(
          value: disabled,
          onChanged: (v) {
            ref.read(disableAnimationsProvider.notifier).setEnabled(v);
            HollowDurations.animationsDisabled = v;
            SharedTickers.instance.disabled = v;
            if (v) {
              SharedTickers.instance.pause();
            } else {
              SharedTickers.instance.start();
              SharedTickers.instance.resume();
            }
          },
          activeTrackColor: hollow.accent,
          activeColor: Colors.white,
          inactiveTrackColor: hollow.border,
        ),
      ],
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
            Text('Cache Size Limit', style: HollowTypography.bodySmall.copyWith(
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
        Text('LRU-evicted cache for vault files',
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
    final gain = asyncGain.valueOrNull ?? 1.3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Microphone Gain',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary)),
            Text('${(gain * 100).round()}%',
                style: HollowTypography.caption.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                )),
          ],
        ),
        Slider(
          value: gain.clamp(0.0, 2.0),
          min: 0.0,
          max: 2.0,
          divisions: 40,
          activeColor: hollow.accent,
          inactiveColor: hollow.border,
          onChanged: (v) =>
              ref.read(micGainProvider.notifier).setGain(v),
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

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  Future<void> _loadStatus() async {
    try {
      final status = await identity_api.getIdentityProtectionStatus();
      if (mounted) {
        setState(() {
          _hasPassword = status.hasPassword;
          _hasOsKeychain = status.hasOsKeychain;
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
                    Text('Password Protection', style: HollowTypography.body.copyWith(
                      color: hollow.textPrimary,
                    )),
                    Text(
                      _hasPassword ? 'Enabled' : 'Not set',
                      style: HollowTypography.caption.copyWith(
                        color: _hasPassword ? hollow.success : hollow.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              HollowButton.outline(
                onPressed: _hasPassword ? _removePassword : _setPassword,
                compact: true,
                child: Text(_hasPassword ? 'Remove' : 'Enable'),
              ),
            ],
          ),
        ),

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

        // iOS push diagnostics — exports the NSE memory footprint + push logs so
        // we can validate the Notification Service Extension fits its memory cap.
        if (Platform.isIOS) ...[
          const SizedBox(height: HollowSpacing.xl),
          _SectionLabel(label: 'Push Diagnostics'),
          const SizedBox(height: HollowSpacing.sm),
          const _ExportPushDiagnosticsButton(),
        ],
      ],
    );
  }

  Future<void> _setPassword() async {
    final password = await _askPassword(context, confirm: true);
    if (password == null || password.isEmpty) return;
    try {
      await identity_api.enablePasswordProtection(
        password: password, requireOnLaunch: true,
      );
      await _loadStatus();
      if (mounted) HollowToast.show(context, 'Password set', type: HollowToastType.success);
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed', type: HollowToastType.error);
    }
  }

  Future<void> _removePassword() async {
    final password = await _askPassword(context);
    if (password == null || password.isEmpty) return;
    try {
      await identity_api.removePasswordProtection(password: password);
      await _loadStatus();
      if (mounted) HollowToast.show(context, 'Password removed', type: HollowToastType.success);
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Wrong password', type: HollowToastType.error);
    }
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

  Future<String?> _askPassword(BuildContext context, {bool confirm = false}) async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    return showHollowDialog<String>(
      context: context,
      builder: (ctx) => HollowDialog(
        title: confirm ? 'Set Password' : 'Enter Password',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowTextField(
              controller: controller,
              hintText: 'Password',
              obscureText: true,
              autofocus: true,
            ),
            if (confirm) ...[
              const SizedBox(height: HollowSpacing.md),
              HollowTextField(
                controller: confirmController,
                hintText: 'Confirm password',
                obscureText: true,
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
              if (confirm && pw != confirmController.text) {
                HollowToast.show(ctx, 'Passwords do not match', type: HollowToastType.error);
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

/// iOS-only: bundle the Notification Service Extension's footprint/metrics log
/// (written into the App Group) + the app's push_debug.log into one text file and
/// save it via the file picker, so it can be shared back for diagnosis. There's
/// no debugger access on TestFlight builds — this is how we read the NSE's
/// runtime memory and whether the on-device fetch+decrypt succeeded.
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
                      color: relayStats.fetchCount > 0
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
                    Text(post.body,
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
                      child: Text(post.body,
                          style: HollowTypography.body.copyWith(
                            color: hollow.textSecondary,
                            fontSize: 13, height: 1.5)),
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
