import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/server_avatar_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons/lucide_icons.dart';

class MobileServerSettingsRoute extends ConsumerStatefulWidget {
  final String serverId;

  const MobileServerSettingsRoute({super.key, required this.serverId});

  @override
  ConsumerState<MobileServerSettingsRoute> createState() =>
      _MobileServerSettingsRouteState();
}

class _MobileServerSettingsRouteState
    extends ConsumerState<MobileServerSettingsRoute> {
  late final TextEditingController _nameController;
  late final TextEditingController _descController;
  late final TextEditingController _nicknameController;
  bool _saving = false;
  bool _savingNickname = false;

  @override
  void initState() {
    super.initState();
    final server = ref.read(serverListProvider)[widget.serverId];
    _nameController = TextEditingController(text: server?.name ?? '');
    _descController = TextEditingController();
    _nicknameController = TextEditingController();
    _loadDescription();
    _loadNickname();
  }

  Future<void> _loadDescription() async {
    try {
      final desc = await crdt_api.getServerSetting(
        serverId: widget.serverId,
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
        serverId: widget.serverId,
      );
      final me = members.where((m) => m.peerId == peerId).firstOrNull;
      if (mounted && me != null && me.nickname.isNotEmpty) {
        _nicknameController.text = me.nickname;
      }
    } catch (_) {}
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
    if (newName.isEmpty) return;
    setState(() => _saving = true);
    try {
      await crdt_api.renameServer(
        serverId: widget.serverId,
        newName: newName,
      );
      if (mounted) {
        HollowToast.show(context, 'Server renamed',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to rename',
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
        serverId: widget.serverId,
        key: 'description',
        value: desc,
      );
      if (mounted) {
        HollowToast.show(context, 'Description updated',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to update',
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
        serverId: widget.serverId,
        peerId: peerId,
        nickname: nickname,
      );
      ref.invalidate(serverMembersProvider(widget.serverId));
      if (mounted) {
        HollowToast.show(
          context,
          nickname.isEmpty ? 'Nickname cleared' : 'Nickname updated',
          type: HollowToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to update nickname',
            type: HollowToastType.error);
      }
    } finally {
      if (mounted) setState(() => _savingNickname = false);
    }
  }

  Future<void> _pickAvatar() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null) return;
    final bytes = await result.files.first.xFile.readAsBytes();
    if (!mounted) return;

    final cropped = await showImageCropDialog(
      context: context,
      imageBytes: bytes,
      aspectRatio: 1.0,
      title: 'Crop Server Avatar',
    );
    if (cropped == null || !mounted) return;

    try {
      await crdt_api.setServerAvatar(
        serverId: widget.serverId,
        rawBytes: cropped,
      );
      ref.invalidate(serverAvatarProvider);
      if (mounted) {
        HollowToast.show(context, 'Avatar updated',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to update avatar',
            type: HollowToastType.error);
      }
    }
  }

  Future<void> _clearAvatar() async {
    try {
      await crdt_api.clearServerAvatar(serverId: widget.serverId);
      ref.invalidate(serverAvatarProvider);
      if (mounted) {
        HollowToast.show(context, 'Avatar cleared',
            type: HollowToastType.success);
      }
    } catch (e) {
      if (mounted) {
        HollowToast.show(context, 'Failed to clear avatar',
            type: HollowToastType.error);
      }
    }
  }

  void _confirmDelete() {
    showHollowDialog(
      context: context,
      builder: (_) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx) {
              final hollow = HollowTheme.of(ctx);
              final server = ref.read(serverListProvider)[widget.serverId];
              return Container(
                constraints: const BoxConstraints(maxWidth: 360),
                padding: const EdgeInsets.all(HollowSpacing.xl),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(color: hollow.border),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Delete Server',
                      style: HollowTypography.heading
                          .copyWith(color: hollow.textPrimary),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Text(
                      'Are you sure you want to delete "${server?.name}"? This cannot be undone.',
                      textAlign: TextAlign.center,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textSecondary),
                    ),
                    const SizedBox(height: HollowSpacing.xl),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.danger(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              await crdt_api.deleteServer(
                                  serverId: widget.serverId);
                              ref.read(selectedServerProvider.notifier).state =
                                  null;
                              ref
                                  .read(selectedChannelProvider.notifier)
                                  .state = null;
                              ref.read(channelListProvider.notifier).clear();
                              if (mounted) {
                                Navigator.pop(context);
                                HollowToast.show(context, 'Server deleted',
                                    type: HollowToastType.success);
                              }
                            },
                            child: const Text('Delete'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  void _confirmLeave() {
    showHollowDialog(
      context: context,
      builder: (_) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx) {
              final hollow = HollowTheme.of(ctx);
              final server = ref.read(serverListProvider)[widget.serverId];
              return Container(
                constraints: const BoxConstraints(maxWidth: 360),
                padding: const EdgeInsets.all(HollowSpacing.xl),
                decoration: BoxDecoration(
                  color: hollow.elevated,
                  borderRadius: BorderRadius.circular(hollow.radiusLg),
                  border: Border.all(color: hollow.border),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Leave Server',
                      style: HollowTypography.heading
                          .copyWith(color: hollow.textPrimary),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Text(
                      'Are you sure you want to leave "${server?.name}"?',
                      textAlign: TextAlign.center,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textSecondary),
                    ),
                    const SizedBox(height: HollowSpacing.xl),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.danger(
                            onPressed: () async {
                              Navigator.pop(ctx);
                              await crdt_api.leaveServer(
                                  serverId: widget.serverId);
                              ref.read(selectedServerProvider.notifier).state =
                                  null;
                              ref
                                  .read(selectedChannelProvider.notifier)
                                  .state = null;
                              ref.read(channelListProvider.notifier).clear();
                              if (mounted) {
                                Navigator.pop(context);
                                HollowToast.show(context, 'Left server',
                                    type: HollowToastType.success);
                              }
                            },
                            child: const Text('Leave'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final server = ref.watch(serverListProvider)[widget.serverId];
    final role = ref.watch(myRoleProvider(widget.serverId)).valueOrNull ?? 'member';
    final perms = ref.watch(myPermissionsProvider(widget.serverId)).valueOrNull ?? 0;
    final canManage = (perms & Permission.manageServer) != 0;
    final isOwner = role == 'owner';
    final serverAvatar = ref.watch(serverAvatarProvider)[widget.serverId];

    if (server == null) {
      return Scaffold(
        backgroundColor: hollow.background,
        body: SafeArea(
          child: Center(
            child: Text('Server not found',
                style: HollowTypography.body.copyWith(color: hollow.textSecondary)),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: hollow.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: HollowSpacing.sm,
                vertical: HollowSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: hollow.surface,
                border: Border(bottom: BorderSide(color: hollow.border)),
              ),
              child: Row(
                children: [
                  HollowPressable(
                    onTap: () => Navigator.pop(context),
                    borderRadius: BorderRadius.circular(hollow.radiusMd),
                    padding: const EdgeInsets.all(HollowSpacing.sm),
                    child: Icon(LucideIcons.arrowLeft,
                        size: 22, color: hollow.textPrimary),
                  ),
                  const SizedBox(width: HollowSpacing.sm),
                  Expanded(
                    child: Text(
                      'Server Settings',
                      style: HollowTypography.heading
                          .copyWith(color: hollow.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(HollowSpacing.lg),
                children: [
                  // Server avatar + name header
                  Center(
                    child: Column(
                      children: [
                        GestureDetector(
                          onTap: canManage ? _pickAvatar : null,
                          onLongPress: canManage && serverAvatar != null
                              ? _clearAvatar
                              : null,
                          child: Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: hollow.elevated,
                              borderRadius:
                                  BorderRadius.circular(hollow.radiusLg),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: serverAvatar != null
                                ? Image.memory(serverAvatar, fit: BoxFit.cover)
                                : Center(
                                    child: Text(
                                      server.name.isNotEmpty
                                          ? server.name[0].toUpperCase()
                                          : '?',
                                      style:
                                          HollowTypography.display.copyWith(
                                        color: hollow.accent,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        if (canManage) ...[
                          const SizedBox(height: HollowSpacing.xs),
                          Text(
                            'Tap to change avatar',
                            style: HollowTypography.caption
                                .copyWith(color: hollow.textSecondary),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.xl),

                  // Server Name (admin only)
                  if (canManage) ...[
                    _SectionDivider(label: 'Server Name'),
                    const SizedBox(height: HollowSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: HollowTextField(
                            controller: _nameController,
                            hintText: 'Server name',
                            isDense: true,
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        HollowButton.filled(
                          onPressed: _saving ? null : _saveName,
                          compact: true,
                          child: const Text('Save'),
                        ),
                      ],
                    ),
                    const SizedBox(height: HollowSpacing.xl),
                  ],

                  // Description (admin only)
                  if (canManage) ...[
                    _SectionDivider(label: 'Description'),
                    const SizedBox(height: HollowSpacing.sm),
                    HollowTextField(
                      controller: _descController,
                      hintText: 'Server description',
                      maxLines: 3,
                      showCounter: true,
                      maxLength: 256,
                    ),
                    const SizedBox(height: HollowSpacing.sm),
                    Align(
                      alignment: Alignment.centerRight,
                      child: HollowButton.filled(
                        onPressed: _saving ? null : _saveDescription,
                        compact: true,
                        child: const Text('Save'),
                      ),
                    ),
                    const SizedBox(height: HollowSpacing.xl),
                  ],

                  // Server ID
                  _SectionDivider(label: 'Server ID'),
                  const SizedBox(height: HollowSpacing.sm),
                  Container(
                    padding: const EdgeInsets.all(HollowSpacing.md),
                    decoration: BoxDecoration(
                      color: hollow.elevated,
                      borderRadius: BorderRadius.circular(hollow.radiusMd),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            widget.serverId,
                            style: HollowTypography.mono.copyWith(
                              color: hollow.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.sm),
                        HollowPressable(
                          onTap: () {
                            Clipboard.setData(
                                ClipboardData(text: widget.serverId));
                            HollowToast.show(context, 'Copied',
                                type: HollowToastType.success);
                          },
                          borderRadius:
                              BorderRadius.circular(hollow.radiusSm),
                          padding: const EdgeInsets.all(HollowSpacing.xs),
                          child: Icon(LucideIcons.copy,
                              size: 16, color: hollow.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.xl),

                  // Your Nickname
                  _SectionDivider(label: 'Your Nickname'),
                  const SizedBox(height: HollowSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: HollowTextField(
                          controller: _nicknameController,
                          hintText: 'Server nickname (optional)',
                          isDense: true,
                        ),
                      ),
                      const SizedBox(width: HollowSpacing.sm),
                      HollowButton.filled(
                        onPressed: _savingNickname ? null : _saveNickname,
                        compact: true,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                  const SizedBox(height: HollowSpacing.xl + HollowSpacing.lg),

                  // Danger zone
                  _SectionDivider(label: 'Danger Zone', danger: true),
                  const SizedBox(height: HollowSpacing.md),
                  if (isOwner)
                    HollowButton.danger(
                      onPressed: _confirmDelete,
                      expand: true,
                      icon: const Icon(LucideIcons.trash2, size: 18),
                      child: const Text('Delete Server'),
                    )
                  else
                    HollowButton.danger(
                      onPressed: _confirmLeave,
                      expand: true,
                      icon: const Icon(LucideIcons.logOut, size: 18),
                      child: const Text('Leave Server'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  final String label;
  final bool danger;

  const _SectionDivider({required this.label, this.danger = false});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = danger ? hollow.error : hollow.textSecondary;
    return Row(
      children: [
        Expanded(child: Divider(color: color.withValues(alpha: 0.3))),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.md),
          child: Text(
            label,
            style: HollowTypography.caption.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        Expanded(child: Divider(color: color.withValues(alpha: 0.3))),
      ],
    );
  }
}
