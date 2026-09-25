import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';

/// What a stage source shows: someone's screen or someone's camera.
enum CallSourceKind { screen, camera }

/// One thing the stage can focus. [owner] is the id the call's provider keys
/// that source by (a DEVICE id in a voice room, the person in a DM).
@immutable
class CallSourceId {
  final String owner;
  final CallSourceKind kind;

  const CallSourceId(this.owner, this.kind);

  const CallSourceId.screen(this.owner) : kind = CallSourceKind.screen;
  const CallSourceId.camera(this.owner) : kind = CallSourceKind.camera;

  @override
  bool operator ==(Object other) =>
      other is CallSourceId && other.owner == owner && other.kind == kind;

  @override
  int get hashCode => Object.hash(owner, kind);

  @override
  String toString() => 'CallSourceId($owner, ${kind.name})';
}

/// One person on the stage. Renderers stay owned by the call's provider: the
/// stage only places views of them and never creates or disposes one.
class CallPerson {
  /// The transport key: a DEVICE id in a voice room. Tiles key by it.
  final String id;

  /// The person behind [id]. Names and colours key by it.
  final String master;

  final bool isSelf;
  final String name;
  final bool cameraOn;
  final RTCVideoRenderer? camera;
  final bool mirror;
  final bool muted;
  final bool deafened;

  /// Selected from the call's VAD provider, so a flip rebuilds this tile alone.
  final ProviderListenable<bool> speaking;

  /// Null for a person whose link is never judged (you).
  final ProviderListenable<LinkHealthSnapshot?>? link;

  /// Opens the per-person menu (volume) at an overlay-space anchor. Null for
  /// you.
  final void Function(BuildContext context, Offset anchor)? onMenu;

  const CallPerson({
    required this.id,
    required this.master,
    required this.isSelf,
    required this.name,
    required this.speaking,
    this.cameraOn = false,
    this.camera,
    this.mirror = false,
    this.muted = false,
    this.deafened = false,
    this.link,
    this.onMenu,
  });

  CallSourceId get cameraSource => CallSourceId.camera(id);
}

/// One screen share: an offer until it is watched, live once it is (or when
/// it is ours).
class CallShare {
  final String owner;
  final String master;
  final bool isMine;
  final String name;

  /// Ours, or someone else's we pressed Watch on (issue #38).
  final bool watched;
  final RTCVideoRenderer? renderer;

  /// The sharer's source label ("1080p60").
  final String? quality;

  /// Who is watching OUR share, as masters.
  final List<String> watchers;

  const CallShare({
    required this.owner,
    required this.master,
    required this.isMine,
    required this.name,
    required this.watched,
    this.renderer,
    this.quality,
    this.watchers = const [],
  });

  CallSourceId get source => CallSourceId.screen(owner);
  bool get isOffer => !watched;
}

/// Everything the stage lays out, built by an adapter from the DM call or the
/// voice room.
class CallStageData {
  /// You first.
  final List<CallPerson> people;
  final List<CallShare> shares;

  /// The EFFECTIVE focus, already resolved by [resolveStageFocus].
  final CallSourceId? focus;

  /// "Show everyone" is on: the grid, with [focus] kept to come back to.
  final bool gridOn;

  final void Function(CallSourceId? source) onFocus;
  final void Function(bool on) onGrid;
  final void Function(String owner) onWatch;
  final void Function(String owner) onStopWatching;
  final VoidCallback onStopSharing;

  const CallStageData({
    required this.people,
    required this.shares,
    required this.focus,
    required this.gridOn,
    required this.onFocus,
    required this.onGrid,
    required this.onWatch,
    required this.onStopWatching,
    required this.onStopSharing,
  });

  /// What the layout centres on: nothing while "Show everyone" is on.
  CallSourceId? get layoutFocus => gridOn ? null : focus;

  List<CallShare> get liveShares => [
        for (final s in shares)
          if (s.watched) s
      ];

  CallShare? shareFor(CallSourceId id) {
    if (id.kind != CallSourceKind.screen) return null;
    for (final s in shares) {
      if (s.owner == id.owner) return s;
    }
    return null;
  }

  CallPerson? cameraFor(CallSourceId id) {
    if (id.kind != CallSourceKind.camera) return null;
    for (final p in people) {
      if (p.id == id.owner && p.cameraOn) return p;
    }
    return null;
  }

  /// Something the Layout control could centre on.
  bool get hasFocusable => focus != null || liveShares.isNotEmpty;
}

/// The sources that can hold focus right now: every live share and every
/// camera that is on. An unwatched offer cannot: it streams nothing.
Set<CallSourceId> liveStageSources({
  required Iterable<CallShare> shares,
  required Iterable<CallPerson> people,
}) =>
    {
      for (final s in shares)
        if (s.watched) s.source,
      for (final p in people)
        if (p.cameraOn) p.cameraSource,
    };

/// Focus only moves when the user clicks (D7). The provider's stored request
/// stands while its source is live; when that source ends, the next live
/// share takes it, else nothing does and the stage shows everyone. A camera
/// turning on, a new offer or a new watcher never changes the answer.
CallSourceId? resolveStageFocus({
  required CallSourceId? requested,
  required Set<CallSourceId> live,
  required List<CallSourceId> liveShares,
}) {
  if (requested == null) return null;
  if (live.contains(requested)) return requested;
  for (final share in liveShares) {
    if (share != requested) return share;
  }
  return null;
}

/// Grid columns for [n] tiles: 1-2 side by side, then 2, 3 and 4 wide.
int stageGridColumns(int n) {
  if (n <= 2) return n < 1 ? 1 : n;
  if (n <= 4) return 2;
  if (n <= 9) return 3;
  return 4;
}

/// What the bar's layout slot offers.
enum CallLayoutAction { showEveryone, focusScreen, backToChat }
