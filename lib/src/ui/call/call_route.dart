import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/media_route_provider.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_tooltip.dart';

/// What a route badge says: the word on the badge and the sentence behind it.
typedef RouteWords = ({String label, String tip});

/// The badge word for one route.
String mediaRouteLabel(MediaRoute route) => switch (route) {
      MediaRoute.direct => 'Direct',
      MediaRoute.relayed => 'Relayed',
      MediaRoute.memberForwarder || MediaRoute.relayForwarder => 'Forwarded',
    };

/// A DM call's route, said about the person on the other end.
RouteWords dmRouteWords(MediaRoute route, String peerName) => (
      label: mediaRouteLabel(route),
      tip: switch (route) {
        MediaRoute.direct =>
          'Your call goes straight to $peerName, with no server in between.',
        _ => 'Your call goes through the relay server. It stays encrypted.',
      },
    );

/// A watched share's route, said about the person sharing.
RouteWords shareRouteWords(MediaRoute route, String sharerName) => (
      label: mediaRouteLabel(route),
      tip: switch (route) {
        MediaRoute.direct => 'This share comes straight from $sharerName.',
        MediaRoute.relayed =>
          'This share comes through the relay server. It stays encrypted.',
        MediaRoute.memberForwarder =>
          "Another member's app passes this share along. It stays encrypted.",
        MediaRoute.relayForwarder =>
          "The relay's forwarder passes this share along. It stays encrypted.",
      },
    );

/// A remote participant of a voice room: the DEVICE id the mesh reports
/// routes by, the person behind it, and the name to show.
typedef RoomRoutePeer = ({String id, String master, String name});

/// One line for a whole voice room: the route every leg shares, or "Partly
/// relayed" naming who is reached which way. Null until a leg reports.
///
/// [peers] are the remote participants in stage order. Names are said once
/// per person, never per device; [selfMaster]'s other devices are "your other
/// device".
RouteWords? roomRouteWords(
  Map<String, MediaRoute> routes,
  List<RoomRoutePeer> peers, {
  String? selfMaster,
}) {
  final direct = <String, bool>{};
  final relayed = <String, bool>{};
  final names = <String, String>{};
  final devices = <String, int>{};
  var unreported = false;
  for (final p in peers) {
    names.putIfAbsent(p.master, () => p.name);
    devices[p.master] = (devices[p.master] ?? 0) + 1;
    switch (routes[p.id]) {
      case null:
        unreported = true;
      case MediaRoute.direct:
        direct[p.master] = true;
      default:
        relayed[p.master] = true;
    }
  }
  if (direct.isEmpty && relayed.isEmpty) return null;

  String nameOf(String master) => master == selfMaster
      ? ((devices[master] ?? 0) > 1 ? 'your other devices' : 'your other device')
      : names[master]!;
  List<String> said(Iterable<String> masters) => [for (final m in masters) nameOf(m)];

  if (relayed.isEmpty) {
    final everyone = !unreported && direct.length > 1;
    return (
      label: mediaRouteLabel(MediaRoute.direct),
      tip: 'Your call goes straight to '
          '${everyone ? 'everyone here' : joinNames(said(direct.keys))}, with '
          'no server in between.',
    );
  }
  if (direct.isEmpty) {
    return (
      label: mediaRouteLabel(MediaRoute.relayed),
      tip: 'Your call goes through the relay server. It stays encrypted.',
    );
  }
  // A person with legs both ways counts as relayed: some of their call is.
  final onlyDirect = [for (final m in direct.keys) if (!relayed.containsKey(m)) m];
  return (
    label: 'Partly relayed',
    tip: onlyDirect.isEmpty
        ? 'Part of your call to ${joinNames(said(relayed.keys))} goes '
            'through the relay server. It stays encrypted.'
        : 'Straight to ${joinNames(said(onlyDirect))}. Through the relay '
            'server to ${joinNames(said(relayed.keys))}. It stays encrypted.',
  );
}

/// "Mira", "Mira and Sam", "Mira, Sam and Ana", "Mira, Sam and 3 others".
String joinNames(List<String> names) {
  if (names.length == 1) return names.first;
  if (names.length <= 3) {
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
  return '${names.take(2).join(', ')} and ${names.length - 2} others';
}

/// Whose call a route badge describes.
sealed class CallRouteSubject {
  const CallRouteSubject();
}

/// The DM call with [peerName].
class DmCallRoute extends CallRouteSubject {
  final String peerName;
  const DmCallRoute(this.peerName);
}

/// A voice room or meeting with these remote participants.
class RoomCallRoute extends CallRouteSubject {
  final List<RoomRoutePeer> peers;

  /// Our own master, so our other devices are named as ours.
  final String? selfMaster;

  const RoomCallRoute(this.peers, {this.selfMaster});
}

/// The room route subject for a stage's remote participants.
RoomCallRoute roomRouteOf(CallStageData data) => RoomCallRoute(
      [
        for (final p in data.people)
          if (!p.isSelf) (id: p.id, master: p.master, name: p.name),
      ],
      selfMaster: data.people.where((p) => p.isSelf).firstOrNull?.master,
    );

/// How the call's media flows, as a badge with the reason in its tooltip.
/// Nothing until the first leg has settled on a route.
class CallRouteIndicator extends ConsumerWidget {
  final CallRouteSubject subject;

  const CallRouteIndicator(this.subject, {super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final words = switch (subject) {
      DmCallRoute(:final peerName) => switch (
            ref.watch(callMediaRouteProvider)) {
          null => null,
          final route => dmRouteWords(route, peerName),
        },
      RoomCallRoute(:final peers, :final selfMaster) => roomRouteWords(
          ref.watch(vcMediaRouteProvider), peers,
          selfMaster: selfMaster),
    };
    if (words == null) return const SizedBox.shrink();
    return HollowTooltip(
      message: words.tip,
      child: Semantics(
        container: true,
        label: '${words.label}. ${words.tip}',
        excludeSemantics: true,
        child: HollowBadge(words.label),
      ),
    );
  }
}
