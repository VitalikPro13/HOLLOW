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
      final generated = webConferenceInviteLink('abcdef0123456789');
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
    expect(webServerInviteLink('abc'),
        'https://hollow.anonlisten.com/join#server=abc');
  });
}
