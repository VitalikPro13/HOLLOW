import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/server_settings/pages/access_page.dart';
import 'package:hollow/src/ui/server_settings/pages/channels_page.dart';
import 'package:hollow/src/ui/server_settings/pages/emotes_page.dart';
import 'package:hollow/src/ui/server_settings/pages/files_storage_page.dart';
import 'package:hollow/src/ui/server_settings/pages/labels_page.dart';
import 'package:hollow/src/ui/server_settings/pages/members_page.dart';
import 'package:hollow/src/ui/server_settings/pages/notifications_page.dart';
import 'package:hollow/src/ui/server_settings/pages/overview_page.dart';
import 'package:hollow/src/ui/server_settings/pages/profile_page.dart';
import 'package:hollow/src/ui/server_settings/pages/roles_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

extension ServerSettingsPageMeta on ServerSettingsPage {
  String get label => switch (this) {
        ServerSettingsPage.overview => 'Overview',
        ServerSettingsPage.access => 'Access',
        ServerSettingsPage.channels => 'Channels',
        ServerSettingsPage.roles => 'Roles',
        ServerSettingsPage.labels => 'Labels',
        ServerSettingsPage.emotes => 'Emotes & stickers',
        ServerSettingsPage.members => 'Members',
        ServerSettingsPage.storage => 'Files & storage',
        ServerSettingsPage.profile => 'Profile',
        ServerSettingsPage.notifications => 'Notifications',
      };

  IconData get icon => switch (this) {
        ServerSettingsPage.overview => LucideIcons.info,
        ServerSettingsPage.access => LucideIcons.lock,
        ServerSettingsPage.channels => LucideIcons.hash,
        ServerSettingsPage.roles => LucideIcons.shield,
        ServerSettingsPage.labels => LucideIcons.tag,
        ServerSettingsPage.emotes => LucideIcons.smile,
        ServerSettingsPage.members => LucideIcons.users,
        ServerSettingsPage.storage => LucideIcons.hardDrive,
        ServerSettingsPage.profile => LucideIcons.user,
        ServerSettingsPage.notifications => LucideIcons.bell,
      };

  /// The page is a `SettingsSliverPage`: Members builds its rows lazily, so a
  /// thousand-member server scrolls without building a thousand rows.
  bool get slivers => this == ServerSettingsPage.members;

  /// Profile and Notifications are about how the server treats YOU.
  bool get isYou =>
      this == ServerSettingsPage.profile ||
      this == ServerSettingsPage.notifications;

  /// The permission bit the page needs, or 0 when everyone sees it (its
  /// actions are gated inside).
  int get requires => switch (this) {
        ServerSettingsPage.overview ||
        ServerSettingsPage.access =>
          Permission.manageServer,
        ServerSettingsPage.channels => Permission.manageChannels,
        ServerSettingsPage.roles ||
        ServerSettingsPage.labels =>
          Permission.manageRoles,
        _ => 0,
      };
}

/// The pages [perms] may open, in rail order.
List<ServerSettingsPage> serverSettingsPagesFor(int perms) => [
      for (final p in ServerSettingsPage.values)
        if (p.requires == 0 || perms & p.requires != 0) p,
    ];

/// Overview for someone who runs the server, else their own Profile.
ServerSettingsPage defaultServerSettingsPage(int perms) =>
    perms & Permission.manageServer != 0
        ? ServerSettingsPage.overview
        : ServerSettingsPage.profile;

/// The page widget: the same one on desktop and phone.
Widget serverSettingsPageFor(ServerSettingsPage page, String serverId) =>
    switch (page) {
      ServerSettingsPage.overview => OverviewPage(serverId: serverId),
      ServerSettingsPage.access => AccessPage(serverId: serverId),
      ServerSettingsPage.channels => ChannelsPage(serverId: serverId),
      ServerSettingsPage.roles => RolesPage(serverId: serverId),
      ServerSettingsPage.labels => LabelsPage(serverId: serverId),
      ServerSettingsPage.emotes => EmotesPage(serverId: serverId),
      ServerSettingsPage.members => MembersPage(serverId: serverId),
      ServerSettingsPage.storage => FilesStoragePage(serverId: serverId),
      ServerSettingsPage.profile => ServerProfilePage(serverId: serverId),
      ServerSettingsPage.notifications =>
        ServerNotificationsPage(serverId: serverId),
    };

/// The app's own container, above the scope a foreign server's settings put
/// over [selectedServerProvider]: clearing the selection inside that scope
/// clears nothing, and reading a provider built on it there asserts.
ProviderContainer _appContainer(BuildContext context) {
  var container = ProviderScope.containerOf(context, listen: false);
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is UncontrolledProviderScope) container = widget.container;
    return true;
  });
  return container;
}

/// After a delete or leave: server settings close if they showed this server,
/// and the server is deselected if it was selected. A phone pops back to its
/// shell.
void _afterServerGone(
    ProviderRead read, String serverId, NavigatorState? phoneNavigator) {
  if (read(serverSettingsTargetProvider) == serverId) {
    closeServerSettings(read);
    read(serverSettingsServerIdProvider.notifier).state = null;
  }
  if (read(selectedServerProvider) == serverId) {
    read(selectedServerProvider.notifier).state = null;
    read(selectedChannelProvider.notifier).state = null;
    read(channelListProvider.notifier).clear();
  }
  if (phoneNavigator?.mounted ?? false) {
    phoneNavigator!.popUntil((r) => r.isFirst);
  }
}

/// THE delete-server confirm for the whole app (settings, strip menu, phone
/// sheet): the delete runs inside the dialog, so a failure stays on screen.
Future<void> confirmDeleteServer(
    BuildContext context, WidgetRef ref, String serverId) async {
  // The container, not [ref]: a menu or sheet that opened this may be gone
  // by the time the dialog answers.
  final read = _appContainer(context).read;
  final name = read(serverListProvider)[serverId]?.name ?? 'this server';
  final phoneNavigator =
      SettingsDensity.touchOf(context) ? Navigator.of(context) : null;
  final ok = await showHollowConfirm(
    context: context,
    title: 'Delete $name?',
    message: 'Every channel and message is deleted for everyone in it. '
        "This can't be undone.",
    confirmLabel: 'Delete server',
    destructive: true,
    onConfirm: () => crdt_api.deleteServer(serverId: serverId),
  );
  if (!ok) return;
  if (context.mounted) {
    HollowToast.show(context, '$name deleted', type: HollowToastType.info);
  }
  _afterServerGone(read, serverId, phoneNavigator);
}

/// THE leave-server confirm for the whole app, with the same shape as
/// [confirmDeleteServer].
Future<void> confirmLeaveServer(
    BuildContext context, WidgetRef ref, String serverId) async {
  // The container, not [ref]: a menu or sheet that opened this may be gone
  // by the time the dialog answers.
  final read = _appContainer(context).read;
  final name = read(serverListProvider)[serverId]?.name ?? 'this server';
  final phoneNavigator =
      SettingsDensity.touchOf(context) ? Navigator.of(context) : null;
  final ok = await showHollowConfirm(
    context: context,
    title: 'Leave $name?',
    message: "You'll need a new invite to come back.",
    confirmLabel: 'Leave server',
    destructive: true,
    onConfirm: () => crdt_api.leaveServer(serverId: serverId),
  );
  if (!ok) return;
  if (context.mounted) {
    HollowToast.show(context, 'You left $name', type: HollowToastType.info);
  }
  _afterServerGone(read, serverId, phoneNavigator);
}
