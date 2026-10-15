import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The voice channel service's half of the alone-in-a-room meter (#97, plan
/// section 10) lives inside WebRTC code no unit test can drive; these pin the
/// ordering the fleet proved, so a refactor cannot quietly undo it.
String _body(String src, String signature) {
  final start = src.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing $signature');
  final next = src.indexOf(RegExp(r'\n  (Future<|void |bool |static |//)'),
      start + signature.length);
  return src.substring(start, next < 0 ? src.length : next);
}

void main() {
  final src = File('lib/src/core/services/voice_channel_service.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('leaving stops the loopback before the microphone track is stopped', () {
    final body = _body(src, 'Future<void> closeAll() async {');
    final shutdown = body.indexOf('_aloneMeter.shutdown()');
    final micStop = body.indexOf('_localAudioStream!.getTracks()');
    expect(shutdown, isNonNegative);
    expect(micStop, greaterThan(shutdown));
  });

  test('a microphone switch moves the loopback before the old track dies', () {
    final body = _body(src, 'Future<void> _recaptureMic(String? deviceId) async {');
    final moved = body.indexOf('_reconcileAloneMeter()');
    final dispose = body.indexOf('_disposeReplacedMicStream(oldStream)');
    expect(moved, isNonNegative);
    expect(dispose, greaterThan(moved));
  });

  test('joining, every leg state change and every closed leg re-judge "alone"',
      () {
    expect(_body(src, 'Future<void> startAudio(String serverId, String channelId) async {'),
        contains('_reconcileAloneMeter()'));
    expect(_body(src, 'void _onPeerConnectionState('),
        contains('_reconcileAloneMeter()'));
    expect(_body(src, 'Future<void> closePeer(String peerId) async {'),
        contains('_reconcileAloneMeter()'));
  });

  test('a leg waits for our microphone before it takes its sender', () {
    // The joiner answered the offer before its getUserMedia finished, so the
    // leg had no sender: our voice never reached that peer and our capture
    // never ran. The wait goes after the leg exists (early candidates queue
    // on it) and before the tracks are added.
    for (final sig in [
      'Future<void> connectToPeer(String peerId) async {',
      'Future<void> _handleSdpOffer(',
    ]) {
      final body = _body(src, sig);
      final created = body.indexOf('await _createPeerConnection(peerId)');
      final waited = body.indexOf('await _awaitLocalAudio(peerId, pc)');
      final tracks = body.indexOf('_addLocalAudioTracks(pc)');
      expect(created, isNonNegative, reason: sig);
      expect(waited, greaterThan(created), reason: sig);
      expect(tracks, greaterThan(waited), reason: sig);
    }
    final start = _body(src, 'Future<void> startAudio(String serverId, String channelId) async {');
    expect(start.indexOf('Completer<void>()'),
        lessThan(start.indexOf('navigator.mediaDevices.getUserMedia')));
    // The overlay's listening lets go of the mic while legs already wait on
    // the pending completer, and before our own capture opens.
    final yielded = start.indexOf('overlayMic.yieldToCall(');
    expect(yielded, greaterThan(start.indexOf('Completer<void>()')));
    expect(yielded,
        lessThan(start.indexOf('navigator.mediaDevices.getUserMedia')));
    expect(start.indexOf('micSettled.complete()'),
        greaterThan(start.indexOf('navigator.mediaDevices.getUserMedia')));
  });

  test('the loopback never lands in the mesh maps', () {
    // A loopback leg in _peerConnections would count as a peer, be polled
    // for remote speech, and feed the Windows voice redirect our own voice.
    expect(src, isNot(contains(RegExp(r'_peerConnections\[[^\]]*\]\s*=\s*loop'))));
    expect(_body(src, 'Future<void> _reconcileAloneMeter() {'),
        contains('_peerConnections.values.any(_legCarriesCapture)'));
  });
}
