import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/channel_layout.dart';
import 'package:hollow/src/core/providers/channel_chat_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_menu.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/server_settings/delete_channel_confirm.dart';
import 'package:hollow/src/ui/settings/access_label_picker.dart';
import 'package:hollow/src/ui/settings/category_bulk_access_dialog.dart';
import 'package:hollow/src/ui/settings/channel_grants_dialog.dart';
import 'package:hollow/src/ui/shell/server_context_menus.dart'
    show markServerRead;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Right-click menus for the channel sidebar (issue #61), driving the same FFI
/// and dialogs the settings editor uses.
///
/// The drag-and-drop editor in `channels_tab.dart` stays the surface for
/// reordering and bulk layout work; these menus only make the single-item edits
/// you want mid-conversation.

/// Applies a layout edit through the ONE mutation path.
///
/// [ChannelLayoutNotifier.mutate] owns normalisation, the optimistic publish
/// and the pending-write guard that stops a server event from reloading the
/// pre-write layout on top of it. Nothing here reimplements any of that.
void _mutateLayout(WidgetRef ref, String serverId,
    List<LayoutItem> Function(List<LayoutItem>) mutator) {
  ref
      .read(channelLayoutProvider.notifier)
      .mutate(serverId, ref.read(channelListProvider), mutator);
}

/// Index of the item AFTER the last one in the category at [categoryIndex],
/// which is where "create channel here" inserts.
///
/// The forward scan mirrors how the sidebar and `channels_tab` decide what a
/// category contains. Categories are addressed by INDEX, never by name,
/// because duplicate names are legal.
int _categoryEnd(List<LayoutItem> layout, int categoryIndex) {
  var i = categoryIndex + 1;
  while (i < layout.length &&
      layout[i] is! CategoryItem &&
      layout[i] is! SeparatorItem) {
    i++;
  }
  return i;
}

/// The right-click menu for one channel row.
void showChannelTileMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
  required ChannelInfo channel,
  required bool canManage,
  required Offset anchor,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    // menuRef is deliberately NOT named `ref`: it belongs to the menu route's
    // Consumer and dies with the menu, while actions run AFTER the menu closes
    // and must capture the caller's longer-lived `ref`. Shadowing it makes
    // every action throw "used after dispose" in an async gap.
    builder: (context, menuRef) => _channelTileEntries(
        context, menuRef, ref, serverId, channel, canManage),
  );
}

/// Rows for one channel, rebuilt on every provider change while the menu is
/// open so the checked tier describes the channel as it is NOW.
///
/// [menuRef] watches live state for display and dies with the menu; every
/// action must use [ref], the caller's, because actions run after it closes.
List<HollowMenuEntry> _channelTileEntries(
  BuildContext context,
  WidgetRef menuRef,
  WidgetRef ref,
  String serverId,
  ChannelInfo fallback,
  bool canManage,
) {
  // Falls back to the snapshot the tile was drawn from when the channel has
  // just been deleted out from under the menu.
  final channel =
      menuRef.watch(channelListProvider)[fallback.channelId] ?? fallback;
  menuRef.watch(notificationSettingsProvider);
  final notifier = ref.read(notificationSettingsProvider.notifier);
  final isMuted = notifier.channelOverride(serverId, channel.channelId) ==
      ChannelNotificationLevel.nothing;
  // A voice channel carries no messages, so read state, notification muting
  // and the posting gate are all meaningless for it.
  final isVoice = channel.channelType == ChannelType.voice;

  return <HollowMenuEntry>[
    if (!isVoice) ...[
      HollowMenuItem(
        icon: LucideIcons.checkCheck,
        label: 'Mark as read',
        onTap: () => _markChannelRead(ref, serverId, channel.channelId),
      ),
      HollowMenuItem(
        icon: isMuted ? LucideIcons.bell : LucideIcons.bellOff,
        label: isMuted ? 'Unmute channel' : 'Mute channel',
        onTap: () => notifier.setChannelOverride(
          serverId,
          channel.channelId,
          isMuted
              ? ChannelNotificationLevel.inherit
              : ChannelNotificationLevel.nothing,
        ),
      ),
    ],
    if (canManage) ...[
      if (!isVoice) const HollowMenuDivider(),
      HollowMenuItem(
        icon: LucideIcons.pencil,
        label: 'Rename channel',
        onTap: () => renameChannelFlow(context, ref, serverId, channel),
      ),
      HollowMenuItem(
        icon: LucideIcons.eye,
        label: 'Visibility',
        trailing: accessTrailing(channel.visibility, channel.visibilityLabels),
        submenu: _accessSubmenu(
          context: context,
          ref: ref,
          serverId: serverId,
          channel: channel,
          forVisibility: true,
        ),
      ),
      if (!isVoice)
        HollowMenuItem(
          icon: LucideIcons.messageSquare,
          label: 'Who can post',
          trailing: accessTrailing(channel.posting, channel.postingLabels),
          submenu: _accessSubmenu(
            context: context,
            ref: ref,
            serverId: serverId,
            channel: channel,
            forVisibility: false,
          ),
        ),
      if (!channel.isPublic)
        HollowMenuItem(
          icon: LucideIcons.userPlus,
          label: 'Temporary access',
          onTap: () => showChannelGrantsDialog(
            context,
            serverId: serverId,
            channelId: channel.channelId,
            channelName: channel.name,
          ),
        ),
      const HollowMenuDivider(),
      HollowMenuItem(
        icon: LucideIcons.trash2,
        label: 'Delete channel',
        isDanger: true,
        onTap: () => confirmDeleteChannel(
          context,
          serverId: serverId,
          channelId: channel.channelId,
          channelName: channel.name,
        ),
      ),
    ],
  ];
}

/// Marks every message in [channelId] seen.
///
/// Unread state compares MILLISECOND timestamps off a ms-sorted list, so the
/// watermark is the LAST message in the in-memory list, exactly as channel
/// selection computes it.
void _markChannelRead(WidgetRef ref, String serverId, String channelId) {
  final msgs = ref.read(channelChatProvider)['$serverId:$channelId'];
  final latestId =
      (msgs != null && msgs.isNotEmpty) ? msgs.last.messageId : null;
  ref
      .read(unreadProvider.notifier)
      .markChannelSeen(serverId, channelId, latestId);
}

/// The short form beside a menu row: the tier, or how many labels gate it.
String accessTrailing(String tier, List<String> labels) {
  if (labels.isNotEmpty) {
    return '${labels.length} label${labels.length == 1 ? '' : 's'}';
  }
  return switch (tier) {
    'moderator' => 'Mod+',
    'admin' => 'Admin+',
    _ => 'Everyone',
  };
}

/// The Visibility and Who-can-post submenu: three tiers plus the label gate.
List<HollowMenuEntry> _accessSubmenu({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
  required ChannelInfo channel,
  required bool forVisibility,
}) {
  final current = forVisibility ? channel.visibility : channel.posting;
  final labels = forVisibility ? channel.visibilityLabels : channel.postingLabels;
  final gated = labels.isNotEmpty;

  HollowMenuItem tier(String value, String label) => HollowMenuItem(
        label: label,
        // A label gate outranks the tier, so none reads as selected while one
        // is set.
        isChecked: !gated && current == value,
        onTap: () => _setAccessTier(
          context,
          ref: ref,
          serverId: serverId,
          channel: channel,
          forVisibility: forVisibility,
          tier: value,
        ),
      );

  return [
    for (final value in const ['everyone', 'moderator', 'admin'])
      tier(value, accessTierLabel(value)),
    const HollowMenuDivider(),
    HollowMenuItem(
      icon: LucideIcons.tag,
      label: gated ? 'Edit access labels' : 'Require access labels',
      isChecked: gated,
      onTap: () => _editAccessLabels(
        context,
        ref: ref,
        serverId: serverId,
        channel: channel,
        forVisibility: forVisibility,
      ),
    ),
  ];
}

Future<void> _setAccessTier(
  BuildContext context, {
  required WidgetRef ref,
  required String serverId,
  required ChannelInfo channel,
  required bool forVisibility,
  required String tier,
}) async {
  final labels =
      forVisibility ? channel.visibilityLabels : channel.postingLabels;
  // Dropping a label gate WIDENS access, so it confirms first, like the
  // settings editor and the mobile sheet.
  if (labels.isNotEmpty) {
    final ok = await confirmClearLabelGate(context,
        channelName: channel.name, tier: tier, forVisibility: forVisibility);
    if (!ok) return;
  }

  // Optimistic FIRST: the setter only QUEUES a CRDT op, so a read back before
  // it lands returns the old value and the sidebar, this menu and the settings
  // editor disagree until something unrelated reloads the list.
  final notifier = ref.read(channelListProvider.notifier);
  final previous = ref.read(channelListProvider)[channel.channelId];
  notifier.updateChannel(
    channel.channelId,
    (ch) => forVisibility
        ? ch.copyWith(visibility: tier, visibilityLabels: const [])
        : ch.copyWith(posting: tier, postingLabels: const []),
  );

  try {
    if (forVisibility) {
      await crdt_api.setChannelVisibility(
        serverId: serverId,
        channelId: channel.channelId,
        visibility: tier,
      );
    } else {
      await crdt_api.setChannelPosting(
        serverId: serverId,
        channelId: channel.channelId,
        posting: tier,
      );
    }
  } catch (_) {
    if (previous != null) {
      notifier.updateChannel(channel.channelId, (_) => previous);
    }
    if (context.mounted) {
      HollowToast.show(context, 'Could not update channel',
          type: HollowToastType.error);
    }
  }
}

Future<void> _editAccessLabels(
  BuildContext context, {
  required WidgetRef ref,
  required String serverId,
  required ChannelInfo channel,
  required bool forVisibility,
}) async {
  final initial =
      (forVisibility ? channel.visibilityLabels : channel.postingLabels)
          .toSet();
  final picked = await showAccessLabelPicker(
    context: context,
    serverId: serverId,
    gate: forVisibility ? AccessLabelGate.see : AccessLabelGate.post,
    target: '#${channel.name}',
    initial: initial,
  );
  if (picked == null) return;

  // A non-empty label gate implies the Admin+ tier, as the settings editor
  // writes it.
  final notifier = ref.read(channelListProvider.notifier);
  final previous = ref.read(channelListProvider)[channel.channelId];
  final labels = picked.toList();
  notifier.updateChannel(
    channel.channelId,
    (ch) => forVisibility
        ? ch.copyWith(
            visibilityLabels: labels,
            visibility: labels.isEmpty ? ch.visibility : 'admin')
        : ch.copyWith(
            postingLabels: labels,
            posting: labels.isEmpty ? ch.posting : 'admin'),
  );

  try {
    if (forVisibility) {
      await crdt_api.setChannelVisibilityLabels(
        serverId: serverId,
        channelId: channel.channelId,
        labels: picked.toList(),
      );
    } else {
      await crdt_api.setChannelPostingLabels(
        serverId: serverId,
        channelId: channel.channelId,
        labels: picked.toList(),
      );
    }
  } catch (_) {
    if (previous != null) {
      notifier.updateChannel(channel.channelId, (_) => previous);
    }
    if (context.mounted) {
      HollowToast.show(context, 'Could not update channel',
          type: HollowToastType.error);
    }
  }
}

/// What a tier is called wherever a person picks one.
String accessTierLabel(String tier) => switch (tier) {
      'moderator' => 'Moderator and above',
      'admin' => 'Admin and above',
      _ => 'Everyone',
    };

/// Asks before a plain tier replaces a channel's access labels, which lets
/// more people in. One wording for the desktop menu and the phone sheet.
Future<bool> confirmClearLabelGate(
  BuildContext context, {
  required String channelName,
  required String tier,
  required bool forVisibility,
}) {
  final who = tier == 'everyone'
      ? 'Everyone'
      : 'Anyone at ${accessTierLabel(tier)}';
  final can = forVisibility ? 'can see' : 'can post in';
  return showHollowConfirm(
    context: context,
    title: 'Drop the access labels?',
    message: '$who $can #$channelName, not only people with its access '
        'labels.',
    confirmLabel: tier == 'everyone'
        ? 'Open to everyone'
        : 'Open to ${accessTierLabel(tier)}',
  );
}

/// Renames a channel from a one-field prompt. The prompt stays open while the
/// rename runs and keeps the typed name when it fails. Desktop menu and phone
/// sheet both call it.
void renameChannelFlow(BuildContext context, WidgetRef ref, String serverId,
    ChannelInfo channel,
    {VoidCallback? onRenamed}) {
  final channels = ref.read(channelListProvider.notifier);
  final host = Overlay.maybeOf(context, rootOverlay: true);
  promptForName(
    context: context,
    title: 'Rename channel',
    hintText: 'Channel name',
    initial: channel.name,
    confirmLabel: 'Rename',
    maxLength: 32,
    onSubmit: (name) async {
      if (name == channel.name) return;
      await crdt_api.renameChannel(
        serverId: serverId,
        channelId: channel.channelId,
        newName: name,
      );
      channels.onChannelRenamed(serverId, channel.channelId, name);
      onRenamed?.call();
      if (host != null && host.mounted) {
        HollowToast.show(host.context, 'Channel renamed',
            type: HollowToastType.success, overlayState: host);
      }
    },
  );
}

/// The right-click menu for a category header.
///
/// [categoryIndex] indexes the PARSED layout: categories are identified by
/// position, never by name, because two may legally share one.
void showCategoryMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
  required String layoutJson,
  required int categoryIndex,
  required String categoryName,
  required bool canManage,
  required bool isCollapsed,
  required VoidCallback onToggleCollapse,
  required Offset anchor,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    // `_` not `ref`: actions below capture the CALLER's ref, which outlives the
    // menu route (see _channelTileEntries).
    builder: (context, _) => <HollowMenuEntry>[
      HollowMenuItem(
        icon: isCollapsed ? LucideIcons.chevronDown : LucideIcons.chevronRight,
        label: isCollapsed ? 'Expand category' : 'Collapse category',
        onTap: onToggleCollapse,
      ),
      if (canManage) ...[
        const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.plus,
          label: 'Create channel here',
          onTap: () =>
              _createChannelInCategory(context, ref, serverId, categoryIndex),
        ),
        HollowMenuItem(
          icon: LucideIcons.pencil,
          label: 'Rename category',
          onTap: () => _renameCategory(
              context, ref, serverId, categoryIndex, categoryName),
        ),
        HollowMenuItem(
          icon: LucideIcons.eye,
          label: 'Set access for all channels',
          onTap: () => _bulkCategoryAccess(
              context, ref, serverId, layoutJson, categoryIndex, categoryName),
        ),
        const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.trash2,
          label: 'Delete category',
          isDanger: true,
          onTap: () => _confirmDeleteCategory(
              context, ref, serverId, categoryIndex, categoryName),
        ),
      ],
    ],
  );
}

/// Creates a channel and PLACES it in the category, rather than leaving it
/// unsorted at the bottom the way the sidebar's "+" does.
void _createChannelInCategory(BuildContext context, WidgetRef ref,
    String serverId, int categoryIndex) {
  showCreateChannelDialog(
    context,
    serverId,
    onCreated: (channelId) {
      _mutateLayout(ref, serverId, (layout) {
        if (categoryIndex >= layout.length ||
            layout[categoryIndex] is! CategoryItem) {
          return layout; // Category moved or vanished; leave it where it fell.
        }
        // The new channel is already appended to the normalised layout as an
        // unplaced one, so MOVE it rather than adding a second reference to the
        // same id.
        layout.removeWhere(
            (item) => item is ChannelItem && item.channelId == channelId);
        layout.insert(_categoryEnd(layout, categoryIndex),
            ChannelItem(channelId));
        return layout;
      });
    },
  );
}

void _renameCategory(BuildContext context, WidgetRef ref, String serverId,
    int categoryIndex, String currentName) {
  promptForName(
    context: context,
    title: 'Rename category',
    hintText: 'Category name',
    initial: currentName,
    confirmLabel: 'Rename',
    onSubmit: (name) async {
      if (name == currentName) return;
      _mutateLayout(ref, serverId, (layout) {
        if (categoryIndex < layout.length &&
            layout[categoryIndex] is CategoryItem) {
          layout[categoryIndex] = CategoryItem(name);
        }
        return layout;
      });
    },
  );
}

/// Stamps one visibility choice onto every channel in the category.
///
/// The scan, the dialog and the per-channel writes are the settings editor's,
/// so the two surfaces cannot disagree about what "the category" means.
Future<void> _bulkCategoryAccess(BuildContext context, WidgetRef ref,
    String serverId, String layoutJson, int categoryIndex,
    String categoryName) {
  final channels = ref.read(channelListProvider);
  // Normalised, so an unplaced channel the sidebar draws under this category
  // counts as being in it.
  final layout = effectiveLayout(layoutJson, channels);
  final channelIds = <String>[];
  for (var i = categoryIndex + 1; i < layout.length; i++) {
    final item = layout[i];
    if (item is CategoryItem || item is SeparatorItem) break;
    if (item is ChannelItem) {
      // Public channels have no access gates: they are plaintext by design.
      final info = channels[item.channelId];
      if (info != null && !info.isPublic) channelIds.add(item.channelId);
    }
  }
  return runCategoryBulkAccess(
    context: context,
    ref: ref,
    serverId: serverId,
    categoryName: categoryName,
    channelIds: channelIds,
  );
}

Future<void> _confirmDeleteCategory(BuildContext context, WidgetRef ref,
    String serverId, int categoryIndex, String categoryName) async {
  final confirmed = await showHollowConfirm(
    context: context,
    title: 'Delete $categoryName?',
    message: 'The category header is removed. Its channels are kept and '
        'become uncategorised.',
    confirmLabel: 'Delete',
    destructive: true,
  );
  if (!confirmed) return;
  _mutateLayout(ref, serverId, (layout) {
    if (categoryIndex < layout.length &&
        layout[categoryIndex] is CategoryItem) {
      layout.removeAt(categoryIndex);
    }
    return layout;
  });
}

/// The right-click menu for empty space in the channel list.
void showChannelSidebarMenu({
  required BuildContext context,
  required WidgetRef ref,
  required String serverId,
  required bool canManage,
  required VoidCallback onOpenSettings,
  required VoidCallback onInvite,
  required Offset anchor,
}) {
  showHollowMenu(
    context: context,
    anchor: anchor,
    // `_` not `ref`: see _channelTileEntries.
    builder: (context, _) => <HollowMenuEntry>[
      HollowMenuItem(
        icon: LucideIcons.checkCheck,
        label: 'Mark server as read',
        onTap: () => markServerRead(ref, serverId),
      ),
      if (canManage) ...[
        const HollowMenuDivider(),
        HollowMenuItem(
          icon: LucideIcons.plus,
          label: 'Create channel',
          onTap: () => showCreateChannelDialog(context, serverId),
        ),
        HollowMenuItem(
          icon: LucideIcons.folderPlus,
          label: 'Create category',
          onTap: () => _createCategory(context, ref, serverId),
        ),
      ],
      const HollowMenuDivider(),
      HollowMenuItem(
        icon: LucideIcons.userPlus,
        label: 'Invite people',
        onTap: onInvite,
      ),
      HollowMenuItem(
        icon: LucideIcons.settings,
        label: 'Server settings',
        onTap: onOpenSettings,
      ),
    ],
  );
}


void _createCategory(BuildContext context, WidgetRef ref, String serverId) {
  promptForName(
    context: context,
    title: 'Create category',
    hintText: 'Category name',
    initial: '',
    confirmLabel: 'Create',
    onSubmit: (name) async {
      // Appended AFTER every channel, so a new category starts empty at the
      // bottom instead of appearing to swallow everything below it.
      _mutateLayout(ref, serverId, (layout) => layout..add(CategoryItem(name)));
    },
  );
}
