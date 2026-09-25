import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/twitch.dart' as twitch_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/chat/message_row.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/dialogs/create_channel_dialog.dart';
import 'package:hollow/src/ui/dialogs/create_server_dialog.dart';
import 'package:hollow/src/ui/dialogs/export_to_file.dart';
import 'package:hollow/src/ui/dialogs/invite_dialog.dart';
import 'package:hollow/src/ui/dialogs/license_key_dialog.dart';
import 'package:hollow/src/ui/dialogs/message_proof_dialog.dart';
import 'package:hollow/src/ui/dialogs/mnemonic_dialog.dart';
import 'package:hollow/src/ui/dialogs/no_turn_dialog.dart';
import 'package:hollow/src/ui/dialogs/recovery_pool_dialog.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/ui/dialogs/report_user_dialog.dart';
import 'package:hollow/src/ui/dialogs/twitch_device_code_dialog.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/settings/settings_catalog.dart';

import '../helpers/test_app.dart';

/// Dialogs pass, batch 1: every dialog that acts runs its FFI inside itself
/// (loading, the failure beside what caused it, the typed text kept), and the
/// message proof never calls a message it cannot check "Invalid".
class _Api implements RustLibApi {
  Object? proofError;
  network_api.MessageProofV2? proof;
  Object? createChannelError;
  Object? createServerError;
  Object? joinServerError;
  Object? saveSettingError;
  Object? reportError;
  Object? twitchStartError;
  final created = <String>[];
  final joined = <String>[];
  final reports = <String>[];

  @override
  Future<network_api.MessageProofV2> crateApiNetworkVerifyMessageProofV2({
    required String msgType,
    required String context,
    required String senderPeerId,
    required String messageId,
  }) async {
    if (proofError != null) throw proofError!;
    return proof!;
  }

  @override
  Future<String> crateApiCrdtCreateChannel({
    required String serverId,
    required String name,
    String? category,
    required String channelType,
  }) async {
    if (createChannelError != null) throw createChannelError!;
    created.add(name);
    return 'ch-$name';
  }

  @override
  Future<String> crateApiCrdtCreateServer({required String name}) async {
    if (createServerError != null) throw createServerError!;
    created.add(name);
    return 'pending';
  }

  @override
  Future<void> crateApiCrdtJoinServer({
    required String serverId,
    String? twitchProofJson,
    required bool nsfwConfirmed,
  }) async {
    if (joinServerError != null) throw joinServerError!;
    joined.add(serverId);
  }

  @override
  Future<void> crateApiStorageSaveSetting({
    required String key,
    required String value,
  }) async {
    if (saveSettingError != null) throw saveSettingError!;
  }

  @override
  Future<void> crateApiNetworkReportUser({
    required String target,
    required String category,
  }) async {
    if (reportError != null) throw reportError!;
    reports.add('$target:$category');
  }

  @override
  Future<twitch_api.TwitchDeviceFlowResult>
      crateApiTwitchTwitchStartDeviceFlow() async {
    if (twitchStartError != null) throw twitchStartError!;
    return twitch_api.TwitchDeviceFlowResult(
      userCode: 'ABCD-EFGH',
      verificationUri: 'https://www.twitch.tv/activate',
      deviceCode: 'dc',
      intervalSecs: BigInt.from(5),
    );
  }

  @override
  Future<String> crateApiTwitchTwitchPollForToken({
    required String deviceCode,
    required BigInt intervalSecs,
  }) =>
      Completer<String>().future;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() =>
      const {'srv1': ServerInfo(serverId: 'srv1', name: 'Night Owls')};
}

class _OtherRelay extends RelayDomainNotifier {
  @override
  String build() => 'myrelay.duckdns.org';
}

class _NoTurn extends RelayStatusNotifier {
  @override
  RelayStatus build() =>
      const RelayStatus(licenseRequired: false, turn: false);
}

class _AlwaysRelay extends AlwaysRelayCallsNotifier {
  @override
  bool build() => true;
}

late BuildContext _ctx;
late WidgetRef _ref;

Future<void> _pump(WidgetTester tester,
    {List<Override> overrides = const [], Size? size}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: overrides),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            _ctx = context;
            _ref = ref;
            return const SizedBox.expand();
          }),
        ),
      ),
    ),
  );
}

HollowButton _button(WidgetTester tester, String label) => tester.widget(
    find.ancestor(of: find.text(label), matching: find.byType(HollowButton)));

HollowTextField _field(WidgetTester tester) =>
    tester.widget(find.byType(HollowTextField).first);

MessageProofData _proofData() => const MessageProofData(
      senderPeerId: '12D3KooWSender',
      senderDisplayName: 'Mira',
      text: 'See you at eight',
      timestampMs: 1758800000000,
      signature: 'c2lnbmF0dXJl',
      publicKey: 'CAESIG1pcmFtaXJhbWlyYW1pcmFtaXJhbWlyYW1pcmFtaXI=',
      messageId: 'mid-1',
      context: 'peer',
      msgType: 'dm',
    );

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api
      ..proofError = null
      ..proof = null
      ..createChannelError = null
      ..createServerError = null
      ..joinServerError = null
      ..saveSettingError = null
      ..reportError = null
      ..twitchStartError = null
      ..created.clear()
      ..joined.clear()
      ..reports.clear();
  });

  group('message proof', () {
    testWidgets('a message missing from this device is not called invalid',
        (tester) async {
      api.proofError = 'Message not found';
      await _pump(tester);
      showMessageProofDialog(_ctx, _proofData());
      await tester.pumpAndSettle();
      expect(find.text('Invalid'), findsNothing);
      expect(find.text('Not on this device'), findsOneWidget);
      expect(find.textContaining("isn't saved on this device"), findsOneWidget);
    });

    testWidgets('a signature that does not match is invalid', (tester) async {
      api.proof = network_api.MessageProofV2(
        hasSignature: true,
        valid: false,
        sigVersion: 0,
        canonicalPayload: 'hollow-msg2:dm:peer',
        text: 'See you at eight',
        timestampMs: 1758800000000,
      );
      await _pump(tester);
      showMessageProofDialog(_ctx, _proofData());
      await tester.pumpAndSettle();
      expect(find.text('Invalid'), findsOneWidget);
      expect(find.text('Not on this device'), findsNothing);
    });

    testWidgets('the message preview sits on the dialog text edge',
        (tester) async {
      api.proofError = 'Message not found';
      await _pump(tester, size: const Size(1440, 900));
      showMessageProofDialog(_ctx, _proofData());
      await tester.pumpAndSettle();
      final avatar = find.descendant(
          of: find.byType(MessageRow), matching: find.byType(HollowAvatar));
      expect(tester.getTopLeft(avatar).dx,
          tester.getTopLeft(find.text('Details')).dx);
    });

    testWidgets('a check that fails for another reason says so, not invalid',
        (tester) async {
      api.proofError = 'Identity is locked';
      await _pump(tester);
      showMessageProofDialog(_ctx, _proofData());
      await tester.pumpAndSettle();
      expect(find.text('Invalid'), findsNothing);
      expect(find.text('Not checked'), findsOneWidget);
      expect(find.text('Hollow is locked. Unlock it and try again.'),
          findsOneWidget);
    });
  });

  group('create channel', () {
    testWidgets('a failed create keeps the dialog, the name and the reason',
        (tester) async {
      api.createChannelError = 'Node is not running';
      await _pump(tester);
      showCreateChannelDialog(_ctx, 'srv1');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'lounge');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Create channel'), findsOneWidget);
      expect(_field(tester).errorText,
          'Hollow is still starting up. Try again in a moment.');
      expect(find.text('lounge'), findsOneWidget);
    });

    testWidgets('success closes and hands back the new id', (tester) async {
      await _pump(tester);
      String? made;
      showCreateChannelDialog(_ctx, 'srv1', onCreated: (id) => made = id);
      await tester.pumpAndSettle();
      expect(_button(tester, 'Create').onPressed, isNull,
          reason: 'nothing to create while the name is empty');
      await tester.enterText(find.byType(TextField), 'lounge');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(made, 'ch-lounge');
      expect(find.text('Create channel'), findsNothing);
    });
  });

  group('add a server', () {
    testWidgets('one region, one action each: no filled button',
        (tester) async {
      await _pump(tester, size: const Size(1440, 900));
      showCreateServerDialog(_ctx);
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate((w) =>
              w is HollowButton && w.variant == HollowButtonVariant.filled),
          findsNothing);
      expect(find.text('Invite link or server ID'), findsOneWidget);
      expect(find.text('My Awesome Server'), findsOneWidget);
    });

    testWidgets('a failed create stays open with the reason on its field',
        (tester) async {
      api.createServerError = 'Node is not running';
      await _pump(tester, size: const Size(1440, 900));
      showCreateServerDialog(_ctx);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Night Owls');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Add a server'), findsOneWidget);
      expect(find.text('Hollow is still starting up. Try again in a moment.'),
          findsOneWidget);
      expect(find.text('Night Owls'), findsOneWidget);
    });

    testWidgets('create closes only after the call returns', (tester) async {
      await _pump(tester, size: const Size(1440, 900));
      showCreateServerDialog(_ctx);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Night Owls');
      await tester.pump();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(api.created, ['Night Owls']);
      expect(find.text('Add a server'), findsNothing);
      expect(find.text('Server created'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets('a failed join stays open with the reason on its field',
        (tester) async {
      api.joinServerError = 'Node is not running';
      await _pump(tester, size: const Size(1440, 900));
      showCreateServerDialog(_ctx);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextField).first, '0123456789abcdef0123456789abcdef');
      await tester.pump();
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(find.text('Add a server'), findsOneWidget);
      expect(find.text('Hollow is still starting up. Try again in a moment.'),
          findsOneWidget);
    });

    testWidgets('text that is no invite is refused on its field, never joined',
        (tester) async {
      await _pump(tester, size: const Size(1440, 900));
      showCreateServerDialog(_ctx);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'not-a-real-invite');
      await tester.pump();
      await tester.tap(find.text('Join'));
      await tester.pumpAndSettle();
      expect(find.text('Add a server'), findsOneWidget);
      expect(
          find.text(
              "That isn't an invite link or server ID. Check what you pasted."),
          findsOneWidget);
      expect(api.joined, isEmpty);
    });
  });

  testWidgets('a failed relay switch shows inside the dialog', (tester) async {
    api.saveSettingError = 'disk full';
    await _pump(tester, size: const Size(1440, 900));
    final link = classifyHollowLink(
        'hollow://join?server=abc123&relay=other.example.org')!;
    unawaited(ensureRelayForInvite(_ctx, _ref, link));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch and restart'));
    await tester.pumpAndSettle();
    expect(find.text('This server lives on another relay'), findsOneWidget);
    expect(find.text('Your disk is full. Free some space and try again.'),
        findsOneWidget);
  });

  group('report user', () {
    testWidgets('a failed report keeps the dialog and the pick',
        (tester) async {
      api.reportError = 'relay not connected';
      await _pump(tester);
      unawaited(showReportUserDialog(_ctx, masterId: 'm1', displayName: 'Sam'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spam'));
      await tester.pump();
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(find.text('Report user'), findsOneWidget);
      expect(find.textContaining("can't reach the relay"), findsOneWidget);
      expect(api.reports, isEmpty);
    });

    testWidgets('a sent report closes, then says so', (tester) async {
      await _pump(tester);
      unawaited(showReportUserDialog(_ctx, masterId: 'm1', displayName: 'Sam'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Harassment'));
      await tester.pump();
      await tester.tap(find.text('Report'));
      await tester.pumpAndSettle();
      expect(api.reports, ['m1:harassment']);
      expect(find.text('Report user'), findsNothing);
      expect(find.text('Report sent'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('the TURN refusal offers Security settings, not OK',
      (tester) async {
    await _pump(tester, overrides: [
      relayStatusProvider.overrideWith(() => _NoTurn()),
      alwaysRelayCallsProvider.overrideWith(() => _AlwaysRelay()),
    ]);
    var answer = true;
    unawaited(ensureTurnForCall(_ctx, _ref).then((v) => answer = v));
    await tester.pumpAndSettle();
    expect(find.text(kNoTurnDialogTitle), findsOneWidget);
    expect(find.text('OK'), findsNothing);
    await tester.tap(find.text('Open Security settings'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
    expect(_ref.read(settingsCategoryProvider), SettingsCategory.security);
    expect(_ref.read(settingsTabOpenProvider), isTrue);
  });

  testWidgets('on a phone the TURN refusal opens the Security page too',
      (tester) async {
    debugNoTurnPhoneOverride = true;
    addTearDown(() => debugNoTurnPhoneOverride = null);
    // Wide, so the test font fits the button; the phone path is the flag.
    await _pump(tester, size: const Size(1440, 900), overrides: [
      relayStatusProvider.overrideWith(() => _NoTurn()),
      alwaysRelayCallsProvider.overrideWith(() => _AlwaysRelay()),
    ]);
    unawaited(ensureTurnForCall(_ctx, _ref));
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsNothing);
    await tester.tap(find.text('Open Security settings'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(kNoTurnDialogTitle), findsNothing);
    final page = find.byType(MobileSettingsSubPage);
    expect(page, findsOneWidget);
    expect(tester.widget<MobileSettingsSubPage>(page).title,
        SettingsCategory.security.label);
    // The desktop place is left alone on a phone.
    expect(_ref.read(settingsTabOpenProvider), isFalse);
  });

  group('access key', () {
    testWidgets('a malformed key is said on the field, text kept',
        (tester) async {
      await _pump(tester, size: const Size(1440, 900),
          overrides: [relayDomainProvider.overrideWith(() => _OtherRelay())]);
      unawaited(showLicenseKeyDialog(_ctx));
      await tester.pumpAndSettle();
      expect(find.textContaining('beta'), findsNothing);
      expect(find.textContaining('license'), findsNothing);
      expect(find.textContaining('only lets people in with an access key',
              findRichText: true),
          findsOneWidget);
      await tester.enterText(find.byType(TextField), 'abcd');
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(_field(tester).errorText, contains('16 letters and numbers'));
      expect(find.text('ABCD'), findsOneWidget);
      expect(find.text('Use the default relay'), findsOneWidget);
    });

    testWidgets('on the default relay there is no switch back',
        (tester) async {
      await _pump(tester);
      unawaited(showLicenseKeyDialog(_ctx));
      await tester.pumpAndSettle();
      expect(find.text('Use the default relay'), findsNothing);
      expect(find.textContaining(kDefaultRelayDomain, findRichText: true),
          findsOneWidget);
    });
  });

  testWidgets('a Twitch failure is a sentence with a retry, never raw text',
      (tester) async {
    api.twitchStartError =
        'Twitch device flow request failed: error sending request for url';
    await _pump(tester);
    showTwitchDeviceCodeDialog(_ctx);
    await tester.pumpAndSettle();
    expect(find.textContaining('error sending request'), findsNothing);
    expect(find.text("Twitch didn't answer. Check your connection and try "
        'again.'), findsOneWidget);
    api.twitchStartError = null;
    await tester.tap(find.text('Try again'));
    // The poll never answers here, so its spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('ABCD-EFGH'), findsOneWidget);
    expect(find.text('Waiting for Twitch'), findsOneWidget);
  });

  testWidgets('a recovery link that is not one is said on the field',
      (tester) async {
    await _pump(tester);
    showJoinRecoveryPoolDialog(_ctx);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Join a recovery pool'), findsOneWidget);
    expect(_field(tester).errorText, contains("isn't a recovery pool link"));
    expect(find.text('hello'), findsOneWidget);
  });

  testWidgets('the invite names the server and drops the raw id',
      (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [serverListProvider.overrideWith(() => _Servers())],
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (context) {
          _ctx = context;
          return const SizedBox.expand();
        })),
      ),
    ));
    showInviteDialog(_ctx, 'https://hollow.chat/join#server=srv1', 'srv1');
    await tester.pumpAndSettle();
    expect(find.text('Anyone with this link can join Night Owls.'),
        findsOneWidget);
    expect(find.textContaining('Server ID'), findsNothing);
    expect(find.textContaining(':'), findsOneWidget,
        reason: 'only the link itself carries a colon');
  });

  testWidgets('the recovery phrase is a numbered grid', (tester) async {
    await _pump(tester, size: const Size(1440, 900));
    final words = List.generate(24, (i) => 'word${i + 1}').join(' ');
    showMnemonicDialog(_ctx, words);
    await tester.pumpAndSettle();
    expect(find.text('word1'), findsOneWidget);
    expect(find.text('word24'), findsOneWidget);
    expect(find.text('24'), findsOneWidget);
    expect(find.text("I've saved it"), findsOneWidget);
  });

  test('export file names keep letters and numbers only', () {
    expect(exportFileStem('Night Owls: the #1 club!'), 'night_owls_the_1_club');
    expect(exportFileStem('!!!'), 'hollow');
  });
}
