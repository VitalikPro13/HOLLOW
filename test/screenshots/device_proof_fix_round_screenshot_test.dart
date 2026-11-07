import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/channel_provider.dart';
import 'package:hollow/src/core/providers/device_proof_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/channel_chat_pane.dart';
import 'package:hollow/src/ui/chat/server_recovery_notices.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/dialogs/restore_chooser.dart';
import 'package:hollow/src/ui/mobile/mobile_chat_route.dart';
import 'package:hollow/src/ui/server_settings/pages/lost_devices_page.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';

import '../helpers/device_proof_fixtures.dart';
import '../helpers/test_app.dart';
import '../helpers/test_data.dart';

/// The device-proof screens in the states the UI review asked to see: 320 px
/// at text scale 1 and 2, phone light, a chosen restore point, a running
/// Restore or Apply, Put back on, an answered review and the real channel pane.
/// One pane per file, labelled by HOLLOW_SHOT_LABEL, so a run on the old code
/// and one on the new code pair up into one before|after image.
/// Output: HOLLOW_SHOT_DIR, else build/ui_screenshots/device_proof_fix.
class _Api implements RustLibApi {
  /// Answers park here while [hold] is set, so a shot catches the spinner.
  bool hold = false;

  Future<void> _maybeHold() =>
      hold ? Completer<void>().future : Future<void>.value();

  /// Keys and channel ids the next answer reports as changed since.
  Set<String> changedSince = {};

  @override
  Future<dp.RefoldApplied> crateApiDeviceProofAnswerRefoldReview({
    required String serverId,
    required String member,
    required String device,
    String? below,
    required List<String> chosen,
    required List<String> putBack,
  }) async {
    await _maybeHold();
    return refoldAppliedFor(chosen, putBack, changedSince: changedSince);
  }

  @override
  Future<void> crateApiDeviceProofChooseRestore(
          {required String serverId, String? cp}) =>
      _maybeHold();

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<Never>().future;
}

class _QuietTray extends FlutterLocalNotificationsPlatform {}

final _api = _Api();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shotKey = Key('screenshot-boundary');
  final sep = Platform.pathSeparator;
  final outDir = Platform.environment['HOLLOW_SHOT_DIR'] ??
      '${Directory.current.path}${sep}build${sep}ui_screenshots${sep}device_proof_fix';
  final label = Platform.environment['HOLLOW_SHOT_LABEL'] ?? 'After';

  setUpAll(() async {
    RustLib.initMock(api: _api);
    FlutterLocalNotificationsPlatform.instance = _QuietTray();
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
      families
          .putIfAbsent(family, () => [])
          .add(ByteData.view(File(face.path).readAsBytesSync().buffer));
    }
    for (final e in families.entries) {
      final loader = FontLoader(e.key);
      for (final b in e.value) {
        loader.addFont(Future.value(b));
      }
      await loader.load();
    }
  });
  setUp(() => _api.hold = false);

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(shotKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) return;
      final file = File('$outDir$sep$name.png');
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(data.buffer.asUint8List());
      debugPrint('[screenshot] wrote ${file.path}');
    });
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
  }

  /// One labelled pane of [width] x [height] showing [pane].
  Future<void> mount(
    WidgetTester tester, {
    required Widget pane,
    required List<Override> overrides,
    required double width,
    required double height,
    bool light = false,
    bool touch = false,
    double scale = 1.0,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(RepaintBoundary(
      key: shotKey,
      child: ProviderScope(
        overrides: hollowTestOverrides(extra: overrides),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? HollowThemeData.light() : HollowThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(builder: (context) {
              final hollow = HollowTheme.of(context);
              return ColoredBox(
                color: hollow.background,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: hollow.surface,
                      padding: const EdgeInsets.all(HollowSpacing.sm),
                      child: MediaQuery.withNoTextScaling(
                        child: Text(label,
                            style: HollowTypography.caption
                                .copyWith(color: hollow.textSecondary)),
                      ),
                    ),
                    Expanded(
                        child: SettingsDensity(touch: touch, child: pane)),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  Widget strip(bool touch) => Builder(builder: (context) {
        final hollow = HollowTheme.of(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 52,
              color: hollow.surface,
              padding: const EdgeInsets.symmetric(horizontal: HollowSpacing.lg),
              alignment: AlignmentDirectional.centerStart,
              child: Text('# general',
                  style: HollowTypography.subheading
                      .copyWith(color: hollow.textPrimary)),
            ),
            const HollowDivider(),
            ServerRecoveryNotices(serverId: kServerId1, touch: touch),
            Expanded(child: ColoredBox(color: hollow.background)),
          ],
        );
      });

  Widget page(bool touch) => SingleChildScrollView(
        padding: EdgeInsets.all(touch ? HollowSpacing.lg : HollowSpacing.xl),
        child: const LostDevicesPage(serverId: kServerId1),
      );

  const chooser = Center(child: RestoreChooserDialog());

  const shell = dp.ServerRecovery(steppedBack: true, removedBy: kTomas);
  final pick = fixtureRestores([dp.RestoreStage.pick]);
  final points = fixtureRestores([dp.RestoreStage.points]);

  Future<void> tapRow(WidgetTester tester, String cp) async {
    await tester.tap(find.byKey(ValueKey('restore-point-$kServerId2-$cp')));
    await tester.pump();
    // The selection fill fades in.
    await tester.pump(const Duration(milliseconds: 300));
  }

  // The chooser.
  testWidgets('chooser pick desktop dark', (tester) async {
    await mount(tester,
        pane: chooser,
        overrides: deviceProofOverrides(restores: pick),
        width: 800,
        height: 620);
    await capture(tester, 'chooser_pick_desktop_dark');
  });
  for (final scale in [1.0, 2.0]) {
    final x = scale == 1.0 ? 'x1' : 'x2';
    testWidgets('chooser pick 320 $x', (tester) async {
      await mount(tester,
          pane: chooser,
          overrides: deviceProofOverrides(restores: pick),
          width: 320,
          height: 900,
          touch: true,
          scale: scale);
      await capture(tester, 'chooser_pick_320_$x');
    });
    testWidgets('chooser points 320 $x', (tester) async {
      await mount(tester,
          pane: chooser,
          overrides: deviceProofOverrides(restores: points),
          width: 320,
          height: scale == 1.0 ? 900 : 1500,
          touch: true,
          scale: scale);
      await tapRow(tester, 'cp-b');
      await capture(tester, 'chooser_points_selected_320_$x');
    });
  }
  testWidgets('chooser points selected desktop dark', (tester) async {
    await mount(tester,
        pane: chooser,
        overrides: deviceProofOverrides(restores: points),
        width: 800,
        height: 700);
    await tapRow(tester, 'cp-a');
    await capture(tester, 'chooser_points_selected_desktop_dark');
  });
  testWidgets('chooser points selected phone light', (tester) async {
    await mount(tester,
        pane: chooser,
        overrides: deviceProofOverrides(restores: points),
        width: 375,
        height: 812,
        light: true,
        touch: true);
    await tapRow(tester, 'cp-a');
    await capture(tester, 'chooser_points_selected_phone_light');
  });
  testWidgets('chooser restoring desktop dark', (tester) async {
    _api.hold = true;
    await mount(tester,
        pane: chooser,
        overrides: deviceProofOverrides(restores: points),
        width: 800,
        height: 700);
    await tapRow(tester, 'cp-a');
    await tester.tap(find.text('Restore'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await capture(tester, 'chooser_restoring_desktop_dark');
  });

  // The banners.
  for (final light in [false, true]) {
    final theme = light ? 'light' : 'dark';
    testWidgets('chat pane shell desktop $theme', (tester) async {
      final channel = testChannels[kChannelId1]!;
      await mount(tester,
          pane: ChannelChatPane(
            serverId: kServerId1,
            channelId: channel.channelId,
            channelName: channel.name,
          ),
          overrides: [
            ...deviceProofOverrides(recovery: shell, reviews: fixtureReviews),
            selectedServerProvider.overrideWith((_) => kServerId1),
            selectedChannelProvider.overrideWith((_) => kChannelId1),
          ],
          width: 1000,
          height: 420,
          light: light);
      await capture(tester, 'chat_pane_shell_desktop_$theme');
    });
  }
  testWidgets('chat shell phone light', (tester) async {
    await mount(tester,
        pane: strip(true),
        overrides: deviceProofOverrides(recovery: shell, reviews: fixtureReviews),
        width: 375,
        height: 420,
        light: true,
        touch: true);
    await capture(tester, 'chat_shell_phone_light');
  });
  for (final scale in [1.0, 2.0]) {
    final x = scale == 1.0 ? 'x1' : 'x2';
    testWidgets('chat shell 320 $x', (tester) async {
      await mount(tester,
          pane: strip(true),
          overrides:
              deviceProofOverrides(recovery: shell, reviews: fixtureReviews),
          width: 320,
          height: scale == 1.0 ? 520 : 1000,
          touch: true,
          scale: scale);
      await capture(tester, 'chat_shell_320_$x');
    });
  }

  // The lost-device review.
  testWidgets('review desktop dark', (tester) async {
    await mount(tester,
        pane: page(false),
        overrides: deviceProofOverrides(reviews: fixtureReviews),
        width: 900,
        height: 2000);
    await capture(tester, 'review_desktop_dark');
  });
  testWidgets('review phone light', (tester) async {
    await mount(tester,
        pane: page(true),
        overrides: deviceProofOverrides(reviews: fixtureReviews),
        width: 375,
        height: 3600,
        light: true,
        touch: true);
    await capture(tester, 'review_phone_light');
  });
  testWidgets('review 320 x2', (tester) async {
    await mount(tester,
        pane: page(true),
        overrides: deviceProofOverrides(reviews: fixtureReviews),
        width: 320,
        height: 7000,
        touch: true,
        scale: 2.0);
    await capture(tester, 'review_320_x2');
  });
  testWidgets('review put back on, applying', (tester) async {
    _api.hold = true;
    await mount(tester,
        pane: page(false),
        overrides: deviceProofOverrides(reviews: fixtureReviews),
        width: 900,
        height: 2000);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('put-back-$kChannelId1')),
        matching: find.byType(HollowToggle)));
    await tester.pump();
    await tester.tap(find.text('Apply selected'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await capture(tester, 'review_put_back_applying_desktop_dark');
  });
  testWidgets('review answered', (tester) async {
    await mount(tester,
        pane: page(false),
        overrides: deviceProofOverrides(reviews: fixtureReviews),
        width: 900,
        height: 1200);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('refold-item-k-ban')),
        matching: find.byType(HollowToggle)));
    await tester.pump();
    await tester.tap(find.text('Apply selected'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await capture(tester, 'review_answered_desktop_dark');
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets('review answered, one change stays', (tester) async {
    _api.changedSince = {'k-ban'};
    addTearDown(() => _api.changedSince = {});
    await mount(tester,
        pane: page(false),
        overrides: [
          ...deviceProofOverrides(reviews: fixtureReviews),
        ],
        width: 900,
        height: 1200);
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('refold-item-k-ban')),
        matching: find.byType(HollowToggle)));
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('refold-item-k-mute')),
        matching: find.byType(HollowToggle)));
    await tester.pump();
    await tester.tap(find.text('Apply selected'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await capture(tester, 'review_answered_changed_since_desktop_dark');
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets('keep all with a selection', (tester) async {
    await mount(tester,
        pane: page(false),
        overrides: deviceProofOverrides(reviews: fixtureReviews),
        width: 900,
        height: 1200);
    await tester.tap(find.text('Select all'));
    await tester.pump();
    await tester.tap(find.text('Keep all'));
    await settle(tester);
    await capture(tester, 'review_keep_all_selected_desktop_dark');
    await tester.pump(const Duration(seconds: 5));
  });

  // Vitalik's two 11-05 answers.
  const removed = dp.ServerRecovery(steppedBack: true, removedBy: kTomas);
  final channel = testChannels[kChannelId1]!;
  final selected = [
    selectedServerProvider.overrideWith((_) => kServerId1),
    selectedChannelProvider.overrideWith((_) => kChannelId1),
  ];
  testWidgets('composer removed desktop dark', (tester) async {
    await mount(tester,
        pane: ChannelChatPane(
          serverId: kServerId1,
          channelId: channel.channelId,
          channelName: channel.name,
        ),
        overrides: [...deviceProofOverrides(recovery: removed), ...selected],
        width: 1000,
        height: 360);
    await capture(tester, 'composer_removed_desktop_dark');
  });
  testWidgets('composer removed phone light', (tester) async {
    await mount(tester,
        pane: MobileChatRoute(
          serverId: kServerId1,
          channelId: channel.channelId,
          channelName: channel.name,
        ),
        overrides: [...deviceProofOverrides(recovery: removed), ...selected],
        width: 375,
        height: 640,
        light: true,
        touch: true);
    await capture(tester, 'composer_removed_phone_light');
  });
  testWidgets('joined with the phrase at start desktop dark', (tester) async {
    await mount(tester,
        pane: _StartHost(
            child: ChannelChatPane(
          serverId: kServerId1,
          channelId: channel.channelId,
          channelName: channel.name,
        )),
        overrides: [
          ...deviceProofOverrides(restores: pick),
          ...selected,
          rosterGateProvider.overrideWith(_Waiting.new),
        ],
        width: 1000,
        height: 620);
    await settle(tester);
    await capture(tester, 'joined_with_phrase_start_desktop_dark');
  });
}

/// A device the roster does not count yet when the start begins.
class _Waiting extends RosterGateNotifier {
  @override
  RosterGate build() => const RosterGate(kind: RosterGateKind.pending);
}

/// The shell's start, with the person joining with the phrase at the roster
/// lock while the start's own dialogs wait, then the start's chooser offer.
class _StartHost extends ConsumerStatefulWidget {
  final Widget child;
  const _StartHost({required this.child});

  @override
  ConsumerState<_StartHost> createState() => _StartHostState();
}

class _StartHostState extends ConsumerState<_StartHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final c = ProviderScope.containerOf(context, listen: false);
      final offers = RestoreChooserOffers(c,
          alive: () => mounted,
          show: ({required fresh}) => showRestoreChooser(context, fresh: fresh),
          fetch: () => c.read(restoreChoicesProvider.future));
      final counted = c.read(rosterGateProvider).kind == RosterGateKind.none;
      c.read(rosterGateProvider.notifier).restored();
      await offers.atStart(countedAtStart: counted);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
