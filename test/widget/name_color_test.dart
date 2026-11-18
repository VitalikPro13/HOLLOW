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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/color_utils.dart';
import 'package:hollow/src/core/providers/name_color_provider.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/name_text.dart';
import 'package:hollow/src/ui/settings/name_color_editor.dart';

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
    final shaded = tester.widget<Text>(find.text('Ada'));
    expect(shaded.style?.foreground?.shader, isNotNull);
    expect(shaded.style?.color, isNull);

    await pump('1:ff3344');
    final text = tester.widget<Text>(find.text('Ada'));
    expect(text.style?.foreground, isNull);
    expect(text.style?.color, namePaintFor(friend, t, field: '1:ff3344').color);
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
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.style?.foreground?.shader != null)
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
}
