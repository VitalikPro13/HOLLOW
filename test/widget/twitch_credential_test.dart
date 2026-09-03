/// The verified Twitch mark (2026-09-03).
///
/// One rule runs through every assertion here: the purple chip draws from a
/// blind-signed `t = 3` support credential and from NOTHING else. The profile
/// field `twitch_username` and the member-level `TwitchUsernameChanged` op are
/// self-declarations any modified client can write, they stay on the wire for
/// old builds, and a new build renders neither — not even as a "claims to be"
/// chip (Vitalik's call: it would look weirder than showing nothing).
///
/// The rest pins the connect row, which is where a person finds out whether
/// they are verified: busy while the shop is asked, the login when it lands,
/// the shop's own sentence when it does not.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/support_marks_provider.dart';
import 'package:hollow/src/core/providers/twitch_provider.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:hollow/src/ui/settings/profile_section.dart';

import '../helpers/test_app.dart';

const String _peer = 'peer_twitch_tester_0001';

/// The window a fresh credential is minted in, the same arithmetic Rust uses.
int _nowPeriod() =>
    DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 ~/ 86400 ~/ 90;

/// A `support_creds` field carrying one verified-account entry. Only the
/// fields a renderer reads are filled: the chain and the blind signature were
/// checked in Rust before this string ever reached the database, which is the
/// whole reason Dart does not re-check them.
String _accountField(String login, {int? period, String userId = '12345'}) =>
    '[{"t":3,"item":"${'a' * 64}","period":${period ?? _nowPeriod()},'
    '"parts":["$userId","$login"],"key":"","key_sig":"","issuer":"",'
    '"issuer_sig":"","sig":"","badge":false}]';

class _SeededProfiles extends ProfileNotifier {
  final String supportCreds;
  final String twitchUsername;
  _SeededProfiles({this.supportCreds = '', this.twitchUsername = ''});

  @override
  Map<String, storage_api.UserProfile> build() => {
        _peer: storage_api.UserProfile(
          peerId: _peer,
          displayName: 'Twitch Tester',
          status: '',
          aboutMe: '',
          updatedAt: 0,
          twitchUsername: twitchUsername,
          showcaseBoard: '',
          avatarFrame: '',
          avatarAnim: '',
          bannerAnim: '',
          supportCreds: supportCreds,
        ),
      };
}

/// Records what the row asked for, and answers what the test wants.
class _FakeTwitchFfi implements TwitchFfi {
  _FakeTwitchFfi({this.connected = false});

  final bool connected;
  final String login = 'somestreamer';
  twitch_api.TwitchVerifyOutcome outcome = const twitch_api.TwitchVerifyOutcome(
    verified: true,
    login: 'somestreamer',
    message: '',
  );

  int verifyCalls = 0;
  int disconnectCalls = 0;

  /// Held open so a test can look at the row WHILE the shop is being asked.
  Completer<twitch_api.TwitchVerifyOutcome>? gate;

  @override
  Future<bool> isConnected() async => connected;

  @override
  Future<String?> username() async => connected ? login : null;

  @override
  Future<String?> userId() async => connected ? '12345' : null;

  @override
  Future<twitch_api.TwitchVerifyOutcome> verifyOwner() async {
    verifyCalls++;
    final held = gate;
    if (held != null) return held.future;
    return outcome;
  }

  @override
  Future<void> disconnect() async => disconnectCalls++;
}

Future<void> _pump(WidgetTester tester, Widget child,
    {List<Override> extra = const []}) async {
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: extra),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('the login a profile publishes', () {
    test('comes from a verified entry and never from twitch_username', () {
      expect(verifiedTwitchLogin(_accountField('somestreamer')), 'somestreamer');
      // A profile carrying only the legacy field has no verified login at all,
      // whatever that field says.
      expect(verifiedTwitchLogin(''), isNull);
    });

    test('an entry outside its window stops showing at once', () {
      final now = _nowPeriod();
      // The current window and one of grace, matching `period_in_window`.
      expect(verifiedTwitchLogin(_accountField('x_streamer', period: now)),
          'x_streamer');
      expect(verifiedTwitchLogin(_accountField('x_streamer', period: now - 1)),
          'x_streamer');
      // Two windows old, or a window that has not happened, or none at all.
      expect(verifiedTwitchLogin(_accountField('x_streamer', period: now - 2)),
          isNull);
      expect(verifiedTwitchLogin(_accountField('x_streamer', period: now + 1)),
          isNull);
      expect(
          verifiedTwitchLogin(_accountField('x_streamer', period: 0)), isNull);
    });

    test('a malformed entry renders nothing rather than junk', () {
      // Not an array, not JSON, the wrong type, a login off the grid, and a
      // `parts` of the wrong arity.
      for (final field in [
        '{}',
        'not json',
        '[{"t":1,"item":"x","period":0,"parts":["a"],"badge":false}]',
        _accountField('Bad Name'),
        _accountField('ab'),
        '[{"t":3,"period":${_nowPeriod()},"parts":["12345"]}]',
      ]) {
        expect(verifiedTwitchLogin(field), isNull, reason: field);
      }
    });
  });

  group('the chip', () {
    testWidgets('draws from a verified entry on the profile card',
        (tester) async {
      await _pump(
        tester,
        ProfileCardBody(
          peerId: _peer,
          density: ProfileCardDensity.compact,
          dismissHost: () {},
        ),
        extra: [
          profileProvider.overrideWith(
            () => _SeededProfiles(supportCreds: _accountField('somestreamer')),
          ),
        ],
      );
      expect(find.text('somestreamer'), findsOneWidget);
    });

    testWidgets('draws nothing from twitch_username on the profile card',
        (tester) async {
      await _pump(
        tester,
        ProfileCardBody(
          peerId: _peer,
          density: ProfileCardDensity.compact,
          dismissHost: () {},
        ),
        extra: [
          profileProvider.overrideWith(
            () => _SeededProfiles(twitchUsername: 'notverified'),
          ),
        ],
      );
      expect(
        find.text('notverified'),
        findsNothing,
        reason: 'a self-declared handle is not a chip on any new client',
      );
    });

    testWidgets('follows the same rule on the mobile profile sheet',
        (tester) async {
      await _pump(
        tester,
        const MobileProfileSheet(peerId: _peer),
        extra: [
          profileProvider.overrideWith(
            () => _SeededProfiles(
              supportCreds: _accountField('somestreamer'),
              // The legacy field says something ELSE, and loses.
              twitchUsername: 'notverified',
            ),
          ),
        ],
      );
      expect(find.text('somestreamer'), findsOneWidget);
      expect(find.text('notverified'), findsNothing);
    });

    testWidgets('and shows nothing there without a credential', (tester) async {
      await _pump(
        tester,
        const MobileProfileSheet(peerId: _peer),
        extra: [
          profileProvider.overrideWith(
            () => _SeededProfiles(twitchUsername: 'notverified'),
          ),
        ],
      );
      expect(find.text('notverified'), findsNothing);
    });
  });

  group('the connect row', () {
    testWidgets('a connected but unverified account is offered the mark',
        (tester) async {
      final ffi = _FakeTwitchFfi(connected: true);
      await _pump(
        tester,
        TwitchConnectionRow(hollow: HollowTheme.dark()),
        extra: [twitchFfiProvider.overrideWithValue(ffi)],
      );
      await tester.pumpAndSettle();
      expect(find.text('Connected as somestreamer, not verified yet'),
          findsOneWidget);
      expect(find.widgetWithText(HollowButton, 'Verify'), findsOneWidget);
    });

    testWidgets('verifying shows busy, then the login', (tester) async {
      final ffi = _FakeTwitchFfi(connected: true);
      ffi.gate = Completer<twitch_api.TwitchVerifyOutcome>();
      await _pump(
        tester,
        TwitchConnectionRow(hollow: HollowTheme.dark()),
        extra: [twitchFfiProvider.overrideWithValue(ffi)],
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(HollowButton, 'Verify'));
      await tester.pump();
      expect(
        find.byType(CircularProgressIndicator),
        findsOneWidget,
        reason: 'a call to the shop is slow enough to need saying so',
      );
      expect(find.widgetWithText(HollowButton, 'Verify'), findsNothing);

      ffi.gate!.complete(const twitch_api.TwitchVerifyOutcome(
        verified: true,
        login: 'somestreamer',
        message: '',
      ));
      await tester.pump();
      await tester.pump();
      expect(ffi.verifyCalls, 1);
      expect(find.text('Verified as somestreamer'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.widgetWithText(HollowButton, 'Verify'),
        findsNothing,
        reason: 'there is nothing left to verify once the mark is worn',
      );
      // The success toast owns a 3s timer; let it retire with the test.
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets("a refusal shows the shop's sentence and wears nothing",
        (tester) async {
      final ffi = _FakeTwitchFfi(connected: true)
        ..outcome = const twitch_api.TwitchVerifyOutcome(
          verified: false,
          login: '',
          message: 'Twitch would not accept that sign in. Connect Twitch again.',
        );
      await _pump(
        tester,
        TwitchConnectionRow(hollow: HollowTheme.dark()),
        extra: [twitchFfiProvider.overrideWithValue(ffi)],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(HollowButton, 'Verify'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        find.text('Twitch would not accept that sign in. Connect Twitch again.'),
        findsOneWidget,
        reason: 'the refusal is the shop\'s own sentence, shown as a toast',
      );
      expect(find.text('Connected as somestreamer, not verified yet'),
          findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('disconnect asks Rust and clears the row', (tester) async {
      final ffi = _FakeTwitchFfi(connected: true);
      await _pump(
        tester,
        TwitchConnectionRow(hollow: HollowTheme.dark()),
        extra: [twitchFfiProvider.overrideWithValue(ffi)],
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(HollowButton, 'Disconnect'));
      await tester.pumpAndSettle();
      expect(ffi.disconnectCalls, 1);
      expect(find.widgetWithText(HollowButton, 'Connect'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });
  });
}
