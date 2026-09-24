import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_settings_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/server_settings/pages/access_page.dart';
import 'package:hollow/src/ui/server_settings/pages/channels_page.dart';
import 'package:hollow/src/ui/server_settings/pages/emotes_page.dart';
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
        ServerSettingsPage.emotes => 'Emotes and stickers',
        ServerSettingsPage.members => 'Members',
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
        ServerSettingsPage.profile => LucideIcons.user,
        ServerSettingsPage.notifications => LucideIcons.bell,
      };

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
      ServerSettingsPage.profile => ServerProfilePage(serverId: serverId),
      ServerSettingsPage.notifications =>
        ServerNotificationsPage(serverId: serverId),
    };

/// After a delete or leave: settings close and the server is no longer
/// selected. A phone also pops back to its shell.
void _afterServerGone(BuildContext context, WidgetRef ref) {
  final touch = SettingsDensity.touchOf(context);
  closeServerSettings(ref.read);
  ref.read(serverSettingsServerIdProvider.notifier).state = null;
  ref.read(selectedServerProvider.notifier).state = null;
  ref.read(selectedChannelProvider.notifier).state = null;
  ref.read(channelListProvider.notifier).clear();
  if (touch) Navigator.of(context).popUntil((r) => r.isFirst);
}

Future<void> confirmDeleteServer(
    BuildContext context, WidgetRef ref, String serverId) async {
  final name = ref.read(serverListProvider)[serverId]?.name ?? 'this server';
  final ok = await showHollowConfirm(
    context: context,
    title: 'Delete $name?',
    message: "Every channel and message is deleted for everyone in it. "
        "This can't be undone.",
    confirmLabel: 'Delete server',
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  try {
    await crdt_api.deleteServer(serverId: serverId);
    if (!context.mounted) return;
    HollowToast.show(context, '$name deleted', type: HollowToastType.info);
    _afterServerGone(context, ref);
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Could not delete the server: $e',
          type: HollowToastType.error);
    }
  }
}

Future<void> confirmLeaveServer(
    BuildContext context, WidgetRef ref, String serverId) async {
  final name = ref.read(serverListProvider)[serverId]?.name ?? 'this server';
  final ok = await showHollowConfirm(
    context: context,
    title: 'Leave $name?',
    message: "You'll need a new invite to come back.",
    confirmLabel: 'Leave server',
    destructive: true,
  );
  if (!ok || !context.mounted) return;
  try {
    await crdt_api.leaveServer(serverId: serverId);
    if (!context.mounted) return;
    HollowToast.show(context, 'You left $name', type: HollowToastType.info);
    _afterServerGone(context, ref);
  } catch (e) {
    if (context.mounted) {
      HollowToast.show(context, 'Could not leave the server: $e',
          type: HollowToastType.error);
    }
  }
}
