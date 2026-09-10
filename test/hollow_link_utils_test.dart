import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';

void main() {
  group('classifyHollowLink', () {
    test('hollow:// server invite', () {
      final link = classifyHollowLink(
          'hollow://join?server=8f3d5c37a26835ddf04b07f2c91da556');
      expect(link!.type, HollowLinkType.serverInvite);
      expect(link.id, '8f3d5c37a26835ddf04b07f2c91da556');
      expect(link.fullUrl,
          'hollow://join?server=8f3d5c37a26835ddf04b07f2c91da556');
    });

    test('web-form fragment invite normalizes to hollow://', () {
      final link = classifyHollowLink(
          'https://hollow.anonlisten.com/join#server=8f3d5c37a26835ddf04b07f2c91da556');
      expect(link!.type, HollowLinkType.serverInvite);
      expect(link.id, '8f3d5c37a26835ddf04b07f2c91da556');
      expect(link.fullUrl,
          'hollow://join?server=8f3d5c37a26835ddf04b07f2c91da556');
    });

    test('web-form query invite tolerated', () {
      final link =
          classifyHollowLink('https://hollow.anonlisten.com/join?server=abc123');
      expect(link!.type, HollowLinkType.serverInvite);
      expect(link.id, 'abc123');
    });

    test('web-form fragment wins over query', () {
      final link = classifyHollowLink(
          'https://hollow.anonlisten.com/join?server=aaa#server=bbb');
      expect(link!.id, 'bbb');
    });

    test('web-form invalid id rejected', () {
      expect(
          classifyHollowLink(
              'https://hollow.anonlisten.com/join#server=../etc/passwd'),
          isNull);
      expect(classifyHollowLink('https://hollow.anonlisten.com/join'), isNull);
    });

    test('other hosts and paths are not invites', () {
      expect(classifyHollowLink('https://evil.com/join#server=abc'), isNull);
      expect(
          classifyHollowLink('https://hollow.anonlisten.com/other#server=abc'),
          isNull);
    });

    test('room invite both forms', () {
      expect(classifyHollowLink('hollow://join?room=code42')!.type,
          HollowLinkType.roomInvite);
      final web =
          classifyHollowLink('https://hollow.anonlisten.com/join#room=code42');
      expect(web!.type, HollowLinkType.roomInvite);
      expect(web.fullUrl, 'hollow://join?room=code42');
    });

    test('share link', () {
      final link = classifyHollowLink('hollow://share/roothash:keyhex');
      expect(link!.type, HollowLinkType.share);
      expect(link.id, 'roothash:keyhex');
    });

    test('recovery link requires server and token', () {
      final link =
          classifyHollowLink('hollow://recovery?server=abc&token=tok');
      expect(link!.type, HollowLinkType.recovery);
      expect(link.id, 'abc');
      expect(classifyHollowLink('hollow://recovery?server=abc'), isNull);
    });

    test('conference link both forms', () {
      final native = classifyHollowLink('hollow://conference/abcdef0123456789');
      expect(native!.type, HollowLinkType.conference);
      expect(native.id, 'abcdef0123456789');
      final web = classifyHollowLink(
          'https://hollow.anonlisten.com/join#conf=abcdef0123456789');
      expect(web!.type, HollowLinkType.conference);
      expect(web.fullUrl, 'hollow://conference/abcdef0123456789');
      // Round-trip: the generated invite classifies back to the same id.
      final generated = webConferenceInviteLink('abcdef0123456789',
          relay: 'relay.anonlisten.com');
      expect(classifyHollowLink(generated)!.id, 'abcdef0123456789');
    });

    test('conference id validation', () {
      expect(classifyHollowLink('hollow://conference/'), isNull);
      expect(
          classifyHollowLink(
              'https://hollow.anonlisten.com/join#conf=../etc/passwd'),
          isNull);
    });

    test('garbage rejected', () {
      expect(classifyHollowLink('hollow://unknown?x=1'), isNull);
      expect(classifyHollowLink('not a url'), isNull);
    });
  });

  group('extractHollowLinks', () {
    test('dedups same invite across both forms', () {
      final links = extractHollowLinks(
          'join here hollow://join?server=abc123 or '
          'https://hollow.anonlisten.com/join#server=abc123');
      expect(links, hasLength(1));
      expect(links.single.type, HollowLinkType.serverInvite);
    });

    test('extracts mixed link types from text', () {
      final links = extractHollowLinks(
          'a hollow://share/payload b hollow://recovery?server=s&token=t c '
          'https://hollow.anonlisten.com/join#server=xyz');
      expect(links.map((l) => l.type), [
        HollowLinkType.share,
        HollowLinkType.recovery,
        HollowLinkType.serverInvite,
      ]);
    });

    test('mightContainHollowLinks gate matches both forms', () {
      expect(mightContainHollowLinks('see hollow://join?server=a'), isTrue);
      expect(
          mightContainHollowLinks(
              'see https://hollow.anonlisten.com/join#server=a'),
          isTrue);
      expect(mightContainHollowLinks('plain text'), isFalse);
    });
  });

  test('webServerInviteLink builds fragment form', () {
    expect(webServerInviteLink('abc', relay: 'relay.anonlisten.com'),
        'https://hollow.anonlisten.com/join#server=abc&relay=relay.anonlisten.com');
  });

  group('inviteIdFromInput', () {
    test('unwraps hollow:// server invite', () {
      expect(
          inviteIdFromInput(
              'hollow://join?server=abc123', HollowLinkType.serverInvite),
          'abc123');
    });

    test('unwraps web fragment-form server invite', () {
      expect(
          inviteIdFromInput('https://hollow.anonlisten.com/join#server=abc123',
              HollowLinkType.serverInvite),
          'abc123');
    });

    test('unwraps web query-form server invite', () {
      expect(
          inviteIdFromInput('https://hollow.anonlisten.com/join?server=abc123',
              HollowLinkType.serverInvite),
          'abc123');
    });

    test('unwraps room invites for the room type', () {
      expect(
          inviteIdFromInput(
              'hollow://join?room=r0om1234', HollowLinkType.roomInvite),
          'r0om1234');
      expect(
          inviteIdFromInput('https://hollow.anonlisten.com/join#room=r0om1234',
              HollowLinkType.roomInvite),
          'r0om1234');
    });

    test('raw id passes through trimmed', () {
      expect(inviteIdFromInput('  abc123  ', HollowLinkType.serverInvite),
          'abc123');
    });

    test('mismatched link type is not unwrapped', () {
      const conf = 'https://hollow.anonlisten.com/join#conf=abc123';
      expect(inviteIdFromInput(conf, HollowLinkType.serverInvite), conf);
    });

    test('a redeem link is not unwrapped into a server id', () {
      const redeem = 'hollow://redeem/ABCDE-FGHIJ-12345';
      expect(inviteIdFromInput(redeem, HollowLinkType.serverInvite), redeem);
    });
  });

  /// Hollow Shop support codes arrive as `hollow://redeem/<code>` from the
  /// order page and the receipt email. The shop builds them with
  /// `encodeURIComponent`, so the code can be percent-encoded on the wire.
  group('redeem codes', () {
    test('plain code', () {
      final link = classifyHollowLink('hollow://redeem/ABCDE-FGHIJ-12345');
      expect(link!.type, HollowLinkType.redeem);
      expect(link.id, 'ABCDE-FGHIJ-12345');
      expect(link.fullUrl, 'hollow://redeem/ABCDE-FGHIJ-12345');
    });

    test('percent-encoded code is decoded', () {
      final link = classifyHollowLink('hollow://redeem/ABCDE%2DFGHIJ');
      expect(link!.type, HollowLinkType.redeem);
      expect(link.id, 'ABCDE-FGHIJ');
      expect(link.fullUrl, 'hollow://redeem/ABCDE-FGHIJ');
    });

    test('rejects an empty, too-short or malformed code', () {
      expect(classifyHollowLink('hollow://redeem/'), isNull);
      expect(classifyHollowLink('hollow://redeem/ab'), isNull);
      expect(classifyHollowLink('hollow://redeem/a%20b'), isNull);
    });

    test('extracted from a chat message', () {
      final links =
          extractHollowLinks('code: hollow://redeem/ABCDE-FGHIJ-12345 ok');
      expect(links.length, 1);
      expect(links.first.type, HollowLinkType.redeem);
      expect(links.first.id, 'ABCDE-FGHIJ-12345');
    });
  });

  group('relay hint', () {
    test('hollow:// server invite carries the relay', () {
      final link = classifyHollowLink(
          'hollow://join?server=abc123&relay=myrelay.duckdns.org');
      expect(link!.type, HollowLinkType.serverInvite);
      expect(link.id, 'abc123');
      expect(link.relay, 'myrelay.duckdns.org');
      expect(link.fullUrl,
          'hollow://join?server=abc123&relay=myrelay.duckdns.org');
    });

    test('web fragment server invite carries the relay', () {
      final link = classifyHollowLink(
          'https://hollow.anonlisten.com/join#server=abc123&relay=myrelay.duckdns.org');
      expect(link!.relay, 'myrelay.duckdns.org');
      expect(link.fullUrl,
          'hollow://join?server=abc123&relay=myrelay.duckdns.org');
    });

    test('room invite carries the relay in both forms', () {
      final native =
          classifyHollowLink('hollow://join?room=r0om1234&relay=box.example.com');
      expect(native!.type, HollowLinkType.roomInvite);
      expect(native.relay, 'box.example.com');
      expect(native.fullUrl,
          'hollow://join?room=r0om1234&relay=box.example.com');
      final web = classifyHollowLink(
          'https://hollow.anonlisten.com/join#room=r0om1234&relay=box.example.com');
      expect(web!.fullUrl, native.fullUrl);
    });

    test('conference carries the relay in both forms', () {
      final native = classifyHollowLink(
          'hollow://conference/abcdef0123456789?relay=box.example.com');
      expect(native!.type, HollowLinkType.conference);
      expect(native.id, 'abcdef0123456789');
      expect(native.relay, 'box.example.com');
      expect(native.fullUrl,
          'hollow://conference/abcdef0123456789?relay=box.example.com');
      final web = classifyHollowLink(
          'https://hollow.anonlisten.com/join#conf=abcdef0123456789&relay=box.example.com');
      expect(web!.fullUrl, native.fullUrl);
    });

    test('absent relay leaves the link and its canonical form unchanged', () {
      final link = classifyHollowLink('hollow://join?server=abc123');
      expect(link!.relay, isNull);
      expect(link.fullUrl, 'hollow://join?server=abc123');
      expect(classifyHollowLink('hollow://conference/abcdef0123456789')!.relay,
          isNull);
    });

    test('an invalid relay is dropped and the link still classifies', () {
      final link = classifyHollowLink(
          'hollow://join?server=abc123&relay=not%20a%20host/path');
      expect(link!.type, HollowLinkType.serverInvite);
      expect(link.id, 'abc123');
      expect(link.relay, isNull);
      expect(link.fullUrl, 'hollow://join?server=abc123');
    });

    test('bracketed IPv6 relay round trips', () {
      final built = webServerInviteLink('abc123', relay: '[2001:db8::1]:8443');
      final link = classifyHollowLink(built);
      expect(link!.relay, '[2001:db8::1]:8443');
      expect(classifyHollowLink(link.fullUrl)!.relay, '[2001:db8::1]:8443');
    });

    test('builders stamp the relay', () {
      expect(webServerInviteLink('abc', relay: 'r.example.com'),
          'https://hollow.anonlisten.com/join#server=abc&relay=r.example.com');
      expect(webConferenceInviteLink('abc', relay: 'r.example.com'),
          'https://hollow.anonlisten.com/join#conf=abc&relay=r.example.com');
      expect(roomInviteLink('code42', relay: 'r.example.com'),
          'hollow://join?room=code42&relay=r.example.com');
    });

    test('extractHollowLinks dedups one invite across both relay forms', () {
      final links = extractHollowLinks(
          'a hollow://join?server=abc123&relay=r.example.com b '
          'https://hollow.anonlisten.com/join#server=abc123&relay=r.example.com');
      expect(links, hasLength(1));
      expect(links.single.relay, 'r.example.com');
    });

    test('the same invite on two relays stays two cards', () {
      final links = extractHollowLinks(
          'a hollow://join?server=abc123&relay=one.example.com b '
          'hollow://join?server=abc123&relay=two.example.com');
      expect(links, hasLength(2));
    });
  });

  group('inviteFromInput', () {
    test('returns the id and the relay', () {
      final parsed = inviteFromInput(
          '  hollow://join?server=abc123&relay=r.example.com  ',
          HollowLinkType.serverInvite);
      expect(parsed.id, 'abc123');
      expect(parsed.relay, 'r.example.com');
    });

    test('a raw id has no relay', () {
      final parsed = inviteFromInput('  abc123  ', HollowLinkType.serverInvite);
      expect(parsed.id, 'abc123');
      expect(parsed.relay, isNull);
    });

    test('a mismatched link type is not unwrapped', () {
      const conf = 'https://hollow.anonlisten.com/join#conf=abc123';
      final parsed = inviteFromInput(conf, HollowLinkType.serverInvite);
      expect(parsed.id, conf);
      expect(parsed.relay, isNull);
    });
  });

  group('normalizeRelayHost', () {
    test('plain hostname', () {
      expect(normalizeRelayHost('relay.anonlisten.com'), 'relay.anonlisten.com');
      expect(
          normalizeRelayHost('  MyRelay.DuckDNS.org '), 'myrelay.duckdns.org');
      expect(normalizeRelayHost('localhost'), 'localhost');
      expect(normalizeRelayHost('my-relay.example.co.uk'),
          'my-relay.example.co.uk');
    });

    test('strips a scheme', () {
      expect(normalizeRelayHost('wss://relay.example.com'), 'relay.example.com');
      expect(normalizeRelayHost('ws://relay.example.com'), 'relay.example.com');
      expect(
          normalizeRelayHost('https://relay.example.com'), 'relay.example.com');
      expect(
          normalizeRelayHost('http://relay.example.com'), 'relay.example.com');
    });

    test('strips a trailing slash or /ws', () {
      expect(normalizeRelayHost('relay.example.com/'), 'relay.example.com');
      expect(
          normalizeRelayHost('wss://relay.example.com/ws'), 'relay.example.com');
      expect(normalizeRelayHost('relay.example.com/ws/'), 'relay.example.com');
    });

    test('port', () {
      expect(normalizeRelayHost('relay.example.com:8443'),
          'relay.example.com:8443');
      expect(normalizeRelayHost('wss://relay.example.com:1/ws'),
          'relay.example.com:1');
      expect(normalizeRelayHost('relay.example.com:65535'),
          'relay.example.com:65535');
      expect(normalizeRelayHost('relay.example.com:0'), isNull);
      expect(normalizeRelayHost('relay.example.com:65536'), isNull);
      expect(normalizeRelayHost('relay.example.com:abc'), isNull);
      expect(normalizeRelayHost('relay.example.com:'), isNull);
    });

    test('IPv4', () {
      expect(normalizeRelayHost('192.168.1.10'), '192.168.1.10');
      expect(normalizeRelayHost('192.168.1.10:8443'), '192.168.1.10:8443');
    });

    test('bracketed IPv6 only', () {
      expect(normalizeRelayHost('[2001:db8::1]'), '[2001:db8::1]');
      expect(normalizeRelayHost('[2001:DB8::1]:8443'), '[2001:db8::1]:8443');
      expect(normalizeRelayHost('2001:db8::1'), isNull);
      expect(normalizeRelayHost('::1'), isNull);
      expect(normalizeRelayHost('[2001:db8::1'), isNull);
    });

    test('rejects paths, spaces and junk', () {
      expect(normalizeRelayHost('relay.example.com/path'), isNull);
      expect(normalizeRelayHost('relay example.com'), isNull);
      expect(normalizeRelayHost(''), isNull);
      expect(normalizeRelayHost('   '), isNull);
      expect(normalizeRelayHost('relay..example.com'), isNull);
      expect(normalizeRelayHost('-relay.example.com'), isNull);
      expect(normalizeRelayHost('relay.example.com-'), isNull);
      expect(normalizeRelayHost('user@relay.example.com'), isNull);
      expect(normalizeRelayHost('relay.example.com?x=1'), isNull);
      expect(normalizeRelayHost('relay_x.example.com'), isNull);
      final tooLong = List.filled(20, 'abcdefghijkl').join('.');
      expect(normalizeRelayHost('$tooLong.example.com'), isNull);
    });
  });
}
