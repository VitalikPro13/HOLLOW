import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/image_pick.dart';
import 'package:hollow/src/rust/api/emotes.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/emoji_picker.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';

// Issue #76: on desktop the picker is a raw OverlayEntry, which the Navigator
// keeps above every route, so the "Name this emote" dialog rendered BEHIND it.
// Its Save button could not be clicked, the click that reached the barrier
// tore the picker down, and the upload silently never landed.

const _png =
    'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAABNSURBVDhPY7hjY/OfEjycDfh/nQEDY1OH1QBsmmEYXS2GAdg0oWNk9dQ1AJtibBhZzyDzAgxj0wTD6GqxGgDCxGgGYZwGEIsH2gCb/wBSPnarPKl6tgAAAABJRU5ErkJggg==';
const _hash =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

class _EmoteApi implements RustLibApi {
  final added = <String>[];

  @override
  Future<ProcessedEmote> crateApiEmotesProcessAndStoreEmote(
          {required List<int> rawBytes}) async =>
      const ProcessedEmote(hash: _hash, animated: false);

  @override
  Future<void> crateApiEmotesAddPersonalEmote({
    required String name,
    required String hash,
    required bool animated,
    required String source,
  }) async {
    added.add(name);
  }

  @override
  Future<List<PersonalEmote>> crateApiEmotesListPersonalEmotes() async => [
        for (final name in added)
          PersonalEmote(
              name: name, hash: _hash, animated: false, source: 'upload'),
      ];

  @override
  Future<Uint8List?> crateApiEmotesGetEmoteBytes({required String hash}) async =>
      null;

  @override
  Future<void> crateApiEmotesRequestEmotes({
    required List<String> hashes,
    String? serverId,
    String? peerHint,
  }) async {}

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {}

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host() {
  return ProviderScope(
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showEmojiPicker(
                context: context,
                anchorPosition: const Offset(400, 500),
                onSelect: (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final api = _EmoteApi();
  setUpAll(() => RustLib.initMock(api: api));

  testWidgets('desktop picker steps aside for its name dialog and the upload lands',
      (tester) async {
    await tester.pumpWidget(_host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mine'));
    await tester.pumpAndSettle();

    debugArmedImagePick = () async => base64Decode(_png);
    await tester.tap(find.text('Upload emote'));
    await tester.pumpAndSettle();

    expect(find.text('Name this emote'), findsOneWidget);
    // Offstage while the dialog is up, so nothing sits over the Save button.
    expect(find.byType(EmojiPickerBody), findsNothing);
    expect(find.byType(EmojiPickerBody, skipOffstage: false), findsOneWidget);

    await tester.enterText(
      find.descendant(
          of: find.byType(HollowDialog), matching: find.byType(TextField)),
      'pe_test',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Name this emote'), findsNothing);
    expect(api.added, ['pe_test']);
    // Back on stage, listing the new emote.
    expect(find.byType(EmojiPickerBody), findsOneWidget);
    expect(find.bySemanticsLabel('Emote pe_test'), findsOneWidget);
    // The name field's controller used to be disposed under the exit animation.
    expect(tester.takeException(), isNull);
  });
}
