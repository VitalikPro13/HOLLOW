import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/relay_status_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/hollow_link_card.dart';
import 'package:hollow/src/ui/chat/hollow_link_utils.dart';
import 'package:hollow/src/ui/components/relay_no_turn_chip.dart';
import 'package:hollow/src/ui/dialogs/no_turn_dialog.dart';
import 'package:hollow/src/ui/dialogs/relay_switch_dialog.dart';
import 'package:hollow/src/ui/settings/network_section.dart';

/// Screenshot harness for the self-hosting relay surfaces: the switch dialog
/// each invite type shows, the pre-dial TURN warning, the no-TURN note on the
/// active relay row, and the Join card's relay line.
///
/// Output dir: $HOLLOW_SHOT_DIR, falling back to build/ui_screenshots.
class _FixedRelayDomain extends RelayDomainNotifier {
  _FixedRelayDomain(this.domain);
  final String domain;

  @override
  String build() => domain;
}

class _FixedRelayStatus extends RelayStatusNotifier {
  _FixedRelayStatus(this.status);
  final RelayStatus status;

  @override
  RelayStatus build() => status;
}

class _FixedAlwaysRelay extends AlwaysRelayCallsNotifier {
  _FixedAlwaysRelay(this.on);
  final bool on;

  @override
  bool build() => on;
}

class _FixedRelayList extends SavedRelayListNotifier {
  _FixedRelayList(this.domains);
  final List<String> domains;

  @override
  List<String> build() => domains;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const shotKey = Key('screenshot-boundary');
  const current = 'relay.anonlisten.com';
  const other = 'myrelay.duckdns.org';

  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${Platform.pathSeparator}build'
          '${Platform.pathSeparator}ui_screenshots';

  setUpAll(() async {
    final fontData =
        await rootBundle.load('packages/lucide_icons_flutter/assets/lucide.ttf');
    final loader = FontLoader('packages/lucide_icons_flutter/Lucide')
      ..addFont(Future.value(fontData));
    await loader.load();
    // Regular AND semibold, or every w600 span falls back to block glyphs and
    // the host strings cannot be read.
    try {
      final faces = [
        r'C:\Windows\Fonts\segoeui.ttf',
        r'C:\Windows\Fonts\seguisb.ttf',
        r'C:\Windows\Fonts\segoeuib.ttf',
      ].map(File.new).where((f) => f.existsSync()).toList();
      if (faces.isNotEmpty) {
        for (final family in ['FlutterTest', 'Ahem', 'Roboto', 'Consolas']) {
          final l = FontLoader(family);
          for (final f in faces) {
            l.addFont(
                Future.value(ByteData.view(f.readAsBytesSync().buffer)));
          }
          await l.load();
        }
      }
    } catch (_) {/* screenshots fall back to block glyphs */}
  });

  List<Override> overrides({bool? turn, bool alwaysRelay = false}) => [
        relayDomainProvider.overrideWith(() => _FixedRelayDomain(current)),
        savedRelayListProvider
            .overrideWith(() => _FixedRelayList([current, other])),
        relayStatusProvider
            .overrideWith(() => _FixedRelayStatus(RelayStatus(turn: turn))),
        alwaysRelayCallsProvider
            .overrideWith(() => _FixedAlwaysRelay(alwaysRelay)),
      ];

  Future<void> pumpHost(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(900, 700),
    List<Override> extra = const [],
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: extra,
        child: RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(body: child),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDialogHost(
    WidgetTester tester, {
    required Future<void> Function(BuildContext context, WidgetRef ref) onOpen,
    required List<Override> extra,
    Size size = const Size(900, 700),
  }) async {
    await pumpHost(
      tester,
      Consumer(
        builder: (context, ref, _) => Center(
          child: ElevatedButton(
            onPressed: () => onOpen(context, ref),
            child: const Text('open'),
          ),
        ),
      ),
      size: size,
      extra: extra,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      try {
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        if (data == null) return;
        final file = File('$outDir${Platform.pathSeparator}$name.png');
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(data.buffer.asUint8List());
        debugPrint('[screenshot] wrote ${file.path}');
      } catch (e) {
        debugPrint('[screenshot] skipped $name: $e');
      }
    });
  }

  HollowLink linkOf(String url) => classifyHollowLink(url)!;

  testWidgets('relay switch dialog — server invite', (tester) async {
    await pumpDialogHost(
      tester,
      extra: overrides(),
      onOpen: (context, ref) => ensureRelayForInvite(context, ref,
          linkOf('hollow://join?server=abc123&relay=$other')),
    );
    expect(find.text('This server lives on another relay'), findsOneWidget);
    expect(find.text('Switch and restart'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    await capture(tester, 'relay_switch_server');
  });

  testWidgets('relay switch dialog — room invite', (tester) async {
    await pumpDialogHost(
      tester,
      extra: overrides(),
      onOpen: (context, ref) => ensureRelayForInvite(
          context, ref, linkOf('hollow://join?room=r0om1234&relay=$other')),
    );
    expect(find.text('This room lives on another relay'), findsOneWidget);
    await capture(tester, 'relay_switch_room');
  });

  testWidgets('relay switch dialog — conference invite', (tester) async {
    await pumpDialogHost(
      tester,
      extra: overrides(),
      onOpen: (context, ref) => ensureRelayForInvite(context, ref,
          linkOf('hollow://conference/abcdef0123456789?relay=$other')),
    );
    expect(find.text('This meeting lives on another relay'), findsOneWidget);
    await capture(tester, 'relay_switch_conference');
  });

  testWidgets('relay switch dialog at phone width', (tester) async {
    await pumpDialogHost(
      tester,
      size: const Size(390, 780),
      extra: overrides(),
      onOpen: (context, ref) => ensureRelayForInvite(context, ref,
          linkOf('hollow://join?server=abc123&relay=$other')),
    );
    await capture(tester, 'relay_switch_narrow');
  });

  testWidgets('a link on our own relay never asks', (tester) async {
    var answer = false;
    await pumpDialogHost(
      tester,
      extra: overrides(),
      onOpen: (context, ref) async {
        answer = await ensureRelayForInvite(context, ref,
            linkOf('hollow://join?server=abc123&relay=$current'));
      },
    );
    expect(answer, isTrue);
    expect(find.text('This server lives on another relay'), findsNothing);
  });

  testWidgets('pre-dial TURN dialog', (tester) async {
    await pumpDialogHost(
      tester,
      extra: overrides(turn: false, alwaysRelay: true),
      onOpen: (context, ref) => ensureTurnForCall(context, ref),
    );
    expect(
        find.text('Always relay calls needs a TURN server'), findsOneWidget);
    expect(find.text('OK'), findsOneWidget);
    await capture(tester, 'no_turn_dialog');
  });

  testWidgets('no TURN dialog stays away with always-relay off',
      (tester) async {
    var answer = false;
    await pumpDialogHost(
      tester,
      extra: overrides(turn: false),
      onOpen: (context, ref) async {
        answer = await ensureTurnForCall(context, ref);
      },
    );
    expect(answer, isTrue);
    expect(find.text('Always relay calls needs a TURN server'), findsNothing);
  });

  testWidgets('settings relay rows carry the no-TURN note', (tester) async {
    await pumpHost(
      tester,
      const SingleChildScrollView(child: RelaySettingsSection()),
      extra: overrides(turn: false),
    );
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    // Only the ACTIVE row is marked: the other saved relay said nothing.
    expect(find.textContaining('No TURN: calls need a direct route',
            findRichText: true),
        findsOneWidget);
    await capture(tester, 'relay_row_no_turn');
  });

  testWidgets('no note while the relay never said', (tester) async {
    await pumpHost(
      tester,
      const SingleChildScrollView(child: RelaySettingsSection()),
      extra: overrides(),
    );
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No TURN', findRichText: true), findsNothing);
  });

  testWidgets('picking another relay offers the restart', (tester) async {
    await pumpHost(
      tester,
      const SingleChildScrollView(child: RelaySettingsSection()),
      extra: overrides(),
    );
    expect(find.text('Switch and restart'), findsNothing);
    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(other));
    await tester.pumpAndSettle();
    expect(find.text('Switch and restart'), findsOneWidget);
  });

  testWidgets('the compact chip mobile uses', (tester) async {
    await pumpHost(
      tester,
      const Center(child: RelayNoTurnChip(compact: true)),
      size: const Size(390, 200),
      extra: overrides(turn: false),
    );
    expect(find.text('No TURN server'), findsOneWidget);
    await capture(tester, 'relay_chip_compact');
  });

  testWidgets('join cards name a foreign relay', (tester) async {
    await pumpHost(
      tester,
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            HollowLinkCard(
                link: linkOf('hollow://join?server=abc123&relay=$other')),
            const SizedBox(height: 12),
            HollowLinkCard(
                link: linkOf('hollow://join?room=r0om1234&relay=$other')),
            const SizedBox(height: 12),
            HollowLinkCard(
                link: linkOf(
                    'hollow://conference/abcdef0123456789?relay=$other')),
            const SizedBox(height: 12),
            HollowLinkCard(
                link: linkOf('hollow://join?server=abc123&relay=$current')),
          ],
        ),
      ),
      size: const Size(560, 480),
      extra: overrides(),
    );
    expect(find.text('On $other'), findsNWidgets(3));
    expect(find.text('On $current'), findsNothing);
    await capture(tester, 'join_cards_relay_line');
  });
}
