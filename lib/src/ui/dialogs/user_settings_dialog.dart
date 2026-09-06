import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/app_relaunch.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/profile_anim_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/avatar_frame_picker.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/settings/about_section.dart';
import 'package:hollow/src/ui/settings/accessibility_section.dart';
import 'package:hollow/src/ui/settings/appearance_section.dart';
import 'package:hollow/src/ui/settings/audio_section.dart';
import 'package:hollow/src/ui/settings/backup_section.dart';
import 'package:hollow/src/ui/settings/devices_section.dart';
import 'package:hollow/src/ui/settings/network_section.dart';
import 'package:hollow/src/ui/settings/profile_section.dart';
import 'package:hollow/src/ui/settings/security_section.dart';
import 'package:hollow/src/ui/settings/shortcuts_section.dart';
import 'package:hollow/src/ui/settings/storage_settings_cards.dart';
import 'package:hollow/src/ui/settings/updates_section.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

bool _settingsDialogOpen = false;

/// Shows the user settings dialog, or closes it if already open.
///
/// Reads providers through the enclosing [ProviderScope], so any context under
/// the app works, including a non-widget caller like the tray menu. That caller
/// passes `toggle: false` so a second click returns to the dialog.
void showUserSettingsDialog(BuildContext context,
    {bool openSystemTab = false,
    bool openUpdatesTab = false,
    bool toggle = true}) {
  if (_settingsDialogOpen) {
    if (toggle) Navigator.of(context, rootNavigator: true).pop();
    return;
  }

  final container = ProviderScope.containerOf(context, listen: false);
  final localPeerId = container.read(identityProvider).peerId;
  if (localPeerId == null) return;

  final profiles = container.read(profileProvider);
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
        initialTab: openUpdatesTab
            ? _SettingsCategory.updates
            : openSystemTab
                ? _SettingsCategory.appearance
                : _SettingsCategory.profile,
      );
    },
  ).then((_) {
    _settingsDialogOpen = false;
  });
}

/// One entry per side-rail item, each narrow enough that its view fits without
/// a giant scroll. Every category's cards live in their own module under
/// `lib/src/ui/settings/`.
enum _SettingsCategory {
  profile,
  appearance,
  accessibility,
  network,
  storage,
  audio,
  shortcuts,
  security,
  devices,
  backup,
  updates,
  about,
}

extension _SettingsCategoryMeta on _SettingsCategory {
  IconData get icon => switch (this) {
        _SettingsCategory.profile => LucideIcons.user,
        _SettingsCategory.appearance => LucideIcons.palette,
        _SettingsCategory.accessibility => LucideIcons.accessibility,
        _SettingsCategory.network => LucideIcons.globe,
        _SettingsCategory.storage => LucideIcons.hardDrive,
        _SettingsCategory.audio => LucideIcons.mic,
        _SettingsCategory.shortcuts => LucideIcons.keyboard,
        _SettingsCategory.security => LucideIcons.shield,
        _SettingsCategory.devices => LucideIcons.smartphone,
        _SettingsCategory.backup => LucideIcons.archive,
        _SettingsCategory.updates => LucideIcons.download,
        _SettingsCategory.about => LucideIcons.info,
      };

  String get label => switch (this) {
        _SettingsCategory.profile => 'Profile',
        _SettingsCategory.appearance => 'Appearance',
        _SettingsCategory.accessibility => 'Accessibility',
        _SettingsCategory.network => 'Network',
        _SettingsCategory.storage => 'Files & Storage',
        _SettingsCategory.audio => 'Audio & Video',
        _SettingsCategory.shortcuts => 'Shortcuts',
        _SettingsCategory.security => 'Security',
        _SettingsCategory.devices => 'Devices',
        _SettingsCategory.backup => 'Backup',
        _SettingsCategory.updates => 'Updates',
        _SettingsCategory.about => 'About',
      };

  /// Lowercase keywords, so the rail search matches a category even when the
  /// query names a setting inside it.
  String get searchTerms => switch (this) {
        _SettingsCategory.profile =>
          'profile display name status about me avatar banner twitch connection',
        _SettingsCategory.appearance =>
          'appearance theme dark light mode accent color background image layout '
              'dock classic invisible',
        _SettingsCategory.accessibility =>
          'accessibility contrast motion reduce animations transitions '
              'transparency blur text size voice screen reader voiceover',
        _SettingsCategory.network =>
          'network relay server domain connection offline delivery inbox '
              'buffer retention',
        _SettingsCategory.storage =>
          'files storage disk space cache clear reclaim downloads breakdown '
              'auto download threshold data location folder media image quality '
              'webp shards vault size limit cleanup manage',
        _SettingsCategory.audio =>
          'audio video voice microphone mic speaker camera gain quality test '
              'ringtone devices',
        _SettingsCategory.shortcuts => 'shortcuts keyboard keys hotkeys chat input',
        _SettingsCategory.security =>
          'security app lock password device protection keychain recovery phrase '
              'mnemonic encrypt blocked block unblock report always relay calls '
              'ip address turn privacy hide',
        _SettingsCategory.devices =>
          'devices linked multi device link sync revoke remove reset',
        _SettingsCategory.backup => 'backup export proof verify signature',
        _SettingsCategory.updates => 'updates version install download release',
        _SettingsCategory.about => 'about version contact legal licenses follow support',
      };
}

class _UserSettingsContent extends ConsumerStatefulWidget {
  final String localPeerId;
  final TextEditingController displayNameController;
  final TextEditingController statusController;
  final TextEditingController aboutMeController;
  final _SettingsCategory initialTab;

  const _UserSettingsContent({
    required this.localPeerId,
    required this.displayNameController,
    required this.statusController,
    required this.aboutMeController,
    this.initialTab = _SettingsCategory.profile,
  });

  @override
  ConsumerState<_UserSettingsContent> createState() =>
      _UserSettingsContentState();
}

class _UserSettingsContentState extends ConsumerState<_UserSettingsContent> {
  String _liveDisplayName = '';
  String _liveStatus = '';

  // Null is no change, empty is clear. These are the bytes the PREVIEW paints,
  // which for an animated pick is the animation.
  Uint8List? _pendingAvatarBytes;
  Uint8List? _pendingBannerBytes;
  bool _avatarChanged = false;
  bool _bannerChanged = false;
  // An animated pick splits in two: the animation is cached on the asset rail
  // under a hash and only the STILL companion rides the profile push. Null on a
  // still pick, which is what CLEARS a previous animation on save.
  Uint8List? _pendingAvatarStill;
  Uint8List? _pendingBannerStill;
  String? _pendingAvatarAnim;
  String? _pendingBannerAnim;
  // In-flight WebP processing; these futures never throw. Save AWAITS them, so
  // an early tap cannot commit while the final bytes are still encoding.
  Future<void>? _avatarProcessing;
  Future<void>? _bannerProcessing;
  // Any newer pick or clear bumps the generation, so a late processing result
  // cannot clobber it.
  int _avatarPickGen = 0;
  int _bannerPickGen = 0;
  bool _avatarBusy = false;
  bool _bannerBusy = false;
  bool _savingProfile = false;

  // Pending avatar frame (issue #54): null with `!_frameChanged` is no change,
  // '' is clear. The picker stores an upload's blob immediately, so only the id
  // is pending here.
  String? _pendingFrameId;
  bool _frameChanged = false;

  late _SettingsCategory _activeTab;
  final _searchController = TextEditingController();
  String _searchQuery = '';

  // Applied only by an explicit Apply and Restart.
  late String _initialRelayDomain;
  late String _selectedRelay;
  bool _showAddRelay = false;
  final _newRelayController = TextEditingController();

  // Profile keeps an explicit Save; every other category auto-saves on change.
  bool _profileDirty = false;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    _liveDisplayName = widget.displayNameController.text;
    _liveStatus = widget.statusController.text;
    widget.displayNameController.addListener(_onFieldChanged);
    widget.statusController.addListener(_onFieldChanged);
    widget.aboutMeController.addListener(_onProfileEdited);

    _initialRelayDomain = ref.read(relayDomainProvider);
    _selectedRelay = _initialRelayDomain;
  }

  void _onFieldChanged() {
    setState(() {
      _liveDisplayName = widget.displayNameController.text;
      _liveStatus = widget.statusController.text;
    });
    _onProfileEdited();
  }

  void _onProfileEdited() {
    if (!_profileDirty && mounted) setState(() => _profileDirty = true);
  }

  /// Shared prologue for the avatar and banner pickers. Returns null when
  /// nothing further should happen, otherwise the raw bytes still needing the
  /// crop dialog; ANIMATED input goes straight to [onAnimatedPicked], because
  /// skipping the cropper is what preserves the animation.
  ///
  /// Deliberately no SOURCE size check: Rust rejects on what it PRODUCES, and a
  /// large GIF that converts small is a fine avatar. The animated test reads the
  /// BYTES, never the extension, or animated WebP and APNG go through the
  /// cropper and silently arrive as a still.
  Future<Uint8List?> _pickImageRaw({
    required void Function(Uint8List rawBytes) onAnimatedPicked,
  }) async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    if (path == null) return null;
    final raw = await File(path).readAsBytes();
    if (!mounted) return null;

    if (isAnimatedImageBytes(raw)) {
      onAnimatedPicked(Uint8List.fromList(raw));
      return null;
    }
    return raw;
  }

  Future<void> _pickAvatar() async {
    final raw = await _pickImageRaw(
      onAnimatedPicked: (rawBytes) => _processAnimated(rawBytes, avatar: true),
    );
    if (raw == null || !mounted) return;

    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: raw,
      aspectRatio: 1.0,
      title: 'Crop Avatar',
    );
    if (cropped == null || !mounted) return;

    // Stage the cropped PNG for the preview now; the WebP encode is a real
    // wall-clock wait and swaps in behind it.
    final prevBytes = _pendingAvatarBytes;
    final prevChanged = _avatarChanged;
    final gen = ++_avatarPickGen;
    setState(() {
      _pendingAvatarBytes = cropped;
      // A still pick drops any previous animation: null here becomes the
      // explicit clear at save time.
      _pendingAvatarStill = null;
      _pendingAvatarAnim = null;
      _avatarChanged = true;
      _profileDirty = true;
      _avatarBusy = true;
    });
    _avatarProcessing = () async {
      try {
        final processed = await network_api.processAvatar(rawBytes: cropped);
        if (!mounted || gen != _avatarPickGen) return;
        setState(() {
          _pendingAvatarBytes = processed;
          _avatarBusy = false;
        });
      } catch (e) {
        if (!mounted || gen != _avatarPickGen) return;
        // The pick failed, so revert the optimistic staging.
        setState(() {
          _pendingAvatarBytes = prevBytes;
          _avatarChanged = prevChanged;
          _avatarBusy = false;
        });
        HollowToast.show(context, 'Failed to process image',
            type: HollowToastType.error);
      }
    }();
  }

  void _clearAvatar() {
    setState(() {
      // Uint8List(0) is the CLEAR sentinel, which a late processing result must
      // never overwrite.
      _avatarPickGen++;
      _avatarBusy = false;
      _pendingAvatarBytes = Uint8List(0);
      _pendingAvatarStill = null;
      _pendingAvatarAnim = null;
      _avatarChanged = true;
      _profileDirty = true;
    });
  }

  Future<void> _pickBanner() async {
    final raw = await _pickImageRaw(
      onAnimatedPicked: (rawBytes) => _processAnimated(rawBytes, avatar: false),
    );
    if (raw == null || !mounted) return;

    // 2.5:1, matching the profile dialog's header and Rust's banner storage.
    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: raw,
      aspectRatio: 2.5,
      title: 'Crop Banner',
    );
    if (cropped == null || !mounted) return;

    final prevBytes = _pendingBannerBytes;
    final prevChanged = _bannerChanged;
    final gen = ++_bannerPickGen;
    setState(() {
      _pendingBannerBytes = cropped;
      _pendingBannerStill = null;
      _pendingBannerAnim = null;
      _bannerChanged = true;
      _profileDirty = true;
      _bannerBusy = true;
    });
    _bannerProcessing = () async {
      try {
        final processed = await network_api.processBanner(rawBytes: cropped);
        if (!mounted || gen != _bannerPickGen) return;
        setState(() {
          _pendingBannerBytes = processed;
          _bannerBusy = false;
        });
      } catch (e) {
        if (!mounted || gen != _bannerPickGen) return;
        setState(() {
          _pendingBannerBytes = prevBytes;
          _bannerChanged = prevChanged;
          _bannerBusy = false;
        });
        HollowToast.show(context, 'Failed to process image',
            type: HollowToastType.error);
      }
    }();
  }

  void _clearBanner() {
    setState(() {
      _bannerPickGen++;
      _bannerBusy = false;
      _pendingBannerBytes = Uint8List(0);
      _pendingBannerStill = null;
      _pendingBannerAnim = null;
      _bannerChanged = true;
      _profileDirty = true;
    });
  }

  /// An ANIMATED pick: Rust crops, walks the quality ladder and caches the
  /// result on the asset rail, handing back the hash, the animation for the
  /// preview and the still companion that rides the profile push.
  ///
  /// The failure toast shows Rust's message verbatim, because a message naming
  /// the length that would fit beats "too large".
  void _processAnimated(Uint8List rawBytes, {required bool avatar}) {
    final gen = avatar ? ++_avatarPickGen : ++_bannerPickGen;
    setState(() {
      if (avatar) {
        _avatarBusy = true;
      } else {
        _bannerBusy = true;
      }
      _profileDirty = true;
    });
    final work = () async {
      try {
        final media = avatar
            ? await network_api.processAndStoreAvatarAnim(rawBytes: rawBytes)
            : await network_api.processAndStoreBannerAnim(rawBytes: rawBytes);
        if (!mounted || gen != (avatar ? _avatarPickGen : _bannerPickGen)) {
          return;
        }
        // The blob is already stored; seeding skips the round trip back out so
        // every surface paints it immediately.
        ref.read(profileAnimProvider.notifier).seed(media.hash, media.bytes);
        setState(() {
          if (avatar) {
            _pendingAvatarBytes = media.bytes;
            _pendingAvatarStill = media.still;
            _pendingAvatarAnim = media.hash;
            _avatarChanged = true;
            _avatarBusy = false;
          } else {
            _pendingBannerBytes = media.bytes;
            _pendingBannerStill = media.still;
            _pendingBannerAnim = media.hash;
            _bannerChanged = true;
            _bannerBusy = false;
          }
        });
      } catch (e) {
        if (!mounted || gen != (avatar ? _avatarPickGen : _bannerPickGen)) {
          return;
        }
        setState(() {
          if (avatar) {
            _avatarBusy = false;
          } else {
            _bannerBusy = false;
          }
        });
        HollowToast.show(context, '$e', type: HollowToastType.error);
      }
    }();
    if (avatar) {
      _avatarProcessing = work;
    } else {
      _bannerProcessing = work;
    }
  }

  @override
  void dispose() {
    widget.displayNameController.removeListener(_onFieldChanged);
    widget.statusController.removeListener(_onFieldChanged);
    widget.aboutMeController.removeListener(_onProfileEdited);
    _newRelayController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _pickFrame() async {
    final saved = ref.read(
        profileProvider.select((p) => p[widget.localPeerId]?.avatarFrame)) ??
        '';
    final pick = await showAvatarFramePicker(
      context: context,
      peerId: widget.localPeerId,
      currentId: _frameChanged ? (_pendingFrameId ?? '') : saved,
    );
    if (pick == null || !mounted) return;
    setState(() {
      _pendingFrameId = pick.id;
      _frameChanged = true;
      _profileDirty = true;
    });
  }

  void _clearFrame() {
    setState(() {
      _pendingFrameId = '';
      _frameChanged = true;
      _profileDirty = true;
    });
  }

  /// Commits the Profile category, which keeps an explicit Save because its
  /// text fields and cropped images want a single commit. Does NOT close the
  /// dialog.
  Future<void> _saveProfile() async {
    if (_savingProfile) return;
    setState(() => _savingProfile = true);
    try {
      // A Save tapped during image processing WAITS for the final WebP, or for
      // the failure revert, rather than committing half-staged state.
      final avatarWait = _avatarProcessing;
      if (avatarWait != null) await avatarWait;
      final bannerWait = _bannerProcessing;
      if (bannerWait != null) await bannerWait;
      if (!mounted) return;

      final displayName = widget.displayNameController.text.trim();
      final status = widget.statusController.text.trim();
      final aboutMe = widget.aboutMeController.text.trim();

      // The legacy `twitch_username` is carried through UNCHANGED: it is a
      // self-declaration, and the verified mark it stood in for lives in
      // `support_creds` now. Writing it from a connected account would keep an
      // unverifiable claim alive on the wire.
      await ref.read(profileProvider.notifier).updateMyProfile(
            displayName: displayName,
            status: status,
            aboutMe: aboutMe,
            // The STILL rides the push; the animation is already on the rail
            // and travels as its hash. An empty hash on a still pick drops a
            // previous animation.
            avatarBytes: _avatarChanged
                ? (_pendingAvatarStill ?? _pendingAvatarBytes)
                : null,
            bannerBytes: _bannerChanged
                ? (_pendingBannerStill ?? _pendingBannerBytes)
                : null,
            twitchUsername: ref
                    .read(profileProvider)[
                        ref.read(identityProvider).peerId ?? '']
                    ?.twitchUsername ??
                '',
            avatarFrame: _frameChanged ? (_pendingFrameId ?? '') : null,
            avatarAnim: _avatarChanged ? (_pendingAvatarAnim ?? '') : null,
            bannerAnim: _bannerChanged ? (_pendingBannerAnim ?? '') : null,
          );

      if (!mounted) return;
      setState(() {
        _profileDirty = false;
        _avatarChanged = false;
        _bannerChanged = false;
        _frameChanged = false;
      });
      HollowToast.show(context, 'Profile saved', type: HollowToastType.success);
    } catch (e) {
      // Keep the dirty flags: the edits are intact and Save is retryable.
      if (mounted) {
        HollowToast.show(context, 'Failed to save profile: $e',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  Future<void> _applyRelayAndRestart() async {
    await ref.read(relayDomainProvider.notifier).setDomain(_selectedRelay);
    await ref.read(savedRelayListProvider.notifier).addRelay(_selectedRelay);
    // Only via the shared waiter: a directly-spawned copy dies against the
    // native single-instance forwarder while this one is still shutting down.
    await relaunchApp();
  }

  Future<void> _removeRelay(String domain) async {
    await ref.read(savedRelayListProvider.notifier).removeRelay(domain);
    if (_selectedRelay == domain) {
      setState(() => _selectedRelay = kDefaultRelayDomain);
    }
  }

  Future<void> _submitNewRelay() async {
    final domain = _newRelayController.text.trim();
    if (domain.isEmpty) return;
    final list = ref.read(savedRelayListProvider);
    if (list.contains(domain)) return;
    await ref.read(savedRelayListProvider.notifier).addRelay(domain);
    setState(() {
      _selectedRelay = domain;
      _newRelayController.clear();
      _showAddRelay = false;
    });
  }

  void _cancelAddRelay() {
    setState(() {
      _newRelayController.clear();
      _showAddRelay = false;
    });
  }

  /// Categories matching the current search query, or all of them when it is
  /// empty.
  List<_SettingsCategory> get _filteredCategories {
    if (_searchQuery.isEmpty) return _SettingsCategory.values;
    final q = _searchQuery.toLowerCase();
    return _SettingsCategory.values
        .where((c) => c.label.toLowerCase().contains(q) || c.searchTerms.contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final radius = BorderRadius.circular(hollow.radiusLg);
    final screen = MediaQuery.of(context).size;

    // Grows with the window rather than sitting at a fixed size, which left the
    // rail and the cards cramped.
    final dialogWidth = screen.width * 0.9 < 920.0 ? screen.width * 0.9 : 920.0;
    final dialogHeight = screen.height * 0.86 < 680.0 ? screen.height * 0.86 : 680.0;

    // The comfortable minimum must still yield to the viewport: in
    // BoxConstraints a min LARGER than the max wins, so a flat minimum in a
    // short viewport pushes the close button off screen and locks the user out
    // at a high interface scale.
    final dialogMinWidth = dialogWidth < 360.0 ? dialogWidth : 360.0;
    final dialogMinHeight = dialogHeight < 420.0 ? dialogHeight : 420.0;

    final filtered = _filteredCategories;
    // Falls back to the first match so the content area never goes blank while
    // the user is typing.
    final activeForContent =
        filtered.contains(_activeTab) ? _activeTab : (filtered.isNotEmpty ? filtered.first : _activeTab);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.lg),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: dialogWidth,
            maxHeight: dialogHeight,
            minHeight: dialogMinHeight,
            minWidth: dialogMinWidth,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: hollow.elevated.withValues(alpha: 0.96),
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
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Own traversal group, so Tab cycles the categories
                  // separately from the content pane.
                  FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: _buildRail(hollow, filtered, activeForContent),
                  ),

                  Container(width: 1, color: hollow.border),

                  // Own traversal group, so Tab stays WITHIN the active pane
                  // instead of leaking back into the category rail.
                  Expanded(
                    child: FocusTraversalGroup(
                      policy: ReadingOrderTraversalPolicy(),
                      child: Stack(
                        children: [
                          _buildCategoryContent(hollow, activeForContent),
                          Positioned(
                            top: HollowSpacing.sm,
                            right: HollowSpacing.sm,
                            child: HollowPressable(
                              onTap: () => Navigator.of(context).pop(),
                              subtle: true,
                              borderRadius:
                                  BorderRadius.circular(hollow.radiusMd),
                              padding: const EdgeInsets.all(HollowSpacing.xs),
                              semanticLabel: 'Close',
                              child: Icon(LucideIcons.x,
                                  size: 18, color: hollow.textSecondary),
                            ),
                          ),
                        ],
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

  Widget _buildRail(HollowTheme hollow, List<_SettingsCategory> filtered,
      _SettingsCategory activeForContent) {
    return Container(
      width: 188,
      color: hollow.surface.withValues(alpha: 0.4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.md,
              HollowSpacing.lg,
              HollowSpacing.md,
              HollowSpacing.sm,
            ),
            child: Text(
              'Settings',
              style: HollowTypography.heading.copyWith(
                color: hollow.textPrimary,
                fontSize: 18,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HollowSpacing.sm,
              HollowSpacing.sm,
              HollowSpacing.sm,
              HollowSpacing.md,
            ),
            child: HollowTextField(
              controller: _searchController,
              hintText: 'Search settings',
              isDense: true,
              prefixIcon:
                  Icon(LucideIcons.search, size: 14, color: hollow.textSecondary),
              borderRadius: hollow.radiusSm,
              onChanged: (v) =>
                  setState(() => _searchQuery = v.trim()),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.xxs,
              ),
              children: [
                if (filtered.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(HollowSpacing.md),
                    child: Text(
                      'No matching settings',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary,
                      ),
                    ),
                  ),
                for (final cat in filtered) ...[
                  _TabItem(
                    icon: cat.icon,
                    label: cat.label,
                    isActive: cat == activeForContent,
                    onTap: () =>
                        setState(() => _activeTab = cat),
                  ),
                  const SizedBox(height: HollowSpacing.xxs),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the scrollable card content for the active category. Profile and
  /// Network take the dialog-scoped edit state, so it survives a category
  /// switch.
  Widget _buildCategoryContent(HollowTheme hollow, _SettingsCategory cat) {
    final Widget body = switch (cat) {
      _SettingsCategory.profile => _buildProfileSection(),
      _SettingsCategory.appearance => const AppearanceSettingsView(),
      _SettingsCategory.accessibility => const AccessibilitySettingsView(),
      _SettingsCategory.network => _buildNetworkSection(),
      _SettingsCategory.storage => const StorageSettingsView(),
      _SettingsCategory.audio => const AudioVideoSettingsView(),
      _SettingsCategory.shortcuts => const ShortcutsSettingsView(),
      _SettingsCategory.security => const SecurityTab(),
      _SettingsCategory.devices => const DevicesCategoryView(),
      _SettingsCategory.backup => const BackupCategoryView(),
      _SettingsCategory.updates => const UpdatesTab(),
      _SettingsCategory.about => const AboutTab(),
    };
    return Padding(
      key: ValueKey(cat),
      // Extra top padding so content clears the floating close button.
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.xl,
        44,
        HollowSpacing.xl,
        HollowSpacing.xl,
      ),
      child: body,
    );
  }

  Widget _buildProfileSection() {
    return ProfileSection(
      localPeerId: widget.localPeerId,
      displayNameController: widget.displayNameController,
      statusController: widget.statusController,
      aboutMeController: widget.aboutMeController,
      liveDisplayName: _liveDisplayName,
      liveStatus: _liveStatus,
      pendingAvatarBytes: _pendingAvatarBytes,
      pendingBannerBytes: _pendingBannerBytes,
      avatarChanged: _avatarChanged,
      bannerChanged: _bannerChanged,
      profileDirty: _profileDirty,
      savingProfile: _savingProfile,
      avatarProcessing: _avatarBusy,
      bannerProcessing: _bannerBusy,
      onPickAvatar: _pickAvatar,
      onClearAvatar: _clearAvatar,
      onPickBanner: _pickBanner,
      onClearBanner: _clearBanner,
      pendingFrameId: _pendingFrameId,
      frameChanged: _frameChanged,
      onPickFrame: _pickFrame,
      onClearFrame: _clearFrame,
      onSaveProfile: _saveProfile,
      onAboutMeChanged: () => setState(() {}),
    );
  }

  Widget _buildNetworkSection() {
    return NetworkSettingsView(
      selectedRelay: _selectedRelay,
      initialRelay: _initialRelayDomain,
      showAddRelay: _showAddRelay,
      newRelayController: _newRelayController,
      onSelectRelay: (domain) => setState(() => _selectedRelay = domain),
      onRemoveRelay: _removeRelay,
      onShowAddRelay: () => setState(() => _showAddRelay = true),
      onSubmitAddRelay: _submitNewRelay,
      onCancelAddRelay: _cancelAddRelay,
      onApplyRestart: _applyRelayAndRestart,
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
