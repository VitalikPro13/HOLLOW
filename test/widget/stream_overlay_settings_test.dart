import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/call_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_badge.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_look_editor.dart';
import 'package:hollow/src/ui/settings/stream_overlay/overlay_tick.dart';
import 'package:hollow/src/ui/settings/stream_overlay/stream_overlay_page.dart';
import 'package:hollow/src/ui/shell/user_context_menu.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// Settings > Stream overlay (#97): the dependent toggle, the phone's missing
/// OBS sections, the profile tick's visibility, the local editor's "not
/// overridden" state, and the port warning.
void main() {
  setUpAll(() => RustLib.initMock(api: _Api()));

  final hashA = 'a' * 64;
  final hashB = 'b' * 64;
  late _FakeOwn own;
  late _FakePeople people;
  late Map<String, String> fields;
  late Set<String> blocked;
  late OverlayServer server;

  setUp(() {
    own = _FakeOwn((
      allow: true,
      share: true,
      look: OverlayLook(effects: OverlayEffects.defaults),
    ));
    people = _FakePeople([]);
    fields = {};
    blocked = {};
    server = (status: _status(), links: null);
    overlayServerSupported = () => true;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in _quietChannels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  List<Override> overrides() => hollowTestOverrides(extra: [
        overlayOwnProvider.overrideWith(() => own),
        overlayPeopleProvider.overrideWith(() => people),
        overlayFieldProvider.overrideWith((ref, m) => fields[m] ?? 'show'),
        overlayServerProvider.overrideWith(() => _FakeServer(server)),
        blockedUsersProvider.overrideWith(() => _Blocked(blocked)),
        audioInputDeviceProvider.overrideWith(_NoInput.new),
        callProvider.overrideWith(_IdleCall.new),
      ]);

  Future<ProviderContainer> pumpPage(WidgetTester tester,
      {bool touch = false, Size size = const Size(1200, 4000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return SettingsDensity(
              touch: touch,
              child: const SingleChildScrollView(
                child: StreamOverlaySettingsPage(),
              ),
            );
          }),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    return container;
  }

  HollowToggle toggle(WidgetTester tester, String label) => tester.widget(
      find.byWidgetPredicate(
          (w) => w is HollowToggle && w.semanticLabel == label));

  testWidgets(
      'Share my overlay images greys out and goes off while Let others show me '
      'is off, and keeps its place', (tester) async {
    await pumpPage(tester);
    const allow = 'Let others show me on their stream overlay';
    const share = 'Share my overlay images';
    expect(toggle(tester, share).value, isTrue);
    expect(toggle(tester, share).onChanged, isNotNull);
    final before = tester.getTopLeft(find.byWidgetPredicate(
        (w) => w is HollowToggle && w.semanticLabel == share));

    await tester.tap(find.byWidgetPredicate(
        (w) => w is HollowToggle && w.semanticLabel == allow));
    await tester.pump();

    expect(own.flags.last, (false, false), reason: 'share is forced off');
    expect(toggle(tester, share).value, isFalse);
    expect(toggle(tester, share).onChanged, isNull);
    expect(find.textContaining('Turn on the switch above first'), findsOneWidget);
    expect(
        tester.getTopLeft(find.byWidgetPredicate(
            (w) => w is HollowToggle && w.semanticLabel == share)),
        before);
  });

  testWidgets('a phone gets the first three sections and no OBS ones',
      (tester) async {
    overlayServerSupported = () => false;
    await pumpPage(tester, touch: true, size: const Size(400, 6000));
    expect(find.text('Who can show me'), findsOneWidget);
    expect(find.text('My overlay look'), findsOneWidget);
    expect(find.text('People on my overlay'), findsOneWidget);
    expect(find.text('Run the overlay for OBS'), findsNothing);
    expect(find.text('Layout'), findsNothing);
    expect(find.text('Listen to my mic now'), findsNothing);
    expect(find.text('Customise with CSS in OBS'), findsNothing);
  });

  testWidgets('desktop shows the OBS sections', (tester) async {
    await pumpPage(tester);
    expect(find.text('Run the overlay for OBS'), findsOneWidget);
    expect(find.text('Listen to my mic now'), findsOneWidget);
    expect(find.text('Customise with CSS in OBS'), findsOneWidget);
  });

  testWidgets('the port warning and the links show while the overlay runs',
      (tester) async {
    server = (
      status: _status(running: true, portChanged: true),
      links: const OverlayLinksFfi(
          room: 'http://127.0.0.1:23456/t/room',
          me: 'http://127.0.0.1:23456/t/me',
          personBase: 'http://127.0.0.1:23456/t/p/'),
    );
    people = _FakePeople([_person('p1', slot: 1)]);
    await pumpPage(tester);
    expect(find.textContaining('moved to a new port'), findsOneWidget);
    expect(find.text('Copy link'), findsNWidgets(2),
        reason: 'whole room and just me; people copy from their own rows');
    expect(find.textContaining('Only this person'), findsNothing);
    expect(find.text('127.0.0.1:23456'), findsOneWidget);
  });

  testWidgets('the tick is hidden for off, for ourselves and for blocked people',
      (tester) async {
    fields = {'off-peer': 'off', 'share-peer': 'share'};
    blocked = {'blocked-peer'};
    people = _FakePeople([_person('share-peer', slot: 1)]);
    final container = await pumpPage(tester);
    await tester.pump();
    ({bool show, bool added}) tick(String peer) =>
        overlayTickState(container.read, peer);
    expect(tick('off-peer').show, isFalse);
    expect(tick(kLocalPeerId).show, isFalse);
    expect(tick('blocked-peer').show, isFalse);
    expect(tick('show-peer'), (show: true, added: false));
    expect(tick('share-peer'), (show: true, added: true));
  });

  testWidgets('the voice row menu carries the tick only where it may show',
      (tester) async {
    fields = {'off-peer': 'off'};
    late WidgetRef widgetRef;
    late BuildContext ctx;
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Consumer(builder: (context, ref, _) {
          widgetRef = ref;
          ctx = context;
          return const SizedBox.expand();
        })),
      ),
    ));
    Future<bool> hasTick(String peer) async {
      showUserContextMenu(
        context: ctx,
        ref: widgetRef,
        peerId: peer,
        anchor: const Offset(100, 100),
        surface: UserMenuSurface.voice,
      );
      await tester.pumpAndSettle();
      final found = find.text(kOverlayTickLabel).evaluate().isNotEmpty;
      Navigator.of(ctx).pop();
      await tester.pumpAndSettle();
      return found;
    }

    expect(await hasTick('show-peer'), isTrue);
    expect(await hasTick('off-peer'), isFalse);
  });

  testWidgets(
      'the local editor shows Not overridden, sets and resets an effect, and '
      'saves only my picks', (tester) async {
    people = _FakePeople([
      _person('p1',
          slot: 1,
          theirs: OverlayLook(
            states: {OverlayLookState.idle: hashA},
            effects: OverlayEffects.defaults.copyWith(talking: 'shake'),
          )),
    ]);
    await pumpPage(tester);
    await tester.tap(find.text('Pick images'));
    await tester.pumpAndSettle();

    Finder inDialog(String text) => find
        .descendant(of: find.byType(HollowDialog), matching: find.text(text))
        .first;
    Finder notOverridden() => find.byWidgetPredicate(
        (w) => w is HollowBadge && w.label == 'Not overridden');
    expect(notOverridden(), findsNWidgets(9));
    expect(find.text('Theirs'), findsOneWidget, reason: 'their idle image');

    // Their shake shows as the current choice until I pick something.
    await tester.tap(inDialog('Glow'));
    await tester.pump();
    expect(notOverridden(), findsNWidgets(8));
    expect(find.text('Reset'), findsOneWidget);

    await tester.tap(inDialog('Reset'));
    await tester.pump();
    expect(notOverridden(), findsNWidgets(9));

    await tester.tap(inDialog('Glow'));
    await tester.pump(const Duration(milliseconds: 400));
    final saved = people.local['p1'];
    expect(saved, isNotNull, reason: 'a choice saves by itself');
    expect(saved!.effects.toMap(), {'talking': 'glow'});
    expect(saved.hashes, isEmpty);
    expect(find.descendant(of: find.byType(HollowDialog), matching: find.text('Save')),
        findsNothing);
    expect(find.descendant(of: find.byType(HollowDialog), matching: find.text('Cancel')),
        findsNothing);

    await tester.tap(inDialog('Reset all'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(people.local.containsKey('p1'), isTrue);
    expect(people.local['p1'], isNull, reason: 'Reset all saves no picks');
    expect(people.saves, 2);

    await tester.tap(inDialog('Done'));
    await tester.pumpAndSettle();
    expect(find.byType(HollowDialog), findsNothing);
    expect(people.saves, 2, reason: 'Done only closes');
  });

  testWidgets(
      'the own editor saves a pick and a choice by itself, a burst as one save',
      (tester) async {
    overlayPickImagePath = () async => 'C:/art/idle.png';
    own.processed = hashB;
    await pumpPage(tester);
    expect(find.text('Save look'), findsNothing);
    expect(find.text('Undo changes'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Pick the Idle image'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Pop').first);
    await tester.pump(const Duration(milliseconds: 100));
    expect(own.saves, 0, reason: 'the burst is still settling');
    await tester.pump(const Duration(milliseconds: 400));

    expect(own.saves, 1);
    expect(own.saved!.hashOf(OverlayLookState.idle), hashB);
    expect(own.saved!.effects.talking, 'pop');

    await tester.tap(find.text('Glow').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(own.saves, 2, reason: 'a later choice saves on its own');
    expect(own.saved!.effects.talking, 'glow');
  });

  testWidgets('a slider saves once on release, never per drag step',
      (tester) async {
    await pumpPage(tester);
    final slider = find.descendant(
        of: find.ancestor(
            of: find.text('Hold after talking'),
            matching: find.byType(SettingsSliderRow)),
        matching: find.byType(Slider));
    final gesture = await tester.startGesture(tester.getCenter(slider));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(12, 0));
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(own.saves, 0, reason: 'nothing saves while the thumb is held');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    expect(own.saves, 1);
    expect(own.saved!.effects.holdMs, isNot(OverlayEffects.defaults.holdMs));
  });

  group('People on my overlay', () {
    List<OverlayPerson> crowd(int n) => [
          for (var i = 1; i <= n; i++)
            _person('ppl-${i.toString().padLeft(2, '0')}', slot: i),
        ];
    Finder rowsOf() => find.textContaining('ppl-');
    Finder copyButtons() => find.byWidgetPredicate((w) =>
        w is HollowIconButton && w.label.startsWith('Copy the OBS link for'));

    testWidgets('three people show whole, with no Show all and no filter',
        (tester) async {
      people = _FakePeople(crowd(3));
      await pumpPage(tester);
      expect(rowsOf(), findsNWidgets(3));
      expect(find.text('Show all'), findsNothing);
      expect(find.text('Find a person'), findsNothing);
    });

    testWidgets('six people show five, and Show all keeps its place',
        (tester) async {
      people = _FakePeople(crowd(6));
      await pumpPage(tester);
      expect(rowsOf(), findsNWidgets(5));
      expect(find.text('Find a person'), findsNothing);
      Offset corner(String label) => tester.getTopRight(
          find.ancestor(of: find.text(label), matching: find.byType(HollowButton)));
      final at = corner('Show all');
      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(rowsOf(), findsNWidgets(6));
      expect(corner('Show less'), at);
      await tester.tap(find.text('Show less'));
      await tester.pump();
      expect(rowsOf(), findsNWidgets(5));
    });

    testWidgets('twelve people get a filter above the list', (tester) async {
      people = _FakePeople(crowd(12));
      await pumpPage(tester);
      expect(rowsOf(), findsNWidgets(5));
      expect(find.text('Find a person'), findsOneWidget);
      final filter = find.byWidgetPredicate(
          (w) => w is HollowTextField && w.hintText == 'Find a person');
      await tester.enterText(filter, '07');
      await tester.pump();
      expect(rowsOf(), findsOneWidget);
      expect(find.text('ppl-07'), findsOneWidget);
      expect(find.text('1 of 12'), findsOneWidget);
      await tester.enterText(filter, 'zz');
      await tester.pump();
      expect(find.text('Nobody here matches that'), findsOneWidget);
    });

    testWidgets('no link button while the overlay is off', (tester) async {
      people = _FakePeople(crowd(2));
      await pumpPage(tester);
      expect(rowsOf(), findsNWidgets(2));
      expect(copyButtons(), findsNothing);
    });

    testWidgets('each row copies its own link, on desktop while the overlay runs',
        (tester) async {
      people = _FakePeople(crowd(2));
      server = (
        status: _status(running: true),
        links: const OverlayLinksFfi(
            room: 'http://127.0.0.1:23456/t/room',
            me: 'http://127.0.0.1:23456/t/me',
            personBase: 'http://127.0.0.1:23456/t/p/'),
      );
      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      await pumpPage(tester);
      expect(copyButtons(), findsNWidgets(2));
      await tester.tap(copyButtons().last);
      await tester.pump();
      expect(copied, 'http://127.0.0.1:23456/t/p/2');
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a phone never shows the link button', (tester) async {
      overlayServerSupported = () => false;
      server = (
        status: _status(running: true),
        links: const OverlayLinksFfi(
            room: 'http://127.0.0.1:23456/t/room',
            me: 'http://127.0.0.1:23456/t/me',
            personBase: 'http://127.0.0.1:23456/t/p/'),
      );
      people = _FakePeople(crowd(2));
      await pumpPage(tester, touch: true, size: const Size(400, 6000));
      expect(copyButtons(), findsNothing);
    });
  });

  testWidgets('the local editor processes a swept pick again before saving',
      (tester) async {
    overlayPickImagePath = () async => 'C:/art/pick.png';
    own.processed = hashA;
    people = _FakePeople([_person('p1', slot: 1)]);
    await pumpPage(tester);
    await tester.tap(find.text('Pick images'));
    await tester.pumpAndSettle();
    final dialog = find.byType(HollowDialog);

    await tester.tap(find
        .descendant(
            of: dialog, matching: find.bySemanticsLabel('Pick the Idle image'))
        .first);
    await tester.pump();
    await tester.pump();
    // Nothing holds the picked image any more (the sweep took the draft), so
    // the save makes it again from its file and saves that image.
    own.processed = hashB;
    await tester.pump(const Duration(milliseconds: 400));

    expect(own.processedPaths, ['C:/art/pick.png', 'C:/art/pick.png']);
    expect(people.local['p1']?.hashOf(OverlayLookState.idle), hashB);
  });
}

OverlayServerStatusFfi _status(
        {bool running = false, bool portChanged = false}) =>
    OverlayServerStatusFfi(
      enabled: running,
      running: running,
      port: running ? 23456 : 0,
      portChanged: portChanged,
      openStreams: 0,
    );

OverlayPerson _person(String master,
    {required int slot, OverlayLook? theirs, OverlayLook? local}) {
  final effective = theirs ?? OverlayLook(effects: OverlayEffects.defaults);
  return OverlayPerson(
    master: master,
    slot: slot,
    field: theirs == null ? 'show' : 'share',
    theirs: theirs,
    local: local,
    effective: effective,
    effectiveJson: effective.toJson(),
  );
}

const _quietChannels = [
  'FlutterWebRTC.Method',
  'FlutterWebRTC.Event',
  'win32audio',
];

class _Api implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}

class _FakeOwn extends OverlayOwnNotifier {
  final OverlayOwn initial;
  final List<(bool, bool)> flags = [];
  OverlayLook? saved;
  int saves = 0;
  String processed = '';
  final List<String> processedPaths = [];

  _FakeOwn(this.initial);

  @override
  Future<OverlayOwn> build() async => initial;

  @override
  Future<void> setFlags({required bool allow, required bool share}) async {
    flags.add((allow, share));
    final now = state.value!;
    state = AsyncData((allow: allow, share: allow && share, look: now.look));
  }

  @override
  Future<OverlayLook> saveLook(OverlayLook look) async {
    saves++;
    saved = look;
    return look.copyWith(stamp: look.stamp + 1);
  }

  @override
  Future<OverlayImageFfi> processImage(String path) async {
    processedPaths.add(path);
    return OverlayImageFfi(
        hash: processed, width: 64, height: 64, animated: false);
  }
}

class _FakePeople extends OverlayPeopleNotifier {
  final List<OverlayPerson> initial;
  final Map<String, OverlayLook?> local = {};
  int saves = 0;

  _FakePeople(this.initial);

  @override
  Future<List<OverlayPerson>> build() async => initial;

  @override
  Future<void> setLocal(String master, OverlayLook? look) async {
    saves++;
    local[master] = look;
  }
}

class _FakeServer extends OverlayServerNotifier {
  final OverlayServer initial;

  _FakeServer(this.initial);

  @override
  OverlayServer build() => initial;
}

class _Blocked extends BlockedUsersNotifier {
  final Set<String> initial;

  _Blocked(this.initial);

  @override
  Set<String> build() => initial;
}

class _NoInput extends AudioInputDeviceNotifier {
  @override
  Future<String?> build() async => null;
}

class _IdleCall extends CallNotifier {
  @override
  CallState build() => const CallState();
}
