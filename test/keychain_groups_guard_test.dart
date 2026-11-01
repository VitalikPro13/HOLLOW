// HOL-SEC-187 source guards: every Apple keychain call names its group (an unnamed
// query matches every group, so a delete or a make reaches keys elsewhere), the
// extensions never claim the keys group, the keychain move has one launch point
// before any unlock, and the macOS self-check runs before the Flutter engine exists.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Each `[String: Any] = [ ... ]` literal of a Swift file, as one string.
List<String> _dictionaries(String swift) {
  final out = <String>[];
  final open = RegExp(r':\s*\[String: Any\]\s*=\s*\[');
  for (final m in open.allMatches(swift)) {
    var depth = 1;
    var i = m.end;
    while (i < swift.length && depth > 0) {
      final c = swift[i];
      if (c == '[') depth++;
      if (c == ']') depth--;
      i++;
    }
    out.add(swift.substring(m.start, i));
  }
  return out;
}

void main() {
  test('every iOS keychain item query names a group', () {
    final swift = _read('ios/Runner/AppDelegate.swift');
    final items = _dictionaries(swift)
        .where((d) => d.contains('kSecClass as String') || d.contains('kSecAttrTokenID'))
        .toList();
    expect(items, isNotEmpty);
    for (final d in items) {
      expect(d, contains('kSecAttrAccessGroup'), reason: d);
    }
    for (final call in RegExp(r'HollowHwKey\.remove\([^)]*\)').allMatches(swift)) {
      expect(call[0], contains('in:'), reason: 'a delete must name its group');
    }
    expect(swift, isNot(contains('func remove(_ tag: Data) ')),
        reason: 'no remove that names no group');
  });

  test('every App Lock storage call on iOS names a group', () {
    final dart = _read('lib/src/core/services/app_lock_service.dart');
    final calls = RegExp(r'_storage\.(read|write|delete|readAll)\(([^;]*);')
        .allMatches(dart)
        .toList();
    expect(calls, isNotEmpty);
    final lines = dart.split('\n');
    for (final c in calls) {
      if (c[0]!.contains('iOptions:')) continue;
      final line = lines[dart.substring(0, c.start).split('\n').length - 1];
      expect(line, matches(RegExp(r'if \((g|group) == null\) return _storage\.')),
          reason: 'an ungrouped call outside the no-groups branch: ${c[0]}');
    }
  });

  test('only the app claims the keys group', () {
    expect(_read('ios/Runner/Runner.entitlements'), contains(r'$(HOLLOW_APP_GROUP).keys'));
    for (final dir in ['ios/NotificationService', 'ios/BroadcastExtension']) {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        if (!f.path.endsWith('.entitlements')) continue;
        expect(f.readAsStringSync(), isNot(contains('.keys')),
            reason: '${f.path} would widen who reads App Lock secrets');
      }
    }
    final plist = _read('ios/Runner/Info.plist');
    expect(plist, contains('<key>HollowKeysGroup</key>\n\t<string>\$(HOLLOW_APP_GROUP).keys</string>'));
    expect(plist,
        contains('<key>HollowAppIdGroup</key>\n\t<string>\$(AppIdentifierPrefix)\$(HOLLOW_BUNDLE_ID)</string>'));
  });

  test('the keychain move runs once at launch, before any unlock', () {
    final shell = _read('lib/src/ui/shell/hollow_shell.dart');
    final boot = shell.substring(shell.indexOf('Future<void> _bootstrap() async {'));
    final wipe = boot.indexOf('await _finishPendingWipe();');
    final relink = boot.indexOf('recovery_api.settleRelink()');
    final move = boot.indexOf('identity_api.settleKeychainMove()');
    final unlock = boot.indexOf('_unlockIdentity()');
    expect([wipe, relink, move, unlock], everyElement(isNot(-1)));
    expect(wipe < relink && relink < move && move < unlock, isTrue,
        reason: 'after the pending wipe and settle_relink, before the launch unlock');
    final callers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .map((f) => (file: f, path: f.path.replaceAll(r'\', '/')))
        .where((f) => f.path.endsWith('.dart') && !f.path.startsWith('lib/src/rust/'))
        .where((f) => f.file.readAsStringSync().contains('settleKeychainMove('))
        .map((f) => f.path)
        .toList();
    expect(callers, ['lib/src/ui/shell/hollow_shell.dart'],
        reason: 'nothing else may start the move (a wipe never does)');
    final rust = _read('rust/hollow_core/src/api/identity.rs');
    final rustCalls = RegExp(r'settle_keychain_move_at\((?!fx\.root\(\))')
        .allMatches(rust)
        .length;
    expect(rustCalls, 2, reason: 'its definition and the FFI, nothing else');
  });

  test('a group key is made only in the keys group, and a missing entitlement is no answer',
      () {
    final swift = _read('ios/Runner/AppDelegate.swift');
    final create = swift.substring(swift.indexOf('private let hwCreate'));
    expect(create.substring(0, create.indexOf('\n}\n')),
        contains('hasSuffix(".k")\n    ? [HollowHwKey.keysGroup]'),
        reason: 'a `.k` key in the app-ID group strands the move');
    final regroup = swift.substring(swift.indexOf('private let hwRegroup'));
    expect(regroup.substring(0, regroup.indexOf('\n}\n')),
        contains('case errSecInteractionNotAllowed, errSecMissingEntitlement: return -1'));
  });

  test('the macOS self-check runs, and can end the process, before the Flutter engine exists',
      () {
    final window = _read('macos/Runner/MainFlutterWindow.swift');
    final check = window.indexOf('BundleSeal.enforceAtStart');
    final engine = window.indexOf('FlutterViewController()');
    expect(check, allOf(isNot(-1), lessThan(engine)));
    expect(window, isNot(contains('BundleSeal.checkAtStart()')),
        reason: 'the bare check never ends the process');
    expect(_read('macos/Runner.xcodeproj/project.pbxproj'),
        contains('BundleSeal.swift in Sources'));
  });
}
