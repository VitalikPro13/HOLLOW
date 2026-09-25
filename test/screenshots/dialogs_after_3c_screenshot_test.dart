import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
import 'package:hollow/src/ui/archive/shared/archive_sender_filter.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/large_file_share_dialog.dart';
import 'package:hollow/src/ui/share/paste_link_dialog.dart';
import 'package:hollow/src/ui/shop/hollowpack_import.dart';
import 'package:hollow/src/ui/shop/owned_art_panel.dart';
import 'package:hollow/src/ui/shop/redeem_code_dialog.dart';

import '../helpers/test_app.dart';

/// Dialogs pass, agent 3 part C: share, shop, archive and the large-file
/// question after the fixes. Invented content only; FFI mocked.
///
/// Output: build/ui_screenshots/dialogs_after/3/c_*.png
final _desktop = TargetPlatformVariant.only(TargetPlatform.windows);
final _phone = TargetPlatformVariant.only(TargetPlatform.android);

const _root = 'r00t';

class _Api implements RustLibApi {
  Object? openError;
  shop_api.RedeemLookup? lookup;

  @override
  Future<share_api.ShareLinkInfo> crateApiShareShareDecodeLink(
          {required String link}) async =>
      const share_api.ShareLinkInfo(rootHash: _root, roomId: 'room');

  @override
  Future<void> crateApiShareShareOpenLink({required String link}) async {
    if (openError != null) throw openError!;
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
  Future<Uint8List?> crateApiStorageGetAvatar({required String peerId}) async =>
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
      license: 'Personal use. Do not resell.',
      importedAt: 1,
    );

final _bundle = OwnedItem(
  itemId: 'item',
  title: 'Aurora set',
  artistName: 'Nadia',
  artistSlug: 'nadia',
  artistUrl: '',
  license: 'Personal use. Do not resell.',
  importedAt: 1,
  byRole: {
    'frame': _art('frame'),
    'avatar': _art('avatar'),
    'banner': _art('banner'),
  },
);

shop_api.RedeemLookup _lookup({String status = 'ok', bool owned = false}) =>
    shop_api.RedeemLookup(
      status: status,
      message: status == 'ok' ? '' : 'This code has already been redeemed.',
      slug: 'aurora',
      title: 'Aurora set',
      artistName: 'Nadia',
      artistSlug: 'nadia',
      itemUrl: '',
      kinds: const ['frame', 'avatar', 'banner'],
      item: 'a' * 64,
      parts: const [],
      alreadySupported: owned,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir =
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}dialogs_after${sep}3';
  final api = _Api();

  setUpAll(() async {
    RustLib.initMock(api: api);
    final lucide =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    await (FontLoader('packages/lucide_icons_flutter/Lucide')
          ..addFont(Future.value(lucide)))
        .load();
    final families = <String, List<ByteData>>{};
    for (final face in Directory('assets/fonts').listSync()) {
      final name = face.uri.pathSegments.last;
      if (!name.endsWith('.ttf')) continue;
      final family = name.startsWith('Onest')
          ? 'Onest'
          : name.startsWith('GeistMono')
              ? 'GeistMono'
              : null;
      if (family == null) continue;
      final bytes = File(face.path).readAsBytesSync();
      families.putIfAbsent(family, () => []).add(ByteData.view(bytes.buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });

  setUp(() {
    api
      ..openError = null
      ..lookup = null;
  });

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir${Platform.pathSeparator}c_$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late BuildContext host;
  late WidgetRef hostRef;

  Future<void> pumpHost(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: hollowTestOverrides(extra: [
        railBytesProvider.overrideWith((ref, hash) async => null as Uint8List?),
        ownedArtProvider.overrideWith(() => _Owned([_bundle])),
      ]),
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(
            body: Consumer(builder: (context, ref, _) {
              host = context;
              hostRef = ref;
              return const SizedBox.expand();
            }),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  final scenarios = <String, Future<void> Function(WidgetTester)>{
    'paste_link_network_error': (tester) async {
      api.openError = AnyhowException('relay not connected');
      unawaited(showHollowDialog<void>(
          context: host, builder: (_) => const PasteLinkDialog()));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'hollow://share/7QX2');
      await tester.pump();
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump();
      await settle(tester);
    },
    'paste_link_confirm': (tester) async {
      unawaited(showHollowDialog<void>(
          context: host, builder: (_) => const PasteLinkDialog()));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'hollow://share/7QX2');
      await tester.pump();
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump();
      await settle(tester);
      ProviderScope.containerOf(host)
          .read(shareTabProvider.notifier)
          .handleShareManifestReady(_root, 'Holiday footage.mp4', 734003200, 1);
      await settle(tester);
    },
    'imported_bundle': (tester) async {
      unawaited(showImportedPackDialog(
        host,
        hostRef,
        network_api.HollowpackImport(
          itemId: 'item',
          title: 'Aurora set',
          artistName: 'Nadia',
          artistSlug: 'nadia',
          artistUrl: '',
          license: 'Personal use. Do not resell.',
          files: [
            for (final role in ['frame', 'avatar_anim', 'banner'])
              network_api.HollowpackFile(
                  role: role,
                  hash: role.padRight(64, 'a').substring(0, 64),
                  bytes: BigInt.one,
                  w: 512,
                  h: 512,
                  animated: role == 'avatar_anim'),
          ],
        ),
      ));
      await settle(tester);
    },
    'pack_failed': (tester) async {
      unawaited(showHollowDialog<void>(
        context: host,
        builder: (dialogContext) => HollowDialog(
          title: "Couldn't import that pack",
          content: HollowDialogText(hollowpackFailureSentence(AnyhowException(
              'The frame file does not match the hash the pack claims'))),
          actions: [
            HollowButton.filled(
                onPressed: () {}, child: const Text('Got it')),
          ],
        ),
      ));
      await settle(tester);
    },
    'redeem_entry': (tester) async {
      unawaited(showRedeemEntryDialog(host));
      await settle(tester);
    },
    'redeem_refused': (tester) async {
      api.lookup = _lookup(status: 'burned');
      unawaited(showRedeemEntryDialog(host));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'K7PQ-2WXA-9MRT');
      await tester.pump();
      await tester.tap(find.text('Look up'));
      await tester.pump();
      await tester.pump();
      await settle(tester);
    },
    'redeem_already_owned': (tester) async {
      api.lookup = _lookup(owned: true);
      unawaited(showRedeemEntryDialog(host));
      await settle(tester);
      await tester.enterText(find.byType(TextField), 'K7PQ-2WXA-9MRT');
      await tester.pump();
      await tester.tap(find.text('Look up'));
      await tester.pump();
      await tester.pump();
      await settle(tester);
    },
    'large_file': (tester) async {
      unawaited(confirmLargeFileShare(host,
          fileName: 'Holiday footage.mp4', sizeBytes: 700 * 1024 * 1024));
      await settle(tester);
    },
    'large_files': (tester) async {
      unawaited(confirmLargeFilesShare(host, files: [
        (name: 'Holiday footage.mp4', sizeBytes: 700 * 1024 * 1024),
        (name: 'Raw photos.zip', sizeBytes: 2200 * 1024 * 1024),
      ]));
      await settle(tester);
    },
    'owned_remove_confirm': (tester) async {
      unawaited(showHollowConfirm(
        context: host,
        title: 'Remove Aurora set?',
        message: '${ownedKindsLeaveSentence(_bundle.kinds)} Anything you wear '
            'now stays on until you change it. Import the pack again to get '
            'it back.',
        confirmLabel: 'Remove',
        destructive: true,
      ));
      await settle(tester);
    },
    'archive_sender_sheet': (tester) async {
      showArchiveFilterSheet(
        host,
        senderIds: const ['p1', 'p2', 'p3'],
        selectedSender: 'p2',
        senderNames: const {'p1': 'Mira', 'p2': 'Juno', 'p3': 'Sam'},
        onSelected: (_) {},
      );
      await settle(tester);
    },
  };

  for (final entry in scenarios.entries) {
    testWidgets('${entry.key} desktop', (tester) async {
      await pumpHost(tester, const Size(1440, 900));
      await entry.value(tester);
      await capture(tester, '${entry.key}_desktop');
      await tester.pumpWidget(const SizedBox());
    }, variant: _desktop);
    testWidgets('${entry.key} phone', (tester) async {
      await pumpHost(tester, const Size(390, 844));
      await entry.value(tester);
      await capture(tester, '${entry.key}_phone');
      await tester.pumpWidget(const SizedBox());
    }, variant: _phone);
  }
}
