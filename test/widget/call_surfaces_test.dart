/// The call surfaces (design language session 21, `tmp3.txt` section 3): the
/// speaking ring, the person tile's marks, the ONE bar, and the stage's focus
/// rules. Focus only moves on a click (D7), the strip sits ABOVE a focused
/// source (D8), and the bar never hides outside fullscreen (D10).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/link_health_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/services/link_resilience.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/call/share_tile.dart';
import 'package:hollow/src/ui/call/speaking_ring.dart';
import 'package:hollow/src/ui/chat/voice_channel_pane.dart';
import 'package:hollow/src/ui/components/call_duration_text.dart';
import 'package:hollow/src/ui/shell/bottom_bar.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

final _quiet = Provider<bool>((_) => false);
final _talking = Provider<bool>((_) => true);

const _me = 'me_master';
const _mira = 'mira_master';
const _juno = 'juno_device';

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(1280, 800),
  List<Override> extra = const [],
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: extra));
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(body: child),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

CallPerson _person(String id,
        {bool self = false,
        bool camera = false,
        bool muted = false,
        ProviderListenable<bool>? speaking,
        ProviderListenable<LinkHealthSnapshot?>? link}) =>
    CallPerson(
      id: id,
      master: id,
      isSelf: self,
      name: self ? 'You' : id,
      cameraOn: camera,
      muted: muted,
      speaking: speaking ?? _quiet,
      link: link,
    );

/// A stage whose sources and focus live in a plain model, so a test can
/// flip a camera or add an offer and see what the stage does with it.
class _Model {
  List<CallPerson> people;
  List<CallShare> shares;
  CallSourceId? requested;
  bool gridOn = false;
  _Model(this.people, this.shares, this.requested);
}

class _FakeSource extends CallStageSource {
  final _Model model;
  final VoidCallback changed;
  _FakeSource(this.model, this.changed);

  @override
  CallStageData? watchData(BuildContext context, WidgetRef ref) {
    final m = model;
    return CallStageData(
      people: m.people,
      shares: m.shares,
      focus: resolveStageFocus(
        requested: m.requested,
        live: liveStageSources(shares: m.shares, people: m.people),
        liveShares: [for (final s in m.shares) if (s.watched) s.source],
      ),
      gridOn: m.gridOn,
      onFocus: (s) {
        m.requested = s;
        m.gridOn = false;
        changed();
      },
      onGrid: (on) {
        m.gridOn = on;
        changed();
      },
      onWatch: (_) {},
      onStopWatching: (_) {},
      onStopSharing: () {},
    );
  }

  @override
  CallBarModel? watchBar(BuildContext context, WidgetRef ref,
          CallStageData data,
          {required bool fullscreen, required VoidCallback onFullscreen}) =>
      _bar();
}

CallBarModel _bar({bool muted = false, bool cameraOn = false}) =>
    CallBarModel(
      startedAt: DateTime.now(),
      muted: muted,
      deafened: false,
      onMute: () {},
      onDeafen: () {},
      cameraOn: cameraOn,
      onCamera: () {},
      sharing: false,
      onShare: () {},
      layout: CallLayoutAction.showEveryone,
      onLayout: () {},
      fullscreen: false,
      onFullscreen: () {},
      watching: false,
      leaveLabel: 'Leave the room',
      onLeave: () {},
    );

class _StageHost extends StatefulWidget {
  final _Model model;
  const _StageHost(this.model);
  @override
  State<_StageHost> createState() => _StageHostState();
}

class _StageHostState extends State<_StageHost> {
  late final _FakeSource source =
      _FakeSource(widget.model, () => setState(() {}));

  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => CallStage(source: source);
}

CallShare _share(String owner, {bool watched = true, bool mine = false}) =>
    CallShare(
      owner: owner,
      master: owner,
      isMine: mine,
      name: owner,
      watched: watched,
    );

Finder _semantic(String label) => find.bySemanticsLabel(label);

void main() {
  group('speaking ring', () {
    testWidgets('yours is the accent, theirs is their own name colour',
        (tester) async {
      late HollowTheme hollow;
      await _pump(
        tester,
        Builder(builder: (context) {
          hollow = HollowTheme.of(context);
          return const SizedBox.shrink();
        }),
      );
      expect(callRingColor(hollow, isSelf: true, master: _mira),
          hollow.accent);
      expect(callRingColor(hollow, isSelf: false, master: _mira),
          nameColorFor(_mira, hollow));
      expect(callRingColor(hollow, isSelf: false, master: _mira),
          isNot(hollow.accent));
    });

    testWidgets('a flip never changes layout', (tester) async {
      Widget ring(bool on) => Center(
            child: SpeakingRing(
              speaking: on,
              color: const Color(0xFF00FF00),
              radius: 8,
              child: const SizedBox(
                  key: ValueKey('face'), width: 40, height: 40),
            ),
          );
      await _pump(tester, ring(false));
      final quiet = tester.getRect(find.byKey(const ValueKey('face')));
      await _pump(tester, ring(true));
      final loud = tester.getRect(find.byKey(const ValueKey('face')));
      expect(loud, quiet);
      expect(tester.getSize(find.byType(SpeakingRing)), const Size(40, 40),
          reason: 'the ring paints outside, it takes no space');
    });
  });

  group('person tile', () {
    testWidgets('nothing at rest; muted and a weak link say so',
        (tester) async {
      Widget tile(CallPerson p) => SizedBox(
          width: 480,
          height: 270,
          child: CallPersonTile(person: p, size: CallTileSize.large));

      await _pump(tester, tile(_person(_mira)));
      expect(find.byIcon(LucideIcons.micOff), findsNothing);
      expect(find.text('Weak connection'), findsNothing);

      final weak = Provider<LinkHealthSnapshot?>((_) =>
          const LinkHealthSnapshot(health: LinkHealth.unstable));
      await _pump(tester, tile(_person(_mira, muted: true, link: weak)));
      expect(find.byIcon(LucideIcons.micOff), findsOneWidget);
      expect(find.text('Weak connection'), findsOneWidget);
    });

    testWidgets('a muted person is never drawn speaking', (tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 480,
          height: 270,
          child: CallPersonTile(
            person: _person(_mira, muted: true, speaking: _talking),
            size: CallTileSize.large,
          ),
        ),
      );
      expect(tester.widget<SpeakingRing>(find.byType(SpeakingRing)).speaking,
          isFalse);
    });
  });

  group('bar', () {
    testWidgets('controls run in the agreed order, Leave last',
        (tester) async {
      await _pump(tester, Center(child: CallStageBar(model: _bar())));
      final order = [
        'Mute',
        'Deafen',
        'Turn on camera',
        'Share your screen',
        'Show everyone',
        'Full screen',
        'More',
        'Leave the room',
      ];
      final xs = [
        for (final label in order) tester.getCenter(_semantic(label).first).dx
      ];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]),
            reason: '${order[i]} comes after ${order[i - 1]}');
      }
    });

    testWidgets('muted reads red, at rest it does not', (tester) async {
      await _pump(tester, Center(child: CallStageBar(model: _bar())));
      final rest = tester
          .widgetList<CallToggleButton>(find.byType(CallToggleButton))
          .where((b) => b.alarm);
      expect(rest, isEmpty);
      await _pump(
          tester, Center(child: CallStageBar(model: _bar(muted: true))));
      final alarms = tester
          .widgetList<CallToggleButton>(find.byType(CallToggleButton))
          .where((b) => b.alarm)
          .map((b) => b.label);
      expect(alarms, ['Unmute']);
    });

    test('the timer shows hours past an hour', () {
      expect(CallDurationText.format(const Duration(minutes: 4, seconds: 3)),
          '04:03');
      expect(
          CallDurationText.format(
              const Duration(hours: 1, minutes: 15, seconds: 3)),
          '1:15:03');
    });
  });

  group('focus rules', () {
    const share = CallSourceId.screen(_mira);
    const cam = CallSourceId.camera(_juno);

    test('a camera turning on keeps the focused share', () {
      expect(
        resolveStageFocus(
          requested: share,
          live: {share, cam},
          liveShares: [share],
        ),
        share,
      );
    });

    test('nothing focused stays nothing, whatever arrives', () {
      expect(
        resolveStageFocus(requested: null, live: {share, cam}, liveShares: [
          share,
        ]),
        isNull,
      );
    });

    test('a focus that ended falls to the next live share, else everyone',
        () {
      const other = CallSourceId.screen(_juno);
      expect(
        resolveStageFocus(
            requested: share, live: {other}, liveShares: [other]),
        other,
      );
      expect(
        resolveStageFocus(requested: cam, live: const {}, liveShares: const []),
        isNull,
      );
    });

    test('an unwatched offer is never live', () {
      final live = liveStageSources(
        shares: [_share(_mira, watched: false)],
        people: [_person(_me, self: true)],
      );
      expect(live, isEmpty);
    });
  });

  group('stage', () {
    testWidgets('the strip sits above the focused share', (tester) async {
      final model = _Model(
        [_person(_me, self: true), _person(_juno, camera: true)],
        [_share(_mira)],
        const CallSourceId.screen(_mira),
      );
      await _pump(tester, _StageHost(model));
      final shareTile = find.byType(ShareTile);
      expect(shareTile, findsOneWidget);
      final strip = find.byWidgetPredicate((w) =>
          w is CallPersonTile && w.size == CallTileSize.strip);
      expect(strip, findsNWidgets(2));
      expect(tester.getBottomLeft(strip.first).dy,
          lessThan(tester.getTopLeft(shareTile).dy));
    });

    testWidgets(
        'a new camera or offer never takes focus; a click does, and the '
        'share drops into the strip', (tester) async {
      final model = _Model(
        [_person(_me, self: true), _person(_juno)],
        [_share(_mira)],
        const CallSourceId.screen(_mira),
      );
      await _pump(tester, _StageHost(model));
      final host = tester.state<_StageHostState>(find.byType(_StageHost));

      // Juno's camera comes on, and a second share is offered.
      model.people = [_person(_me, self: true), _person(_juno, camera: true)];
      model.shares = [_share(_mira), _share('kes', watched: false)];
      host.rebuild();
      await tester.pump();
      expect(
          find.byWidgetPredicate((w) =>
              w is ShareTile &&
              w.share.owner == _mira &&
              w.size == CallTileSize.large),
          findsOneWidget,
          reason: 'the focused share stays where it was');

      // Clicking Juno's camera in the strip focuses it.
      await tester.tap(find.byWidgetPredicate((w) =>
          w is CallPersonTile &&
          w.person.id == _juno &&
          w.size == CallTileSize.strip));
      await tester.pump();
      expect(model.requested, const CallSourceId.camera(_juno));
      expect(
          find.byWidgetPredicate((w) =>
              w is ShareTile &&
              w.share.owner == _mira &&
              w.size == CallTileSize.strip),
          findsOneWidget,
          reason: 'the share is a strip tile now, one click from back');
    });

    testWidgets('Hide and Show the people sit on the same spot',
        (tester) async {
      final model = _Model(
        [_person(_me, self: true), _person(_juno)],
        [_share(_mira)],
        const CallSourceId.screen(_mira),
      );
      await _pump(tester, _StageHost(model));
      final hide = tester.getCenter(_semantic('Hide the people').first);
      await tester.tap(_semantic('Hide the people').first);
      await tester.pump();
      final show = tester.getCenter(_semantic('Show the people').first);
      expect(show.dx, hide.dx, reason: 'one toggle, one place');
    });

    testWidgets('the bar stays put outside fullscreen', (tester) async {
      final model = _Model([_person(_me, self: true), _person(_juno)],
          const [], null);
      await _pump(tester, _StageHost(model));
      expect(find.byType(CallStageBar), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      final opacity = find.ancestor(
          of: find.byType(CallStageBar),
          matching: find.byType(AnimatedOpacity));
      expect(opacity, findsNothing, reason: 'no auto-hide outside fullscreen');
      expect(find.byType(CallStageBar), findsOneWidget);
    });

    testWidgets('nothing focused is everyone, you first', (tester) async {
      final model = _Model([_person(_me, self: true), _person(_juno)],
          const [], null);
      await _pump(tester, _StageHost(model));
      final tiles = find.byWidgetPredicate((w) =>
          w is CallPersonTile && w.size == CallTileSize.large);
      expect(tiles, findsNWidgets(2));
      expect(
          tester.widget<CallPersonTile>(tiles.first).person.isSelf, isTrue);
    });
  });

  group('your share', () {
    testWidgets('says who is watching', (tester) async {
      Widget tile(List<String> watchers) => SizedBox(
            width: 640,
            height: 360,
            child: ShareTile(
              size: CallTileSize.large,
              share: CallShare(
                owner: _me,
                master: _me,
                isMine: true,
                name: 'You',
                watched: true,
                watchers: watchers,
              ),
            ),
          );
      await _pump(tester, tile([kFriendPeerId1]));
      expect(find.textContaining('is watching'), findsOneWidget);
      expect(find.text('Stop sharing'), findsOneWidget);
      await _pump(tester, tile([kFriendPeerId1, kFriendPeerId2]));
      expect(find.text('2 watching'), findsOneWidget);
    });

    testWidgets("someone else's live share carries Stop watching",
        (tester) async {
      await _pump(
        tester,
        SizedBox(
          width: 640,
          height: 360,
          child: ShareTile(size: CallTileSize.large, share: _share(_mira)),
        ),
      );
      expect(find.text('Stop watching'), findsOneWidget);
      expect(find.text("$_mira's screen"), findsOneWidget);
    });
  });

  group('a room you are not in', () {
    Future<void> room(WidgetTester tester, Set<String> here) => _pump(
          tester,
          const VoiceChannelPane(
              serverId: 's1', channelId: 'v1', channelName: 'lounge'),
          extra: [
            vcChatPanelOpenProvider.overrideWith((_) => false),
            voiceChannelProvider.overrideWith(() => _Room(VoiceChannelState(
                  participants: {
                    's1': {'v1': here}
                  },
                ))),
          ],
        );

    testWidgets('shows who is there and one Join voice', (tester) async {
      await room(tester, {_mira, _juno});
      expect(
          find.byWidgetPredicate((w) =>
              w is CallPersonTile && w.size == CallTileSize.large),
          findsNWidgets(2));
      expect(find.text('Join voice'), findsOneWidget);
      expect(find.byType(CallStageBar), findsNothing,
          reason: 'no controls for a call you are not in');
      expect(find.text('2 people'), findsOneWidget);
    });

    testWidgets('empty says so, with Join voice', (tester) async {
      await room(tester, const {});
      expect(find.text("Nobody's here yet"), findsOneWidget);
      expect(find.text('Join voice'), findsOneWidget);
    });
  });

  group('dock', () {
    testWidgets('a DM call rides the dock', (tester) async {
      await _pump(
        tester,
        const Align(alignment: Alignment.bottomCenter, child: BottomBar()),
        size: const Size(1400, 300),
        extra: [
          overallConnectionProvider
              .overrideWithValue(OverallConnection.connected),
          callProvider.overrideWith(() => _InCall(const CallState(
                status: CallStatus.active,
                peerId: kFriendPeerId1,
                callId: 'c1',
              ))),
        ],
      );
      expect(find.textContaining('In a call with'), findsOneWidget);
      expect(_semantic('Leave the call'), findsWidgets);
      expect(_semantic('Mute'), findsWidgets);
    });

    testWidgets('ringing out is just Cancel', (tester) async {
      await _pump(
        tester,
        const Align(alignment: Alignment.bottomCenter, child: BottomBar()),
        size: const Size(1400, 300),
        extra: [
          overallConnectionProvider
              .overrideWithValue(OverallConnection.connected),
          callProvider.overrideWith(() => _InCall(const CallState(
                status: CallStatus.ringing,
                direction: CallDirection.outgoing,
                peerId: kFriendPeerId1,
                callId: 'c1',
              ))),
        ],
      );
      expect(find.textContaining('Calling'), findsOneWidget);
      expect(_semantic('Cancel'), findsWidgets);
      expect(_semantic('Mute'), findsNothing);
    });
  });
}

class _Room extends VoiceChannelNotifier {
  final VoiceChannelState initial;
  _Room(this.initial);
  @override
  VoiceChannelState build() => initial;
}

class _InCall extends CallNotifier {
  final CallState initial;
  _InCall(this.initial);
  @override
  CallState build() => initial;
}
