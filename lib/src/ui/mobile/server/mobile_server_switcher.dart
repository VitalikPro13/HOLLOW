import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/notification_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/components/server_avatar.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_navigation.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_order.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A live voice room in [serverId]: how many people and the room's name.
({int people, String room})? mobileServerVoiceRoom(
    WidgetRef ref, String serverId) {
  final rooms =
      ref.watch(voiceChannelProvider.select((s) => s.participants[serverId]));
  if (rooms == null) return null;
  final links = ref.watch(deviceLinkProvider);
  MapEntry<String, int>? busiest;
  for (final MapEntry(key: channelId, value: devices) in rooms.entries) {
    final count = {for (final d in devices) links.identityOf(d)}.length;
    if (count > 0 && (busiest == null || count > busiest.value)) {
      busiest = MapEntry(channelId, count);
    }
  }
  if (busiest == null) return null;
  final name = ref
          .watch(serverChannelsProvider(serverId))
          .valueOrNull?[busiest.key]
          ?.name ??
      '';
  return (people: busiest.value, room: name);
}

/// The line under a server's name: "Muted", "3 in Lounge" while a voice room
/// has people, else its member count.
String mobileServerSubline(WidgetRef ref, String serverId) {
  final muted = ref.watch(
      notificationSettingsProvider.select((s) => s.isServerMuted(serverId)));
  if (muted) return 'Muted';
  final room = mobileServerVoiceRoom(ref, serverId);
  if (room != null && room.room.isNotEmpty) {
    return '${room.people} in ${room.room}';
  }
  final members =
      ref.watch(serverListProvider.select((s) => s[serverId]?.memberCount)) ??
          0;
  return members == 1 ? '1 member' : '$members members';
}

/// "Your servers": tap one to see it instead of [currentServerId].
void showMobileServerSwitcher(BuildContext context, String currentServerId) {
  showHollowSheet<void>(
    context: context,
    scrollControlled: true,
    maxHeightFactor: kSheetTallHeightFactor,
    builder: (sheetContext) => SafeArea(
      child: _Switcher(current: currentServerId, pageContext: context),
    ),
  );
}

class _Switcher extends ConsumerWidget {
  final String current;

  /// The server page's own context, which outlives the sheet.
  final BuildContext pageContext;

  const _Switcher({required this.current, required this.pageContext});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The page under the sheet leaves with its server (LeaveWithServer); the
    // sheet goes with it, or every row would be a dead tap.
    ref.listen(keptServersProvider.select((s) => s.containsKey(current)),
        (_, listed) {
      if (listed || !ref.read(serverListLoadStateProvider).loaded) return;
      final route = ModalRoute.of(context);
      final nav = Navigator.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route != null && route.isActive) nav.removeRoute(route);
      });
    });
    final order = mobileServerOrder(ref);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HollowSheetTitle('Your servers'),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: HollowSpacing.sm),
            children: [
              for (final id in order)
                _SwitcherRow(
                  key: ValueKey(id),
                  serverId: id,
                  current: id == current,
                  onPick: () {
                    Navigator.pop(context);
                    if (id != current && pageContext.mounted) {
                      openMobileServer(pageContext, ref, id);
                    }
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SwitcherRow extends ConsumerWidget {
  final String serverId;
  final bool current;
  final VoidCallback onPick;

  const _SwitcherRow({
    super.key,
    required this.serverId,
    required this.current,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final server = ref.watch(serverListProvider.select((s) => s[serverId]));
    if (server == null) return const SizedBox.shrink();
    final muted = ref.watch(
        notificationSettingsProvider.select((s) => s.isServerMuted(serverId)));
    // A muted server counts nothing, as on the Servers tab and the dock.
    final mentions = muted
        ? 0
        : ref.watch(
            unreadProvider.select((u) => u.serverMentionCount(serverId)));
    final unread = muted
        ? 0
        : ref.watch(
            unreadProvider.select((u) => u.serverUnreadCount(serverId)));
    final Widget? trailing = current
        ? Semantics(
            label: 'Open now',
            child: Icon(LucideIcons.check, size: 20, color: hollow.accentText),
          )
        : mentions > 0
            ? HollowCountBadge(count: mentions, mention: true)
            : unread > 0
                ? HollowCountBadge(count: unread)
                : null;
    return HollowListRow(
      touch: true,
      leading: ServerAvatar(serverId: serverId, name: server.name, size: 40),
      title: server.name,
      subtitle: mobileServerSubline(ref, serverId),
      trailing: trailing,
      selected: current,
      muted: muted && !current,
      onTap: onPick,
    );
  }
}
