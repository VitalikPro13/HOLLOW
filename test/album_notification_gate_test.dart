import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/album_notification_gate.dart';
import 'package:hollow/src/ui/chat/staged_attachments.dart';

StagedAttachment _a(String name) =>
    StagedAttachment(path: '/tmp/$name', name: name, sizeBytes: 1);

void main() {
  group('album notification gate', () {
    testWidgets('a lone message notifies at once', (tester) async {
      final gate = AlbumNotificationGate();
      final fired = <String>[];
      gate.offer(
          albumId: null, conversation: 'dm:a', text: 'hi', fire: fired.add);
      expect(fired, ['hi']);
    });

    testWidgets('an album notifies once, with its count', (tester) async {
      final gate = AlbumNotificationGate();
      final fired = <String>[];
      for (var i = 0; i < 4; i++) {
        gate.offer(
            albumId: 'A',
            conversation: 'dm:a',
            text: '[file:f$i]',
            fire: fired.add);
      }
      expect(fired, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      expect(fired, ['4 files']);

      // A straggler after the notification stays silent.
      gate.offer(
          albumId: 'A', conversation: 'dm:a', text: '[file:f9]', fire: fired.add);
      await tester.pump(const Duration(seconds: 2));
      expect(fired.length, 1);
    });

    testWidgets('the caption wins, whichever item carries it', (tester) async {
      final gate = AlbumNotificationGate();
      final fired = <String>[];
      gate.offer(
          albumId: 'A', conversation: 'c', text: '[file:f0]', fire: fired.add);
      gate.offer(
          albumId: 'A', conversation: 'c', text: 'Our trip', fire: fired.add);
      await tester.pump(const Duration(seconds: 2));
      expect(fired, ['Our trip']);
    });

    testWidgets('one album id from two senders is two notifications',
        (tester) async {
      final gate = AlbumNotificationGate();
      final fired = <String>[];
      gate.offer(
          albumId: 'A', conversation: 'ch:s1', text: '[file:1]', fire: fired.add);
      gate.offer(
          albumId: 'A', conversation: 'ch:s2', text: '[file:2]', fire: fired.add);
      await tester.pump(const Duration(seconds: 2));
      expect(fired.length, 2);
    });
  });

  test('reorderStaged moves an item to its post-removal index', () {
    final list = [_a('a'), _a('b'), _a('c')];
    expect(reorderStaged(list, 0, 2).map((x) => x.name), ['b', 'c', 'a']);
    expect(reorderStaged(list, 2, 0).map((x) => x.name), ['c', 'a', 'b']);
  });

  test('staged kinds come from the extension', () {
    expect(_a('x.JPG').isImage, isTrue);
    expect(_a('x.mov').isVideo, isTrue);
    expect(_a('x.pdf').isImage || _a('x.pdf').isVideo, isFalse);
  });
}
