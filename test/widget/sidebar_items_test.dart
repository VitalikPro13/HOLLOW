/// Issue #141: the optional places beside the servers (Public channels,
/// Share, Archive, Conferences, the Shop) can each be hidden from the Classic
/// rail and the dock, Home never; every hidden place still opens from the Home
/// menu; the Shop sits at the bottom of the rail beside the guides.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/server_info.dart';
import 'package:hollow/src/core/models/strip_item.dart';
import 'package:hollow/src/core/providers/connection_status_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/core/providers/server_strip_layout_provider.dart';
import 'package:hollow/src/core/providers/shell_tab.dart';
import 'package:hollow/src/core/providers/sidebar_items_provider.dart';
import 'package:hollow/src/core/shop_availability.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/components/nav_selection_mark.dart';
import 'package:hollow/src/ui/settings/appearance_section.dart';
import 'package:hollow/src/ui/shell/bottom_bar.dart';
import 'package:hollow/src/ui/shell/server_strip.dart';
import 'package:hollow/src/ui/shell/sidebar_places.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

class _Hidden extends HiddenSidebarItemsNotifier {
  final Set<SidebarItem> seed;
  final bool failSaves;
  _Hidden(this.seed, {this.failSaves = false});
  @override
  Set<SidebarItem> build() => seed;
  @override
  Future<String?> readSaved() async => HiddenSidebarItemsNotifier.encode(seed);
  @override
  Future<void> writeSaved(String value) async {
    if (failSaves) throw Exception('kaboom');
  }
}

/// The notifier over an in-memory store, for the save and load rules.
class _Mem extends HiddenSidebarItemsNotifier {
  String? stored;
  final bool readThrows;
  final bool writeThrows;
  final List<String> writes = [];

  /// Holds the FIRST write until completed, to race a second one past it.
  Completer<void>? holdFirst;

  _Mem({this.stored, this.readThrows = false, this.writeThrows = false});

  @override
  Future<String?> readSaved() async {
    if (readThrows) throw Exception('store not open');
    return stored;
  }

  @override
  Future<void> writeSaved(String value) async {
    if (writeThrows) throw Exception('disk full');
    final hold = holdFirst;
    if (hold != null && writes.isEmpty) {
      holdFirst = null;
      await hold.future;
    }
    writes.add(value);
    stored = value;
  }
}

_Mem _mem(ProviderContainer c) =>
    c.read(hiddenSidebarItemsProvider.notifier) as _Mem;

ProviderContainer _memContainer(_Mem m) {
  final c = ProviderContainer(
      overrides: [hiddenSidebarItemsProvider.overrideWith(() => m)]);
  addTearDown(c.dispose);
  return c;
}

class _Servers extends ServerListNotifier {
  @override
  Map<String, ServerInfo> build() => {
        for (var i = 0; i < 3; i++)
          's$i': ServerInfo(serverId: 's$i', name: 'Server $i'),
      };
}

class _Strip extends ServerStripLayoutNotifier {
  @override
  List<StripItem> build() =>
      [for (var i = 0; i < 3; i++) ServerStripItem(serverId: 's$i')];
}

List<Override> _overrides(
        Set<SidebarItem> hidden, bool shopAvailable, bool failSaves) =>
    hollowTestOverrides(extra: [
      hiddenSidebarItemsProvider
          .overrideWith(() => _Hidden(hidden, failSaves: failSaves)),
      shopAvailableProvider.overrideWithValue(shopAvailable),
      serverListProvider.overrideWith(_Servers.new),
      serverStripLayoutProvider.overrideWith(_Strip.new),
      overallConnectionProvider.overrideWithValue(OverallConnection.connected),
    ]);

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget body, {
  Set<SidebarItem> hidden = const {},
  bool shopAvailable = true,
  Size size = const Size(1400, 900),
  bool failSaves = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final container =
      ProviderContainer(
          overrides: _overrides(hidden, shopAvailable, failSaves));
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: Scaffold(body: body),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

Future<ProviderContainer> _pumpClassic(WidgetTester tester,
        {Set<SidebarItem> hidden = const {}, bool shopAvailable = true}) =>
    _pump(tester, const Row(children: [ServerStrip()]),
        hidden: hidden, shopAvailable: shopAvailable);

Future<ProviderContainer> _pumpDock(WidgetTester tester,
        {Set<SidebarItem> hidden = const {},
        bool shopAvailable = true,
        double width = 1400}) =>
    _pump(
      tester,
      const Align(alignment: Alignment.bottomCenter, child: BottomBar()),
      hidden: hidden,
      shopAvailable: shopAvailable,
      size: Size(width, 300),
    );

Finder _label(String label) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.label == label,
    );

Future<void> _rightClick(WidgetTester tester, String label) async {
  expect(_label(label), findsWidgets, reason: '"$label" should be shown');
  await tester.tap(_label(label).first,
      buttons: kSecondaryButton, warnIfMissed: false);
  await tester.pump(const Duration(milliseconds: 300));
}

/// [label] on the rail or the dock itself, not in a menu or tooltip above it.
Finder _onBar(String label) => find.descendant(
      of: find.byWidgetPredicate((w) => w is ServerStrip || w is BottomBar),
      matching: _label(label),
    );

Color? _iconColor(WidgetTester tester, Type bar, IconData icon) => tester
    .widget<Icon>(find.descendant(
        of: find.byType(bar), matching: find.byIcon(icon)))
    .color;

Color _accent(WidgetTester tester, Type bar) =>
    HollowTheme.of(tester.element(find.byType(bar))).accent;

/// Lets toasts and tooltip timers run out before the test ends.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 10));
}

Future<void> _tapText(WidgetTester tester, String text) async {
  await tester.tap(find.text(text).last, warnIfMissed: false);
  // A menu row acts as its exit animation ends, so one more frame shows it.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

const _placeLabels = {
  SidebarItem.publicChannels: 'Public channels',
  SidebarItem.share: 'Share',
  SidebarItem.archive: 'Archive',
  SidebarItem.conferences: 'Conferences',
  SidebarItem.shop: 'Hollow Shop',
};

/// Every subset of the five places, for the exhaustive checks.
Iterable<Set<SidebarItem>> _allSubsets() sync* {
  const all = SidebarItem.values;
  for (var mask = 0; mask < (1 << all.length); mask++) {
    yield {
      for (var i = 0; i < all.length; i++)
        if (mask & (1 << i) != 0) all[i],
    };
  }
}

void main() {
  group('the hidden set', () {
    test('a new or existing install hides nothing', () {
      expect(HiddenSidebarItemsNotifier.decode(null), isEmpty);
      expect(HiddenSidebarItemsNotifier.decode(''), isEmpty);
    });

    test('round-trips, and skips a name this build does not know', () {
      for (final hidden in _allSubsets()) {
        expect(
          HiddenSidebarItemsNotifier.decode(
              HiddenSidebarItemsNotifier.encode(hidden)),
          hidden,
        );
      }
      expect(HiddenSidebarItemsNotifier.decode('archive\nfuture_place\nshop'),
          {SidebarItem.archive, SidebarItem.shop});
    });

    test('the saved names never change', () {
      expect([for (final i in SidebarItem.values) i.key], [
        'public_channels',
        'share',
        'archive',
        'conferences',
        'shop',
      ]);
    });

    test('setShown hides and shows one place, at once', () async {
      final c = _memContainer(_Mem());
      final n = _mem(c);
      await n.load();
      final saved = n.setShown(SidebarItem.archive, false);
      expect(c.read(hiddenSidebarItemsProvider), {SidebarItem.archive},
          reason: 'shown before the save lands');
      await saved;
      await n.setShown(SidebarItem.share, false);
      await n.setShown(SidebarItem.archive, true);
      expect(c.read(hiddenSidebarItemsProvider), {SidebarItem.share});
      expect(n.writes, ['archive', 'share\narchive', 'share']);
    });

    test('never saves before reading what is stored', () async {
      final c = _memContainer(_Mem(stored: 'archive'));
      final n = _mem(c);
      await n.setShown(SidebarItem.share, false);
      expect(HiddenSidebarItemsNotifier.decode(n.writes.single),
          {SidebarItem.share, SidebarItem.archive},
          reason: 'the stored Archive survives a change made before load');
    });

    test('a store that cannot be read saves nothing and says so', () async {
      final c = _memContainer(_Mem(readThrows: true));
      final n = _mem(c);
      await n.load();
      await expectLater(n.setShown(SidebarItem.share, false), throwsException);
      expect(n.writes, isEmpty);
      expect(c.read(hiddenSidebarItemsProvider), isEmpty);
    });

    test('fast toggles save in the order they were made', () async {
      final c = _memContainer(_Mem());
      final n = _mem(c);
      await n.load();
      final hold = n.holdFirst = Completer<void>();
      final first = n.setShown(SidebarItem.archive, false);
      final second = n.setShown(SidebarItem.archive, true);
      await Future<void>.delayed(Duration.zero);
      hold.complete();
      await Future.wait([first, second]);
      expect(n.writes, ['archive', '']);
      expect(n.stored, '', reason: 'the last change made is the one kept');
    });

    test('names from a newer build are kept and written back', () async {
      final c = _memContainer(_Mem(stored: 'future_place\narchive'));
      final n = _mem(c);
      await n.load();
      expect(c.read(hiddenSidebarItemsProvider), {SidebarItem.archive});
      await n.setShown(SidebarItem.share, false);
      expect(n.writes.single.split('\n'),
          containsAll(['future_place', 'share', 'archive']));
    });

    test('a failed save reaches the caller', () async {
      final c = _memContainer(_Mem(writeThrows: true));
      final n = _mem(c);
      await n.load();
      await expectLater(n.setShown(SidebarItem.share, false), throwsException);
    });
  });

  group('reachability', () {
    test('every available place is shown or offered by Home, exactly once',
        () {
      for (final shop in [true, false]) {
        final available = sidebarItemsAvailable(shopAvailable: shop);
        for (final open in <ShellTab?>[null, ...ShellTab.values]) {
          for (final hidden in _allSubsets()) {
            final why = 'hidden=$hidden shop=$shop open=$open';
            final shown =
                sidebarItemsShown(hidden, shopAvailable: shop, open: open);
            final offered =
                sidebarItemsHidden(hidden, shopAvailable: shop, open: open);
            expect({...shown, ...offered}, available.toSet(), reason: why);
            expect(shown.length + offered.length, available.length,
                reason: 'no place twice, $why');
            for (final item in available) {
              final expected = hidden.contains(item) && item.tab != open;
              expect(offered.contains(item), expected, reason: '$item $why');
            }
          }
        }
      }
    });

    test('a hidden place shows only while it is the open tab', () {
      const hidden = {SidebarItem.archive};
      expect(sidebarItemsShown(hidden, shopAvailable: true),
          isNot(contains(SidebarItem.archive)));
      expect(
          sidebarItemsShown(hidden,
              shopAvailable: true, open: ShellTab.archive),
          contains(SidebarItem.archive));
      expect(
          sidebarItemsShown(hidden, shopAvailable: true, open: ShellTab.share),
          isNot(contains(SidebarItem.archive)));
    });

    test('a store build neither shows nor offers the Shop', () {
      expect(sidebarItemsAvailable(shopAvailable: false),
          isNot(contains(SidebarItem.shop)));
      expect(
          sidebarItemsHidden({SidebarItem.shop}, shopAvailable: false), isEmpty);
    });
  });

  group('Classic rail', () {
    testWidgets('by default every place shows, as today', (tester) async {
      await _pumpClassic(tester);
      expect(_label('Home'), findsWidgets);
      for (final label in _placeLabels.values) {
        expect(_label(label), findsWidgets, reason: label);
      }
    });

    testWidgets('the Shop sits at the bottom beside the guides',
        (tester) async {
      await _pumpClassic(tester);
      final shopY = tester.getCenter(_label('Hollow Shop').first).dy;
      final guidesY = tester.getCenter(_label('App guides').first).dy;
      final lastServerY = tester.getCenter(find.text('S2').first).dy;
      final conferencesY = tester.getCenter(_label('Conferences').first).dy;
      expect(shopY, greaterThan(lastServerY),
          reason: 'below the servers, not above them');
      expect(shopY, lessThan(guidesY), reason: 'directly above App guides');
      expect(guidesY - shopY, lessThan(64), reason: 'beside the guides');
      expect(conferencesY, lessThan(lastServerY));
    });

    testWidgets('hidden places leave the rail, Home stays', (tester) async {
      await _pumpClassic(tester, hidden: {
        SidebarItem.archive,
        SidebarItem.conferences,
        SidebarItem.shop,
      });
      expect(_label('Home'), findsWidgets);
      expect(_label('Archive'), findsNothing);
      expect(_label('Conferences'), findsNothing);
      expect(_label('Hollow Shop'), findsNothing);
      expect(_label('Public channels'), findsWidgets);
      expect(_label('Share'), findsWidgets);
    });

    testWidgets('Home has no hide', (tester) async {
      await _pumpClassic(tester);
      await _rightClick(tester, 'Home');
      expect(find.textContaining('Hide from'), findsNothing);
    });

    testWidgets('right-click Hide from sidebar hides the place and says how '
        'to get it back', (tester) async {
      final c = await _pumpClassic(tester);
      await _rightClick(tester, 'Archive');
      await _tapText(tester, 'Hide from sidebar');
      expect(c.read(hiddenSidebarItemsProvider), {SidebarItem.archive});
      expect(_onBar('Archive'), findsNothing);
      expect(find.text(sidebarItemHiddenMessage(SidebarItem.archive)),
          findsOneWidget);
      expect(sidebarItemHiddenMessage(SidebarItem.archive).toLowerCase(),
          isNot(contains('click')),
          reason: 'touch has no right click, so the copy names no gesture');
      await _drain(tester);
    });

    testWidgets('a hide that cannot be saved says so, not that it is hidden',
        (tester) async {
      await _pump(tester, const Row(children: [ServerStrip()]),
          failSaves: true);
      await _rightClick(tester, 'Archive');
      await _tapText(tester, 'Hide from sidebar');
      await tester.pump();
      expect(find.text(kSidebarItemSaveFailed), findsOneWidget);
      expect(find.text(sidebarItemHiddenMessage(SidebarItem.archive)),
          findsNothing);
      await _drain(tester);
    });

    testWidgets('the Home menu opens each hidden place, and only those',
        (tester) async {
      for (final item in sidebarItemsAvailable(shopAvailable: true)) {
        final c = await _pumpClassic(tester, hidden: {item});
        await _rightClick(tester, 'Home');
        expect(find.text('Hidden places'), findsOneWidget);
        for (final other in _placeLabels.entries) {
          expect(find.text(other.value),
              other.key == item ? findsOneWidget : findsNothing,
              reason: 'menu row for ${other.value} with $item hidden');
        }
        await _tapText(tester, _placeLabels[item]!);
        expect(c.read(openShellTabProvider), item.tab,
            reason: '$item opens from the Home menu');
        await _drain(tester);
      }
    });

    testWidgets('a hidden place that is open shows, marked, until you leave',
        (tester) async {
      final c = await _pumpClassic(tester, hidden: {SidebarItem.archive});
      expect(_onBar('Archive'), findsNothing);
      await _rightClick(tester, 'Home');
      await _tapText(tester, 'Archive');
      expect(c.read(openShellTabProvider), ShellTab.archive);
      expect(_onBar('Archive'), findsWidgets,
          reason: 'where you are keeps its button');
      expect(_iconColor(tester, ServerStrip, LucideIcons.archive),
          _accent(tester, ServerStrip),
          reason: 'and its selected look');
      // Home no longer offers what already shows.
      await _rightClick(tester, 'Home');
      expect(find.text('Hidden places'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      // Its menu offers it back rather than a second hide.
      await _rightClick(tester, 'Archive');
      expect(find.text('Show in sidebar'), findsOneWidget);
      expect(find.text('Hide from sidebar'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(_onBar('Home').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(c.read(openShellTabProvider), isNull);
      expect(_onBar('Archive'), findsNothing, reason: 'gone once you leave');
      await _drain(tester);
    });

    testWidgets('Show in sidebar on an open hidden place keeps it',
        (tester) async {
      final c = await _pumpClassic(tester, hidden: {SidebarItem.share});
      await _rightClick(tester, 'Home');
      await _tapText(tester, 'Share');
      await _rightClick(tester, 'Share');
      await _tapText(tester, 'Show in sidebar');
      expect(c.read(hiddenSidebarItemsProvider), isEmpty);
      await tester.tap(_onBar('Home').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_onBar('Share'), findsWidgets);
      await _drain(tester);
    });

    testWidgets('a touch long press on Home opens the Home menu',
        (tester) async {
      await _pumpClassic(tester, hidden: SidebarItem.values.toSet());
      await tester.longPress(_onBar('Home').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Hidden places'), findsOneWidget);
    });

    testWidgets('a mouse long press on Home opens nothing', (tester) async {
      await _pumpClassic(tester, hidden: SidebarItem.values.toSet());
      await tester.longPress(_onBar('Home').first,
          kind: PointerDeviceKind.mouse, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Hidden places'), findsNothing);
    });

    testWidgets('a long press on a place or a server opens no menu',
        (tester) async {
      await _pumpClassic(tester);
      await tester.longPress(_onBar('Archive').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Hide from sidebar'), findsNothing);
    });

    testWidgets('keyboard: Shift+F10 on a focused Home opens the Home menu',
        (tester) async {
      await _pumpClassic(tester, hidden: SidebarItem.values.toSet());
      final home = tester.element(_onBar('Home').first);
      bool homeFocused() {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused == null) return false;
        var hit = false;
        void walk(Element e) {
          if (e == focused) hit = true;
          if (!hit) e.visitChildElements(walk);
        }

        walk(home);
        return hit;
      }

      for (var tabs = 0; !homeFocused() && tabs < 30; tabs++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
      }
      expect(homeFocused(), isTrue, reason: 'Home takes keyboard focus');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Hidden places'), findsOneWidget);
    });

    testWidgets('nothing hidden: the Home menu offers no places',
        (tester) async {
      await _pumpClassic(tester);
      await _rightClick(tester, 'Home');
      expect(find.text('Mark all DMs as read'), findsOneWidget);
      expect(find.text('Hidden places'), findsNothing);
    });
  });

  group('Dock', () {
    testWidgets('hidden places leave the dock and open from Home',
        (tester) async {
      final c = await _pumpDock(tester, hidden: {SidebarItem.share});
      expect(_label('Share'), findsNothing);
      expect(_label('Archive'), findsWidgets);
      await _rightClick(tester, 'Home');
      expect(find.text('Hidden places'), findsOneWidget);
      await _tapText(tester, 'Share');
      expect(c.read(openShellTabProvider), ShellTab.share);
      await _drain(tester);
    });

    testWidgets('the dock keeps its own order, Conferences first',
        (tester) async {
      await _pumpDock(tester);
      final xs = [
        for (final label in [
          'Conferences',
          'Public channels',
          'Share',
          'Archive',
          'Hollow Shop',
        ])
          tester.getCenter(_onBar(label).first).dx,
      ];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i], greaterThan(xs[i - 1]), reason: 'place $i');
      }
    });

    testWidgets('a hidden place that is open shows with the one mark, until '
        'you leave', (tester) async {
      final c = await _pumpDock(tester, hidden: {SidebarItem.share});
      await _rightClick(tester, 'Home');
      await _tapText(tester, 'Share');
      expect(c.read(openShellTabProvider), ShellTab.share);
      expect(_onBar('Share'), findsWidgets);
      expect(find.byType(NavSelectionMark), findsOneWidget);
      final markX = tester.getCenter(find.byType(NavSelectionMark)).dx;
      expect((markX - tester.getCenter(_onBar('Share').first).dx).abs(),
          lessThan(4), reason: 'the mark sits over Share');
      await tester.tap(_onBar('Home').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(_onBar('Share'), findsNothing);
      await _drain(tester);
    });

    testWidgets('a folded dock marks and lists an open hidden place',
        (tester) async {
      final c = await _pumpDock(tester,
          width: 900, hidden: SidebarItem.values.toSet());
      expect(_label('Places'), findsNothing);
      await _rightClick(tester, 'Home');
      await _tapText(tester, 'Archive');
      expect(c.read(openShellTabProvider), ShellTab.archive);
      expect(_label('Places'), findsWidgets);
      expect(find.byType(NavSelectionMark), findsOneWidget);
      await tester.tap(_label('Places').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Share'), findsNothing);
      await _drain(tester);
    });

    testWidgets('right-click Hide from dock', (tester) async {
      final c = await _pumpDock(tester);
      await _rightClick(tester, 'Conferences');
      await _tapText(tester, 'Hide from dock');
      expect(c.read(hiddenSidebarItemsProvider), {SidebarItem.conferences});
      expect(_onBar('Conferences'), findsNothing);
      await _drain(tester);
    });

    testWidgets('a touch long press on the dock Home opens the Home menu',
        (tester) async {
      await _pumpDock(tester, hidden: SidebarItem.values.toSet());
      await tester.longPress(_onBar('Home').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Hidden places'), findsOneWidget);
    });

    testWidgets('a folded dock hides a place from its own menu',
        (tester) async {
      final c = await _pumpDock(tester, width: 900);
      await tester.tap(_label('Places').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      await _tapText(tester, 'Hide from dock');
      await _tapText(tester, 'Archive');
      expect(c.read(hiddenSidebarItemsProvider), {SidebarItem.archive});
      await _drain(tester);
    });

    testWidgets('a folded dock lists only the shown places', (tester) async {
      await _pumpDock(tester, width: 900, hidden: {SidebarItem.archive});
      await tester.tap(_label('Places').first, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Archive'), findsNothing);
      expect(find.text('Public channels'), findsOneWidget);
    });

    testWidgets('everything hidden: no Places button', (tester) async {
      await _pumpDock(tester,
          width: 900, hidden: SidebarItem.values.toSet());
      expect(_label('Places'), findsNothing);
      expect(_label('Home'), findsWidgets);
    });
  });

  group('Appearance setting', () {
    Future<ProviderContainer> pumpSection(WidgetTester tester,
            {bool shopAvailable = true}) =>
        _pump(
          tester,
          const SingleChildScrollView(child: SidebarItemsSection()),
          shopAvailable: shopAvailable,
        );

    testWidgets('one switch per place, all on; Home has none and says so',
        (tester) async {
      await pumpSection(tester);
      expect(find.text('Places'), findsOneWidget);
      expect(find.textContaining('Home always shows'), findsOneWidget);
      final toggles =
          tester.widgetList<HollowToggle>(find.byType(HollowToggle)).toList();
      expect(toggles, hasLength(5));
      expect(toggles.every((t) => t.value && t.onChanged != null), isTrue);
      expect(toggles.map((t) => t.semanticLabel), isNot(contains('Home')));
    });

    testWidgets('a change that cannot be saved says so', (tester) async {
      await _pump(
        tester,
        const SingleChildScrollView(child: SidebarItemsSection()),
        failSaves: true,
      );
      await tester.tap(find.byWidgetPredicate(
          (w) => w is HollowToggle && w.semanticLabel == 'Archive'));
      await tester.pump();
      await tester.pump();
      expect(find.text(kSidebarItemSaveFailed), findsOneWidget);
      await _drain(tester);
    });

    testWidgets('turning a place off hides it, on brings it back',
        (tester) async {
      final c = await pumpSection(tester);
      final archive = find.byWidgetPredicate(
          (w) => w is HollowToggle && w.semanticLabel == 'Archive');
      await tester.tap(archive);
      await tester.pump();
      expect(c.read(hiddenSidebarItemsProvider), {SidebarItem.archive});
      await tester.tap(archive);
      await tester.pump();
      expect(c.read(hiddenSidebarItemsProvider), isEmpty);
    });

    testWidgets('a store build has no Shop switch', (tester) async {
      await pumpSection(tester, shopAvailable: false);
      expect(find.byType(HollowToggle), findsNWidgets(4));
      expect(find.text('Hollow Shop'), findsNothing);
    });
  });
}
