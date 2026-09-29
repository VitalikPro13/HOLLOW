import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/forwarder_info_provider.dart';

void main() {
  const day = 24 * 60 * 60 * 1000;
  const now = 100 * day;

  test('the first forwarder a relay names is pinned', () {
    final d = forwarderPinDecision(null, 'fwdA', true, now);
    expect(d.accept, isTrue);
    expect(d.pin?.peerId, 'fwdA');
    expect(d.pin?.lastOnlineMs, now);
  });

  test('the pinned forwarder keeps counting and refreshes its sighting', () {
    const pin = ForwarderPin(peerId: 'fwdA', lastOnlineMs: now - day);
    final online = forwarderPinDecision(pin, 'fwdA', true, now);
    expect(online.accept, isTrue);
    expect(online.pin?.lastOnlineMs, now);
    final offline = forwarderPinDecision(pin, 'fwdA', false, now);
    expect(offline.accept, isTrue);
    expect(offline.pin?.lastOnlineMs, now - day, reason: 'offline is no sighting');
  });

  test('another forwarder is refused while the pinned one was seen lately', () {
    const pin = ForwarderPin(peerId: 'fwdA', lastOnlineMs: now - 6 * day);
    final d = forwarderPinDecision(pin, 'member-device', true, now);
    expect(d.accept, isFalse);
    expect(d.pin?.peerId, 'fwdA');
  });

  test('a forwarder unseen for a week can be replaced', () {
    const pin = ForwarderPin(peerId: 'fwdA', lastOnlineMs: now - 7 * day);
    final d = forwarderPinDecision(pin, 'fwdB', true, now);
    expect(d.accept, isTrue);
    expect(d.pin?.peerId, 'fwdB');
  });

  test('no forwarder configured changes nothing', () {
    const pin = ForwarderPin(peerId: 'fwdA', lastOnlineMs: now);
    final d = forwarderPinDecision(pin, '', false, now);
    expect(d.accept, isTrue);
    expect(d.pin?.peerId, 'fwdA');
  });

  test('a pin round-trips through its stored form', () {
    const pin = ForwarderPin(peerId: '12D3KooWabc', lastOnlineMs: 1790000000000);
    expect(ForwarderPin.decode(pin.encode())?.peerId, '12D3KooWabc');
    expect(ForwarderPin.decode(pin.encode())?.lastOnlineMs, 1790000000000);
    expect(ForwarderPin.decode('garbage'), isNull);
    expect(ForwarderPin.decode(null), isNull);
  });
}
