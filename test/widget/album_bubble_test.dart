import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/album_bubble.dart';
import 'package:hollow/src/ui/chat/file_attachment_widget.dart';

import '../helpers/test_app.dart';

AlbumItem _item(int i, {String ext = 'webp', bool image = true}) => AlbumItem(
      attachment: FileAttachment(
        fileId: 'f$i',
        fileName: 'file$i.$ext',
        fileExt: ext,
        mimeType: 'application/octet-stream',
        sizeBytes: 1000,
        isImage: image,
        width: 400,
        height: 300,
        totalChunks: 0,
      ),
      messageId: 'm$i',
      senderId: 'peer',
      timestampMs: 0,
      isMine: false,
    );

Future<void> _pump(WidgetTester tester, List<AlbumItem> items) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Center(child: AlbumBubble(items: items)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('two items sit side by side as equal squares', (tester) async {
    await _pump(tester, [_item(0), _item(1)]);
    final cells = find.byType(FileAttachmentWidget);
    expect(cells, findsNWidgets(2));
    final a = tester.getRect(cells.at(0));
    final b = tester.getRect(cells.at(1));
    expect(a.size, b.size);
    expect(a.width, a.height);
    expect(a.top, b.top);
    expect(b.left, greaterThan(a.right));
    expect(b.right - a.left, closeTo(320, 0.01));
  });

  testWidgets('three items: one large, two stacked beside it', (tester) async {
    await _pump(tester, [_item(0), _item(1), _item(2)]);
    final cells = find.byType(FileAttachmentWidget);
    final big = tester.getRect(cells.at(0));
    final top = tester.getRect(cells.at(1));
    final bottom = tester.getRect(cells.at(2));
    expect(big.height, greaterThan(top.height));
    expect(top.left, bottom.left);
    expect(bottom.top, greaterThan(top.bottom));
  });

  testWidgets('ten items show six cells, "+4", and one Download all',
      (tester) async {
    await _pump(tester, [for (var i = 0; i < 10; i++) _item(i)]);
    expect(find.byType(FileAttachmentWidget), findsNWidgets(6));
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('Download all (10)'), findsOneWidget);
  });

  testWidgets('non-media files stack under the mosaic', (tester) async {
    await _pump(tester, [
      _item(0),
      _item(1),
      _item(2, ext: 'pdf', image: false),
    ]);
    final cells = find.byType(FileAttachmentWidget);
    expect(cells, findsNWidgets(3));
    expect(tester.getRect(cells.at(2)).top,
        greaterThan(tester.getRect(cells.at(0)).bottom));
    expect(find.text('file2.pdf'), findsOneWidget);
  });
}
