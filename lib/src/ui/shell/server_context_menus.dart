/// Right-click menus for the server strip and the Home button (issue #61).
///
/// Both shells show the same strip, [ServerStrip] in Classic layout and
/// [BottomBar] in Dock, so the menus live here and both call them: a row in one
/// and not the other is a bug nobody notices until they switch layouts.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/components/server_folder_popup.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The right-click menu for one server icon in the strip.
///
/// [onOpenSettings] selects the server and shows its settings. The two shells
/// reach that differently, so the caller supplies it.
void showServerIconMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
  required Offset anchor,
  required VoidCallback onOpenSettings,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    // `menuRef` deliberately not named `ref`: it dies with the menu, and every
    // row below runs after the menu has closed.
    builder: (menuContext, menuRef) =>
        _serverIconEntries(context, menuContext, menuRef, ref, serverId,
            onOpenSettings),
  );
}

List<HollowMenuEntry> _serverIconEntries(
  BuildContext context,
  BuildContext menuContext,
  WidgetRef menuRef,
  WidgetRef ref,
  String serverId,
  VoidCallback onOpenSettings,
) {
  final server = menuRef.watch(serverListProvider)[serverId];
  final name = server?.name ?? 'this server';
  final muted = menuRef
      .watch(notificationSettingsProvider)
      .isServerMuted(serverId);

  return <HollowMenuEntry>[
    HollowMenuItem(
      icon: LucideIcons.checkCheck,
      label: 'Mark as read',
      onTap: () => markServerRead(ref, serverId),
    ),
    HollowMenuItem(
      icon: muted ? LucideIcons.bell : LucideIcons.bellOff,
      label: muted ? 'Unmute server' : 'Mute server',
      // Un-awaited, so the failure is caught here: a sync try/catch around a
      // dangling Future catches nothing and the rejection reaches the zone
      // crash handler.
      onTap: () => ref
          .read(notificationSettingsProvider.notifier)
          .setServerLevel(
            serverId,
            muted ? NotificationLevel.all : NotificationLevel.nothing,
          )
          .catchError((Object _) {
        if (context.mounted) {
          HollowToast.show(context, 'Could not change notifications',
              type: HollowToastType.error);
        }
      }),
    ),
    const HollowMenuDivider(),
    HollowMenuItem(
      icon: LucideIcons.userPlus,
      label: 'Invite people',
      onTap: () =>
          showInviteDialog(context, webServerInviteLink(serverId), serverId),
    ),
    HollowMenuItem(
      icon: LucideIcons.settings,
      label: 'Server settings',
      onTap: onOpenSettings,
    ),
    const HollowMenuDivider(),
    HollowMenuItem(
      icon: LucideIcons.folder,
      label: 'Move to folder',
      trailing: _currentFolderName(menuRef, serverId),
      submenu: _folderSubmenu(context, menuRef, ref, serverId),
    ),
    const HollowMenuDivider(),
    HollowMenuItem(
      icon: LucideIcons.logOut,
      label: 'Leave server',
      isDanger: true,
      onTap: () => confirmAndLeaveServer(context, ref,
          serverId: serverId, serverName: name),
    ),
  ];
}

String? _currentFolderName(WidgetRef ref, String serverId) {
  final notifier = ref.read(serverStripLayoutProvider.notifier);
  ref.watch(serverStripLayoutProvider);
  final folderId = notifier.folderIdOf(serverId);
  if (folderId == null) return null;
  return notifier
      .folders()
      .where((f) => f.id == folderId)
      .map((f) => f.name)
      .firstOrNull;
}

/// Every folder plus "New folder", with the one holding this server checked.
List<HollowMenuEntry> _folderSubmenu(
  BuildContext context,
  WidgetRef menuRef,
  WidgetRef ref,
  String serverId,
) {
  menuRef.watch(serverStripLayoutProvider);
  final notifier = ref.read(serverStripLayoutProvider.notifier);
  final folders = notifier.folders();
  final currentId = notifier.folderIdOf(serverId);

  return <HollowMenuEntry>[
    for (final folder in folders)
      HollowMenuItem(
        icon: LucideIcons.folder,
        label: folder.name,
        isChecked: folder.id == currentId,
        onTap: () => ref
            .read(serverStripLayoutProvider.notifier)
            .addToFolder(folder.id, serverId),
      ),
    if (folders.isNotEmpty) const HollowMenuDivider(),
    HollowMenuItem(
      icon: LucideIcons.folderPlus,
      label: 'New folder',
      onTap: () => promptForName(
        context: context,
        title: 'New folder',
        hintText: 'Folder name',
        initial: 'Folder',
        confirmLabel: 'Create',
        onSubmit: (name) => ref
            .read(serverStripLayoutProvider.notifier)
            .createFolderWith(serverId, name),
      ),
    ),
    if (currentId != null)
      HollowMenuItem(
        icon: LucideIcons.folderMinus,
        label: 'Remove from folder',
        onTap: () => ref
            .read(serverStripLayoutProvider.notifier)
            .moveOutOfFolder(serverId),
      ),
  ];
}

/// Marks every channel of [serverId] seen.
///
/// Unread state compares MILLISECOND timestamps off a ms-sorted list, so the
/// watermark is the LAST message in the in-memory list — the same rule channel
/// selection uses.
void markServerRead(WidgetRef ref, String serverId) {
  final chats = ref.read(channelChatProvider);
  final unread = ref.read(unreadProvider.notifier);
  for (final channelId in ref.read(channelListProvider).keys) {
    final msgs = chats['$serverId:$channelId'];
    final latestId =
        (msgs != null && msgs.isNotEmpty) ? msgs.last.messageId : null;
    unread.markChannelSeen(serverId, channelId, latestId);
  }
}

/// The right-click menu for a folder icon.
void showFolderIconMenu({
  required BuildContext context,
  required WidgetRef ref,
  required FolderStripItem folder,
  required Offset anchor,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    builder: (menuContext, menuRef) {
      // Read live, so a rename landing while the menu is open shows.
      final live = menuRef
              .watch(serverStripLayoutProvider)
              .whereType<FolderStripItem>()
              .where((f) => f.id == folder.id)
              .firstOrNull ??
          folder;
      return <HollowMenuEntry>[
        HollowMenuItem(
          icon: LucideIcons.checkCheck,
          label: 'Mark all as read',
          onTap: () {
            for (final serverId in live.serverIds) {
              markServerRead(ref, serverId);
            }
          },
        ),
        const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.pencil,
          label: 'Rename folder',
          onTap: () =>
              showFolderRenameDialog(context: context, ref: ref, folder: live),
        ),
        HollowMenuItem(
          icon: LucideIcons.folderMinus,
          label: 'Dissolve folder',
          onTap: () => ref
              .read(serverStripLayoutProvider.notifier)
              .dissolveFolder(live.id),
        ),
      ];
    },
  );
}

/// The right-click menu for the Home button.
///
/// One row, and it earns its place: Home's unread badge comes from the DM
/// counts, and an unreachable conversation leaves one behind with no tile to
/// click.
void showHomeMenu({
  required BuildContext context,
  required WidgetRef ref,
  required Offset anchor,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    builder: (menuContext, menuRef) {
      final unread = menuRef.watch(dmUnreadBadgeProvider);
      return <HollowMenuEntry>[
        HollowMenuItem(
          icon: LucideIcons.checkCheck,
          label: 'Mark all DMs as read',
          trailing: unread > 0 ? '$unread' : null,
          onTap: () => _markAllDmsRead(context, ref),
        ),
      ];
    },
  );
}

Future<void> _markAllDmsRead(BuildContext context, WidgetRef ref) async {
  final cleared = await ref.read(unreadProvider.notifier).markAllDmsSeen();
  if (!context.mounted) return;
  HollowToast.show(
    context,
    cleared == 0
        ? 'No unread direct messages'
        : 'Marked $cleared conversation${cleared == 1 ? '' : 's'} as read',
    type: HollowToastType.success,
  );
}

/// Confirms, then leaves [serverId] and navigates away from it.
///
/// The same flow the Danger Zone tab runs. Rust re-checks the op; this handles
/// only the UI side of leaving.
Future<void> confirmAndLeaveServer(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String serverName,
}) async {
  final confirmed = await showHollowDialog<bool>(
    context: context,
    builder: (ctx) => HollowDialog(
      title: 'Leave server',
      content: Text(
        'Are you sure you want to leave "$serverName"? You will need a new '
        'invite to rejoin.',
        style: HollowTypography.body
            .copyWith(color: HollowTheme.of(ctx).textSecondary),
      ),
      actions: [
        HollowButton.ghost(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        HollowButton.danger(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Leave server'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  try {
    await crdt_api.leaveServer(serverId: serverId);
    ref.read(serverSettingsOpenProvider.notifier).state = false;
    if (ref.read(selectedServerProvider) == serverId) {
      ref.read(selectedServerProvider.notifier).state = null;
      ref.read(selectedChannelProvider.notifier).state = null;
      ref.read(channelListProvider.notifier).clear();
    }
    if (context.mounted) {
      HollowToast.show(context, 'Left "$serverName"',
          type: HollowToastType.info);
    }
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Failed to leave server: $e',
          type: HollowToastType.error);
    }
  }
}

/// One small "type a name" dialog, submitting on Enter as well as the button.
///
/// Public because the strip menus and the folder flows both need it and neither
/// can see into `channel_context_menus.dart`.
void promptForName({
  required BuildContext context,
  required String title,
  required String hintText,
  required String initial,
  required String confirmLabel,
  required FutureOr<void> Function(String name) onSubmit,
}) {
  final controller = TextEditingController(text: initial);
  showHollowDialog(
    context: context,
    builder: (ctx) {
      Future<void> submit() async {
        final name = controller.text.trim();
        Navigator.of(ctx).pop();
        if (name.isEmpty) return;
        await onSubmit(name);
      }

      return HollowDialog(
        title: title,
        content: Padding(
          padding: const EdgeInsets.only(top: HollowSpacing.xs),
          child: HollowTextField(
            controller: controller,
            hintText: hintText,
            autofocus: true,
            onSubmitted: (_) => submit(),
          ),
        ),
        actions: [
          HollowButton.ghost(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          HollowButton.filled(
            onPressed: submit,
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
}
