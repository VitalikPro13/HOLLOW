import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/channel_info.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/server_settings/delete_channel_confirm.dart';
import 'package:hollow/src/ui/server_settings/server_settings_catalog.dart';
import 'package:hollow/src/ui/settings/server_template.dart';

import '../helpers/test_app.dart';

/// The app-wide server and channel confirms: one wording each, the write runs
/// INSIDE the dialog (so a failure stays on screen), and the delete-channel
/// copy says what is true (messages stay on the devices that have them).
void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.fail = false;
    api.calls.clear();
  });

  late BuildContext host;
  late WidgetRef hostRef;
  late ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            host = context;
            hostRef = ref;
            container = ProviderScope.containerOf(context, listen: false);
            return const SizedBox.expand();
          }),
        ),
      ),
    ));
  }

  HollowButton button(WidgetTester tester, String label) =>
      tester.widget<HollowButton>(find.ancestor(
          of: find.text(label), matching: find.byType(HollowButton)));

  group('delete channel', () {
    testWidgets('says messages stay, and deletes inside the dialog',
        (tester) async {
      await pump(tester);
      final done = confirmDeleteChannel(host,
          serverId: 'srv', channelId: 'ch-1', channelName: 'general');
      await tester.pumpAndSettle();
      expect(find.text('Delete #general?'), findsOneWidget);
      expect(find.textContaining('stay on the devices'), findsOneWidget);
      expect(find.textContaining('go for everyone'), findsNothing);
      expect(button(tester, 'Delete channel').variant,
          HollowButtonVariant.danger);

      api.gate = Completer<void>();
      await tester.tap(find.text('Delete channel'));
      await tester.pump();
      expect(button(tester, 'Delete channel').loading, isTrue);
      expect(api.calls, ['removeChannel ch-1']);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(await done, isTrue);
      expect(find.text('Delete #general?'), findsNothing);
      api.gate = null;
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('a failure stays in the dialog', (tester) async {
      await pump(tester);
      api.fail = true;
      unawaited(confirmDeleteChannel(host,
          serverId: 'srv', channelId: 'ch-1', channelName: 'general'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete channel'));
      await tester.pumpAndSettle();
      expect(find.text('Delete #general?'), findsOneWidget);
      expect(find.textContaining('starting up'), findsOneWidget);
    });
  });

  group('leave and delete server', () {
    testWidgets('delete says it is for everyone and runs inside',
        (tester) async {
      await pump(tester);
      container.read(serverListProvider.notifier).state = {
        's1': const ServerInfo(serverId: 's1', name: 'Den'),
      };
      unawaited(confirmDeleteServer(host, hostRef, 's1'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Den?'), findsOneWidget);
      expect(find.textContaining('for everyone'), findsOneWidget);
      await tester.tap(find.text('Delete server'));
      await tester.pumpAndSettle();
      expect(api.calls, ['deleteServer s1']);
      expect(find.text('Delete Den?'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets('leaving another server keeps the one you are in selected',
        (tester) async {
      await pump(tester);
      container.read(serverListProvider.notifier).state = {
        's1': const ServerInfo(serverId: 's1', name: 'Den'),
        's2': const ServerInfo(serverId: 's2', name: 'Lab'),
      };
      container.read(selectedServerProvider.notifier).state = 's2';
      unawaited(confirmLeaveServer(host, hostRef, 's1'));
      await tester.pumpAndSettle();
      expect(find.text('Leave Den?'), findsOneWidget);
      await tester.tap(find.text('Leave server'));
      await tester.pumpAndSettle();
      expect(api.calls, ['leaveServer s1']);
      expect(container.read(selectedServerProvider), 's2');
      expect(container.read(serverSettingsOpenProvider), isFalse);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('apply template', () {
    const template = ServerTemplate(
        version: 1,
        name: 'Club',
        description: '',
        channels: [],
        channelLayout: []);

    testWidgets('removing channels is a danger confirm that says how many',
        (tester) async {
      await pump(tester);
      unawaited(showTemplateConfirmDialog(
          host,
          template,
          const TemplateDiff(channelsToRemove: [
            ChannelInfo(channelId: 'a', name: 'old'),
            ChannelInfo(channelId: 'b', name: 'older'),
          ])));
      await tester.pumpAndSettle();
      expect(button(tester, 'Apply and remove 2 channels').variant,
          HollowButtonVariant.danger);
      expect(find.textContaining('stay on the devices'), findsOneWidget);
      expect(find.textContaining('never deleted'), findsNothing);
    });

    testWidgets('no removals stays a plain filled confirm', (tester) async {
      await pump(tester);
      unawaited(showTemplateConfirmDialog(
          host, template, const TemplateDiff(nameChange: 'Club')));
      await tester.pumpAndSettle();
      expect(button(tester, 'Apply template').variant,
          HollowButtonVariant.filled);
      expect(find.textContaining('stay on the devices'), findsNothing);
    });
  });
}

class _Api implements RustLibApi {
  bool fail = false;
  Completer<void>? gate;
  final calls = <String>[];

  Future<void> _run(String call) async {
    calls.add(call);
    if (gate != null) await gate!.future;
    if (fail) throw 'Node is not running';
  }

  @override
  Future<void> crateApiCrdtRemoveChannel(
          {required String serverId, required String channelId}) =>
      _run('removeChannel $channelId');

  @override
  Future<void> crateApiCrdtDeleteServer({required String serverId}) =>
      _run('deleteServer $serverId');

  @override
  Future<void> crateApiCrdtLeaveServer({required String serverId}) =>
      _run('leaveServer $serverId');

  @override
  Future<void> crateApiNetworkLogFromDart({required String message}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
