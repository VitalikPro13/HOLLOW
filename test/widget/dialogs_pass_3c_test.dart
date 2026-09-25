/// Dialogs pass, share / shop / large-file dialogs: each test pins a bug the
/// pass fixed.
///
/// - Open a share link: a failed request for the file went invisible (the
///   spinner kept running) and then blamed "nobody sharing"; it now returns to
///   the field with the honest cause. A failed download start stays in the
///   dialog instead of crashing the zone.
/// - Imported pack: one primary, never a row of outlines.
/// - Redeem: a lookup problem sits on the field.
/// - Pack import failures read as a next step, never the Rust string.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/owned_art_provider.dart';
import 'package:hollow/src/core/providers/share_tab_provider.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/share.dart' as share_api;
import 'package:hollow/src/rust/api/shop.dart' as shop_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_text_field.dart';
import 'package:hollow/src/ui/components/large_file_share_dialog.dart';
import 'package:hollow/src/ui/share/paste_link_dialog.dart';
import 'package:hollow/src/ui/shop/hollowpack_import.dart';
import 'package:hollow/src/ui/shop/owned_art_panel.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';

import '../helpers/test_app.dart';

const _root = 'r00t';

class _Api implements RustLibApi {
  Object? openError;
  Object? downloadError;
  bool decodeFails = false;
  shop_api.RedeemLookup? lookup;

  @override
  Future<share_api.ShareLinkInfo> crateApiShareShareDecodeLink(
      {required String link}) async {
    if (decodeFails) throw AnyhowException('bad base32');
    return const share_api.ShareLinkInfo(rootHash: _root, roomId: 'room');
  }

  @override
  Future<void> crateApiShareShareOpenLink({required String link}) async {
    if (openError != null) throw openError!;
  }

  @override
  Future<void> crateApiShareShareStartDownload({
    required String rootHash,
    required String saveDir,
    required String link,
    required bool sequential,
  }) async {
    if (downloadError != null) throw downloadError!;
  }

  @override
  Future<void> crateApiShareShareCancel({required String rootHash}) async {}

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      null;

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  Future<Uint8List?> crateApiEmotesGetEmoteBytes({required String hash}) async =>
      null;

  @override
  Future<shop_api.RedeemLookup> crateApiShopRedeemLookup(
          {required String code}) async =>
      lookup!;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Owned extends OwnedArtNotifier {
  _Owned(this.items);
  final List<OwnedItem> items;

  @override
  List<OwnedItem> build() => items;

  @override
  Future<void> reload() async {}
}

network_api.OwnedArt _art(String role) => network_api.OwnedArt(
      hash: role.padRight(64, 'a').substring(0, 64),
      role: role,
      itemId: 'item',
      title: 'Aurora set',
      artistName: 'Nadia',
      artistSlug: 'nadia',
      artistUrl: '',
      license: '',
      importedAt: 1,
    );

final _bundle = OwnedItem(
  itemId: 'item',
  title: 'Aurora set',
  artistName: 'Nadia',
  artistSlug: 'nadia',
  artistUrl: '',
  license: '',
  importedAt: 1,
  byRole: {
    'frame': _art('frame'),
    'avatar': _art('avatar'),
    'banner': _art('banner'),
  },
);

late BuildContext _host;
late WidgetRef _hostRef;

Future<void> _pumpHost(WidgetTester tester, {List<Override> extra = const []}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      railBytesProvider.overrideWith((ref, hash) async => null as Uint8List?),
      ...extra,
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: Scaffold(
        body: Consumer(builder: (context, ref, _) {
          _host = context;
          _hostRef = ref;
          return const SizedBox.expand();
        }),
      ),
    ),
  ));
}

String? _fieldError(WidgetTester tester) =>
    tester.widget<HollowTextField>(find.byType(HollowTextField)).errorText;

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api
      ..openError = null
      ..downloadError = null
      ..decodeFails = false
      ..lookup = null;
  });

  group('Open a share link', () {
    Future<void> openWith(WidgetTester tester, String link) async {
      await _pumpHost(tester);
      unawaited(showHollowDialog<void>(
          context: _host, builder: (_) => const PasteLinkDialog()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), link);
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a failed request returns to the field with its cause',
        (tester) async {
      api.openError = AnyhowException('relay not connected');
      await openWith(tester, 'hollow://share/abc');

      expect(find.text('Open'), findsOneWidget,
          reason: 'back on the input step, not a spinner');
      expect(_fieldError(tester), contains("can't reach the relay"));

      // The countdown never runs on to blame the people sharing the file.
      await tester.pump(const Duration(seconds: 11));
      expect(find.textContaining('Nobody sharing'), findsNothing);
      expect(_fieldError(tester), isNot(contains("isn't a share link")));
    });

    testWidgets('text that is not a link says so', (tester) async {
      api.decodeFails = true;
      await openWith(tester, 'hello');
      expect(_fieldError(tester), "That isn't a share link");
    });

    testWidgets('a failed download start stays in the dialog', (tester) async {
      api.downloadError = AnyhowException('relay not connected');
      await openWith(tester, 'hollow://share/abc');
      final container =
          ProviderScope.containerOf(tester.element(find.byType(PasteLinkDialog)));
      container
          .read(shareTabProvider.notifier)
          .handleShareManifestReady(_root, 'clip.mp4', 2048, 1);
      await tester.pump();
      await tester.pump();
      expect(find.text('clip.mp4'), findsOneWidget);

      await tester.tap(find.text('Download'));
      await tester.pump();
      await tester.pump();

      expect(find.byType(PasteLinkDialog), findsOneWidget);
      expect(find.textContaining("can't reach the relay"), findsOneWidget);
      expect(container.read(shareTabProvider), isEmpty,
          reason: 'the optimistic download row is rolled back');
      expect(
          container
              .read(shareTabProvider.notifier)
              .pendingManifests
              .containsKey(_root),
          isTrue,
          reason: 'kept for a retry');
    });
  });

  testWidgets('an imported bundle offers ONE primary and no outlines',
      (tester) async {
    await _pumpHost(tester,
        extra: [ownedArtProvider.overrideWith(() => _Owned([_bundle]))]);
    unawaited(showImportedPackDialog(
      _host,
      _hostRef,
      network_api.HollowpackImport(
        itemId: 'item',
        title: 'Aurora set',
        artistName: 'Nadia',
        artistSlug: 'nadia',
        artistUrl: '',
        license: '',
        files: [
          for (final role in ['frame', 'avatar', 'banner'])
            network_api.HollowpackFile(
                role: role,
                hash: role.padRight(64, 'a').substring(0, 64),
                bytes: BigInt.one,
                w: 512,
                h: 512,
                animated: role == 'avatar'),
        ],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Aurora set is in your library'), findsOneWidget);
    expect(find.text('Imported'), findsNothing);
    final buttons =
        tester.widgetList<HollowButton>(find.byType(HollowButton)).toList();
    expect(
        buttons.where((b) => b.variant == HollowButtonVariant.filled).length, 1);
    expect(
        buttons.where((b) => b.variant == HollowButtonVariant.outline), isEmpty);
    expect(find.text('Wear all'), findsOneWidget);
    expect(find.text('Avatar, animated'), findsOneWidget);
    expect(find.textContaining('512x512'), findsNothing);
    expect(find.text('Not now'), findsOneWidget);
  });

  testWidgets('a refused redeem code sits on the field', (tester) async {
    api.lookup = const shop_api.RedeemLookup(
      status: 'burned',
      message: 'This code has already been redeemed.',
      slug: '',
      title: '',
      artistName: '',
      artistSlug: '',
      itemUrl: '',
      kinds: [],
      item: '',
      parts: [],
      alreadySupported: false,
    );
    await _pumpHost(tester);
    unawaited(showRedeemEntryDialog(_host));
    await tester.pumpAndSettle();

    expect(find.text('Copy code'), findsNothing,
        reason: 'nothing to copy yet');
    expect(find.textContaining('blind'), findsNothing);

    await tester.enterText(find.byType(TextField), 'ABCD-EFGH');
    await tester.pump();
    expect(find.text('Copy code'), findsOneWidget);
    await tester.tap(find.text('Look up'));
    await tester.pump();
    await tester.pump();

    expect(_fieldError(tester), 'This code has already been redeemed.');
  });

  test('pack failures read as a next step, never the Rust check', () {
    expect(
        hollowpackFailureSentence(
            AnyhowException('The frame file does not match the hash the pack '
                'claims for it')),
        contains('damaged'));
    expect(
        hollowpackFailureSentence(
            AnyhowException('That pack was made by a newer version of Hollow')),
        contains('Update Hollow'));
    expect(
        hollowpackFailureSentence(
            AnyhowException('That pack is too large to open (over 64 MB)')),
        contains('bigger than Hollow accepts'));
    expect(
        hollowpackFailureSentence(
            AnyhowException('That file is not a Hollow art pack')),
        contains("isn't a Hollow art pack"));
    expect(hollowpackFailureSentence(StateError('boom')),
        isNot(contains('boom')));
  });

  test('owned kinds join as a sentence', () {
    expect(ownedKindsLeaveSentence(['frame']),
        'Its frame leaves Your art on this device.');
    expect(ownedKindsLeaveSentence(['frame', 'avatar', 'banner']),
        'Its frame, avatar and banner leave Your art on this device.');
  });

  testWidgets('the large-file question speaks plainly', (tester) async {
    await _pumpHost(tester);
    unawaited(confirmLargeFileShare(_host,
        fileName: 'film.mkv', sizeBytes: 40 * 1024 * 1024));
    await tester.pumpAndSettle();
    expect(find.textContaining('Heads up'), findsNothing);
    expect(find.textContaining('STUN'), findsNothing);
    expect(find.text("Don't send it"), findsOneWidget);
    expect(find.text('Send as Share'), findsOneWidget);
    expect(find.textContaining('Keep Hollow open'), findsOneWidget);
  });
}
