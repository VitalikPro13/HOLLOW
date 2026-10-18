import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// Stands in for Rust's `open_push_wake`: what the FCM data block opens to.
class _Api implements RustLibApi {
  Map<String, String>? opens;
  Map<String, String>? asked;
  bool? askedTap;
  bool throws = false;

  @override
  Future<Map<String, String>?> crateApiPushOpenPushWake(
      {required Map<String, String> fields, required bool tap}) async {
    asked = fields;
    askedTap = tap;
    if (throws) throw StateError('rust');
    return opens;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api
      ..opens = null
      ..asked = null
      ..askedTap = null
      ..throws = false;
  });

  test('a wake Rust will not open is dropped', () async {
    final data = await openFirebaseWake(
        {'type': 'wake', 'sender': 'dev1'}, rustReady: true);
    expect(data, isNull);
    expect(api.asked, {'type': 'wake', 'sender': 'dev1'});
    expect(api.askedTap, isFalse, reason: 'a delivery is opened once');
  });

  test('a tap only asks where to route', () async {
    api.opens = {'type': 'wake', 'sender': 'dev1'};
    await openFirebaseWake({'sealed': 'blob'}, rustReady: true, tap: true);
    expect(api.askedTap, isTrue);
  });

  test('a failing open drops the wake too', () async {
    api.throws = true;
    expect(await openFirebaseWake({'sealed': 'x'}, rustReady: true), isNull);
  });

  test('the opened wake is what the handler reads, never the raw fields',
      () async {
    api.opens = {'type': 'channel_wake', 'server': 's1', 'channel': 'c1'};
    final data = await openFirebaseWake(
        {'sealed': 'blob', 'sender': 'spoofed', 'n': 3}, rustReady: true);
    expect(data, {'type': 'channel_wake', 'server': 's1', 'channel': 'c1'});
    expect(api.asked, {'sealed': 'blob', 'sender': 'spoofed'},
        reason: 'only string fields reach Rust');
  });

  test('with Rust down the wake names nobody', () async {
    final data = await openFirebaseWake(
        {'type': 'wake', 'sender': 'dev1'}, rustReady: false);
    expect(data, {'type': 'wake'});
    expect(api.asked, isNull);
  });

  test('iOS banners are cleared by the conversation threads the phone keeps',
      () {
    expect(iosDmThreads('dev1', 'master1'), {'master1', 'dev1'});
    expect(iosDmThreads('m', 'm'), {'m'});
    expect(iosChannelThread('s1', 'c1'), 's1:c1');
  });

  test('clearing a thread asks iOS once per thread', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('hollow/app_group'),
            (call) async {
      calls.add(call);
      return null;
    });
    await removeIosThreadBanners(['master1', 'dev1', 'master1']);
    expect(calls.single.method, 'removeDeliveredInThreads');
    expect(calls.single.arguments, ['master1', 'dev1']);
  });

  test('every Firebase entry point opens the wake first', () {
    final source = File('lib/src/core/services/push_notification_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(source, isNot(contains('message.data[')),
        reason: 'raw FCM fields are never read');
    expect(source, isNot(contains('handlePushWake(message.data')));
    for (final entry in [
      'Future<void> _firebaseBackgroundHandler(',
      'static Future<void> _deliverFromRemote(',
    ]) {
      final start = source.indexOf(entry);
      expect(start, isNonNegative, reason: entry);
      final body = source.substring(start, start + 400);
      expect(body, contains('openFirebaseWake('), reason: entry);
    }
    final tap = source.indexOf('static Future<void> _deliverFromRemote(');
    expect(source.substring(tap, tap + 400), contains('tap: true'),
        reason: 'a tap must not spend the blob the handler acts on');
    expect(source, isNot(contains("data['cid']")),
        reason: 'sealed wakes carry no banner id');
  });
}
