import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/peer_id_label.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/components/peer_id_text.dart';
import 'package:hollow/src/ui/dialogs/friends_manager_dialog.dart';

import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

const _id = '12D3KooWQx9mzS4zJp1rT8bH2kLcV7nYwE5aGfD3uT7iS4F';

class _Api implements RustLibApi {
  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Friends extends FriendsNotifier {
  @override
  Map<String, FriendInfo> build() => testFriends;
}

Future<void> _pumpBox(WidgetTester tester, double width) async {
  await tester.pumpWidget(MaterialApp(
    theme: HollowThemeData.dark(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: width,
          child: PeerIdText(_id, style: HollowTypography.mono),
        ),
      ),
    ),
  ));
}

String _shown(WidgetTester tester) =>
    tester.renderObject<RenderPeerIdText>(find.byType(PeerIdText)).shown;

void main() {
  setUpAll(() => RustLib.initMock(api: _api));

  group('PeerIdText', () {
    testWidgets('shows the whole id when it fits', (tester) async {
      await _pumpBox(tester, 2000);
      expect(_shown(tester), _id);
    });

    testWidgets('a narrow box keeps the ending and fills the width',
        (tester) async {
      // The test font draws every glyph one em wide: 13 px in mono.
      await _pumpBox(tester, 13.0 * 20);
      final shown = _shown(tester);
      expect(shown.length, 20);
      expect(shown.endsWith('T7iS4F'), isTrue, reason: shown);
      expect(shown.startsWith('12D3'), isTrue, reason: shown);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wider box shows more of the id', (tester) async {
      await _pumpBox(tester, 13.0 * 20);
      final narrow = _shown(tester).length;
      await _pumpBox(tester, 13.0 * 32);
      expect(_shown(tester).length, greaterThan(narrow));
      expect(_shown(tester).endsWith('T7iS4F'), isTrue);
    });
  });

  testWidgets('a larger text size fits fewer characters, ending kept',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 13.0 * 20,
              child: PeerIdText(_id, style: HollowTypography.mono),
            ),
          ),
        ),
      ),
    ));
    expect(_shown(tester).length, 10);
    expect(_shown(tester).endsWith('T7iS4F'), isTrue);
  });

  testWidgets('answers intrinsic sizes and lines up on a baseline',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: IntrinsicWidth(
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  PeerIdText(_id, style: HollowTypography.mono),
                  const Text(' · online'),
                ],
              ),
            ),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(_shown(tester), _id);
    expect(tester.getSize(find.byType(PeerIdText)).width, 13.0 * _id.length);
  });

  testWidgets('a nameless person in a tight slot keeps the id ending',
      (tester) async {
    Future<Widget> slot(String name) async => MaterialApp(
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 13.0 * 12,
                child: PeerNameText(
                    name: name, peerId: _id, style: HollowTypography.mono),
              ),
            ),
          ),
        );
    await tester.pumpWidget(await slot(shortPeerLabel(_id)));
    expect(_shown(tester), endsWith('T7iS4F'));
    expect(_shown(tester).length, 12);

    await tester.pumpWidget(await slot('A chosen name that is long'));
    expect(find.byType(PeerIdText), findsNothing);
    expect(find.text('A chosen name that is long'), findsOneWidget);
  });

  group('"Your user ID" at phone width', () {
    for (final width in [375.0, 320.0]) {
      testWidgets('shows the ending of the id at $width and copies it whole',
          (tester) async {
        tester.view.physicalSize = Size(width, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        String? copied;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null));
        final container = ProviderContainer(
          overrides: hollowTestOverrides(extra: [
            friendsProvider.overrideWith(_Friends.new),
          ]),
        );
        addTearDown(container.dispose);
        late BuildContext host;
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: HollowThemeData.dark(),
            home: Scaffold(body: Builder(builder: (context) {
              host = context;
              return const SizedBox.expand();
            })),
          ),
        ));
        showFriendsManager(host, tab: FriendsManagerTab.add);
        await tester.pumpAndSettle();

        final ending = kLocalPeerId.substring(kLocalPeerId.length - 6);
        final idText = find.byType(PeerIdText);
        expect(idText, findsOneWidget);
        final shown = tester.renderObject<RenderPeerIdText>(idText);
        expect(shown.shown.endsWith(ending), isTrue, reason: shown.shown);
        expect(shown.shown, isNot(kLocalPeerId),
            reason: 'the id does not fit at $width, so its middle goes');
        expect(tester.takeException(), isNull);

        await tester.tap(find.bySemanticsLabel('Copy your user ID'));
        await tester.pump();
        expect(copied, kLocalPeerId);
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      });
    }
  });
}

final _api = _Api();
