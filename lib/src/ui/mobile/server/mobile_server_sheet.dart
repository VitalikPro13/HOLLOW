import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_server_settings_route.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart'
    show confirmDeleteServer, confirmLeaveServer;
import 'package:hollow/src/ui/shell/server_context_menus.dart'
    show markServerRead;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the invite dialog for [serverId] with a link on this install's relay.
void showMobileServerInvite(
        BuildContext context, WidgetRef ref, String serverId) =>
    showInviteDialog(
        context,
        serverInviteLinkFor(serverId, relay: ref.read(relayDomainProvider)),
        serverId);

/// The desktop strip menu's rows, minus folders, which a phone has none of.
/// An owner deletes and everyone else leaves: an owner cannot leave.
void showMobileServerActions(
    BuildContext context, WidgetRef ref, String serverId) {
  final serverName = ref.read(serverListProvider)[serverId]?.name ?? '';
  final muted = ref.read(notificationSettingsProvider).isServerMuted(serverId);
  // The sheet's opener can be gone when an action ends (a leave closes the
  // server page), so its toasts go to the app's own overlay.
  final overlay = Navigator.of(context, rootNavigator: true).overlay;

  void report(Future<Object?> action, String failed, {String? done}) {
    action.then((_) {
      if (done != null && overlay != null && overlay.mounted) {
        HollowToast.show(overlay.context, done,
            type: HollowToastType.success, overlayState: overlay);
      }
    }, onError: (Object _) {
      if (overlay != null && overlay.mounted) {
        HollowToast.show(overlay.context, failed,
            type: HollowToastType.error, overlayState: overlay);
      }
    });
  }

  Widget row(BuildContext sheetContext, IconData icon, String label,
          VoidCallback onTap) =>
      HollowListRow(
        touch: true,
        title: label,
        leading: Icon(icon,
            size: 20, color: HollowTheme.of(sheetContext).textSecondary),
        onTap: () {
          Navigator.pop(sheetContext);
          onTap();
        },
      );

  showHollowSheet<void>(
    context: context,
    // Role and permissions are watched: opened from the Servers tab they may
    // still be loading, and a read would offer an owner "Leave server".
    builder: (sheetContext) => Consumer(builder: (sheetContext, sheetRef, _) {
      final role =
          sheetRef.watch(myRoleProvider(serverId)).valueOrNull ?? 'member';
      final perms =
          sheetRef.watch(myPermissionsProvider(serverId)).valueOrNull ?? 0;
      final isOwner = role == 'owner';
      final canManageChannels = (perms & Permission.manageChannels) != 0;
      return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HollowSheetTitle(serverName),
          row(sheetContext, LucideIcons.checkCheck, 'Mark as read',
              () => markServerRead(ref, serverId)),
          row(
              sheetContext,
              muted ? LucideIcons.bell : LucideIcons.bellOff,
              muted ? 'Unmute server' : 'Mute server',
              () => report(
                  // Unmuting goes back to the default, never to "All messages".
                  muted
                      ? ref
                          .read(notificationSettingsProvider.notifier)
                          .resetServerLevel(serverId)
                      : ref
                          .read(notificationSettingsProvider.notifier)
                          .setServerLevel(serverId, NotificationLevel.nothing),
                  'Could not change notifications',
                  done: muted
                      ? 'Notifications unmuted'
                      : 'Notifications muted')),
          row(sheetContext, LucideIcons.userPlus, 'Invite people',
              () => showMobileServerInvite(context, ref, serverId)),
          if (canManageChannels)
            row(sheetContext, LucideIcons.plusCircle, 'Create channel',
                () => showCreateChannelDialog(context, serverId)),
          row(sheetContext, LucideIcons.settings, 'Server settings',
              () => Navigator.of(context, rootNavigator: true).push(
                    hollowMobileRoute(
                      builder: (_) =>
                          MobileServerSettingsRoute(serverId: serverId),
                    ),
                  )),
          row(sheetContext, LucideIcons.copy, 'Copy server ID',
              () => report(Clipboard.setData(ClipboardData(text: serverId)),
                  'Could not copy the server ID',
                  done: 'Server ID copied')),
          const HollowDivider(),
          row(
              sheetContext,
              isOwner ? LucideIcons.trash2 : LucideIcons.logOut,
              isOwner ? 'Delete server' : 'Leave server',
              () => isOwner
                  ? confirmDeleteServer(context, ref, serverId)
                  : confirmLeaveServer(context, ref, serverId)),
          const SizedBox(height: HollowSpacing.sm),
        ],
      ),
    );
    }),
  );
}
