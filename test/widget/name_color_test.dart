/// #140: a person's own name colour on this device.
///
/// What this pins: the viewer's "Show custom name colours" switch decides
/// whether a chosen colour is drawn at all (off = everyone's hashed colour),
/// a gradient paints through one shader across the name and a single colour
/// stays a plain text colour, and the Settings > Profile editor writes the
/// draft field (pick, add a stop, remove one, clear) and saves it.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/blocked_users_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/name_color_provider.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/contrast.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/name_text.dart';
import 'package:hollow/src/ui/settings/name_color_editor.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

storage_api.UserProfile _profile(String peerId, String nameColor) =>
    storage_api.UserProfile(
      peerId: peerId,
      displayName: 'Ada',
      status: '',
      aboutMe: '',
      updatedAt: 1,
      twitchUsername: '',
      showcaseBoard: '',
      avatarFrame: '',
      avatarAnim: '',
      bannerAnim: '',
      supportCreds: '',
      nameColor: nameColor,
    );

class _Profiles extends ProfileNotifier {
  final Map<String, String> colors;
  final sentNameColors = <String?>[];

  _Profiles(this.colors);

  @override
  Map<String, storage_api.UserProfile> build() =>
      {for (final e in colors.entries) e.key: _profile(e.key, e.value)};

  @override
  Future<void> updateMyProfile({
    required String displayName,
    String status = '',
    String aboutMe = '',
    Uint8List? avatarBytes,
    Uint8List? bannerBytes,
    String twitchUsername = '',
    String? showcaseBoard,
    List<dynamic>? showcaseAssets,
    String? avatarFrame,
    String? avatarAnim,
    String? bannerAnim,
    String? supportCreds,
    String? nameColor,
  }) async {
    sentNameColors.add(nameColor);
  }
}

class _Links extends DeviceLinkNotifier {
  @override
  DeviceLinkState build() =>
      const DeviceLinkState(links: {'device-of-friend': kFriendPeerId1});
}

class _NameColorsOff extends ShowNameColorsNotifier {
  @override
  bool build() => false;
}

ProviderContainer _container(_Profiles profiles, {bool showColors = true}) {
  final c = ProviderContainer(
    overrides: hollowTestOverrides(extra: [
      profileProvider.overrideWith(() => profiles),
      if (!showColors) showNameColorsProvider.overrideWith(_NameColorsOff.new),
    ]),
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  const friend = kFriendPeerId1;
  const gradient = '1:ff3344,22cc55,3366ff';

  test('a chosen colour is shown while the switch is on', () {
    final c = _container(_Profiles({friend: gradient}));
    expect(c.read(showNameColorsProvider), isTrue, reason: 'on by default');
    expect(c.read(shownNameColorProvider(friend)), gradient);
    final paint = namePaintFor(friend, HollowTheme.dark(),
        field: c.read(shownNameColorProvider(friend)));
    expect(paint.stops, hasLength(3));
  });

  test('switching custom colours off falls back to the hashed colour', () {
    final c = _container(_Profiles({friend: gradient}), showColors: false);
    expect(c.read(shownNameColorProvider(friend)), '');
    final t = HollowTheme.dark();
    expect(
      namePaintFor(friend, t, field: c.read(shownNameColorProvider(friend))),
      NamePaint([nameColorFor(friend, t)]),
    );
  });

  testWidgets('only your own name keeps a colour in the accent band',
      (tester) async {
    final t = HollowTheme.dark();
    final a = HSLColor.fromColor(t.accent).hue;
    final teal = nameColorField([HSLColor.fromAHSL(1, a, 0.7, 0.5).toColor()]);
    final shown = <String, Color>{};
    Future<void> pump(String own) async {
      final c = ProviderContainer(
        overrides: hollowTestOverrides(extra: [
          profileProvider.overrideWith(() => _Profiles({friend: teal})),
          ownNameMasterProvider.overrideWithValue(own),
        ]),
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: Consumer(builder: (context, ref, _) {
          shown[own] = ref.chosenNamePaintOf(friend, t)!.color;
          shown['$own/namePaint'] = ref.namePaint(friend, t).color;
          return const SizedBox();
        }),
      ));
    }

    await pump(friend);
    await pump('someone else');
    double gap(Color c) {
      final d = (HSLColor.fromColor(c).hue - a).abs() % 360;
      return d > 180 ? 360 - d : d;
    }

    expect(gap(shown[friend]!), lessThan(3), reason: 'your own name');
    expect(gap(shown['$friend/namePaint']!), lessThan(3));
    expect(gap(shown['someone else']!), greaterThanOrEqualTo(kNameAccentBand - 3),
        reason: 'the same colour on someone else turns out of the band');
    expect(gap(shown['someone else/namePaint']!),
        greaterThanOrEqualTo(kNameAccentBand - 3));
  });

  testWidgets('a gradient paints through a shader, one colour does not',
      (tester) async {
    final t = HollowTheme.dark();
    Future<void> pump(String field) => tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: NameText('Ada',
              paint: namePaintFor(friend, t, field: field),
              style: const TextStyle()),
        ));

    await pump(gradient);
    expect(find.byType(ShaderMask), findsNothing, reason: 'no layer per name');
    final shaded =
        tester.renderObject<RenderParagraph>(find.text('Ada')).text.style;
    expect(shaded?.foreground?.shader, isNotNull);
    expect(shaded?.color, isNull);

    await pump('1:ff3344');
    final text = tester.widget<Text>(find.text('Ada'));
    expect(text.style?.foreground, isNull);
    expect(text.style?.color, namePaintFor(friend, t, field: '1:ff3344').color);
  });

  test("a blocked person's chosen colour shows nowhere", () {
    const device = 'device-of-friend';
    final c = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        profileProvider.overrideWith(() => _Profiles({friend: gradient})),
        deviceLinkProvider.overrideWith(_Links.new),
      ]),
    );
    addTearDown(c.dispose);
    expect(c.read(shownNameColorProvider(device)), gradient,
        reason: 'a device id reads its master\'s colour');
    c.read(blockedUsersProvider.notifier).state = {friend};
    expect(c.read(shownNameColorProvider(friend)), '');
    expect(c.read(shownNameColorProvider(device)), '');
    final t = HollowTheme.dark();
    expect(
        namePaintFor(friend, t, field: c.read(shownNameColorProvider(friend))),
        NamePaint([nameColorFor(friend, t)]),
        reason: 'in a chat they keep only the hashed colour');
  });

  testWidgets('a selected row lifts a chosen name over its fill',
      (tester) async {
    for (final (t, data) in [
      (HollowTheme.dark(), HollowThemeData.dark()),
      (HollowTheme.light(), HollowThemeData.light()),
    ]) {
      final chosen = namePaintFor(friend, t, field: '1:c92222');
      Future<Color?> drawn({required bool selected}) async {
        await tester.pumpWidget(MaterialApp(
          theme: data,
          home: Scaffold(
            body: HollowListRow(
                title: 'Ada', titlePaint: chosen, selected: selected),
          ),
        ));
        return tester.widget<Text>(find.text('Ada')).style?.color;
      }

      expect(await drawn(selected: false), chosen.color);
      final lifted = await drawn(selected: true);
      final theme = HollowTheme.of(tester.element(find.text('Ada')));
      expect(lifted, namePaintOnSelected(chosen, theme).color);
      for (final bg in selectedNameSurfaces(theme)) {
        expect(Contrast.ratio(lifted!, bg),
            greaterThanOrEqualTo(kChosenNameContrast - 0.01));
      }
    }
  });

  testWidgets('the editor picks, adds, removes and clears into the draft',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final profiles = _Profiles({kLocalPeerId: ''});
    final c = _container(profiles);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(
              child: NameColorEditor(peerId: kLocalPeerId)),
        ),
      ),
    ));
    await tester.pump();

    String? field() => c.read(profileDraftProvider).effectiveNameColor;
    int gradients() => tester
        .renderObjectList<RenderParagraph>(find.byType(RichText))
        .where((p) => p.text.style?.foreground?.shader != null)
        .length;
    expect(field(), isNull);
    expect(find.bySemanticsLabel('Add a colour'), findsNothing,
        reason: 'nothing to add to before the first pick');

    await tester.tap(find.bySemanticsLabel('Use this colour').first);
    await tester.pump();
    expect(nameColorStops(field()!), hasLength(1));
    expect(gradients(), 0, reason: 'one colour');

    await tester.tap(find.bySemanticsLabel('Add a colour'));
    await tester.pump();
    expect(nameColorStops(field()!), hasLength(2));
    // Both previews, dark and light, draw the gradient.
    expect(gradients(), 2);

    await tester.tap(find.bySemanticsLabel('Add a colour'));
    await tester.pump();
    expect(nameColorStops(field()!), hasLength(3));
    expect(find.bySemanticsLabel('Add a colour'), findsNothing,
        reason: 'three stops at most');

    await tester.tap(find.bySemanticsLabel('Remove colour 3'));
    await tester.pump();
    expect(nameColorStops(field()!), hasLength(2));

    await tester.tap(find.bySemanticsLabel('Remove name colour'));
    await tester.pump();
    expect(field(), '', reason: 'back to the usual colour');
    expect(gradients(), 0);
  });

  testWidgets('the preview shows the name as everyone else sees it',
      (tester) async {
    // A teal pick sits in the default accent band, so others see it turned.
    for (final field in ['1:00bfa6', '1:c92222']) {
      for (final t in [HollowTheme.dark(), HollowTheme.light()]) {
        await tester.pumpWidget(MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: NameColorPreview(
                name: 'Ada',
                peerId: kLocalPeerId,
                field: field,
                theme: t,
                caption: 'On dark',
                radius: 8),
          ),
        ));
        final text = tester.widget<Text>(find.text('Ada'));
        expect(text.style?.color, namePaintFor(kLocalPeerId, t, field: field).color,
            reason: field);
      }
    }
    expect(namePaintFor(kLocalPeerId, HollowTheme.light(), field: '1:00bfa6').color,
        isNot(namePaintFor(kLocalPeerId, HollowTheme.light(), field: '1:00bfa6', self: true).color),
        reason: 'the case this pins: others see a turned colour');
  });

  test('saving the draft sends the field, and only when it changed', () async {
    final profiles = _Profiles({kLocalPeerId: ''});
    final c = _container(profiles);
    final draft = c.read(profileDraftProvider.notifier);

    draft.displayName.text = 'Ada';
    await draft.save();
    expect(profiles.sentNameColors.last, isNull, reason: 'untouched = preserve');

    draft.setNameColor('1:3366ff,9933ff');
    await draft.save();
    expect(profiles.sentNameColors.last, '1:3366ff,9933ff');
    expect(c.read(profileDraftProvider).nameColorChanged, isFalse);

    draft.setNameColor('');
    await draft.save();
    expect(profiles.sentNameColors.last, '', reason: 'an explicit clear');
  });

  // #140, Vitalik Nov 22: the editor says when, and which way, the floor moves
  // a pick, read off the same paint the previews draw.
  group('the readability note', () {
    Future<ProviderContainer> pumpEditor(WidgetTester tester, String saved) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = _container(_Profiles({kLocalPeerId: saved}));
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(
                child: NameColorEditor(peerId: kLocalPeerId)),
          ),
        ),
      ));
      await tester.pump();
      return c;
    }

    final note = find.textContaining('readable');
    const indigo = Color(0xff4b0082); // design-ignore: a pick below the floor on dark
    const nearBlack = Color(0xff141414); // design-ignore: a pick below the floor on dark
    const yellow = Color(0xffffff00); // design-ignore: a pick below the floor on light
    const reporterRed = Color(0xffc92222); // design-ignore: the reporter's pick

    testWidgets('a pick drawn as picked says nothing', (tester) async {
      for (final pick in [nameColorFromHue(0), reporterRed]) {
        await pumpEditor(tester, nameColorField([pick]));
        expect(note, findsNothing, reason: '$pick');
      }
    });

    testWidgets('a pick lightened on dark says so', (tester) async {
      for (final pick in [indigo, nearBlack]) {
        await pumpEditor(tester, nameColorField([pick]));
        expect(find.text('Lightened on dark so it stays readable.'),
            findsOneWidget, reason: '$pick');
        expect(find.byIcon(LucideIcons.triangleAlert), findsOneWidget);
      }
    });

    testWidgets('a pick darkened on light says so', (tester) async {
      await pumpEditor(tester, nameColorField([yellow]));
      expect(find.text('Darkened on light so it stays readable.'),
          findsOneWidget);
    });

    testWidgets('a gradient names the one colour that moved', (tester) async {
      await pumpEditor(tester, nameColorField([nameColorFromHue(0), indigo]));
      expect(find.text('Colour 2 is lightened on dark so it stays readable.'),
          findsOneWidget);
    });

    test('the note names the theme, the way and the colours', () {
      expect(nameColorShiftNote([0], [0]), isNull);
      expect(nameColorShiftNote(null, null), isNull);
      expect(nameColorShiftNote([1], [-1]),
          'Lightened on dark and darkened on light so it stays readable.');
      expect(nameColorShiftNote([0, 1, 1], [0, 0, 0]),
          'Colours 2 and 3 are lightened on dark so they stay readable.');
      expect(nameColorShiftNote([0, 1], [0, -1]),
          'Colour 2 is lightened on dark and darkened on light so it stays '
          'readable.');
      expect(nameColorShiftNote([1, 0], [0, -1]),
          'Colour 1 is lightened on dark and colour 2 is darkened on light so '
          'they stay readable.');
      expect(nameColorShiftNote([1, 1], [0, -1]),
          'Every colour is lightened on dark and colour 2 is darkened on '
          'light so they stay readable.');
      for (final note in [
        nameColorShiftNote([1], [-1])!,
        nameColorShiftNote([1, 0], [0, -1])!,
      ]) {
        expect(note.contains('\u2014'), isFalse, reason: 'no em dash');
      }
    });

    testWidgets('the note follows the pick as it changes', (tester) async {
      final c = await pumpEditor(tester, nameColorField([nameColorFromHue(0)]));
      expect(note, findsNothing);
      c.read(profileDraftProvider.notifier).setNameColor(nameColorField([yellow]));
      await tester.pump();
      expect(find.text('Darkened on light so it stays readable.'),
          findsOneWidget);
      c
          .read(profileDraftProvider.notifier)
          .setNameColor(nameColorField([nameColorFromHue(0)]));
      await tester.pump();
      expect(note, findsNothing);
    });
  });
}
