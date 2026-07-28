import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_banner_provider.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/settings/server_template.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:atlas_icons/atlas_icons.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:hollow/src/core/brand_icons.dart';

/// Overview tab — server settings (admin+) and server identity (all members).
class OverviewTab extends ConsumerStatefulWidget {
  final ServerInfo server;
  final bool canManageServer;

  const OverviewTab({
    super.key,
    required this.server,
    required this.canManageServer,
  });

  @override
  ConsumerState<OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<OverviewTab> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _nicknameController;
  late final TextEditingController _twitchChannelController;
  late final TextEditingController _twitchChannelIdController;
  late final TextEditingController _twitchMinDaysController;
  bool _saving = false;
  bool _savingNickname = false;

  // Optimistic server-icon staging: the cropped bytes render instantly while
  // the Rust WebP encode + CRDT write run behind a small spinner. Any newer
  // pick/clear bumps the generation so a stale completion can't clobber it.
  Uint8List? _stagedIcon;
  bool _iconBusy = false;
  int _iconPickGen = 0;
  Uint8List? _stagedBanner;
  bool _bannerBusy = false;
  int _bannerPickGen = 0;

  bool _twitchEnabled = false;
  bool _twitchRequireSub = false;
  bool _twitchOwnerVerify = false;
  bool _savingTwitch = false;

  bool _isPrivate = false;
  bool _isNsfw = false;
  late final TextEditingController _maxMembersController;
  bool _savingAccess = false;

  /// Relay offline catch-up retention in DAYS (0 = off). Mirrors the CRDT
  /// setting `relay_catchup_secs` (stored in seconds).
  int _catchupDays = 0;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.server.name);
    _descController = TextEditingController();
    _nicknameController = TextEditingController();
    _twitchChannelController = TextEditingController();
    _twitchChannelIdController = TextEditingController();
    _twitchMinDaysController = TextEditingController(text: '0');
    _maxMembersController = TextEditingController();
    _loadDescription();
    _loadNickname();
    _loadTwitchSettings();
    _loadAccessSettings();
  }

  Future<void> _loadAccessSettings() async {
    try {
      final sid = widget.server.serverId;
      final isPrivate =
          await crdt_api.getServerSetting(serverId: sid, key: 'is_private');
      final isNsfw =
          await crdt_api.getServerSetting(serverId: sid, key: 'is_nsfw');
      final maxMembers =
          await crdt_api.getServerSetting(serverId: sid, key: 'max_members');
      final catchupSecs =
          await crdt_api.getServerSetting(serverId: sid, key: 'relay_catchup_secs');
      if (mounted) {
        setState(() {
          _isPrivate = isPrivate == 'true';
          _isNsfw = isNsfw == 'true';
          // 0 / empty = unlimited; leave the field blank in that case.
          _maxMembersController.text =
              (maxMembers.isEmpty || maxMembers == '0') ? '' : maxMembers;
          // Absent = default ON at 3 days (matches Rust relay_catchup_secs()).
          if (catchupSecs.isEmpty) {
            _catchupDays = 3;
          } else {
            final secs = int.tryParse(catchupSecs) ?? 0;
            _catchupDays = secs <= 0
                ? 0
                : (secs <= 86400 ? 1 : (secs <= 3 * 86400 ? 3 : 7));
          }
        });
      }
    } catch (_) {}
  }

  /// Applies immediately (single CRDT key, optimistic local apply in Rust).
  Future<void> _setRelayCatchup(int days) async {
    final prev = _catchupDays;
    setState(() => _catchupDays = days);
    try {
      await crdt_api.updateServerSetting(
        serverId: widget.server.serverId,
        key: 'relay_catchup_secs',
        value: (days * 86400).toString(),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _catchupDays = prev);
        HollowToast.show(context, 'Failed to update: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _saveAccessSettings() async {
    setState(() => _savingAccess = true);
    try {
      final sid = widget.server.serverId;
      // Empty or non-positive = unlimited, stored as "0".
      final raw = _maxMembersController.text.trim();
      final parsed = int.tryParse(raw) ?? 0;

      // A finite cap can't be set below the current member count (you can't
      // retroactively evict people). Check the live count, not the possibly
      // stale memberCount on the passed-in ServerInfo.
      if (parsed > 0) {
        final members = await crdt_api.getServerMembers(serverId: sid);
        final current = members.length;
        if (parsed < current) {
          if (mounted) {
            HollowToast.show(
              context,
              'Max can\'t be below the current member count ($current).',
              type: HollowToastType.error,
            );
            setState(() => _savingAccess = false);
          }
          return;
        }
      }

      final maxValue = parsed > 0 ? parsed.toString() : '0';
      await crdt_api.updateServerSetting(
          serverId: sid, key: 'is_private', value: _isPrivate ? 'true' : 'false');
      await crdt_api.updateServerSetting(
          serverId: sid, key: 'is_nsfw', value: _isNsfw ? 'true' : 'false');
      await crdt_api.updateServerSetting(
          serverId: sid, key: 'max_members', value: maxValue);
      if (mounted) {
        // Normalize the field to the saved value.
        _maxMembersController.text = maxValue == '0' ? '' : maxValue;
        HollowToast.show(context, 'Access settings saved',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to save: $e',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _savingAccess = false);
    }
  }

  Future<void> _loadDescription() async {
    try {
      final desc = await crdt_api.getServerSetting(
        serverId: widget.server.serverId,
        key: 'description',
      );
      if (mounted && desc.isNotEmpty) {
        _descController.text = desc;
      }
    } catch (_) {}
  }

  Future<void> _loadNickname() async {
    try {
      final peerId = ref.read(identityProvider).peerId ?? '';
      final members = await crdt_api.getServerMembers(
        serverId: widget.server.serverId,
      );
      final me = members.where((m) => m.peerId == peerId).firstOrNull;
      if (mounted && me != null && me.nickname.isNotEmpty) {
        _nicknameController.text = me.nickname;
      }
    } catch (_) {}
  }


  @override
  void didUpdateWidget(OverviewTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.server.name != widget.server.name) {
      _nameController.text = widget.server.name;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descController.dispose();
    _nicknameController.dispose();
    _twitchChannelController.dispose();
    _twitchChannelIdController.dispose();
    _twitchMinDaysController.dispose();
    _maxMembersController.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty || newName == widget.server.name) return;

    setState(() => _saving = true);
    try {
      await crdt_api.renameServer(
        serverId: widget.server.serverId,
        newName: newName,
      );
      if (mounted) {
        HollowToast.show(context, 'Server renamed',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to rename: $e',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveDescription() async {
    final desc = _descController.text.trim();
    setState(() => _saving = true);
    try {
      await crdt_api.updateServerSetting(
        serverId: widget.server.serverId,
        key: 'description',
        value: desc,
      );
      if (mounted) {
        HollowToast.show(context, 'Description updated',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to update: $e',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveNickname() async {
    final nickname = _nicknameController.text.trim();
    setState(() => _savingNickname = true);
    try {
      final peerId = ref.read(identityProvider).peerId ?? '';
      await crdt_api.setNickname(
        serverId: widget.server.serverId,
        peerId: peerId,
        nickname: nickname,
      );
      ref.invalidate(serverMembersProvider(widget.server.serverId));
      if (mounted) {
        HollowToast.show(
          context,
          nickname.isEmpty ? 'Nickname cleared' : 'Nickname updated',
          type: HollowToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to update nickname: $e',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _savingNickname = false);
    }
  }

  Future<void> _pickServerAvatar() async {
    final gen = ++_iconPickGen;
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final raw = await File(path).readAsBytes();
    if (!mounted || gen != _iconPickGen) return;
    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: raw,
      aspectRatio: 1.0,
      title: 'Crop Server Icon',
    );
    if (cropped == null || !mounted || gen != _iconPickGen) return;
    // Instant feedback: show the cropped bytes NOW; the Rust WebP encode +
    // CRDT write (a real wall-clock wait) runs behind the spinner.
    setState(() {
      _stagedIcon = cropped;
      _iconBusy = true;
    });
    try {
      await crdt_api.setServerAvatar(
        serverId: widget.server.serverId,
        rawBytes: cropped,
      );
      if (!mounted || gen != _iconPickGen) return;
      // Seed the provider with the bytes we just sent — reading the DB here
      // races the fire-and-forget CRDT persist and returns the PREVIOUS icon
      // ("second upload applies the first" bug). applyLocalWrite reconciles
      // to the processed bytes once the write lands.
      ref
          .read(serverAvatarProvider.notifier)
          .applyLocalWrite(widget.server.serverId, cropped);
      setState(() {
        _stagedIcon = null;
        _iconBusy = false;
      });
      HollowToast.show(context, 'Server icon updated',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted || gen != _iconPickGen) return;
      // Revert the optimistic staging — the pick failed.
      setState(() {
        _stagedIcon = null;
        _iconBusy = false;
      });
      HollowToast.show(context, 'Failed to update icon: $e',
          type: HollowToastType.error);
    }
  }

  /// GIF / animated-WebP magic — animated picks skip the crop dialog (the
  /// cropper flattens to a still PNG); Rust center-crops 3:1 per frame.
  static bool _isAnimatedPick(Uint8List bytes) {
    if (bytes.length > 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38) {
      return true; // GIF8
    }
    return bytes.length > 20 &&
        bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 && // RIFF
        bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50 && // WEBP
        bytes[12] == 0x56 && bytes[13] == 0x50 && bytes[14] == 0x38 && bytes[15] == 0x58 && // VP8X
        (bytes[20] & 0x02) != 0;
  }

  Future<void> _pickServerBanner() async {
    final gen = ++_bannerPickGen;
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final raw = await File(path).readAsBytes();
    if (!mounted || gen != _bannerPickGen) return;

    Uint8List toSend;
    if (_isAnimatedPick(raw)) {
      if (raw.length > 2 * 1024 * 1024) {
        HollowToast.show(context, 'Animated banner too large (max 2MB)',
            type: HollowToastType.error);
        return;
      }
      toSend = raw;
    } else {
      final cropped = await showImageCropDialog(
        context: context,
        imageBytes: raw,
        aspectRatio: 3.0,
        title: 'Crop Server Banner',
      );
      if (cropped == null || !mounted || gen != _bannerPickGen) return;
      toSend = cropped;
    }
    // Instant feedback: show the picked bytes NOW; the Rust WebP encode +
    // CRDT write (a real wall-clock wait) runs behind the spinner.
    setState(() {
      _stagedBanner = toSend;
      _bannerBusy = true;
    });
    try {
      await crdt_api.setServerBanner(
        serverId: widget.server.serverId,
        rawBytes: toSend,
      );
      if (!mounted || gen != _bannerPickGen) return;
      // Seed the provider with the bytes we just sent — reading the DB here
      // races the fire-and-forget CRDT persist ("second upload applies the
      // first" bug). applyLocalWrite reconciles once the write lands.
      ref
          .read(serverBannerProvider.notifier)
          .applyLocalWrite(widget.server.serverId, toSend);
      setState(() {
        _stagedBanner = null;
        _bannerBusy = false;
      });
      HollowToast.show(context, 'Server banner updated',
          type: HollowToastType.success);
    } catch (e) {
      if (!mounted || gen != _bannerPickGen) return;
      setState(() {
        _stagedBanner = null;
        _bannerBusy = false;
      });
      HollowToast.show(context, 'Failed to update banner: $e',
          type: HollowToastType.error);
    }
  }

  Future<void> _clearServerBanner() async {
    _bannerPickGen++;
    setState(() {
      _stagedBanner = null;
      _bannerBusy = false;
    });
    try {
      await crdt_api.clearServerBanner(serverId: widget.server.serverId);
      if (!mounted) return;
      ref
          .read(serverBannerProvider.notifier)
          .applyLocalWrite(widget.server.serverId, null);
      HollowToast.show(context, 'Server banner removed',
          type: HollowToastType.success);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to remove banner: $e',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _loadTwitchSettings() async {
    try {
      final sid = widget.server.serverId;
      final enabled = await crdt_api.getServerSetting(serverId: sid, key: 'twitch_verification_enabled');
      final channel = await crdt_api.getServerSetting(serverId: sid, key: 'twitch_channel_name');
      final channelId = await crdt_api.getServerSetting(serverId: sid, key: 'twitch_channel_id');
      final minDays = await crdt_api.getServerSetting(serverId: sid, key: 'twitch_min_follow_days');
      final requireSub = await crdt_api.getServerSetting(serverId: sid, key: 'twitch_require_sub');
      final ownerVerify = await crdt_api.getServerSetting(serverId: sid, key: 'twitch_owner_verify');
      if (mounted) {
        setState(() {
          _twitchEnabled = enabled == 'true';
          _twitchChannelController.text = channel;
          _twitchChannelIdController.text = channelId;
          _twitchMinDaysController.text = minDays.isEmpty ? '0' : minDays;
          _twitchRequireSub = requireSub == 'true';
          _twitchOwnerVerify = ownerVerify == 'true';
        });
      }
    } catch (_) {}
  }

  Future<void> _fillTwitchFromAccount() async {
    try {
      final userId = await twitch_api.twitchGetUserId();
      final username = await twitch_api.twitchGetUsername();
      if (userId != null && mounted) {
        setState(() {
          _twitchChannelIdController.text = userId;
          if (username != null && _twitchChannelController.text.isEmpty) {
            _twitchChannelController.text = username;
          }
        });
        HollowToast.show(context, 'Twitch ID and name filled from your account', type: HollowToastType.success);
      } else if (mounted) {
        HollowToast.show(context, 'Connect your Twitch account in user settings first', type: HollowToastType.error);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed: $e', type: HollowToastType.error);
      }
    }
  }

  Future<void> _saveTwitchSettings() async {
    setState(() => _savingTwitch = true);
    try {
      final sid = widget.server.serverId;
      await crdt_api.updateServerSetting(serverId: sid, key: 'twitch_verification_enabled', value: _twitchEnabled ? 'true' : 'false');
      await crdt_api.updateServerSetting(serverId: sid, key: 'twitch_channel_name', value: _twitchChannelController.text.trim());
      await crdt_api.updateServerSetting(serverId: sid, key: 'twitch_channel_id', value: _twitchChannelIdController.text.trim());
      await crdt_api.updateServerSetting(serverId: sid, key: 'twitch_min_follow_days', value: _twitchMinDaysController.text.trim());
      await crdt_api.updateServerSetting(serverId: sid, key: 'twitch_require_sub', value: _twitchRequireSub ? 'true' : 'false');
      await crdt_api.updateServerSetting(serverId: sid, key: 'twitch_owner_verify', value: _twitchOwnerVerify ? 'true' : 'false');

      // Set owner's Twitch username badge if they have a connected account
      if (_twitchEnabled) {
        final username = await twitch_api.twitchGetUsername();
        if (username != null && username.isNotEmpty) {
          final localPeerId = ref.read(identityProvider).peerId;
          if (localPeerId != null) {
            await crdt_api.setTwitchUsername(
                serverId: sid, peerId: localPeerId, twitchUsername: username);
          }
        }
      }

      if (mounted) {
        HollowToast.show(context, 'Twitch settings saved', type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to save: $e', type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _savingTwitch = false);
    }
  }

  Future<void> _clearServerAvatar() async {
    // Invalidate any in-flight pick — its late completion must not resurrect
    // the staged icon after the clear.
    _iconPickGen++;
    setState(() {
      _stagedIcon = null;
      _iconBusy = false;
    });
    try {
      await crdt_api.clearServerAvatar(serverId: widget.server.serverId);
      if (!mounted) return;
      // Drop the cached bytes NOW — a DB read here races the queued write
      // and would resurrect the just-removed icon.
      ref
          .read(serverAvatarProvider.notifier)
          .applyLocalWrite(widget.server.serverId, null);
      HollowToast.show(context, 'Server icon removed',
          type: HollowToastType.success);
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to remove icon: $e',
            type: HollowToastType.error);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    return ListView(
      padding: const EdgeInsets.all(HollowSpacing.xl),
      children: [
        // ── Server Settings (admin+ only) ──
        if (widget.canManageServer) ...[
          Text(
            'SERVER SETTINGS',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),

          // Server Avatar
          Text(
            'Server Icon',
            style:
                HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Builder(builder: (_) {
                // Staged bytes (optimistic pick) win over the provider cache.
                final avatar = _stagedIcon ??
                    ref.watch(serverAvatarProvider)[widget.server.serverId];
                final Widget icon;
                if (avatar != null) {
                  icon = ClipRRect(
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    child: Image.memory(avatar,
                        width: 48, height: 48, fit: BoxFit.cover,
                        gaplessPlayback: true),
                  );
                } else {
                  icon = Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: hollow.elevated,
                      borderRadius: BorderRadius.circular(hollow.radiusMd),
                    ),
                    alignment: Alignment.center,
                    child: Icon(LucideIcons.image, size: 20, color: hollow.textSecondary),
                  );
                }
                if (!_iconBusy) return icon;
                // Small non-blocking spinner while the WebP encode + CRDT
                // write run (the tile already shows the cropped bytes).
                return Stack(
                  children: [
                    icon,
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: hollow.textSecondary,
                        ),
                      ),
                    ),
                  ],
                );
              }),
              const SizedBox(width: HollowSpacing.md),
              HollowButton.ghost(
                onPressed: _pickServerAvatar,
                icon: const Icon(LucideIcons.upload, size: 14),
                compact: true,
                child: const Text('Upload'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Builder(builder: (_) {
                final hasAvatar = ref.watch(serverAvatarProvider).containsKey(widget.server.serverId);
                if (!hasAvatar) return const SizedBox.shrink();
                return HollowButton.ghost(
                  onPressed: _clearServerAvatar,
                  icon: const Icon(LucideIcons.trash2, size: 14),
                  compact: true,
                  child: const Text('Remove'),
                );
              }),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),

          // Server Banner (issue #25) — shown at the top of the channel
          // sidebar. Same optimistic-staging pattern as the icon above.
          Text(
            'Server Banner',
            style:
                HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Builder(builder: (_) {
                final banner = _stagedBanner ??
                    ref
                        .watch(serverBannerProvider)[widget.server.serverId]
                        ?.bytes;
                final Widget preview;
                if (banner != null) {
                  preview = ClipRRect(
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    child: AnimatedGifImage(
                      bytes: banner,
                      width: 144,
                      height: 48,
                      fit: BoxFit.cover,
                    ),
                  );
                } else {
                  preview = Container(
                    width: 144,
                    height: 48,
                    decoration: BoxDecoration(
                      color: hollow.elevated,
                      borderRadius: BorderRadius.circular(hollow.radiusMd),
                    ),
                    alignment: Alignment.center,
                    child: Icon(LucideIcons.image,
                        size: 20, color: hollow.textSecondary),
                  );
                }
                if (!_bannerBusy) return preview;
                return Stack(
                  children: [
                    preview,
                    Positioned(
                      right: 2,
                      bottom: 2,
                      child: SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: hollow.textSecondary,
                        ),
                      ),
                    ),
                  ],
                );
              }),
              const SizedBox(width: HollowSpacing.md),
              HollowButton.ghost(
                onPressed: _pickServerBanner,
                icon: const Icon(LucideIcons.upload, size: 14),
                compact: true,
                child: const Text('Upload'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Builder(builder: (_) {
                final hasBanner = ref
                    .watch(serverBannerProvider)
                    .containsKey(widget.server.serverId);
                if (!hasBanner) return const SizedBox.shrink();
                return HollowButton.ghost(
                  onPressed: _clearServerBanner,
                  icon: const Icon(LucideIcons.trash2, size: 14),
                  compact: true,
                  child: const Text('Remove'),
                );
              }),
            ],
          ),
          const SizedBox(height: HollowSpacing.lg),

          // Server Name
          Text(
            'Server Name',
            style:
                HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Expanded(
                child: HollowTextField(
                  controller: _nameController,
                  hintText: 'Server name',
                  maxLength: 32,
                  onSubmitted: (_) => _saveName(),
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.filled(
                onPressed: _saving ? null : _saveName,
                child: const Text('Save'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xl),

          // Description
          Text(
            'Description',
            style:
                HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          HollowTextField(
            controller: _descController,
            hintText: 'What is this server about?',
            maxLines: 3,
            maxLength: 256,
            onSubmitted: (_) => _saveDescription(),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Align(
            alignment: Alignment.centerRight,
            child: HollowButton.filled(
              onPressed: _saving ? null : _saveDescription,
              compact: true,
              child: const Text('Save Description'),
            ),
          ),
          const SizedBox(height: HollowSpacing.xl),
          Divider(color: hollow.border),
          const SizedBox(height: HollowSpacing.xl),

          // ── Access (private + member cap) ──
          Text(
            'ACCESS',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.globeLock,
                            size: 15, color: hollow.textSecondary),
                        const SizedBox(width: HollowSpacing.sm),
                        Text('Private server',
                            style: HollowTypography.body
                                .copyWith(color: hollow.textPrimary)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'New members can\'t join via the link.',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary, fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              HollowToggle(
                value: _isPrivate,
                onChanged: (v) => setState(() => _isPrivate = v),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Atlas.adult_18,
                            size: 15, color: hollow.textSecondary),
                        const SizedBox(width: HollowSpacing.sm),
                        Text('NSFW server',
                            style: HollowTypography.body
                                .copyWith(color: hollow.textPrimary)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Members must confirm before joining. For adult or '
                      'sensitive content.',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary, fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              HollowToggle(
                value: _isNsfw,
                onChanged: (v) => setState(() => _isNsfw = v),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.md),
          Text(
            'Max members',
            style:
                HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          HollowTextField(
            controller: _maxMembersController,
            hintText: 'Unlimited',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            isDense: true,
            onSubmitted: (_) => _saveAccessSettings(),
          ),
          const SizedBox(height: HollowSpacing.xs),
          Text(
            'Leave blank for no limit. Existing members are never removed.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11,
            ),
          ),
          const SizedBox(height: HollowSpacing.lg),
          Align(
            alignment: Alignment.centerRight,
            child: HollowButton.filled(
              onPressed: _savingAccess ? null : _saveAccessSettings,
              compact: true,
              child: const Text('Save Access Settings'),
            ),
          ),
          const SizedBox(height: HollowSpacing.xl),
          Divider(color: hollow.border),
          const SizedBox(height: HollowSpacing.xl),

          // ── Offline catch-up (relay message-availability cache) ──
          Text(
            'OFFLINE CATCH-UP',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(LucideIcons.inbox,
                            size: 15, color: hollow.textSecondary),
                        const SizedBox(width: HollowSpacing.sm),
                        Text('Relay offline catch-up',
                            style: HollowTypography.body
                                .copyWith(color: hollow.textPrimary)),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'The relay keeps encrypted channel messages so members '
                      'catch up even when nobody else is online. Text and '
                      'file cards only — the relay can\'t read any of it.',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary, fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              HollowToggle(
                value: _catchupDays > 0,
                onChanged: (v) => _setRelayCatchup(v ? 3 : 0),
              ),
            ],
          ),
          if (_catchupDays > 0) ...[
            const SizedBox(height: HollowSpacing.md),
            Text(
              'Keep messages for',
              style:
                  HollowTypography.label.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.sm),
            // Selection chips, not buttons: a filled HollowButton here read
            // as another primary CTA competing with the section Save buttons.
            Row(
              children: [
                for (final days in const [1, 3, 7]) ...[
                  Builder(builder: (context) {
                    final selected = _catchupDays == days;
                    return HollowPressable(
                      onTap: selected ? null : () => _setRelayCatchup(days),
                      borderRadius: BorderRadius.circular(hollow.radiusSm),
                      backgroundColor: selected ? hollow.accentMuted : null,
                      padding: const EdgeInsets.symmetric(
                        horizontal: HollowSpacing.md,
                        vertical: HollowSpacing.xs + 2,
                      ),
                      child: Text(
                        '$days day${days == 1 ? '' : 's'}',
                        style: HollowTypography.label.copyWith(
                          color: selected
                              ? hollow.accent
                              : hollow.textSecondary,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    );
                  }),
                  const SizedBox(width: HollowSpacing.sm),
                ],
              ],
            ),
          ],
          const SizedBox(height: HollowSpacing.xl),
          Divider(color: hollow.border),
          const SizedBox(height: HollowSpacing.xl),

          // Server Template
          Text(
            'SERVER TEMPLATE',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Export your server structure as a template, or import one to reconfigure this server.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              HollowButton.outline(
                onPressed: () =>
                    exportServerTemplate(context, widget.server),
                icon: const Icon(LucideIcons.upload, size: 14),
                compact: true,
                child: const Text('Export'),
              ),
              const SizedBox(width: HollowSpacing.sm),
              HollowButton.outline(
                onPressed: () =>
                    importServerTemplate(context, ref, widget.server),
                icon: const Icon(LucideIcons.download, size: 14),
                compact: true,
                child: const Text('Import'),
              ),
            ],
          ),
          const SizedBox(height: HollowSpacing.xl),

          // Server ID
          Text(
            'Server ID',
            style:
                HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.md,
              vertical: HollowSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusMd),
              border: Border.all(color: hollow.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: SelectableText(
                    widget.server.serverId,
                    style: HollowTypography.mono.copyWith(
                      color: hollow.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.ghost(
                  onPressed: () {
                    Clipboard.setData(
                      ClipboardData(text: widget.server.serverId),
                    );
                    HollowToast.show(context, 'Copied to clipboard');
                  },
                  compact: true,
                  icon: const Icon(LucideIcons.copy),
                  child: const Text('Copy'),
                ),
              ],
            ),
          ),

          const SizedBox(height: HollowSpacing.xl),
          Divider(color: hollow.border),
          const SizedBox(height: HollowSpacing.xl),

          // ── Twitch Verification ──
          Text(
            'TWITCH VERIFICATION',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Text(
            'Gate join requests behind Twitch follow or subscription checks.',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
            ),
          ),
          const SizedBox(height: HollowSpacing.md),

          // Enable toggle
          Row(
            children: [
              const Icon(BrandIcons.twitch, size: 16, color: Color(0xFF9146FF)),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Text(
                  'Require Twitch Verification',
                  style: HollowTypography.body.copyWith(color: hollow.textPrimary),
                ),
              ),
              HollowToggle(
                value: _twitchEnabled,
                onChanged: (v) => setState(() => _twitchEnabled = v),
              ),
            ],
          ),

          if (_twitchEnabled) ...[
            const SizedBox(height: HollowSpacing.lg),

            Text(
              'Twitch Channel ID',
              style: HollowTypography.label.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              'Your numeric Twitch user ID. Use "Fill from account" if you\'ve connected Twitch in user settings.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: HollowTextField(
                    controller: _twitchChannelIdController,
                    hintText: 'e.g. 123456789',
                    maxLength: 32,
                  ),
                ),
                const SizedBox(width: HollowSpacing.sm),
                HollowButton.ghost(
                  onPressed: _fillTwitchFromAccount,
                  compact: true,
                  icon: const Icon(LucideIcons.userCheck, size: 14),
                  child: const Text('Fill from account'),
                ),
              ],
            ),

            const SizedBox(height: HollowSpacing.lg),

            Text(
              'Channel Display Name',
              style: HollowTypography.label.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              'Shown to joiners in verification messages.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            HollowTextField(
              controller: _twitchChannelController,
              hintText: 'e.g. coolStreamer123',
              maxLength: 64,
            ),

            const SizedBox(height: HollowSpacing.lg),

            Text(
              'Minimum Follow Days',
              style: HollowTypography.label.copyWith(color: hollow.textSecondary),
            ),
            const SizedBox(height: HollowSpacing.xs),
            Text(
              'How many days someone must have been following before they can join. 0 = just following.',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            SizedBox(
              width: 100,
              child: HollowTextField(
                controller: _twitchMinDaysController,
                hintText: '0',
                maxLength: 4,
              ),
            ),

            const SizedBox(height: HollowSpacing.lg),

            // Require sub toggle
            Row(
              children: [
                Icon(LucideIcons.crown, size: 16, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Require Subscription',
                        style: HollowTypography.body.copyWith(color: hollow.textPrimary),
                      ),
                      Text(
                        'Members must be subscribed to your channel',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                HollowToggle(
                  value: _twitchRequireSub,
                  onChanged: (v) => setState(() => _twitchRequireSub = v),
                ),
              ],
            ),

            const SizedBox(height: HollowSpacing.lg),

            // Owner-online verification toggle
            Row(
              children: [
                Icon(LucideIcons.shield, size: 16, color: hollow.textSecondary),
                const SizedBox(width: HollowSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Owner-Online Verification',
                        style: HollowTypography.body.copyWith(color: hollow.textPrimary),
                      ),
                      Text(
                        'Only you (the owner) can accept join requests. Fully resistant to modified clients, but you must be online.',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textSecondary,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                HollowToggle(
                  value: _twitchOwnerVerify,
                  onChanged: (v) => setState(() => _twitchOwnerVerify = v),
                ),
              ],
            ),

            const SizedBox(height: HollowSpacing.lg),

            Align(
              alignment: Alignment.centerRight,
              child: HollowButton.filled(
                onPressed: _savingTwitch ? null : _saveTwitchSettings,
                compact: true,
                child: const Text('Save Twitch Settings'),
              ),
            ),
          ] else ...[
            const SizedBox(height: HollowSpacing.md),
            Align(
              alignment: Alignment.centerRight,
              child: HollowButton.filled(
                onPressed: _savingTwitch ? null : _saveTwitchSettings,
                compact: true,
                child: const Text('Save Twitch Settings'),
              ),
            ),
          ],

          const SizedBox(height: HollowSpacing.xl),
          Divider(color: hollow.border),
          const SizedBox(height: HollowSpacing.xl),
        ],

        // ── Your Identity (all members) ──
        Text(
          'YOUR IDENTITY',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: HollowSpacing.md),

        Text(
          'Server Nickname',
          style:
              HollowTypography.label.copyWith(color: hollow.textSecondary),
        ),
        const SizedBox(height: HollowSpacing.xs),
        Text(
          'This nickname is only visible on this server. Leave empty to use your display name.',
          style: HollowTypography.caption.copyWith(
            color: hollow.textSecondary,
          ),
        ),
        const SizedBox(height: HollowSpacing.sm),
        Row(
          children: [
            Expanded(
              child: HollowTextField(
                controller: _nicknameController,
                hintText: 'Nickname (optional)',
                maxLength: 32,
                onSubmitted: (_) => _saveNickname(),
              ),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.filled(
              onPressed: _savingNickname ? null : _saveNickname,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}
