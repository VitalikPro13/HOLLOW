/// The dock after the chrome pass: one selection mark whatever is active,
/// hover that adds nothing, badges the scroll never cuts, the call riding your
/// identity, the places toggling, and the Shop only where it may exist.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/conference_provider.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/shop_tab_provider.dart';
import 'package:hollow/src/core/providers/unread_provider.dart';
import 'package:hollow/src/core/providers/voice_channel_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_count_badge.dart';
import 'package:hollow/src/ui/components/nav_selection_mark.dart';
import 'package:hollow/src/ui/components/voice_here_badge.dart';
import 'package:hollow/src/ui/shell/bottom_bar.dart';

import '../helpers/test_app.dart';

const _folderId = 'folder-1';

Map<String, ServerInfo> _servers(int n) => {
      for (var i = 0; i < n; i++)
        's$i': ServerInfo(serverId: 's$i', name: 'Server $i'),
    };

class _Servers extends ServerListNotifier {
  final int n;
  _Servers(this.n);
  @override
  Map<String, ServerInfo> build() => _servers(n);
}

class _Strip extends ServerStripLayoutNotifier {
  final List<StripItem> items;
  _Strip(this.items);
  @override
  List<StripItem> build() => items;
}

class _Unread extends UnreadNotifier {
  final UnreadState seed;
  _Unread(this.seed);
  @override
  UnreadState build() => seed;
}

class _Voice extends VoiceChannelNotifier {
  final VoiceChannelState seed;
  _Voice(this.seed);
  @override
  VoiceChannelState build() => seed;
}

/// Three loose servers, then a folder holding s3 and s4.
List<StripItem> _layout(int n) => [
      for (var i = 0; i < n && i < 3; i++) ServerStripItem(serverId: 's$i'),
      if (n > 3)
        FolderStripItem(
          id: _folderId,
          name: 'Folder',
          serverIds: [for (var i = 3; i < n && i < 5; i++) 's$i'],
        ),
      for (var i = 5; i < n; i++) ServerStripItem(serverId: 's$i'),
    ];

Future<ProviderContainer> _pumpDock(
  WidgetTester tester, {
  int servers = 5,
  double width = 1400,
  bool shopAvailable = true,
  UnreadState unread = const UnreadState(),
  VoiceChannelState voice = const VoiceChannelState(),
}) async {
  tester.view.physicalSize = Size(width, 300);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: hollowTestOverrides(extra: [
      shopAvailableProvider.overrideWithValue(shopAvailable),
      serverListProvider.overrideWith(() => _Servers(servers)),
      serverStripLayoutProvider.overrideWith(() => _Strip(_layout(servers))),
      unreadProvider.overrideWith(() => _Unread(unread)),
      voiceChannelProvider.overrideWith(() => _Voice(voice)),
      overallConnectionProvider
          .overrideWithValue(OverallConnection.connected),
    ]),
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: BottomBar()),
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

Finder _label(String label) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );

Future<void> _tap(WidgetTester tester, String label) async {
  expect(_label(label), findsWidgets, reason: '"$label" should be on the dock');
  await tester.tap(_label(label).first, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectOneMark(String why) =>
    expect(find.byType(NavSelectionMark), findsOneWidget, reason: why);

void main() {
  testWidgets('exactly one selection mark, whatever is active',
      (tester) async {
    final c = await _pumpDock(tester);
    _expectOneMark('Home at rest');

    c.read(selectedPeerProvider.notifier).state = 'someone';
    await tester.pump();
    _expectOneMark('a DM counts as Home');

    c.read(selectedPeerProvider.notifier).state = null;
    c.read(selectedServerProvider.notifier).state = 's1';
    await tester.pump();
    _expectOneMark('a loose server');

    c.read(selectedServerProvider.notifier).state = 's4';
    await tester.pump();
    _expectOneMark('a server inside a folder marks the folder');

    c.read(selectedServerProvider.notifier).state = null;
    for (final tab in ShellTab.values) {
      setShellTab(c.read, tab);
      await tester.pump();
      _expectOneMark('the $tab place');
    }
  });

  testWidgets('hovering a tile adds no mark', (tester) async {
    await _pumpDock(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await gesture.moveTo(tester.getCenter(_label('Server 1').first));
    await tester.pump(const Duration(milliseconds: 300));
    _expectOneMark('hover is a surface step, never a bar');
    // Lets the tooltip's show and hide timers run out.
    await gesture.moveTo(Offset.zero);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a folder with a mention shows the @ badge, selected or not',
      (tester) async {
    final c = await _pumpDock(
      tester,
      unread: const UnreadState(
        channelUnreadCounts: {'s4:c': 3},
        channelMentionCounts: {'s4:c': 1},
      ),
    );
    Finder mentionBadge() => find.byWidgetPredicate(
        (w) => w is HollowCountBadge && w.mention && w.count == 1);
    expect(mentionBadge(), findsOneWidget);

    c.read(selectedServerProvider.notifier).state = 's4';
    await tester.pump();
    expect(mentionBadge(), findsOneWidget,
        reason: 'a selected folder keeps its count');
  });

  testWidgets('with many servers the scroll viewport is the dock height',
      (tester) async {
    await _pumpDock(tester, servers: 20);
    final row = find.byWidgetPredicate(
        (w) => w is EdgeScrollRow && w.semanticLabel == 'servers');
    expect(tester.getSize(row).height, kDockHeight,
        reason: 'a shorter viewport cuts the badges and the mark');
  });

  testWidgets('in a voice room: the room on your identity and three controls',
      (tester) async {
    await _pumpDock(
      tester,
      voice: const VoiceChannelState(
        currentServerId: 's1',
        currentChannelId: 'v1',
        currentChannelName: 'Jam room',
      ),
    );
    expect(find.text('Jam room · Server 1'), findsOneWidget);
    expect(_label('Mute'), findsWidgets);
    expect(_label('Deafen'), findsWidgets);
    expect(_label('Disconnect'), findsWidgets);
    expect(find.byType(VoiceHereBadge), findsOneWidget,
        reason: 'the server holding the call carries the speaker');
  });

  testWidgets('out of a call there are no call controls', (tester) async {
    await _pumpDock(tester);
    expect(_label('Disconnect'), findsNothing);
    expect(find.byType(VoiceHereBadge), findsNothing);
  });

  testWidgets('places toggle, and are exclusive', (tester) async {
    final c = await _pumpDock(tester);

    await _tap(tester, 'Conferences');
    expect(c.read(conferenceTabOpenProvider), isTrue);
    await _tap(tester, 'Conferences');
    expect(c.read(anyShellTabOpenProvider), isFalse,
        reason: 'a lit place un-lights (issue #28)');

    await _tap(tester, 'Archive');
    await _tap(tester, 'Hollow Shop');
    expect(c.read(openShellTabProvider), ShellTab.shop);
    expect(c.read(shopTabOpenProvider), isTrue);
  });

  /// Apple 3.1.1 and Play policy: a store build carries no shop surface at
  /// all, so the button is ABSENT rather than disabled.
  testWidgets('the Shop is absent on store builds', (tester) async {
    await _pumpDock(tester, shopAvailable: false);
    expect(_label('Hollow Shop'), findsNothing);
    expect(_label('Archive'), findsWidgets);
  });

  testWidgets('a narrow dock folds the places into one menu', (tester) async {
    await _pumpDock(tester, width: 900);
    expect(_label('Places'), findsWidgets);
    expect(_label('Archive'), findsNothing);

    await _tap(tester, 'Places');
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('Public channels'), findsOneWidget);
  });
}
