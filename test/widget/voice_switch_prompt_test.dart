import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/settings/audio_section.dart';
import 'package:hollow/src/ui/shell/voice_room_switch.dart';

import '../helpers/test_app.dart';

/// Issue #106: "Switch voice room?" offers "Don't ask again", and a settings
/// row turns the question back on. Asking stays the default.
class _Voice extends VoiceChannelNotifier {
  _Voice(this.initial);
  final VoiceChannelState initial;
  @override
  VoiceChannelState build() => initial;
}

/// The stored answer without a store; [saved] records every write.
class _Ask extends AskBeforeVoiceSwitchNotifier {
  _Ask(this.initial, this.saved);
  final bool initial;
  final List<bool> saved;
  @override
  Future<bool> build() async => initial;
  @override
  Future<void> setEnabled(bool enabled) async {
    saved.add(enabled);
    state = AsyncData(enabled);
  }
}

void main() {
  const self = 'dev-self';
  const busyRoom = VoiceChannelState(
    participants: {
      's1': {
        'lobby': {self, 'someone'},
      },
    },
    currentServerId: 's1',
    currentChannelId: 'lobby',
    currentChannelName: 'lobby',
  );

  late BuildContext host;
  late WidgetRef hostRef;
  late List<bool> saved;

  Future<Future<bool>> ask(WidgetTester tester, {required bool askFirst}) async {
    saved = [];
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        voiceChannelProvider.overrideWith(() => _Voice(busyRoom)),
        localDevicePeerIdProvider.overrideWith((ref) async => self),
        askBeforeVoiceSwitchProvider.overrideWith(() => _Ask(askFirst, saved)),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            host = context;
            hostRef = ref;
            return const SizedBox.expand();
          }),
        ),
      ),
    ));
    await ProviderScope.containerOf(host)
        .read(localDevicePeerIdProvider.future);
    final answer = confirmVoiceRoomSwitch(host, hostRef,
        serverId: 's1', channelId: 'stage', channelName: 'stage');
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('the question offers "Don\'t ask again", off by default',
      (tester) async {
    final answer = await ask(tester, askFirst: true);
    expect(find.text('Switch voice room?'), findsOneWidget);
    expect(find.text("Don't ask again"), findsOneWidget);
    expect(tester.widget<HollowToggle>(find.byType(HollowToggle)).value,
        isFalse);
    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
    expect(saved, isEmpty, reason: 'switching alone keeps asking');
  });

  testWidgets('"Don\'t ask again" then Switch stops the question',
      (tester) async {
    final answer = await ask(tester, askFirst: true);
    await tester.tap(find.text("Don't ask again"));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
    expect(saved, [false]);
  });

  testWidgets('"Don\'t ask again" then Cancel changes nothing', (tester) async {
    final answer = await ask(tester, askFirst: true);
    await tester.tap(find.byType(HollowToggle));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
    expect(saved, isEmpty);
  });

  testWidgets('with the question off, a busy room switches straight away',
      (tester) async {
    final answer = await ask(tester, askFirst: false);
    expect(find.byType(HollowDialog), findsNothing);
    expect(await answer, isTrue);
  });

  testWidgets('the settings row turns the question back on', (tester) async {
    saved = [];
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        askBeforeVoiceSwitchProvider.overrideWith(() => _Ask(false, saved)),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: VoiceSwitchPromptRow()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Ask before switching voice rooms'), findsOneWidget);
    expect(tester.widget<HollowToggle>(find.byType(HollowToggle)).value,
        isFalse);
    await tester.tap(find.byType(HollowToggle));
    await tester.pumpAndSettle();
    expect(saved, [true]);
    expect(tester.widget<HollowToggle>(find.byType(HollowToggle)).value,
        isTrue);
  });

  test('asking is the default', () {
    expect(kAskBeforeVoiceSwitchDefault, isTrue);
  });
}
