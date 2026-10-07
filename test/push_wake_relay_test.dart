import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/core/services/relay_triggers.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/frb_generated.dart';

/// Records the relay client calls a push wake makes, in order.
class _Api implements RustLibApi {
  final calls = <String>[];
  bool nudgeFails = false;

  @override
  Future<void> crateApiNetworkRelayNudge({required String reason}) async {
    calls.add('nudge:$reason');
    if (nudgeFails) throw StateError('no node');
  }

  @override
  Future<bool> crateApiNetworkNudgeLiveDmFetch(
      {required String senderPeerId}) async {
    calls.add('rejoin dm');
    return true;
  }

  @override
  Future<bool> crateApiNetworkNudgeLiveRoomJoin(
      {required String roomCode}) async {
    calls.add('rejoin room');
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The body of the top-level async function [name] in [source].
String _body(String source, String name) {
  final start =
      source.indexOf(RegExp('^Future<[^\\n]*\\b$name\\(', multiLine: true));
  expect(start, isNonNegative, reason: name);
  final next = source.indexOf(RegExp(r'\n(Future|void|String|bool|@pragma|///)'),
      start + name.length);
  return source.substring(start, next < 0 ? source.length : next);
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.calls.clear();
    api.nudgeFails = false;
  });

  test('a push brings the held session back before the live node rejoins',
      () async {
    // A phone suspended in the background keeps its socket closed: the rejoin
    // alone would wait in the client's queue until the app came back.
    final joined = await rejoinThroughLiveNode(
        () => network_api.nudgeLiveDmFetch(senderPeerId: 'peer'));
    expect(api.calls, ['nudge:$kPushNudge', 'rejoin dm']);
    expect(joined, isTrue);
  });

  test('the rejoin still runs when the nudge fails', () async {
    api.nudgeFails = true;
    final joined = await rejoinThroughLiveNode(
        () => network_api.nudgeLiveRoomJoin(roomCode: 'room'));
    expect(api.calls, ['nudge:$kPushNudge', 'rejoin room']);
    expect(joined, isFalse);
  });

  test('both live-node wake paths go through it', () {
    final source = File('lib/src/core/services/push_notification_service.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    for (final name in ['_tryLiveDmNudge', '_tryLiveChannelNudge']) {
      final body = _body(source, name);
      expect(body, contains('rejoinThroughLiveNode('), reason: name);
    }
  });

  test('a push nudge is not a trigger event', () {
    // Native code never forwards it: only a push wake sends it.
    expect(kPushNudge, 'push');
    expect(kPushNudge, isNot(anyOf('network', 'wake', 'foreground', 'focus')));
  });
}
