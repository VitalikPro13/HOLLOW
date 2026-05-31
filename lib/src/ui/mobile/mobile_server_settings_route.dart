import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
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
import 'package:hollow/src/core/brand_icons.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_image_crop_route.dart';
import 'package:hollow/src/ui/mobile/mobile_storage_route.dart';
import 'package:hollow/src/ui/dialogs/image_crop_dialog.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_members_route.dart';
import 'package:hollow/src/ui/mobile/mobile_roles_route.dart';
import 'package:hollow/src/ui/mobile/mobile_labels_route.dart';
import 'package:hollow/src/ui/mobile/mobile_twitch_settings_route.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:lucide_icons_flutter/lucide_icons.dart';

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

    final isMobile = Platform.isAndroid || Platform.isIOS;
    final cropped = isMobile
        ? await showMobileImageCrop(
            context: context, imageBytes: bytes,
            aspectRatio: 1.0, title: 'Crop Server Avatar',
          )
        : await showImageCropDialog(
            context: context, imageBytes: bytes,
            aspectRatio: 1.0, title: 'Crop Server Avatar',
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
    final canManageChannels = (perms & Permission.manageChannels) != 0;
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

                  // Channels (admin only)
                  if (canManageChannels) ...[
                    _SectionDivider(label: 'Channels'),
                    const SizedBox(height: HollowSpacing.sm),
                    _ChannelLayoutEditor(serverId: widget.serverId),
                    const SizedBox(height: HollowSpacing.xl),
                  ],

                  // Management rows
                  _SectionDivider(label: 'Management'),
                  const SizedBox(height: HollowSpacing.sm),
                  _NavRow(
                    icon: LucideIcons.users,
                    label: 'Members',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MobileMembersRoute(serverId: widget.serverId),
                      ),
                    ),
                  ),
                  if ((perms & Permission.manageRoles) != 0)
                    _NavRow(
                      icon: LucideIcons.shieldCheck,
                      label: 'Roles',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MobileRolesRoute(serverId: widget.serverId),
                        ),
                      ),
                    ),
                  _NavRow(
                    icon: LucideIcons.tag,
                    label: 'Labels',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MobileLabelsRoute(serverId: widget.serverId),
                      ),
                    ),
                  ),
                  if (canManage)
                    _NavRow(
                      icon: BrandIcons.twitch,
                      label: 'Twitch Verification',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => MobileTwitchSettingsRoute(serverId: widget.serverId),
                        ),
                      ),
                    ),
                  _NavRow(
                    icon: LucideIcons.link,
                    label: 'Invite',
                    onTap: () {
                      final link = 'hollow://join?server=${widget.serverId}';
                      showInviteDialog(context, link, widget.serverId);
                    },
                  ),
                  _NavRow(
                    icon: LucideIcons.hardDrive,
                    label: 'Storage',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MobileStorageRoute(serverId: widget.serverId),
                      ),
                    ),
                  ),
                  const SizedBox(height: HollowSpacing.xl),

                  // Notifications
                  _SectionDivider(label: 'Notifications'),
                  const SizedBox(height: HollowSpacing.sm),
                  _NotificationSection(serverId: widget.serverId),
                  const SizedBox(height: HollowSpacing.xl),

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

class _NavRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _NavRow({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      subtle: true,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md, vertical: HollowSpacing.md,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: hollow.textSecondary),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Text(label, style: HollowTypography.body.copyWith(
              color: hollow.textPrimary,
            )),
          ),
          Icon(LucideIcons.chevronRight, size: 16, color: hollow.textSecondary),
        ],
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

// ─────────────────────────────────────────────────
// Notification level settings
// ─────────────────────────────────────────────────

class _NotificationSection extends ConsumerWidget {
  final String serverId;

  const _NotificationSection({required this.serverId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final notifState = ref.watch(notificationSettingsProvider);
    final notifNotifier = ref.read(notificationSettingsProvider.notifier);
    final channels = ref.watch(channelListProvider);
    final serverLevel = notifState.serverLevels[serverId] ?? NotificationLevel.all;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Default for all channels',
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary, fontSize: 11)),
        const SizedBox(height: HollowSpacing.sm),
        // Server-wide level pills
        Row(
          children: [
            Expanded(
              child: _NotifLevelPill(
                icon: LucideIcons.bell,
                label: 'All',
                isSelected: serverLevel == NotificationLevel.all,
                onTap: () => notifNotifier.setServerLevel(serverId, NotificationLevel.all),
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: _NotifLevelPill(
                icon: LucideIcons.atSign,
                label: 'Mentions',
                isSelected: serverLevel == NotificationLevel.mentions,
                onTap: () => notifNotifier.setServerLevel(serverId, NotificationLevel.mentions),
                activeColor: hollow.warning,
              ),
            ),
            const SizedBox(width: HollowSpacing.xs),
            Expanded(
              child: _NotifLevelPill(
                icon: LucideIcons.bellOff,
                label: 'Nothing',
                isSelected: serverLevel == NotificationLevel.nothing,
                onTap: () => notifNotifier.setServerLevel(serverId, NotificationLevel.nothing),
                activeColor: hollow.error,
              ),
            ),
          ],
        ),

        if (channels.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.lg),
          Text('Channel overrides',
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary, fontSize: 11)),
          const SizedBox(height: HollowSpacing.sm),
          ...channels.values.map((channel) {
            final override = notifNotifier.channelOverride(
                serverId, channel.channelId);
            return _ChannelNotifRow(
              channelName: channel.name,
              level: override,
              onTap: () => _showChannelOverrideSheet(
                context, ref, serverId, channel.channelId, channel.name, override,
              ),
            );
          }),
        ],
      ],
    );
  }

  void _showChannelOverrideSheet(
    BuildContext context,
    WidgetRef ref,
    String serverId,
    String channelId,
    String channelName,
    ChannelNotificationLevel current,
  ) {
    final hollow = HollowTheme.of(context);
    final options = [
      (ChannelNotificationLevel.inherit, 'Default', LucideIcons.settings),
      (ChannelNotificationLevel.all, 'All Messages', LucideIcons.bell),
      (ChannelNotificationLevel.mentions, 'Mentions Only', LucideIcons.atSign),
      (ChannelNotificationLevel.nothing, 'Nothing', LucideIcons.bellOff),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: hollow.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(hollow.radiusLg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.sm),
              child: Container(
                width: 32, height: 4,
                decoration: BoxDecoration(
                  color: hollow.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
            Text('#$channelName',
                style: HollowTypography.body.copyWith(
                  color: hollow.textSecondary, fontSize: 12)),
            const SizedBox(height: HollowSpacing.sm),
            for (final option in options)
              HollowPressable(
                onTap: () {
                  ref.read(notificationSettingsProvider.notifier)
                      .setChannelOverride(serverId, channelId, option.$1);
                  Navigator.pop(ctx);
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: HollowSpacing.lg,
                    vertical: HollowSpacing.sm + 2,
                  ),
                  child: Row(
                    children: [
                      Icon(option.$3, size: 16,
                          color: option.$1 == current
                              ? hollow.accent : hollow.textSecondary),
                      const SizedBox(width: HollowSpacing.md),
                      Expanded(
                        child: Text(option.$2,
                            style: HollowTypography.body.copyWith(
                              color: option.$1 == current
                                  ? hollow.accent : hollow.textPrimary,
                              fontWeight: option.$1 == current
                                  ? FontWeight.w600 : FontWeight.w400,
                            )),
                      ),
                      if (option.$1 == current)
                        Icon(LucideIcons.check, size: 16, color: hollow.accent),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: HollowSpacing.md),
          ],
        ),
      ),
    );
  }
}

class _NotifLevelPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final Color? activeColor;

  const _NotifLevelPill({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final color = activeColor ?? hollow.accent;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.15) : hollow.surface,
          borderRadius: BorderRadius.circular(hollow.radiusMd),
          border: Border.all(color: isSelected ? color : hollow.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14,
                color: isSelected ? color : hollow.textSecondary),
            const SizedBox(width: HollowSpacing.xs),
            Flexible(
              child: Text(label,
                  style: HollowTypography.body.copyWith(
                    color: isSelected ? color : hollow.textSecondary,
                    fontSize: 12,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelNotifRow extends StatelessWidget {
  final String channelName;
  final ChannelNotificationLevel level;
  final VoidCallback onTap;

  const _ChannelNotifRow({
    required this.channelName,
    required this.level,
    required this.onTap,
  });

  static const _labels = {
    ChannelNotificationLevel.inherit: 'Default',
    ChannelNotificationLevel.all: 'All',
    ChannelNotificationLevel.mentions: 'Mentions',
    ChannelNotificationLevel.nothing: 'Nothing',
  };

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: HollowPressable(
        onTap: onTap,
        subtle: true,
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.sm, vertical: HollowSpacing.sm),
        child: Row(
          children: [
            Icon(LucideIcons.hash, size: 16, color: hollow.textSecondary),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(channelName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary, fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: hollow.surface,
                borderRadius: BorderRadius.circular(hollow.radiusSm),
                border: Border.all(color: hollow.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_labels[level] ?? 'Default',
                      style: HollowTypography.body.copyWith(
                        color: hollow.textPrimary, fontSize: 12)),
                  const SizedBox(width: HollowSpacing.xs),
                  Icon(LucideIcons.chevronDown, size: 12,
                      color: hollow.textSecondary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────
// Channel layout editor (reorder, categories, CRUD)
// ─────────────────────────────────────────────────

class _ChannelLayoutEditor extends ConsumerStatefulWidget {
  final String serverId;

  const _ChannelLayoutEditor({required this.serverId});

  @override
  ConsumerState<_ChannelLayoutEditor> createState() =>
      _ChannelLayoutEditorState();
}

class _ChannelLayoutEditorState extends ConsumerState<_ChannelLayoutEditor> {
  List<LayoutItem> _layout = [];
  List<LayoutItem> _savedLayout = [];
  Map<String, ChannelInfo> _channels = {};
  bool _loaded = false;

  bool get _dirty {
    if (_layout.length != _savedLayout.length) return true;
    for (int i = 0; i < _layout.length; i++) {
      final a = _layout[i];
      final b = _savedLayout[i];
      if (a.runtimeType != b.runtimeType) return true;
      if (a is CategoryItem && b is CategoryItem && a.name != b.name) {
        return true;
      }
      if (a is ChannelItem && b is ChannelItem && a.channelId != b.channelId) {
        return true;
      }
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      ChannelListNotifier.fetchChannels(widget.serverId),
      ChannelLayoutNotifier.fetchLayout(widget.serverId),
    ]);
    if (!mounted) return;
    final channels = results[0] as Map<String, ChannelInfo>;
    final layoutJson = results[1] as String;
    final layout = _effectiveLayout(parseLayoutJson(layoutJson), channels);
    setState(() {
      _channels = channels;
      _layout = layout;
      _savedLayout = List.of(layout);
      _loaded = true;
    });
  }

  List<LayoutItem> _effectiveLayout(
    List<LayoutItem> base,
    Map<String, ChannelInfo> channels,
  ) {
    final layout = List<LayoutItem>.of(base);
    final placedIds =
        layout.whereType<ChannelItem>().map((c) => c.channelId).toSet();
    final missing = channels.keys
        .where((id) => !placedIds.contains(id))
        .toList()
      ..sort(
          (a, b) => (channels[a]?.name ?? '').compareTo(channels[b]?.name ?? ''));
    for (final id in missing) {
      layout.add(ChannelItem(id));
    }
    layout.removeWhere(
        (item) => item is ChannelItem && !channels.containsKey(item.channelId));
    return layout;
  }

  void _save() {
    crdt_api.updateChannelLayout(
      serverId: widget.serverId,
      layoutJson: layoutToJson(_layout),
    );
    setState(() => _savedLayout = List.of(_layout));
    HollowToast.show(context, 'Layout saved', type: HollowToastType.success);
  }

  void _addCategory() {
    final controller = TextEditingController();
    showHollowDialog(
      context: context,
      builder: (ctx) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx2) {
              final hollow = HollowTheme.of(ctx2);
              void submit() {
                final name = controller.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx2);
                setState(() => _layout.add(CategoryItem(name)));
              }

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
                    Text('New Category',
                        style: HollowTypography.heading
                            .copyWith(color: hollow.textPrimary)),
                    const SizedBox(height: HollowSpacing.md),
                    HollowTextField(
                      controller: controller,
                      hintText: 'Category name',
                      autofocus: true,
                      maxLength: 32,
                      onSubmitted: (_) => submit(),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.filled(
                            onPressed: submit,
                            child: const Text('Add'),
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

  void _renameCategory(int index, String currentName) {
    final controller = TextEditingController(text: currentName);
    showHollowDialog(
      context: context,
      builder: (ctx) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx2) {
              final hollow = HollowTheme.of(ctx2);
              void submit() {
                final name = controller.text.trim();
                if (name.isEmpty || name == currentName) {
                  Navigator.pop(ctx2);
                  return;
                }
                Navigator.pop(ctx2);
                setState(() => _layout[index] = CategoryItem(name));
              }

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
                    Text('Rename Category',
                        style: HollowTypography.heading
                            .copyWith(color: hollow.textPrimary)),
                    const SizedBox(height: HollowSpacing.md),
                    HollowTextField(
                      controller: controller,
                      hintText: 'Category name',
                      autofocus: true,
                      maxLength: 32,
                      onSubmitted: (_) => submit(),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.filled(
                            onPressed: submit,
                            child: const Text('Rename'),
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

  void _renameChannel(int index, String channelId, String currentName) {
    final controller = TextEditingController(text: currentName);
    showHollowDialog(
      context: context,
      builder: (ctx) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx2) {
              final hollow = HollowTheme.of(ctx2);
              Future<void> submit() async {
                final name = controller.text.trim();
                if (name.isEmpty || name == currentName) {
                  Navigator.pop(ctx2);
                  return;
                }
                Navigator.pop(ctx2);
                await crdt_api.renameChannel(
                  serverId: widget.serverId,
                  channelId: channelId,
                  newName: name,
                );
                final old = _channels[channelId];
                if (old != null) {
                  setState(() {
                    _channels[channelId] = old.copyWith(name: name);
                  });
                }
              }

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
                    Text('Rename Channel',
                        style: HollowTypography.heading
                            .copyWith(color: hollow.textPrimary)),
                    const SizedBox(height: HollowSpacing.md),
                    HollowTextField(
                      controller: controller,
                      hintText: 'Channel name',
                      autofocus: true,
                      maxLength: 32,
                      onSubmitted: (_) => submit(),
                    ),
                    const SizedBox(height: HollowSpacing.md),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.filled(
                            onPressed: submit,
                            child: const Text('Rename'),
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

  void _deleteChannel(int index, String channelId, String name) {
    showHollowDialog(
      context: context,
      builder: (ctx) => Center(
        child: Padding(
          padding: const EdgeInsets.all(HollowSpacing.xl),
          child: Material(
            color: Colors.transparent,
            child: Builder(builder: (ctx2) {
              final hollow = HollowTheme.of(ctx2);
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
                    Text('Delete Channel',
                        style: HollowTypography.heading
                            .copyWith(color: hollow.textPrimary)),
                    const SizedBox(height: HollowSpacing.md),
                    Text(
                      'Are you sure you want to delete #$name?',
                      textAlign: TextAlign.center,
                      style: HollowTypography.body
                          .copyWith(color: hollow.textSecondary),
                    ),
                    const SizedBox(height: HollowSpacing.xl),
                    Row(
                      children: [
                        Expanded(
                          child: HollowButton.ghost(
                            onPressed: () => Navigator.pop(ctx2),
                            child: const Text('Cancel'),
                          ),
                        ),
                        const SizedBox(width: HollowSpacing.md),
                        Expanded(
                          child: HollowButton.danger(
                            onPressed: () async {
                              Navigator.pop(ctx2);
                              setState(() {
                                _layout.removeAt(index);
                                _channels.remove(channelId);
                                _savedLayout = List.of(_layout);
                              });
                              await crdt_api.removeChannel(
                                serverId: widget.serverId,
                                channelId: channelId,
                              );
                              crdt_api.updateChannelLayout(
                                serverId: widget.serverId,
                                layoutJson: layoutToJson(_layout),
                              );
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

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);

    // Reload when channel events fire (per-server, no cascade).
    ref.listen(
      serverListProvider.select((s) => s[widget.serverId]),
      (prev, next) { if (prev != next) _load(); },
    );

    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: HollowSpacing.md),
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Action buttons
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            HollowButton.ghost(
              onPressed: () => showCreateChannelDialog(
                context,
                widget.serverId,
                onCreated: _load,
              ),
              compact: true,
              icon: const Icon(LucideIcons.plus, size: 14),
              child: const Text('Channel'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              onPressed: _addCategory,
              compact: true,
              icon: const Icon(LucideIcons.folderPlus, size: 14),
              child: const Text('Category'),
            ),
            const SizedBox(width: HollowSpacing.sm),
            HollowButton.ghost(
              onPressed: () =>
                  setState(() => _layout.add(const SeparatorItem())),
              compact: true,
              icon: const Icon(LucideIcons.minus, size: 14),
              child: const Text('Break'),
            ),
          ],
        ),
        const SizedBox(height: HollowSpacing.md),

        // Reorderable list
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          proxyDecorator: (child, index, animation) {
            return AnimatedBuilder(
              animation: animation,
              builder: (ctx, child) => Material(
                elevation: 4,
                color: Colors.transparent,
                child: child,
              ),
              child: child,
            );
          },
          onReorderItem: (oldIndex, newIndex) {
            setState(() {
              final item = _layout.removeAt(oldIndex);
              _layout.insert(newIndex, item);
            });
          },
          itemCount: _layout.length,
          itemBuilder: (context, index) {
            final item = _layout[index];
            return _buildLayoutRow(hollow, item, index);
          },
        ),

        // Save/Discard bar
        if (_dirty) ...[
          const SizedBox(height: HollowSpacing.md),
          Row(
            children: [
              Expanded(
                child: HollowButton.ghost(
                  onPressed: () => setState(() => _layout = List.of(_savedLayout)),
                  child: const Text('Discard'),
                ),
              ),
              const SizedBox(width: HollowSpacing.md),
              Expanded(
                child: HollowButton.filled(
                  onPressed: _save,
                  child: const Text('Save Layout'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildLayoutRow(HollowTheme hollow, LayoutItem item, int index) {
    final key = ValueKey('layout_$index');

    if (item is CategoryItem) {
      return Container(
        key: key,
        margin: const EdgeInsets.only(bottom: HollowSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.accentMuted,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Icon(LucideIcons.gripVertical,
                  size: 20, color: hollow.textSecondary),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Icon(LucideIcons.folder, size: 16, color: hollow.accent),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                item.name,
                style: HollowTypography.body.copyWith(
                  color: hollow.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            HollowPressable(
              onTap: () => _renameCategory(index, item.name),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.pencil, size: 16, color: hollow.textSecondary),
            ),
            HollowPressable(
              onTap: () => setState(() => _layout.removeAt(index)),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
            ),
          ],
        ),
      );
    }

    if (item is ChannelItem) {
      final ch = _channels[item.channelId];
      final name = ch?.name ?? item.channelId;
      final isVoice = ch?.channelType == ChannelType.voice;
      return Container(
        key: key,
        margin: const EdgeInsets.only(bottom: HollowSpacing.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: HollowSpacing.md,
          vertical: HollowSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Icon(LucideIcons.gripVertical,
                  size: 20, color: hollow.textSecondary),
            ),
            const SizedBox(width: HollowSpacing.sm),
            Icon(
              isVoice ? LucideIcons.volume2 : LucideIcons.hash,
              size: 16,
              color: hollow.textSecondary,
            ),
            const SizedBox(width: HollowSpacing.sm),
            Expanded(
              child: Text(
                name,
                style: HollowTypography.body
                    .copyWith(color: hollow.textPrimary),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            HollowPressable(
              onTap: () => _renameChannel(index, item.channelId, name),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.pencil, size: 16, color: hollow.textSecondary),
            ),
            HollowPressable(
              onTap: () => _deleteChannel(index, item.channelId, name),
              padding: const EdgeInsets.all(HollowSpacing.xs),
              child: Icon(LucideIcons.trash2, size: 16, color: hollow.error),
            ),
          ],
        ),
      );
    }

    // SeparatorItem
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: HollowSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.md,
        vertical: HollowSpacing.sm,
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Icon(LucideIcons.gripVertical,
                size: 20, color: hollow.textSecondary),
          ),
          const SizedBox(width: HollowSpacing.sm),
          Expanded(child: Divider(color: hollow.border)),
          const SizedBox(width: HollowSpacing.sm),
          HollowPressable(
            onTap: () => setState(() => _layout.removeAt(index)),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: Icon(LucideIcons.x, size: 16, color: hollow.textSecondary),
          ),
        ],
      ),
    );
  }
}
