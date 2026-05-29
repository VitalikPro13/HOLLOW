import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/banner_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
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
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
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

    final cropped = await showImageCropDialog(
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

    final cropped = await showImageCropDialog(
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
                // TODO: showTwitchDeviceCodeDialog — needs device code flow on mobile
                HollowToast.show(context, 'Connect via desktop for now',
                    type: HollowToastType.info);
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

class _SystemTab extends ConsumerWidget {
  const _SystemTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final identity = ref.watch(identityProvider);
    final nodeState = ref.watch(nodeProvider);
    final peerId = identity.peerId ?? '';

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        // Peer ID
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

        // Network status
        _SectionLabel(label: 'Network'),
        const SizedBox(height: HollowSpacing.sm),
        _InfoRow(
          label: 'Node Status',
          value: nodeState.status == NodeStatus.connected ? 'Connected' : 'Connecting...',
          valueColor: nodeState.status == NodeStatus.connected ? hollow.success : hollow.warning,
        ),
        if (nodeState.error != null)
          _InfoRow(label: 'Error', value: nodeState.error!),

        const SizedBox(height: HollowSpacing.xl),

        // Voice & Audio
        _SectionLabel(label: 'Voice & Audio'),
        const SizedBox(height: HollowSpacing.sm),
        _AudioQualityPicker(),
        const SizedBox(height: HollowSpacing.md),
        _MicGainSlider(),
        const SizedBox(height: HollowSpacing.md),
        _AudioProcessingInfo(),

        const SizedBox(height: HollowSpacing.xl),

        // Ringtone
        _SectionLabel(label: 'Ringtone'),
        const SizedBox(height: HollowSpacing.sm),
        _RingtonePicker(),
        const SizedBox(height: HollowSpacing.md),
        _RingtoneVolumeSlider(),
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
    final gain = asyncGain.valueOrNull ?? 1.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Microphone Gain',
                style: HollowTypography.bodySmall
                    .copyWith(color: hollow.textSecondary)),
            Text('${gain.toStringAsFixed(1)}x',
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
        if (path != null && path.isNotEmpty)
          HollowPressable(
            onTap: () =>
                ref.read(ringtonePathProvider.notifier).setPath(null),
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child:
                Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
          ),
        const SizedBox(width: HollowSpacing.sm),
        HollowButton.ghost(
          compact: true,
          onPressed: () async {
            final result = await FilePicker.platform
                .pickFiles(type: FileType.audio);
            if (result != null && result.files.single.path != null) {
              ref
                  .read(ringtonePathProvider.notifier)
                  .setPath(result.files.single.path!);
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

// ─────────────────────────────────────────────────
// About Tab
// ─────────────────────────────────────────────────

class _AboutTab extends ConsumerWidget {
  const _AboutTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.lg),
      children: [
        // App info
        Center(
          child: Column(
            children: [
              Text('Hollow', style: HollowTypography.display.copyWith(
                color: hollow.accent,
              )),
              const SizedBox(height: HollowSpacing.xs),
              Text('v0.4.2', style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
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
        _InfoRow(label: 'Version', value: '0.4.2'),
        _InfoRow(label: 'Platform', value: Platform.operatingSystem),
        _InfoRow(label: 'License', value: 'AGPL-3.0'),

        const SizedBox(height: HollowSpacing.xl),

        _SectionLabel(label: 'Links'),
        const SizedBox(height: HollowSpacing.sm),
        Text('anonlisten.com',
            style: HollowTypography.body.copyWith(color: hollow.accent)),
        const SizedBox(height: HollowSpacing.sm),
        Text('github.com/AnonListen/Hollow',
            style: HollowTypography.body.copyWith(color: hollow.accent)),
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
