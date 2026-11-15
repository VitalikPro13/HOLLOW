// HOL-SEC-187: a password whose key the keychain caches, left by an older
// build in a login keychain item only that build may delete, moves off it only
// with the password. The start asks once; "Not now" changes nothing; a wrong
// password says so; a duress code ends the session like any other prompt.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/destroy_flow.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/app.dart';
import 'package:hollow/src/ui/dialogs/keychain_protection_dialogs.dart';

import '../helpers/test_app.dart';

const _password = 'correct horse battery';
const _code = '9 1 1 1';

/// Rust as the ask sees it, with every call recorded.
class _Api implements RustLibApi {
  final calls = <String>[];
  bool wants = true;

  @override
  Future<bool> crateApiIdentityKeychainRekeyWantsPassword() async {
    calls.add('wants');
    return wants;
  }

  @override
  Future<bool> crateApiIdentityFinishKeychainRekey(
      {required String password}) async {
    calls.add('finish:$password');
    if (password == _code) throw 'duress';
    if (password != _password) {
      throw 'Wrong password or corrupted identity file';
    }
    wants = false;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls.add('unexpected:${invocation.memberName}');
    return super.noSuchMethod(invocation);
  }
}

void main() {
  final api = _Api();
  setUpAll(() {
    RustLib.initMock(api: api);
    FlutterSecureStorage.setMockInitialValues({});
  });
  setUp(() {
    api.calls.clear();
    api.wants = true;
  });

  Future<BuildContext> host(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    late BuildContext context;
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        navigatorKey: hollowNavigatorKey,
        theme: HollowThemeData.dark(),
        home: Scaffold(body: Builder(builder: (c) {
          context = c;
          return const SizedBox.expand();
        })),
      ),
    ));
    return context;
  }

  testWidgets('nothing is asked off macOS or when Rust has nothing to finish',
      (tester) async {
    final context = await host(tester);
    expect(await askToFinishKeychainRekey(context, macOS: false), isFalse);
    expect(api.calls, isEmpty, reason: 'another platform asked Rust');
    api.wants = false;
    expect(await askToFinishKeychainRekey(context, macOS: true), isFalse);
    await tester.pumpAndSettle();
    expect(find.text(kFinishKeychainTitle), findsNothing);
    expect(api.calls, ['wants']);
  });

  testWidgets('Not now changes nothing and the next start asks again',
      (tester) async {
    final context = await host(tester);
    for (var start = 0; start < 2; start++) {
      final asked = askToFinishKeychainRekey(context, macOS: true);
      await tester.pumpAndSettle();
      expect(find.text(kFinishKeychainTitle), findsOneWidget);
      expect(find.text(kFinishKeychainMessage), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(await asked, isFalse);
    }
    expect(api.calls, ['wants', 'wants'], reason: 'Not now reached Rust');
  });

  testWidgets('a wrong password says so, the right one finishes',
      (tester) async {
    final context = await host(tester);
    final asked = askToFinishKeychainRekey(context, macOS: true);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not it');
    await tester.pump();
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(find.text("That password isn't right."), findsOneWidget);
    expect(find.text(kFinishKeychainTitle), findsOneWidget);

    await tester.enterText(find.byType(TextField), _password);
    await tester.pump();
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();
    expect(await asked, isTrue);
    expect(find.text(kFinishKeychainTitle), findsNothing);
    expect(api.calls.where((c) => !c.contains('LogFromDart')),
        ['wants', 'finish:not it', 'finish:$_password']);
  });

  testWidgets('a duress code typed here ends the session and shows nothing',
      (tester) async {
    var ended = 0;
    final never = Completer<Never>();
    onDuressAtPrompt = () {
      ended++;
      return never.future;
    };
    addTearDown(() => onDuressAtPrompt = endSessionAfterDuress);
    final context = await host(tester);
    unawaited(askToFinishKeychainRekey(context, macOS: true));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _code);
    await tester.pump();
    await tester.tap(find.text('Finish'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(ended, 1, reason: 'the session went on after a duress code');
    expect(find.text("That password isn't right."), findsNothing);
    expect(find.textContaining('duress'), findsNothing);
  });
}
