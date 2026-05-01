import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/settings/server_template.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

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

  bool _twitchEnabled = false;
  bool _twitchRequireSub = false;
  bool _twitchOwnerVerify = false;
  bool _savingTwitch = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.server.name);
    _descController = TextEditingController();
    _nicknameController = TextEditingController();
    _twitchChannelController = TextEditingController();
    _twitchChannelIdController = TextEditingController();
    _twitchMinDaysController = TextEditingController(text: '0');
    _loadDescription();
    _loadNickname();
    _loadTwitchSettings();
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
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final raw = await File(path).readAsBytes();
    if (!mounted) return;
    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: raw,
      aspectRatio: 1.0,
      title: 'Crop Server Icon',
    );
    if (cropped == null || !mounted) return;
    try {
      await crdt_api.setServerAvatar(
        serverId: widget.server.serverId,
        rawBytes: cropped,
      );
      if (mounted) {
        HollowToast.show(context, 'Server icon updated',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to update icon: $e',
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
      if (userId != null && mounted) {
        setState(() {
          _twitchChannelIdController.text = userId;
        });
        HollowToast.show(context, 'Twitch ID filled from your account', type: HollowToastType.success);
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
    try {
      await crdt_api.clearServerAvatar(serverId: widget.server.serverId);
      if (mounted) {
        HollowToast.show(context, 'Server icon removed',
            type: HollowToastType.success);
      }
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
                final avatar = ref.watch(serverAvatarProvider)[widget.server.serverId];
                if (avatar != null) {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    child: Image.memory(avatar, width: 48, height: 48, fit: BoxFit.cover),
                  );
                }
                return Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: hollow.elevated,
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                  ),
                  alignment: Alignment.center,
                  child: Icon(LucideIcons.image, size: 20, color: hollow.textSecondary),
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
              Icon(SimpleIcons.twitch, size: 16, color: const Color(0xFF9146FF)),
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
