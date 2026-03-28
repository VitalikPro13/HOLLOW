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
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons/lucide_icons.dart';

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
  bool _saving = false;
  bool _savingNickname = false;
  int _maxFileSizeMb = 34;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.server.name);
    _descController = TextEditingController();
    _nicknameController = TextEditingController();
    _loadDescription();
    _loadNickname();
    _loadMaxFileSize();
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

  Future<void> _loadMaxFileSize() async {
    try {
      final val = await crdt_api.getServerSetting(
        serverId: widget.server.serverId,
        key: 'max_file_size_mb',
      );
      if (mounted && val.isNotEmpty) {
        setState(() {
          _maxFileSizeMb = int.tryParse(val) ?? 34;
        });
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

          // Max File Size
          Text(
            'Max File Size',
            style:
                HollowTypography.label.copyWith(color: hollow.textSecondary),
          ),
          const SizedBox(height: HollowSpacing.sm),
          Row(
            children: [
              Icon(LucideIcons.fileUp, size: 16, color: hollow.textSecondary),
              const SizedBox(width: HollowSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Maximum file upload size for this server',
                      style: HollowTypography.body.copyWith(
                        color: hollow.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '1–500 MB  •  Enter to save',
                      style: HollowTypography.caption.copyWith(
                        color: hollow.textSecondary.withValues(alpha: 0.5),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 100,
                child: HollowTextField(
                  controller: TextEditingController(text: _maxFileSizeMb.toString()),
                  isDense: true,
                  hintText: '1–500',
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontSize: 13,
                  ),
                  borderRadius: hollow.radiusSm,
                  onSubmitted: (val) async {
                    final mb = int.tryParse(val.trim());
                    if (mb == null || mb < 1 || mb > 500) {
                      HollowToast.show(context, 'Must be between 1 and 500 MB', type: HollowToastType.error);
                      return;
                    }
                    setState(() => _maxFileSizeMb = mb);
                    try {
                      await crdt_api.updateServerSetting(
                        serverId: widget.server.serverId,
                        key: 'max_file_size_mb',
                        value: mb.toString(),
                      );
                      if (mounted) HollowToast.show(context, 'Max file size set to ${mb}MB', type: HollowToastType.success);
                    } catch (_) {}
                  },
                ),
              ),
              const SizedBox(width: HollowSpacing.sm),
              Text(
                'MB',
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
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
