import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:record/record.dart' as rec;
import 'package:win32audio/win32audio.dart' as win32audio;
import 'package:hollow/src/core/providers/accent_color_provider.dart';
import 'package:hollow/src/core/providers/background_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/layout_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/theme_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
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
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:lucide_icons/lucide_icons.dart';

/// Tracks whether the settings dialog is currently open.
bool _settingsDialogOpen = false;

/// Shows the user settings dialog, or closes it if already open (toggle).
void showUserSettingsDialog(BuildContext context, WidgetRef ref, {bool openSystemTab = false}) {
  // Toggle: if already open, close it.
  if (_settingsDialogOpen) {
    Navigator.of(context, rootNavigator: true).pop();
    return;
  }

  final localPeerId = ref.read(identityProvider).peerId;
  if (localPeerId == null) return;

  final profiles = ref.read(profileProvider);
  final currentProfile = profiles[localPeerId];

  final displayNameController = TextEditingController(
    text: currentProfile?.displayName ?? '',
  );
  final statusController = TextEditingController(
    text: currentProfile?.status ?? '',
  );
  final aboutMeController = TextEditingController(
    text: currentProfile?.aboutMe ?? '',
  );

  _settingsDialogOpen = true;

  showHollowDialog(
    context: context,
    builder: (dialogContext) {
      return _UserSettingsContent(
        localPeerId: localPeerId,
        displayNameController: displayNameController,
        statusController: statusController,
        aboutMeController: aboutMeController,
        initialTab: openSystemTab ? _SettingsTab.system : _SettingsTab.profile,
      );
    },
  ).then((_) {
    // Reset flag when dialog closes (Cancel, Save, barrier tap, or toggle).
    _settingsDialogOpen = false;
  });
}

/// Deterministic banner color from peer ID (shifted hue from avatar).
Color _bannerColorFromId(String id) {
  final hash = id.hashCode;
  final hue = ((hash % 360).abs() + 40) % 360; // Shift hue from avatar
  return HSLColor.fromAHSL(1.0, hue.toDouble(), 0.45, 0.35).toColor();
}

/// Settings tab enum.
enum _SettingsTab { profile, system, security }

class _UserSettingsContent extends ConsumerStatefulWidget {
  final String localPeerId;
  final TextEditingController displayNameController;
  final TextEditingController statusController;
  final TextEditingController aboutMeController;
  final _SettingsTab initialTab;

  const _UserSettingsContent({
    required this.localPeerId,
    required this.displayNameController,
    required this.statusController,
    required this.aboutMeController,
    this.initialTab = _SettingsTab.profile,
  });

  @override
  ConsumerState<_UserSettingsContent> createState() =>
      _UserSettingsContentState();
}

class _UserSettingsContentState extends ConsumerState<_UserSettingsContent> {
  // Track live fields for the preview card.
  String _liveDisplayName = '';
  String _liveStatus = '';

  // Pending avatar/banner (null = no change, empty = clear).
  Uint8List? _pendingAvatarBytes;
  Uint8List? _pendingBannerBytes;
  bool _avatarChanged = false;
  bool _bannerChanged = false;

  // Active tab.
  late _SettingsTab _activeTab;

  // Pending toggle states (applied only on Save).
  late bool _pendingDarkMode;
  bool _pendingMinimizeToTray = true;
  bool _initialMinimizeToTray = true;
  bool _trayInitialized = false;
  bool _pendingProxy = false;
  bool _initialProxy = false;
  bool _proxyInitialized = false;
  bool _pendingDockMode = true;
  bool _initialDockMode = true;
  bool _layoutInitialized = false;
  double _initialAccentHue = defaultAccentHue;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    _liveDisplayName = widget.displayNameController.text;
    _liveStatus = widget.statusController.text;
    widget.displayNameController.addListener(_onFieldChanged);
    widget.statusController.addListener(_onFieldChanged);
    _initialAccentHue = ref.read(accentHueProvider);

    _pendingDarkMode =
        ref.read(themeModeProvider) == ThemeMode.dark;

    // If already loaded, use the value directly.
    final trayAsync = ref.read(minimizeToTrayProvider);
    if (trayAsync.hasValue) {
      _pendingMinimizeToTray = trayAsync.value!;
      _initialMinimizeToTray = _pendingMinimizeToTray;
      _trayInitialized = true;
    }

    final proxyAsync = ref.read(proxyEnabledProvider);
    if (proxyAsync.hasValue) {
      _pendingProxy = proxyAsync.value!;
      _initialProxy = _pendingProxy;
      _proxyInitialized = true;
    }

    final layoutAsync = ref.read(layoutModeProvider);
    if (layoutAsync.hasValue) {
      _pendingDockMode = layoutAsync.value! == LayoutMode.dock;
      _initialDockMode = _pendingDockMode;
      _layoutInitialized = true;
    }
  }

  void _onFieldChanged() {
    setState(() {
      _liveDisplayName = widget.displayNameController.text;
      _liveStatus = widget.statusController.text;
    });
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final raw = await File(path).readAsBytes();
    if (!mounted) return;

    final isGif = path.toLowerCase().endsWith('.gif');
    if (isGif) {
      // Skip crop for GIFs to preserve animation — use raw bytes directly
      if (raw.length > 1000000) {
        if (mounted) HollowToast.show(context, 'GIF too large (max 1MB)', type: HollowToastType.error);
        return;
      }
      setState(() {
        _pendingAvatarBytes = Uint8List.fromList(raw);
        _avatarChanged = true;
      });
      return;
    }

    // Open crop dialog (1:1 aspect for avatar)
    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: raw,
      aspectRatio: 1.0,
      title: 'Crop Avatar',
    );
    if (cropped == null || !mounted) return;
    try {
      final processed = await network_api.processAvatar(rawBytes: cropped);
      setState(() {
        _pendingAvatarBytes = processed;
        _avatarChanged = true;
      });
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed to process image', type: HollowToastType.error);
    }
  }

  void _clearAvatar() {
    setState(() {
      _pendingAvatarBytes = Uint8List(0);
      _avatarChanged = true;
    });
  }

  Future<void> _pickBanner() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final raw = await File(path).readAsBytes();
    if (!mounted) return;

    final isGif = path.toLowerCase().endsWith('.gif');
    if (isGif) {
      // Skip crop for GIFs to preserve animation — use raw bytes directly
      if (raw.length > 2000000) {
        if (mounted) HollowToast.show(context, 'GIF too large (max 2MB)', type: HollowToastType.error);
        return;
      }
      setState(() {
        _pendingBannerBytes = Uint8List.fromList(raw);
        _bannerChanged = true;
      });
      return;
    }

    // Open crop dialog (3:1 aspect for banner)
    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: raw,
      aspectRatio: 3.0,
      title: 'Crop Banner',
    );
    if (cropped == null || !mounted) return;
    try {
      final processed = await network_api.processBanner(rawBytes: cropped);
      setState(() {
        _pendingBannerBytes = processed;
        _bannerChanged = true;
      });
    } catch (e) {
      if (mounted) HollowToast.show(context, 'Failed to process image', type: HollowToastType.error);
    }
  }

  void _clearBanner() {
    setState(() {
      _pendingBannerBytes = Uint8List(0);
      _bannerChanged = true;
    });
  }

  @override
  void dispose() {
    widget.displayNameController.removeListener(_onFieldChanged);
    widget.statusController.removeListener(_onFieldChanged);
    super.dispose();
  }

  Future<void> _onSave() async {
    final displayName = widget.displayNameController.text.trim();
    final status = widget.statusController.text.trim();
    final aboutMe = widget.aboutMeController.text.trim();

    // Apply theme change.
    ref.read(themeModeProvider.notifier).state =
        _pendingDarkMode ? ThemeMode.dark : ThemeMode.light;

    // Apply minimize to tray change.
    if (_pendingMinimizeToTray != _initialMinimizeToTray) {
      await ref
          .read(minimizeToTrayProvider.notifier)
          .setEnabled(_pendingMinimizeToTray);
    }

    // Apply proxy change.
    final proxyChanged = _pendingProxy != _initialProxy;
    if (proxyChanged) {
      await ref
          .read(proxyEnabledProvider.notifier)
          .setEnabled(_pendingProxy);
    }

    // Apply layout mode change.
    if (_pendingDockMode != _initialDockMode) {
      await ref.read(layoutModeProvider.notifier).setMode(
            _pendingDockMode ? LayoutMode.dock : LayoutMode.classic,
          );
    }

    // Save profile.
    await ref.read(profileProvider.notifier).updateMyProfile(
          displayName: displayName,
          status: status,
          aboutMe: aboutMe,
          avatarBytes: _avatarChanged ? _pendingAvatarBytes : null,
          bannerBytes: _bannerChanged ? _pendingBannerBytes : null,
        );

    if (!mounted) return;
    Navigator.of(context).pop();

    // Show restart prompt if proxy setting changed.
    if (proxyChanged && mounted) {
      _showRestartDialog(context);
    }
  }

  void _showRestartDialog(BuildContext parentContext) {
    showHollowDialog(
      context: parentContext,
      builder: (ctx) => _RestartPrompt(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Update pending minimize-to-tray once the async value resolves.
    if (!_trayInitialized) {
      ref.listen(minimizeToTrayProvider, (prev, next) {
        if (next.hasValue && !_trayInitialized) {
          setState(() {
            _pendingMinimizeToTray = next.value!;
            _initialMinimizeToTray = _pendingMinimizeToTray;
            _trayInitialized = true;
          });
        }
      });
    }

    // Update pending proxy once the async value resolves.
    if (!_proxyInitialized) {
      ref.listen(proxyEnabledProvider, (prev, next) {
        if (next.hasValue && !_proxyInitialized) {
          setState(() {
            _pendingProxy = next.value!;
            _initialProxy = _pendingProxy;
            _proxyInitialized = true;
          });
        }
      });
    }

    // Update pending layout mode once the async value resolves.
    if (!_layoutInitialized) {
      ref.listen(layoutModeProvider, (prev, next) {
        if (next.hasValue && !_layoutInitialized) {
          setState(() {
            _pendingDockMode = next.value! == LayoutMode.dock;
            _initialDockMode = _pendingDockMode;
            _layoutInitialized = true;
          });
        }
      });
    }

    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusLg);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 680,
            maxHeight: 540,
            minHeight: 540,
            minWidth: 400,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.92),
                borderRadius: radius,
                border: Border.all(
                  color: hollow.accent.withValues(alpha: 0.15),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Header
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      HollowSpacing.xl,
                      HollowSpacing.xl,
                      HollowSpacing.xl,
                      0,
                    ),
                    child: Row(
                      children: [
                        Text(
                          'Settings',
                          style: HollowTypography.heading
                              .copyWith(color: hollow.textPrimary),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: HollowSpacing.lg),

                  // Tab rail + content
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.xl,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Left: tab rail
                          SizedBox(
                            width: 140,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _TabItem(
                                  icon: LucideIcons.user,
                                  label: 'Profile',
                                  isActive:
                                      _activeTab == _SettingsTab.profile,
                                  onTap: () => setState(() =>
                                      _activeTab = _SettingsTab.profile),
                                ),
                                const SizedBox(height: HollowSpacing.xxs),
                                _TabItem(
                                  icon: LucideIcons.monitor,
                                  label: 'System',
                                  isActive:
                                      _activeTab == _SettingsTab.system,
                                  onTap: () => setState(() =>
                                      _activeTab = _SettingsTab.system),
                                ),
                                const SizedBox(height: HollowSpacing.xxs),
                                _TabItem(
                                  icon: LucideIcons.shield,
                                  label: 'Security',
                                  isActive:
                                      _activeTab == _SettingsTab.security,
                                  onTap: () => setState(() =>
                                      _activeTab = _SettingsTab.security),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(width: HollowSpacing.lg),

                          // Vertical divider
                          Container(
                            width: 1,
                            color: hollow.border,
                          ),

                          const SizedBox(width: HollowSpacing.xl),

                          // Right: content area
                          Expanded(
                            child: switch (_activeTab) {
                              _SettingsTab.profile => _buildProfileTab(hollow),
                              _SettingsTab.system => _buildSystemTab(hollow),
                              _SettingsTab.security => _SecurityTab(),
                            },
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Actions
                  Padding(
                    padding: const EdgeInsets.all(HollowSpacing.xl),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        HollowButton.ghost(
                          onPressed: () {
                            // Revert accent color to what it was before opening
                            ref.read(accentHueProvider.notifier).setHue(_initialAccentHue);
                            Navigator.of(context).pop();
                          },
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        HollowButton.filled(
                          onPressed: _onSave,
                          child: const Text('Save'),
                        ),
                      ],
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

  // ── Profile tab ──────────────────────────────────────────────────

  Widget _buildProfileTab(HollowTheme hollow) {
    final bannerColor = _bannerColorFromId(widget.localPeerId);
    final previewName = _liveDisplayName.trim().isNotEmpty
        ? _liveDisplayName.trim()
        : displayNameFor(ref.watch(profileProvider), widget.localPeerId);

    return SingleChildScrollView(
      key: const ValueKey('profile'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Profile preview card + image buttons
          SizedBox(
            width: 200,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                  // Banner
                  Builder(builder: (_) {
                    final savedBanner = ref.watch(profileProvider)[widget.localPeerId]?.bannerBytes;
                    final displayBanner = _bannerChanged ? _pendingBannerBytes : savedBanner;
                    if (displayBanner != null && displayBanner.isNotEmpty) {
                      return SizedBox(
                        height: 70,
                        width: double.infinity,
                        child: AnimatedGifImage(bytes: displayBanner, height: 70, width: double.infinity, fit: BoxFit.cover,
                          errorWidget: Container(
                            height: 70,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                              ),
                            ),
                          ),
                        ),
                      );
                    }
                    return Container(
                      height: 70,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [bannerColor, bannerColor.withValues(alpha: 0.7)],
                        ),
                      ),
                    );
                  }),

                  // Avatar overlapping banner
                  Transform.translate(
                    offset: const Offset(0, -28),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.md,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Avatar with border
                          Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                  hollow.radiusMd + 2),
                              border: Border.all(
                                color: hollow.surface,
                                width: 3,
                              ),
                            ),
                            child: Builder(builder: (_) {
                              final savedAvatar = ref.watch(profileProvider)[widget.localPeerId]?.avatarBytes;
                              final displayAvatar = _avatarChanged ? _pendingAvatarBytes : savedAvatar;
                              return HollowAvatar(
                                peerId: widget.localPeerId,
                                size: 56,
                                imageBytes: (displayAvatar != null && displayAvatar.isNotEmpty) ? displayAvatar : null,
                                animate: true,
                              );
                            }),
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
                          if (_liveStatus.trim().isNotEmpty) ...[
                            const SizedBox(height: HollowSpacing.xxs),
                            Text(
                              _liveStatus.trim(),
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
                          if (widget.aboutMeController.text
                              .trim()
                              .isNotEmpty) ...[
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
                              widget.aboutMeController.text.trim(),
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
                                color: hollow.textSecondary
                                    .withValues(alpha: 0.35),
                              ),
                              const SizedBox(width: 3),
                              Text(
                                widget.localPeerId.length > 16
                                    ? widget.localPeerId.substring(
                                        widget.localPeerId.length - 8)
                                    : widget.localPeerId,
                                style: HollowTypography.mono.copyWith(
                                  color: hollow.textSecondary
                                      .withValues(alpha: 0.35),
                                  fontSize: 8,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                    ],
                  ),
                ),

                // Image management (below card)
                const SizedBox(height: HollowSpacing.md),
                // Avatar row
                Builder(builder: (_) {
                  final profile = ref.watch(profileProvider)[widget.localPeerId];
                  final hasAvatar = _avatarChanged
                      ? (_pendingAvatarBytes != null && _pendingAvatarBytes!.isNotEmpty)
                      : (profile?.avatarBytes != null && profile!.avatarBytes!.isNotEmpty);
                  return _ImageRow(
                    label: 'Avatar',
                    onPick: _pickAvatar,
                    onClear: hasAvatar ? _clearAvatar : null,
                    hollow: hollow,
                  );
                }),
                const SizedBox(height: HollowSpacing.xs),
                // Banner row
                Builder(builder: (_) {
                  final profile = ref.watch(profileProvider)[widget.localPeerId];
                  final hasBanner = _bannerChanged
                      ? (_pendingBannerBytes != null && _pendingBannerBytes!.isNotEmpty)
                      : (profile?.bannerBytes != null && profile!.bannerBytes!.isNotEmpty);
                  return _ImageRow(
                    label: 'Banner',
                    onPick: _pickBanner,
                    onClear: hasBanner ? _clearBanner : null,
                    hollow: hollow,
                  );
                }),
              ],
            ),
          ),

          const SizedBox(width: HollowSpacing.lg),

          // Edit fields
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _FieldLabel(label: 'DISPLAY NAME'),
                const SizedBox(height: HollowSpacing.xs),
                HollowTextField(
                  controller: widget.displayNameController,
                  hintText: 'Enter a display name',
                  autofocus: true,
                  maxLength: 32,
                ),

                const SizedBox(height: HollowSpacing.lg),

                _FieldLabel(label: 'STATUS'),
                const SizedBox(height: HollowSpacing.xs),
                HollowTextField(
                  controller: widget.statusController,
                  hintText: 'What are you up to?',
                  maxLength: 48,
                ),

                const SizedBox(height: HollowSpacing.lg),

                _FieldLabel(label: 'ABOUT ME'),
                const SizedBox(height: HollowSpacing.xs),
                HollowTextField(
                  controller: widget.aboutMeController,
                  hintText: 'Tell us about yourself',
                  maxLines: 3,
                  maxLength: 128,
                  onChanged: (_) => setState(() {}),
                ),

              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── System tab ───────────────────────────────────────────────────

  Widget _buildSystemTab(HollowTheme hollow) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;

    return SingleChildScrollView(
      key: const ValueKey('system'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Appearance ──
          _SectionLabel(label: 'APPEARANCE'),
          const SizedBox(height: HollowSpacing.sm),

          // Theme toggle
          _ToggleRow(
            icon: _pendingDarkMode ? LucideIcons.moon : LucideIcons.sun,
            label: 'Dark Mode',
            value: _pendingDarkMode,
            onChanged: (value) =>
                setState(() => _pendingDarkMode = value),
          ),

          const SizedBox(height: HollowSpacing.lg),

          // Accent color
          _AccentColorPicker(hollow: hollow),

          const SizedBox(height: HollowSpacing.lg),

          // Background image
          _BackgroundPicker(hollow: hollow),

          const SizedBox(height: HollowSpacing.xl),

          // ── Layout ──
          _SectionLabel(label: 'LAYOUT'),
          const SizedBox(height: HollowSpacing.sm),
          _ToggleRow(
            icon: LucideIcons.layoutDashboard,
            label: 'Dock Mode',
            subtitle: 'Bottom bar with friends strip',
            value: _pendingDockMode,
            onChanged: (value) =>
                setState(() => _pendingDockMode = value),
          ),

          const SizedBox(height: HollowSpacing.xl),

          // ── System ──
          _SectionLabel(label: 'SYSTEM'),
          const SizedBox(height: HollowSpacing.sm),

          // Minimize to tray toggle
          if (isDesktop) ...[
            _ToggleRow(
              icon: LucideIcons.minimize2,
              label: 'Minimize to Tray',
              value: _pendingMinimizeToTray,
              onChanged: (value) =>
                  setState(() => _pendingMinimizeToTray = value),
            ),
            const SizedBox(height: HollowSpacing.md),
          ],

          const SizedBox(height: HollowSpacing.xl),

          // ── Voice & Video ──
          _SectionLabel(label: 'VOICE & VIDEO'),
          const SizedBox(height: HollowSpacing.sm),
          const _AudioDeviceSettings(),

          const SizedBox(height: HollowSpacing.xl),

          // ── Keyboard Shortcuts ──
          _SectionLabel(label: 'KEYBOARD SHORTCUTS'),
          const SizedBox(height: HollowSpacing.sm),

          _ShortcutRow(
            label: 'Open Settings',
            shortcut: 'Ctrl + ,',
          ),
          _ShortcutRow(
            label: 'Toggle Member Panel',
            shortcut: 'Ctrl + Shift + M',
          ),
          _ShortcutRow(
            label: 'Quick Search',
            shortcut: 'Ctrl + K',
          ),
          _ShortcutRow(
            label: 'Toggle Split View',
            shortcut: r'Ctrl + Shift + \',
          ),
          _ShortcutRow(
            label: 'Focus Left Pane',
            shortcut: 'Ctrl + 1',
          ),
          _ShortcutRow(
            label: 'Focus Right Pane',
            shortcut: 'Ctrl + 2',
          ),

          const SizedBox(height: HollowSpacing.lg),

          // Sub-section: Chat Input
          Text(
              'CHAT INPUT',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary.withValues(alpha: 0.5),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                fontSize: 9,
              ),
          ),
          const SizedBox(height: HollowSpacing.sm),

          _ShortcutRow(
            label: 'Send Message',
            shortcut: 'Enter',
          ),
          _ShortcutRow(
            label: 'New Line',
            shortcut: 'Shift + Enter',
          ),
          _ShortcutRow(
            label: 'Bold',
            shortcut: 'Ctrl + B',
          ),
          _ShortcutRow(
            label: 'Italic',
            shortcut: 'Ctrl + I',
          ),
          _ShortcutRow(
            label: 'Code',
            shortcut: 'Ctrl + E',
          ),
          _ShortcutRow(
            label: 'Strikethrough',
            shortcut: 'Ctrl + Shift + X',
          ),
          _ShortcutRow(
            label: 'Spoiler',
            shortcut: 'Ctrl + Shift + S',
          ),
        ],
      ),
    );
  }
}

/// Security tab — recovery phrase viewer + account backup.
class _SecurityTab extends StatefulWidget {
  @override
  State<_SecurityTab> createState() => _SecurityTabState();
}

class _SecurityTabState extends State<_SecurityTab> {
  bool _revealed = false;
  bool _loading = true;
  bool _includeVault = false;
  String? _mnemonic;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMnemonic();
  }

  Future<void> _loadMnemonic() async {
    try {
      final mnemonic = await storage_api.getMnemonic();
      if (!mounted) return;
      setState(() {
        _mnemonic = mnemonic;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _exportBackup() async {
    // Ask for passphrase.
    final passphrase = await _askPassphrase(context, 'Set Backup Passphrase', confirm: true);
    if (passphrase == null || !mounted) return;

    final result = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Backup',
      fileName: 'hollow-backup.hollow',
      type: FileType.custom,
      allowedExtensions: ['hollow'],
    );
    if (result == null || !mounted) return;

    try {
      final size = await storage_api.exportBackup(
        outputPath: result,
        includeVault: _includeVault,
        passphrase: passphrase,
      );
      if (!mounted) return;
      final mb = (size.toDouble() / (1024 * 1024)).toStringAsFixed(1);
      HollowToast.show(context, 'Backup exported ($mb MB)', type: HollowToastType.success);
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Export failed: $e', type: HollowToastType.error);
    }
  }

  Future<String?> _askPassphrase(BuildContext context, String title, {bool confirm = false}) async {
    final controller = TextEditingController();
    final confirmController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) {
        final hollow = HollowTheme.of(ctx);
        return AlertDialog(
          backgroundColor: hollow.surface,
          title: Text(title, style: HollowTypography.heading.copyWith(color: hollow.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Enter passphrase',
                  hintStyle: TextStyle(color: hollow.textSecondary),
                ),
                style: TextStyle(color: hollow.textPrimary),
                onSubmitted: confirm ? null : (val) {
                  if (val.isNotEmpty) Navigator.of(ctx).pop(val);
                },
              ),
              if (confirm) ...[
                const SizedBox(height: HollowSpacing.sm),
                TextField(
                  controller: confirmController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: 'Confirm passphrase',
                    hintStyle: TextStyle(color: hollow.textSecondary),
                  ),
                  style: TextStyle(color: hollow.textPrimary),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text('Cancel', style: TextStyle(color: hollow.textSecondary)),
            ),
            TextButton(
              onPressed: () {
                final pass = controller.text.trim();
                if (pass.isEmpty) return;
                if (confirm && pass != confirmController.text.trim()) {
                  HollowToast.show(ctx, 'Passphrases don\'t match', type: HollowToastType.error);
                  return;
                }
                Navigator.of(ctx).pop(pass);
              },
              child: Text('OK', style: TextStyle(color: hollow.accent)),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return SingleChildScrollView(
      key: const ValueKey('security'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Recovery Phrase ──
          _SectionLabel(label: 'RECOVERY PHRASE'),
          const SizedBox(height: HollowSpacing.sm),

          if (_loading)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(HollowSpacing.xl),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: hollow.accent,
                  ),
                ),
              ),
            )
          else if (_error != null)
            Text(
              'Failed to load mnemonic: $_error',
              style: HollowTypography.body.copyWith(color: hollow.error),
            )
          else if (_mnemonic == null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No recovery phrase stored. If you have your 24 words, you can enter them below.',
                  style: HollowTypography.body.copyWith(color: hollow.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: HollowSpacing.sm),
                SizedBox(
                  width: 300,
                  child: HollowTextField(
                    controller: TextEditingController(),
                    hintText: 'Enter 24-word recovery phrase',
                    isDense: true,
                    style: HollowTypography.body.copyWith(color: hollow.textPrimary, fontSize: 12),
                    borderRadius: hollow.radiusSm,
                    onSubmitted: (val) async {
                      final words = val.trim().split(RegExp(r'\s+'));
                      if (words.length != 24) {
                        HollowToast.show(context, 'Must be exactly 24 words', type: HollowToastType.error);
                        return;
                      }
                      try {
                        await storage_api.saveMnemonic(mnemonic: val.trim());
                        if (mounted) {
                          setState(() => _mnemonic = val.trim());
                          HollowToast.show(context, 'Recovery phrase saved', type: HollowToastType.success);
                        }
                      } catch (e) {
                        if (mounted) HollowToast.show(context, 'Failed to save: $e', type: HollowToastType.error);
                      }
                    },
                  ),
                ),
              ],
            )
          else ...[
            // Mnemonic container
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(HollowSpacing.md),
              decoration: BoxDecoration(
                color: hollow.background,
                borderRadius: BorderRadius.circular(hollow.radiusMd),
                border: Border.all(
                  color: _revealed
                      ? hollow.warning.withValues(alpha: 0.4)
                      : hollow.border,
                ),
              ),
              child: _revealed
                  ? _buildWordGrid(hollow)
                  : Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.lg),
                        child: Text(
                          'Hidden for security',
                          style: HollowTypography.body.copyWith(
                            color: hollow.textSecondary.withValues(alpha: 0.5),
                          ),
                        ),
                      ),
                    ),
            ),

            const SizedBox(height: HollowSpacing.sm),

            // Reveal / Hide button + Copy button
            Row(
              children: [
                HollowButton.ghost(
                  onPressed: () => setState(() => _revealed = !_revealed),
                  icon: Icon(
                    _revealed ? LucideIcons.eyeOff : LucideIcons.eye,
                    size: 16,
                  ),
                  child: Text(_revealed ? 'Hide' : 'Reveal'),
                ),
                if (_revealed) ...[
                  const SizedBox(width: HollowSpacing.sm),
                  HollowButton.ghost(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _mnemonic!));
                      HollowToast.show(
                        context,
                        'Copied to clipboard',
                        type: HollowToastType.success,
                      );
                    },
                    icon: Icon(LucideIcons.copy, size: 16),
                    child: const Text('Copy'),
                  ),
                ],
              ],
            ),

            const SizedBox(height: HollowSpacing.sm),

            // Warning text
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(
                    LucideIcons.alertTriangle,
                    size: 14,
                    color: hollow.warning,
                  ),
                ),
                const SizedBox(width: HollowSpacing.xs),
                Expanded(
                  child: Text(
                    'Anyone with these words can access your account. Never share them.',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.warning,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: HollowSpacing.xl),

          // ── Account Backup ──
          _SectionLabel(label: 'ACCOUNT BACKUP'),
          const SizedBox(height: HollowSpacing.sm),

          Text(
            'Exports your identity, profile, servers, friends, and messages.',
            style: HollowTypography.body.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
            ),
          ),

          const SizedBox(height: HollowSpacing.md),

          // Include vault checkbox
          GestureDetector(
            onTap: () => setState(() => _includeVault = !_includeVault),
            child: Row(
              children: [
                Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: _includeVault ? hollow.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: _includeVault ? hollow.accent : hollow.border,
                      width: 1.5,
                    ),
                  ),
                  child: _includeVault
                      ? Icon(LucideIcons.check, size: 12, color: Colors.white)
                      : null,
                ),
                const SizedBox(width: HollowSpacing.sm),
                Text(
                  'Include vault shard data',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: HollowSpacing.md),

          HollowButton.filled(
            onPressed: _exportBackup,
            icon: Icon(LucideIcons.download, size: 16),
            child: const Text('Export Backup'),
          ),
        ],
      ),
    );
  }

  Widget _buildWordGrid(HollowTheme hollow) {
    final words = _mnemonic!.split(' ');
    // 6 rows x 4 columns (easier to read, less cramped)
    const cols = 4;
    final rows = (words.length / cols).ceil();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int row = 0; row < rows; row++)
          Padding(
            padding: EdgeInsets.only(
              bottom: row < rows - 1 ? HollowSpacing.xs : 0,
            ),
            child: Row(
              children: [
                for (int col = 0; col < cols; col++) ...[
                  if (col > 0) const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Builder(builder: (context) {
                      final index = row * cols + col;
                      if (index >= words.length) return const SizedBox();
                      return RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(
                              text: '${(index + 1).toString().padLeft(2)}. ',
                              style: HollowTypography.mono.copyWith(
                                color: hollow.textSecondary.withValues(alpha: 0.5),
                                fontSize: 10,
                              ),
                            ),
                            TextSpan(
                              text: words[index],
                              style: HollowTypography.mono.copyWith(
                                color: hollow.textPrimary,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// Tab item in the settings rail.
class _TabItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;

  const _TabItem({
    required this.icon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return HollowPressable(
      onTap: onTap,
      subtle: true,
      borderRadius: BorderRadius.circular(hollow.radiusSm),
      hoverColor: hollow.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm + 2,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: isActive ? hollow.accent : hollow.textSecondary,
          ),
          const SizedBox(width: HollowSpacing.sm),
          Text(
            label,
            style: HollowTypography.body.copyWith(
              color: isActive ? hollow.textPrimary : hollow.textSecondary,
              fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reusable toggle row for System tab.
class _ToggleRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ToggleRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Row(
      children: [
        Icon(icon, size: 16, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        Expanded(
          child: subtitle != null
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textPrimary),
                    ),
                    Text(
                      subtitle!,
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ],
                )
              : Text(
                  label,
                  style: HollowTypography.body
                      .copyWith(color: hollow.textPrimary),
                ),
        ),
        HollowToggle(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// Single shortcut row: label on left, key badge on right.
class _ShortcutRow extends StatelessWidget {
  final String label;
  final String shortcut;

  const _ShortcutRow({
    required this.label,
    required this.shortcut,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: HollowSpacing.xxs + 1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: HollowTypography.body.copyWith(
                color: hollow.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
          _KeyBadge(shortcut: shortcut),
        ],
      ),
    );
  }
}

/// Styled keyboard shortcut badge (e.g. "Ctrl + B").
class _KeyBadge extends StatelessWidget {
  final String shortcut;

  const _KeyBadge({required this.shortcut});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Split on " + " to render each key individually.
    final keys = shortcut.split(' + ');

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (int i = 0; i < keys.length; i++) ...[
          if (i > 0)
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: HollowSpacing.xxs),
              child: Text(
                '+',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary.withValues(alpha: 0.4),
                  fontSize: 9,
                ),
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.xs + 2,
              vertical: HollowSpacing.xxs,
            ),
            decoration: BoxDecoration(
              color: hollow.surface,
              borderRadius: BorderRadius.circular(hollow.radiusSm - 2),
              border: Border.all(
                color: hollow.border,
              ),
            ),
            child: Text(
              keys[i],
              style: HollowTypography.mono.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Section label for the system tab.
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Text(
        label,
        style: HollowTypography.caption.copyWith(
          color: hollow.textSecondary,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
          fontSize: 10,
        ),
    );
  }
}

/// Audio device selection + mic test for the System tab.
class _AudioDeviceSettings extends ConsumerStatefulWidget {
  const _AudioDeviceSettings();

  @override
  ConsumerState<_AudioDeviceSettings> createState() =>
      _AudioDeviceSettingsState();
}

class _AudioDeviceSettingsState extends ConsumerState<_AudioDeviceSettings> {
  List<win32audio.AudioDevice> _audioInputs = [];
  List<win32audio.AudioDevice> _audioOutputs = [];
  bool _loading = true;
  rec.AudioRecorder? _recorder;
  StreamSubscription<rec.Amplitude>? _ampSub;
  bool _micTesting = false;
  double _micLevel = 0.0;
  AudioPlayer? _ringtonePreview;

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  @override
  void dispose() {
    _stopMicTest();
    _stopRingtonePreview();
    super.dispose();
  }

  Future<void> _startRingtonePreview(double volume) async {
    final path = ref.read(ringtonePathProvider).valueOrNull;
    if (path == null || path.isEmpty || !File(path).existsSync()) return;

    _ringtonePreview = AudioPlayer();
    await _ringtonePreview!.setReleaseMode(ReleaseMode.loop);
    await _ringtonePreview!.setVolume(volume);
    await _ringtonePreview!.play(DeviceFileSource(path));
  }

  void _stopRingtonePreview() {
    _ringtonePreview?.stop();
    _ringtonePreview?.dispose();
    _ringtonePreview = null;
  }

  Future<void> _loadDevices() async {
    try {
      // Enumerate both input and output devices via win32audio.
      // This gives us the isActive flag to auto-select the right device.
      List<win32audio.AudioDevice> inputs = [];
      List<win32audio.AudioDevice> outputs = [];
      try {
        final inDevices = await win32audio.Audio.enumDevices(
            win32audio.AudioDeviceType.input);
        inputs = inDevices ?? [];
        final outDevices = await win32audio.Audio.enumDevices(
            win32audio.AudioDeviceType.output);
        outputs = outDevices ?? [];
      } catch (e) {
        debugPrint('[HOLLOW] Device enumeration failed: $e');
      }

      if (!mounted) return;
      setState(() {
        _audioInputs = inputs;
        _audioOutputs = outputs;
        _loading = false;
      });

      // Auto-select the system active device if the user hasn't chosen one.
      final savedInput = ref.read(audioInputDeviceProvider).valueOrNull;
      if (savedInput == null && inputs.isNotEmpty) {
        final active = inputs.firstWhere(
            (d) => d.isActive,
            orElse: () => inputs.first);
        ref.read(audioInputDeviceProvider.notifier).setDevice(active.id);
      }
      final savedOutput = ref.read(audioOutputDeviceProvider).valueOrNull;
      if (savedOutput == null && outputs.isNotEmpty) {
        final active = outputs.firstWhere(
            (d) => d.isActive,
            orElse: () => outputs.first);
        ref.read(audioOutputDeviceProvider.notifier).setDevice(active.id);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _startMicTest() async {
    final selectedInput =
        ref.read(audioInputDeviceProvider).valueOrNull;

    try {
      _recorder = rec.AudioRecorder();

      // Start a stream recording (data is discarded — we just need the
      // session active for amplitude monitoring).
      final stream = await _recorder!.startStream(
        rec.RecordConfig(
          encoder: rec.AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: 16000,
          device: selectedInput != null
              ? rec.InputDevice(id: selectedInput, label: '')
              : null,
        ),
      );

      // Drain the PCM stream so it doesn't buffer.
      stream.listen((_) {});

      if (!mounted) return;
      setState(() => _micTesting = true);

      // Listen for amplitude updates.
      _ampSub = _recorder!
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amp) {
        if (!mounted) return;
        // Normalize dBFS (-60..0) to 0.0..1.0 for the level bar.
        const minDb = -60.0;
        final clamped = amp.current.clamp(minDb, 0.0);
        final level = (clamped - minDb) / (0.0 - minDb);
        setState(() => _micLevel = level);
      });
    } catch (e) {
      if (!mounted) return;
      HollowToast.show(context, 'Microphone error: $e',
          type: HollowToastType.error);
    }
  }

  void _stopMicTest() {
    _ampSub?.cancel();
    _ampSub = null;

    if (_recorder != null) {
      _recorder!.stop();
      _recorder!.dispose();
      _recorder = null;
    }

    _micLevel = 0.0;
    if (mounted) setState(() => _micTesting = false);
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final selectedInput =
        ref.watch(audioInputDeviceProvider).valueOrNull;
    final selectedOutput =
        ref.watch(audioOutputDeviceProvider).valueOrNull;

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HollowSpacing.md),
        child: Text(
          'Loading devices...',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Microphone input (win32audio)
        _buildDeviceRow(
          hollow: hollow,
          icon: LucideIcons.mic,
          label: 'Microphone',
          items: _audioInputs.map((d) => DropdownMenuItem<String?>(
                value: d.id,
                child: Text(
                  d.name.isNotEmpty ? d.name : 'Device ${d.id.substring(0, 8.clamp(0, d.id.length))}',
                  overflow: TextOverflow.ellipsis,
                ),
              )).toList(),
          selectedValue: _resolveInputValue(selectedInput),
          onChanged: (deviceId) {
            if (deviceId != null) {
              ref.read(audioInputDeviceProvider.notifier).setDevice(deviceId);
            }
          },
        ),
        const SizedBox(height: HollowSpacing.md),

        // Speaker output (win32audio)
        _buildDeviceRow(
          hollow: hollow,
          icon: LucideIcons.volume2,
          label: 'Speaker',
          items: _audioOutputs.map((d) => DropdownMenuItem<String?>(
                value: d.id,
                child: Text(
                  d.name.isNotEmpty ? d.name : 'Device ${d.id.substring(0, 8.clamp(0, d.id.length))}',
                  overflow: TextOverflow.ellipsis,
                ),
              )).toList(),
          selectedValue: _resolveOutputValue(selectedOutput),
          onChanged: (deviceId) {
            if (deviceId != null) {
              ref.read(audioOutputDeviceProvider.notifier).setDevice(deviceId);
              webrtc.Helper.selectAudioOutput(deviceId).catchError((e) {
                debugPrint('[HOLLOW] selectAudioOutput failed: $e');
              });
            }
          },
        ),
        const SizedBox(height: HollowSpacing.md),

        // Audio quality preset
        _buildDeviceRow(
          hollow: hollow,
          icon: LucideIcons.sliders,
          label: 'Audio Quality',
          items: AudioQualityPreset.values.map((p) => DropdownMenuItem<String?>(
                value: p.name,
                child: Text(
                  '${p.label} — ${p.bitrate ~/ 1000} kbps${p.stereo ? ' stereo' : ' mono'}',
                  overflow: TextOverflow.ellipsis,
                ),
              )).toList(),
          selectedValue:
              ref.watch(audioQualityProvider).valueOrNull?.name ??
                  AudioQualityPreset.voice.name,
          onChanged: (value) {
            if (value != null) {
              final preset = AudioQualityPreset.values.firstWhere(
                (p) => p.name == value,
                orElse: () => AudioQualityPreset.voice,
              );
              ref.read(audioQualityProvider.notifier).setPreset(preset);
            }
          },
        ),
        const SizedBox(height: HollowSpacing.md),

        // Mic test button + volume meter
        Row(
          children: [
            Icon(
              _micTesting ? LucideIcons.micOff : LucideIcons.mic,
              size: 14,
              color: hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              onPressed: _micTesting ? _stopMicTest : _startMicTest,
              compact: true,
              child: Text(_micTesting ? 'Stop Test' : 'Test Microphone'),
            ),
            if (_micTesting) ...[
              const SizedBox(width: HollowSpacing.md),
              // Volume meter bar
              Expanded(
                child: SizedBox(
                  height: 8,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: Stack(
                      children: [
                        // Background
                        Container(
                          color: hollow.border,
                        ),
                        // Level fill
                        FractionallySizedBox(
                          widthFactor: _micLevel.clamp(0.0, 1.0),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 80),
                            decoration: BoxDecoration(
                              color: _micLevel > 0.5
                                  ? hollow.success
                                  : _micLevel > 0.02
                                      ? hollow.accent
                                      : hollow.textSecondary
                                          .withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),

        // Refresh devices
        Row(
          children: [
            Icon(LucideIcons.refreshCw, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              onPressed: () {
                setState(() => _loading = true);
                _loadDevices();
              },
              compact: true,
              child: const Text('Refresh Devices'),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.lg),

        // Ringtone selector
        Row(
          children: [
            Icon(LucideIcons.bellRing, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Ringtone',
              style: HollowTypography.caption.copyWith(
                color: hollow.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),
        Builder(builder: (_) {
          final ringtonePath =
              ref.watch(ringtonePathProvider).valueOrNull;
          final fileName =
              ringtonePath?.split(RegExp(r'[\\/]')).last;

          return Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.sm,
                    vertical: HollowSpacing.xs + 2,
                  ),
                  decoration: BoxDecoration(
                    color: hollow.surface,
                    borderRadius: BorderRadius.circular(hollow.radiusSm),
                    border: Border.all(color: hollow.border),
                  ),
                  child: Text(
                    fileName ?? 'No ringtone selected',
                    style: HollowTypography.caption.copyWith(
                      color: fileName != null
                          ? hollow.textPrimary
                          : hollow.textSecondary,
                      fontSize: 12,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.ghost(
                onPressed: () async {
                  final result = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['mp3', 'wav', 'ogg', 'flac', 'm4a'],
                    dialogTitle: 'Select Ringtone',
                  );
                  if (result != null && result.files.single.path != null) {
                    ref.read(ringtonePathProvider.notifier)
                        .setPath(result.files.single.path);
                  }
                },
                compact: true,
                child: const Text('Browse'),
              ),
              if (ringtonePath != null) ...[
                const SizedBox(width: HollowSpacing.xs),
                HollowButton.ghost(
                  onPressed: () {
                    ref.read(ringtonePathProvider.notifier).setPath(null);
                  },
                  compact: true,
                  child: Icon(LucideIcons.x,
                      size: 14, color: hollow.textSecondary),
                ),
              ],
            ],
          );
        }),
        const SizedBox(height: HollowSpacing.sm),

        // Ringtone volume slider
        Row(
          children: [
            Icon(LucideIcons.volume2, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Volume',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(
                  activeTrackColor: hollow.accent,
                  inactiveTrackColor: hollow.border,
                  thumbColor: hollow.accent,
                  overlayColor: hollow.accent.withValues(alpha: 0.1),
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6),
                ),
                child: Slider(
                  value: ref.watch(ringtoneVolumeProvider).valueOrNull ?? 0.5,
                  onChangeStart: (v) => _startRingtonePreview(v),
                  onChanged: (v) {
                    ref.read(ringtoneVolumeProvider.notifier).setVolume(v);
                    _ringtonePreview?.setVolume(v);
                  },
                  onChangeEnd: (_) => _stopRingtonePreview(),
                ),
              ),
            ),
            SizedBox(
              width: 32,
              child: Text(
                '${((ref.watch(ringtoneVolumeProvider).valueOrNull ?? 0.5) * 100).round()}%',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.xs),

        // 30s info label
        Text(
          'Ringtone plays for up to 30 seconds during incoming calls.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary.withValues(alpha: 0.6),
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  String? _resolveInputValue(String? savedId) {
    if (savedId == null || _audioInputs.isEmpty) return null;
    // If the saved device exists, use it. Otherwise fall back to active device.
    if (_audioInputs.any((d) => d.id == savedId)) return savedId;
    final active = _audioInputs.where((d) => d.isActive);
    return active.isNotEmpty ? active.first.id : _audioInputs.first.id;
  }

  String? _resolveOutputValue(String? savedId) {
    if (savedId == null || _audioOutputs.isEmpty) return null;
    if (_audioOutputs.any((d) => d.id == savedId)) return savedId;
    final active = _audioOutputs.where((d) => d.isActive);
    return active.isNotEmpty ? active.first.id : _audioOutputs.first.id;
  }

  Widget _buildDeviceRow({
    required HollowTheme hollow,
    required IconData icon,
    required String label,
    required List<DropdownMenuItem<String?>> items,
    required String? selectedValue,
    required void Function(String?) onChanged,
  }) {
    return Row(
      children: [
        Icon(icon, size: 14, color: hollow.textSecondary),
        const SizedBox(width: HollowSpacing.sm),
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: hollow.textPrimary,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.sm),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: selectedValue,
                isExpanded: true,
                dropdownColor: hollow.elevated,
                style: HollowTypography.caption.copyWith(
                  color: hollow.textPrimary,
                  fontSize: 12,
                ),
                icon: Icon(LucideIcons.chevronDown,
                    size: 14, color: hollow.textSecondary),
                items: items,
                onChanged: onChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Restart prompt dialog shown after proxy setting changes.
class _RestartPrompt extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusMd);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Material(
          color: Colors.transparent,
          child: Container(
            decoration: BoxDecoration(
              color: hollow.elevated.withValues(alpha: 0.95),
              borderRadius: radius,
              border: Border.all(
                color: hollow.accent.withValues(alpha: 0.15),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 20,
                ),
              ],
            ),
            padding: const EdgeInsets.all(HollowSpacing.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.rotateCcw,
                  size: 32,
                  color: hollow.accent,
                ),
                const SizedBox(height: HollowSpacing.md),
                Text(
                  'Restart Required',
                  style: HollowTypography.subheading.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: HollowSpacing.sm),
                Text(
                  'The proxy setting requires a restart to take effect.',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: HollowSpacing.xl),
                Row(
                  children: [
                    Expanded(
                      child: HollowButton.ghost(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Restart Later'),
                      ),
                    ),
                    const SizedBox(width: HollowSpacing.sm),
                    Expanded(
                      child: HollowButton.filled(
                        onPressed: () async {
                          // Graceful shutdown: notify peers, stop node.
                          try {
                            await network_api.notifyShutdown();
                            await Future.delayed(
                                const Duration(milliseconds: 200));
                          } catch (_) {}

                          // Spawn new instance before exiting.
                          final exe = Platform.resolvedExecutable;
                          await Process.start(exe, [],
                              mode: ProcessStartMode.detached);

                          // Small delay to let the OS fully detach the child.
                          await Future.delayed(
                              const Duration(milliseconds: 100));
                          exit(0);
                        },
                        child: const Text('Restart Now'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String label;
  const _FieldLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Text(
      label,
      style: HollowTypography.caption.copyWith(
        color: hollow.textSecondary,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.5,
        fontSize: 10,
      ),
    );
  }
}

/// Image row: "Avatar -------- [trash]" or "Banner -------- [trash]"
/// Background image picker + panel opacity slider.
class _BackgroundPicker extends ConsumerWidget {
  final HollowTheme hollow;
  const _BackgroundPicker({required this.hollow});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bg = ref.watch(backgroundProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label + buttons
        Row(
          children: [
            Icon(LucideIcons.image, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Background',
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            HollowButton.ghost(
              onPressed: () async {
                final result = await FilePicker.platform.pickFiles(type: FileType.image);
                if (result == null || result.files.isEmpty) return;
                final path = result.files.single.path;
                if (path == null) return;
                final raw = await File(path).readAsBytes();
                if (!context.mounted) return;
                final cropped = await showImageCropDialog(
                  context: context,
                  imageBytes: raw,
                  aspectRatio: 16.0 / 9.0,
                  title: 'Crop Background',
                );
                if (cropped != null) {
                  ref.read(backgroundProvider.notifier).setImage(cropped);
                }
              },
              compact: true,
              child: Text(bg.hasBackground ? 'Change' : 'Set Image'),
            ),
            if (bg.hasBackground) ...[
              const SizedBox(width: HollowSpacing.xs),
              HollowButton.ghost(
                onPressed: () => ref.read(backgroundProvider.notifier).clearImage(),
                compact: true,
                child: const Text('Remove'),
              ),
            ],
          ],
        ),

        // Opacity slider (only when background is set)
        if (bg.hasBackground) ...[
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Text(
                'Darken',
                style: HollowTypography.caption.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 20,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 4,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 7,
                      ),
                      thumbColor: Colors.white,
                      activeTrackColor: accentFromHue(ref.watch(accentHueProvider)),
                      inactiveTrackColor: hollow.border,
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(
                      value: bg.panelOpacity,
                      min: 0.4,
                      max: 1.0,
                      onChanged: (value) {
                        ref.read(backgroundProvider.notifier).setOpacity(value);
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: HollowSpacing.xs),
              Text(
                '${(bg.panelOpacity * 100).round()}%',
                style: HollowTypography.mono.copyWith(
                  color: hollow.textSecondary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Accent color picker — hue slider + preset swatches.
class _AccentColorPicker extends ConsumerStatefulWidget {
  final HollowTheme hollow;

  const _AccentColorPicker({required this.hollow});

  @override
  ConsumerState<_AccentColorPicker> createState() => _AccentColorPickerState();
}

class _AccentColorPickerState extends ConsumerState<_AccentColorPicker> {

  @override
  Widget build(BuildContext context) {
    final hollow = widget.hollow;
    final currentHue = ref.watch(accentHueProvider);
    final presets = ref.watch(accentPresetsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label row with color preview
        Row(
          children: [
            Icon(LucideIcons.palette, size: 14, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Text(
              'Accent Color',
              style: HollowTypography.body.copyWith(
                color: hollow.textPrimary,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: accentFromHue(currentHue),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.2),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.sm),

        // Hue slider (rainbow gradient)
        SizedBox(
          height: 24,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 14,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 9,
                elevation: 2,
              ),
              thumbColor: Colors.white,
              overlayShape: SliderComponentShape.noOverlay,
              trackShape: _RainbowSliderTrackShape(),
              activeTrackColor: Colors.transparent,
              inactiveTrackColor: Colors.transparent,
            ),
            child: Slider(
              value: currentHue.clamp(0, 359),
              min: 0,
              max: 359,
              onChanged: (value) {
                ref.read(accentHueProvider.notifier).setHue(value);
              },
            ),
          ),
        ),

        const SizedBox(height: HollowSpacing.sm),

        // Preset swatches row
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            // Default teal
            _ColorSwatch(
              hue: defaultAccentHue,
              isSelected: (currentHue - defaultAccentHue).abs() < 1,
              label: 'Default',
              onTap: () =>
                  ref.read(accentHueProvider.notifier).setHue(defaultAccentHue),
              hollow: hollow,
            ),
            // Saved presets
            for (final hue in presets)
              _ColorSwatch(
                hue: hue,
                isSelected: (currentHue - hue).abs() < 1,
                onTap: () =>
                    ref.read(accentHueProvider.notifier).setHue(hue),
                onRemove: () =>
                    ref.read(accentPresetsProvider.notifier).removePreset(hue),
                hollow: hollow,
              ),
            // Save current button
            if (!presets.any((h) => (h - currentHue).abs() < 1) &&
                (currentHue - defaultAccentHue).abs() > 1)
              GestureDetector(
                onTap: () =>
                    ref.read(accentPresetsProvider.notifier).addPreset(currentHue),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: hollow.textSecondary.withValues(alpha: 0.4),
                        style: BorderStyle.solid,
                      ),
                    ),
                    child: Icon(
                      LucideIcons.plus,
                      size: 12,
                      color: hollow.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// A small color swatch for preset selection.
class _ColorSwatch extends StatelessWidget {
  final double hue;
  final bool isSelected;
  final String? label;
  final VoidCallback onTap;
  final VoidCallback? onRemove;
  final HollowTheme hollow;

  const _ColorSwatch({
    required this.hue,
    required this.isSelected,
    this.label,
    required this.onTap,
    this.onRemove,
    required this.hollow,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onSecondaryTapUp: onRemove != null ? (_) => onRemove!() : null,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: HollowTooltip(
          message: label ?? 'Right-click to remove',
          child: Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: accentFromHue(hue),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: isSelected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.15),
                width: isSelected ? 2 : 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Custom slider track that renders a rainbow hue gradient.
class _RainbowSliderTrackShape extends SliderTrackShape {
  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = true,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 14;
    final trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    return Rect.fromLTWH(
      offset.dx + 8,
      trackTop,
      parentBox.size.width - 16,
      trackHeight,
    );
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = true,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
    );

    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));

    // Rainbow gradient across the full hue spectrum
    final gradient = LinearGradient(
      colors: List.generate(
        13,
        (i) => HSLColor.fromAHSL(1.0, i * 30.0, 0.85, 0.5).toColor(),
      ),
    );

    final paint = Paint()
      ..shader = gradient.createShader(rect);

    context.canvas.drawRRect(rrect, paint);
  }
}

class _ImageRow extends StatelessWidget {
  final String label;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  final HollowTheme hollow;

  const _ImageRow({
    required this.label,
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
              Icon(LucideIcons.image, size: 12, color: hollow.accent),
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
