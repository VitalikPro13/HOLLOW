/// The Profile draft: every unsaved Settings > Profile edit, kept for the
/// app's lifetime so the Settings place can offer one Reset / Save bar.
///
/// What this pins: the fields start from the saved profile, a text edit or a
/// frame pick makes the draft dirty, Reset puts the saved values back, and
/// Save sends the edits through `updateMyProfile` (the legacy Twitch handle
/// carried through untouched) and leaves the draft clean. A failed save
/// rethrows with the edits intact.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/profile_draft_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/rust/api/showcase.dart' as showcase_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/pages/profile_page.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// One call to `updateMyProfile`, as the draft made it.
typedef _Saved = ({
  String displayName,
  String status,
  String aboutMe,
  String twitchUsername,
  String? avatarFrame,
  Object? avatarBytes,
  String? avatarAnim,
});

/// Holds my saved row and records every save instead of reaching Rust.
class _RecordingProfiles extends ProfileNotifier {
  final saves = <_Saved>[];
  bool fail = false;

  @override
  Map<String, storage_api.UserProfile> build() => {
        kLocalPeerId: const storage_api.UserProfile(
          peerId: kLocalPeerId,
          displayName: 'Saved name',
          status: 'Saved status',
          aboutMe: 'Saved about',
          updatedAt: 1,
          twitchUsername: 'legacyhandle',
          showcaseBoard: '',
          avatarFrame: '',
          avatarAnim: '',
          bannerAnim: '',
          supportCreds: '',
        ),
      };

  @override
  Future<void> updateMyProfile({
    required String displayName,
    String status = '',
    String aboutMe = '',
    Uint8List? avatarBytes,
    Uint8List? bannerBytes,
    String twitchUsername = '',
    String? showcaseBoard,
    List<showcase_api.ShowcaseAsset>? showcaseAssets,
    String? avatarFrame,
    String? avatarAnim,
    String? bannerAnim,
    String? supportCreds,
  }) async {
    if (fail) throw Exception('node is down');
    saves.add((
      displayName: displayName,
      status: status,
      aboutMe: aboutMe,
      twitchUsername: twitchUsername,
      avatarFrame: avatarFrame,
      avatarBytes: avatarBytes,
      avatarAnim: avatarAnim,
    ));
  }
}

({ProviderContainer container, _RecordingProfiles profiles}) _setUp() {
  final profiles = _RecordingProfiles();
  final container = ProviderContainer(
    overrides: hollowTestOverrides(extra: [
      profileProvider.overrideWith(() => profiles),
    ]),
  );
  addTearDown(container.dispose);
  return (container: container, profiles: profiles);
}

void main() {
  test('the fields start from the saved profile, clean', () {
    final (:container, profiles: _) = _setUp();
    final draft = container.read(profileDraftProvider.notifier);

    expect(container.read(profileDraftProvider).dirty, isFalse);
    expect(draft.displayName.text, 'Saved name');
    expect(draft.status.text, 'Saved status');
    expect(draft.aboutMe.text, 'Saved about');
  });

  test('a text edit makes the draft dirty, a caret move does not', () {
    final (:container, profiles: _) = _setUp();
    final draft = container.read(profileDraftProvider.notifier);

    draft.status.selection = const TextSelection.collapsed(offset: 2);
    expect(container.read(profileDraftProvider).dirty, isFalse);

    draft.status.text = 'Out walking';
    expect(container.read(profileDraftProvider).dirty, isTrue);
  });

  test('a frame pick makes the draft dirty', () {
    final (:container, profiles: _) = _setUp();
    container.read(profileDraftProvider.notifier).setFrame('b:250');

    final state = container.read(profileDraftProvider);
    expect(state.dirty, isTrue);
    expect(state.effectiveFrame, 'b:250');
  });

  test('Reset puts the saved profile back', () {
    final (:container, :profiles) = _setUp();
    final draft = container.read(profileDraftProvider.notifier);

    draft.displayName.text = 'Someone else';
    draft.aboutMe.text = 'Changed';
    draft.setFrame('b:0');
    draft.clearImage(avatar: true);
    draft.reset();

    final state = container.read(profileDraftProvider);
    expect(state.dirty, isFalse);
    expect(state.frameChanged, isFalse);
    expect(state.avatarChanged, isFalse);
    expect(draft.displayName.text, 'Saved name');
    expect(draft.aboutMe.text, 'Saved about');
    expect(profiles.saves, isEmpty);
  });

  test('Save sends the edits and leaves the draft clean', () async {
    final (:container, :profiles) = _setUp();
    final draft = container.read(profileDraftProvider.notifier);

    draft.displayName.text = '  New name ';
    draft.setFrame('b:140');
    await draft.save();

    expect(profiles.saves, hasLength(1));
    final sent = profiles.saves.single;
    expect(sent.displayName, 'New name');
    expect(sent.status, 'Saved status');
    expect(sent.aboutMe, 'Saved about');
    expect(sent.avatarFrame, 'b:140');
    expect(sent.twitchUsername, 'legacyhandle',
        reason: 'the self-declared handle rides through unchanged');
    expect(sent.avatarBytes, isNull, reason: 'the avatar was not touched');
    expect(sent.avatarAnim, isNull);

    final state = container.read(profileDraftProvider);
    expect(state.dirty, isFalse);
    expect(state.saving, isFalse);
    expect(state.frameChanged, isFalse);
    expect(draft.displayName.text, '  New name ',
        reason: 'the field keeps what was typed');
  });

  test('a cleared avatar saves the empty sentinel and drops its animation',
      () async {
    final (:container, :profiles) = _setUp();
    final draft = container.read(profileDraftProvider.notifier);

    draft.clearImage(avatar: true);
    await draft.save();

    final sent = profiles.saves.single;
    expect(sent.avatarBytes, isA<Uint8List>());
    expect((sent.avatarBytes! as Uint8List).isEmpty, isTrue);
    expect(sent.avatarAnim, '');
  });

  test('a failed save rethrows with the edits intact', () async {
    final (:container, :profiles) = _setUp();
    final draft = container.read(profileDraftProvider.notifier);
    profiles.fail = true;

    draft.status.text = 'Kept';
    await expectLater(draft.save(), throwsException);

    final state = container.read(profileDraftProvider);
    expect(state.dirty, isTrue);
    expect(state.saving, isFalse);
    expect(draft.status.text, 'Kept');
  });

  testWidgets('the page renders the draft and marks it dirty on an edit',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final profiles = _RecordingProfiles();
    final container = ProviderContainer(
      overrides: hollowTestOverrides(extra: [
        profileProvider.overrideWith(() => profiles),
        shopAvailableProvider.overrideWithValue(false),
      ]),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: SingleChildScrollView(child: ProfileSettingsPage()),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));

    for (final title in [
      'Avatar',
      'Banner',
      'Frame',
      'Display name',
      'Appear invisible',
      'Twitch',
    ]) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Saved name'), findsWidgets,
        reason: 'the field and the preview both show the saved name');
    expect(find.text('Save'), findsNothing,
        reason: 'the Settings place owns the one Save');

    await tester.enterText(
        find.byWidgetPredicate(
            (w) => w is EditableText && w.controller.text == 'Saved status'), 'Live status');
    await tester.pump();
    expect(container.read(profileDraftProvider).dirty, isTrue);
    expect(find.text('Live status'), findsNWidgets(2),
        reason: 'the preview follows the field as it is typed');
  });
}
