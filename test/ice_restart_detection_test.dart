import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/voice_service.dart';

/// The bug this file exists for (field-caught 2026-08-27, Windows VM):
/// a call recovered from a 25 second outage, the audio came back, and it was
/// NOISE. An ICE restart rebuilds the transport but keeps the SSRC and the
/// msid, so no new transceiver appears, `onTrack` never fires, and the SFrame
/// cryptors stay bound to a transport that no longer exists. They were not
/// failing, they were detached, so nothing reported it: the whole recovery
/// produced zero SFrame lines in the log.
///
/// A change of ICE credentials between two remote descriptions is the only
/// signal that this happened, and it is what now triggers the re-assert. It
/// gates a security-relevant re-key, so it gets pinned here.
String _sdp(String ufrag, {String? secondSection}) => 'v=0\r\n'
    'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
    'a=ice-ufrag:$ufrag\r\n'
    'a=ice-pwd:somepasswordvalue1234567\r\n'
    'a=mid:0\r\n'
    '${secondSection == null ? '' : 'm=video 9 UDP/TLS/RTP/SAVPF 96\r\n'
        'a=ice-ufrag:$secondSection\r\n'
        'a=mid:1\r\n'}';

void main() {
  test('reads the ufrag out of a real-shaped SDP', () {
    expect(iceUfragOf(_sdp('4ZcD')), '4ZcD');
  });

  test('CRLF line endings do not hide it', () {
    expect(iceUfragOf(_sdp('abc1')), isNotNull,
        reason: 'SDP is CRLF terminated on the wire; a ^ anchor that only '
            'matched LF would never fire and SFrame would never be re-asserted');
  });

  test('takes the first section when BUNDLE repeats it', () {
    expect(iceUfragOf(_sdp('same', secondSection: 'same')), 'same');
  });

  test('an unchanged ufrag is NOT a restart', () {
    expect(iceUfragOf(_sdp('keep')), iceUfragOf(_sdp('keep')),
        reason: 'a camera toggle renegotiates without restarting ICE, and must '
            'not spend the re-assert (it drops the sender cryptor for a moment)');
  });

  test('a changed ufrag IS a restart', () {
    expect(iceUfragOf(_sdp('before')) == iceUfragOf(_sdp('after')), isFalse);
  });

  test('no ufrag at all reads as no opinion, never as a change', () {
    expect(iceUfragOf('v=0\r\ns=-\r\n'), isNull);
  });

  test('the CALLEE has a baseline to compare against', () {
    // Field-caught 2026-08-27. Detection needs a REMEMBERED ufrag: the first
    // one seen is a baseline, not a restart. The callee answers the initial
    // offer through `handleOffer`, which did not record one, so its first
    // renegotiation compared against null and read as "nothing changed".
    //
    // The consequence was not subtle. The callee never re-asserted SFrame, so
    // its sender cryptor stayed bound to a dead transport while the caller
    // re-created its receiver: the callee's microphone went silent to the
    // other side, and the caller's audio failed to decrypt. Both directions,
    // from one missing baseline.
    //
    // Whether handleOffer records it is a source-level fact, so that is what
    // is checked here; the parsing itself is covered above.
    final src = File('lib/src/core/services/voice_service.dart')
        .readAsStringSync();
    final from = src.indexOf('Future<String> handleOffer');
    expect(from, greaterThan(0), reason: 'handleOffer moved; re-point this.');
    final applied = src.indexOf("RTCSessionDescription(sdp, 'offer')", from);
    expect(applied, greaterThan(from));
    expect(src.substring(from, applied).contains('_noteRemoteIceCredentials(sdp)'),
        isTrue,
        reason: 'handleOffer must record the baseline ICE credentials BEFORE '
            'applying the initial offer, or the callee can never detect its '
            'first ICE restart.');
  });
}
