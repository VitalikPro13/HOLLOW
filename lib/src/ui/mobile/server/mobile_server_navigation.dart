import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/age_gate.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/event_provider.dart'
    show showEventToast;
import 'package:hollow/src/core/providers/relay_denial_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';
import 'package:hollow/src/ui/mobile/mobile_call_chrome.dart'
    show kMobileVoiceRouteName;
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/mobile/mobile_page_route.dart';
import 'package:hollow/src/ui/mobile/mobile_voice_channel_route.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_route.dart';
import 'package:hollow/src/ui/mobile/server/mobile_server_sheet.dart';
import 'package:hollow/src/ui/shell/voice_room_switch.dart';

/// The phone's way into a server and its channels. Every path that opens a
/// channel comes through here, so the stack is always
/// [shell, server page, channel (, voice room)] and a swipe back from a channel
/// lands on its server's list.

/// [RouteSettings.name] of a server page; its arguments are the server id.
const String kMobileServerRouteName = 'mobile-server';

/// The [RouteSettings.arguments] of a channel page pushed from here.
typedef MobileChannelRef = ({String serverId, String channelId});

/// The channel last opened in each server this session: the server page marks
/// it, and a drag to the left on the page reopens it.
final mobileLastChannelProvider =
    StateProvider<Map<String, String>>((ref) => const {});

bool isMobileServerRoute(Route<dynamic> route, [String? serverId]) =>
    route.settings.name == kMobileServerRouteName &&
    (serverId == null || route.settings.arguments == serverId);

bool _isChannelRoute(Route<dynamic> route, String serverId, String channelId) =>
    route.settings.name == MobileChatRoute.routeName &&
    route.settings.arguments ==
        (serverId: serverId, channelId: channelId);

/// The route on top, read without popping anything.
Route<dynamic>? _topRoute(NavigatorState nav) {
  Route<dynamic>? top;
  nav.popUntil((route) {
    top = route;
    return true;
  });
  return top;
}

Route<void> _serverRoute(String serverId, {bool instant = false}) =>
    hollowMobileRoute<void>(
      settings:
          RouteSettings(name: kMobileServerRouteName, arguments: serverId),
      instant: instant,
      builder: (_) => MobileServerRoute(serverId: serverId),
    );

/// Opens [serverId]'s full-screen page above the shell. From another server's
/// page (the switcher) it replaces that page instead of stacking on it.
Future<void> openMobileServer(
  BuildContext context,
  WidgetRef ref,
  String serverId,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final nav = Navigator.of(context, rootNavigator: true);
  if (container.read(appLockedProvider)) return;
  if (container.read(serverAgeHiddenProvider(serverId))) return;
  // A channel or sheet above the current server page goes first.
  nav.popUntil((route) => isMobileServerRoute(route) || route.isFirst);
  final top = _topRoute(nav);
  if (top != null && isMobileServerRoute(top, serverId)) return;
  if (top != null && isMobileServerRoute(top)) {
    // Switching what the page shows is instant.
    await nav.pushReplacement(_serverRoute(serverId, instant: true));
    return;
  }
  await nav.push(_serverRoute(serverId));
}

/// Opens a text channel so the stack ends as [shell, server page, channel].
Future<void> openMobileChannel(
  BuildContext context,
  WidgetRef ref, {
  required String serverId,
  required String channelId,
  String? channelName,
}) =>
    openMobileChannelOn(Navigator.of(context, rootNavigator: true),
        serverId: serverId, channelId: channelId, channelName: channelName);

/// [openMobileChannel] for code holding only the app's navigator (a call
/// screen on its way out, a banner whose page is closing).
Future<void> openMobileChannelOn(
  NavigatorState nav, {
  required String serverId,
  required String channelId,
  String? channelName,
}) async {
  final container = ProviderScope.containerOf(nav.context, listen: false);
  if (container.read(appLockedProvider)) return;
  if (container.read(serverAgeHiddenProvider(serverId))) return;
  var name = channelName ?? '';
  if (name.isEmpty) {
    // The header needs a name, which only the local DB has.
    try {
      final channels = await ChannelListNotifier.fetchChannels(serverId);
      name = channels[channelId]?.name ?? '';
    } catch (_) {}
    if (!nav.mounted || container.read(appLockedProvider)) return;
  }
  _openChannel(nav, container,
      serverId: serverId, channelId: channelId, channelName: name);
}

/// Pops down to [serverId]'s page (pushing one, instantly, when none is on
/// the stack) or to [keep], a page of that channel already open above it.
/// True when [keep] is what is left on top.
bool _shapeStack(NavigatorState nav, String serverId, {String? keep}) {
  var kept = false;
  nav.popUntil((route) {
    if (keep != null && _isChannelRoute(route, serverId, keep)) {
      kept = true;
      return true;
    }
    return isMobileServerRoute(route, serverId) || route.isFirst;
  });
  if (kept) return true;
  final top = _topRoute(nav);
  if (top == null || !isMobileServerRoute(top, serverId)) {
    nav.push(_serverRoute(serverId, instant: true));
  }
  return false;
}

void _select(ProviderContainer container, String serverId, String channelId) {
  // Written BEFORE any pop, so a popped page's guarded cleanup no-ops.
  container.read(selectedPeerProvider.notifier).state = null;
  container.read(selectedServerProvider.notifier).state = serverId;
  container.read(selectedChannelProvider.notifier).state = channelId;
  final last = container.read(mobileLastChannelProvider);
  if (last[serverId] != channelId) {
    container.read(mobileLastChannelProvider.notifier).state = {
      ...last,
      serverId: channelId,
    };
  }
}

Route<void> _channelRoute(
  String serverId,
  String channelId,
  String channelName, {
  bool instant = false,
}) =>
    hollowMobileRoute<void>(
      settings: RouteSettings(
        name: MobileChatRoute.routeName,
        arguments: (serverId: serverId, channelId: channelId),
      ),
      instant: instant,
      builder: (_) => MobileChatRoute(
        serverId: serverId,
        channelId: channelId,
        channelName: channelName.isNotEmpty ? channelName : 'channel',
      ),
    );

/// Clears the selection once the page closes, unless another page has taken
/// it since.
void Function(void) _clearOnPop(
        ProviderContainer container, String serverId, String channelId) =>
    (_) {
      if (container.read(selectedServerProvider) == serverId &&
          container.read(selectedChannelProvider) == channelId) {
        container.read(selectedServerProvider.notifier).state = null;
        container.read(selectedChannelProvider.notifier).state = null;
      }
    };

void _openChannel(
  NavigatorState nav,
  ProviderContainer container, {
  required String serverId,
  required String channelId,
  required String channelName,
  bool instant = false,
}) {
  _select(container, serverId, channelId);
  if (_shapeStack(nav, serverId, keep: channelId)) return;
  nav
      .push(_channelRoute(serverId, channelId, channelName, instant: instant))
      .then(_clearOnPop(container, serverId, channelId));
}

/// The channel last opened in [serverId], for its page's leftward drag to
/// bring back. Null when there is none, it is gone or hidden from us now, the
/// channels have not loaded, or it is a voice room (its chat is reached
/// through the room, and may be off).
HollowSwipeIn? lastMobileChannelSwipeIn(
  BuildContext context, {
  required String serverId,
  required String? channelId,
  required Map<String, ChannelInfo>? channels,
  required WidgetBuilder Function(String channelName) preview,
}) {
  if (channelId == null) return null;
  final channel = channels?[channelId];
  if (channel == null ||
      !channel.meCanSee ||
      channel.channelType == ChannelType.voice) {
    return null;
  }
  final name = channel.name;
  final container = ProviderScope.containerOf(context, listen: false);
  return HollowSwipeIn(
    preview: preview(name),
    route: () {
      _select(container, serverId, channelId);
      return _channelRoute(serverId, channelId, name);
    },
    onPushed: (popped) =>
        popped.then(_clearOnPop(container, serverId, channelId)),
  );
}

/// Joins (or returns to) a voice room: the leave-your-call toast, the room
/// switch confirm, then the room's text chat (when on) under the voice page.
Future<void> openMobileVoiceChannel(
  BuildContext context,
  WidgetRef ref,
  String serverId,
  ChannelInfo channel,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (container.read(appLockedProvider)) return;
  if (container.read(serverAgeHiddenProvider(serverId))) return;
  // Nothing opens: a room pushed here would bury the refusal's toast and sit
  // on "Joining the room" until its deadline.
  if (container.read(serverRelayDeniedProvider(serverId))) {
    showEventToast(kServerDeniedText,
        kind: 'relay_denied_voice', id: serverId.toLowerCase());
    return;
  }
  if (container.read(serverElsewhereProvider(serverId)) != null) {
    showEventToast(kVoiceElsewhereText,
        kind: 'relay_elsewhere_voice', id: serverId.toLowerCase());
    return;
  }
  if (container.read(callProvider).status != CallStatus.idle) {
    HollowToast.show(context, 'Leave your call first',
        type: HollowToastType.error);
    return;
  }
  final nav = Navigator.of(context, rootNavigator: true);
  final vc = container.read(voiceChannelProvider);
  final alreadyIn = vc.currentServerId == serverId &&
      vc.currentChannelId == channel.channelId;

  Future<void>? join;
  if (!alreadyIn) {
    if (!await confirmVoiceRoomSwitch(context, ref,
            serverId: serverId,
            channelId: channel.channelId,
            channelName: channel.name) ||
        !context.mounted) {
      return;
    }
    join = container
        .read(voiceChannelProvider.notifier)
        .joinChannel(serverId, channel.channelId);
    join.catchError((Object e) {
      if (nav.mounted) {
        HollowToast.show(nav.context,
            friendlyError(e, fallback: "Couldn't join the voice room"),
            type: HollowToastType.error,
            overlayState: nav.overlay);
      }
    });
  }
  if (!nav.mounted || container.read(appLockedProvider)) return;
  // No chat under the call while the room's text chat is off (#107); the
  // chat goes in instantly, the voice page covers it.
  if (channel.chatOpen) {
    _openChannel(nav, container,
        serverId: serverId,
        channelId: channel.channelId,
        channelName: channel.name,
        instant: true);
  } else {
    _shapeStack(nav, serverId);
  }
  await nav.push(hollowMobileRoute<void>(
    settings: const RouteSettings(name: kMobileVoiceRouteName),
    transition: HollowRouteTransition.slideUp,
    builder: (_) => MobileVoiceChannelRoute(
      serverId: serverId,
      channelId: channel.channelId,
      channelName: channel.name,
      join: join,
    ),
  ));
}

/// The server actions sheet (long press on a server row, More in the header).
void showMobileServerSheet(
  BuildContext context,
  WidgetRef ref,
  String serverId,
) =>
    showMobileServerActions(context, ref, serverId);
