/// The Home dashboard must stay reachable as the interface zoom shrinks the
/// logical viewport.
///
/// Its three columns are `Profile | Recent Conversations | Network`, but only
/// the middle one had a `ListView` — the side columns were plain `Column`s.
/// At 100% on a big window that is invisible because everything fits. Raise
/// the zoom and the viewport shrinks (`window / scale`): on a 1596x991 window
/// at 165% the dashboard gets ~580 logical px of height, and the profile
/// column's "Your Stats" card and the network column's news section were
/// clipped by the shell's `ClipRect` — no scrollbar, no way down.
///
/// The same sweep found two bare `Text`s in tight `Row`s — the shape the
/// `UserBar` fix had just dealt with: the "Recent Conversations" header (162px
/// over at ~800 logical wide, because that column is the `Expanded` one the
/// zoom squeezes first) and `StatBar`'s label/value row (8px over at EVERY
/// window size, because the `Spacer` between them claimed the free space).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/relay_bandwidth_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/stat_bar.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

/// Both notifiers reach for the network/FFI from `build()`, which cannot work
/// headless. Static state keeps the news panel rendering so it still occupies
/// (and can overflow) real space.
///
/// Two posts with real body text on purpose: the panel is only interesting
/// when it has more content than fits, which is what makes it scroll
/// internally instead of stretching the column.
class _StubNews extends NewsNotifier {
  @override
  NewsState build() => NewsState(hasFetched: true, posts: [
        NewsPost(
          id: '1',
          date: '2026-07-30',
          title: 'Hollow 0.9.1 is out',
          body: 'A body long enough that the panel has something to '
              'scroll through. ' * 4,
        ),
        NewsPost(
          id: '2',
          date: '2026-07-28',
          title: 'Wayland window sharing',
          body: 'Another post with a fair amount of text in it. ' * 4,
        ),
      ]);
}

class _StubUpdater extends UpdateNotifier {
  @override
  UpdateState build() => const UpdateState(currentVersion: '0.9.1');
}

/// Polls the relay over HTTP/FFI on a timer from `build()`.
class _StubRelayStats extends RelayStatsNotifier {
  @override
  RelayStats build() => const RelayStats();
}

/// Fires `request_relay_bandwidth()` from `build()`. Real numbers so the
/// relay card renders the long label/value pair that used to overflow.
class _StubBandwidth extends RelayBandwidthNotifier {
  @override
  RelayBandwidth build() =>
      const RelayBandwidth(usedBytes: 1200000, budgetBytes: 10000000000);
}

/// Viewports the desktop shell actually renders `HomeDashboard` at. Below 600
/// logical wide `hollow_shell` switches to `MobileShell`, so 640 is the floor
/// worth pinning — 798x480 is 200% zoom on the reporter's 1596x991 window,
/// and 967x581 is the 165% screenshot itself.
const _viewports = [
  Size(1280, 800),
  Size(967, 581),
  Size(798, 480),
  Size(640, 470),
];

Future<Set<String>> _pumpDashboard(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final overflows = <String>{};
  final prior = FlutterError.onError;
  // Collect from the handler, not `takeException`, which surfaces only the
  // first of several. Everything else is forwarded — swallowing errors
  // broadly is how a layout test starts passing against an empty tree.
  FlutterError.onError = (d) {
    final s = d.exceptionAsString();
    if (s.contains('overflow')) {
      // Include the creator location — "overflowed by 19px" alone does not
      // tell you which Row to go fix.
      final where = RegExp(r'(Row|Column|Flex)\b[^\n]*file:[^\s)]+')
          .firstMatch(d.toString());
      overflows.add('${s.split('\n').first}  <<${where?.group(0) ?? '?'}>>');
    } else {
      prior?.call(d);
    }
  };

  await tester.pumpWidget(
    ProviderScope(
      overrides: hollowTestOverrides(extra: [
        newsProvider.overrideWith(_StubNews.new),
        updaterProvider.overrideWith(_StubUpdater.new),
        relayStatsProvider.overrideWith(_StubRelayStats.new),
        relayBandwidthProvider.overrideWith(_StubBandwidth.new),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: HomeDashboard()),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
  FlutterError.onError = prior;
  return overflows;
}

void main() {
  group('side columns scroll', () {
    testWidgets('both side columns can scroll, not just the middle list',
        (tester) async {
      await _pumpDashboard(tester, const Size(967, 581));

      final bars = tester.widgetList<Scrollbar>(find.byType(Scrollbar));
      expect(bars, hasLength(2),
          reason: 'the profile and network columns must each scroll; without '
              'them their lower cards are clipped with no way to reach them');
      // Default fade, matching the Recent Conversations list beside them.
      // `thumbVisibility: true` pinned the thumb on screen permanently, which
      // reads as a stuck UI element rather than a hint.
      expect(bars.every((b) => b.thumbVisibility != true), isTrue,
          reason: 'the column scrollbar must fade like every other one');
    });

    /// The regression this guards: the news panel is supposed to absorb the
    /// network column's slack and scroll its posts INTERNALLY. Bounding it
    /// only by `Expanded` made its intrinsic height (both posts, unscrolled)
    /// inflate the column past the viewport, so the OUTER bar took over the
    /// scrolling and the panel never collapsed into its own.
    testWidgets('on a roomy window only the news panel scrolls, not the '
        'column around it', (tester) async {
      await _pumpDashboard(tester, const Size(1280, 800));

      final scrolling = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .map((s) => s.position.maxScrollExtent)
          .where((e) => e > 0)
          .toList();

      expect(scrolling, hasLength(1),
          reason: 'exactly one thing should scroll here — the news panel '
              'inside the network column, as it did before');
    });
  });

  group('no overflow as the zoom shrinks the viewport', () {
    for (final size in _viewports) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        final overflows = await _pumpDashboard(tester, size);
        // Landmark: if the tree had failed to build there would be nothing
        // left to overflow and this would pass vacuously.
        expect(find.text('Recent Conversations'), findsOneWidget);
        expect(overflows, isEmpty,
            reason: 'HomeDashboard overflowed at $size:\n  '
                '${overflows.join('\n  ')}');
      });
    }
  });

  group('column count follows the width', () {
    test('three columns while they fit, two once they do not', () {
      // Natural widths whenever there is room for them plus the centre list.
      expect(dashboardColumnWidths(1280).left, 240);
      expect(dashboardColumnWidths(1280).right, 260);

      // Squeezed but still three, at 200% zoom on a 1596px window.
      final at798 = dashboardColumnWidths(798);
      expect(at798.right, isNotNull);
      expect(at798.left, lessThan(240));
      expect(at798.left, greaterThan(240 * 0.85 - 0.01));

      // Below the three-column minimum the Network column drops rather than
      // every card inside it overflowing — squeezing to 62% made the relay
      // StatBars, the stats rows AND the conversation header all break.
      expect(dashboardColumnWidths(640).right, isNull);
      expect(dashboardColumnWidths(640).left, 240,
          reason: 'the profile column keeps its natural width once it is '
              'only sharing with the conversation list');
    });

    testWidgets('the Network column is present at 967 wide and gone at 640',
        (tester) async {
      await _pumpDashboard(tester, const Size(967, 581));
      expect(find.byType(StatBar), findsWidgets,
          reason: 'the relay card belongs on a normal-width dashboard');

      await _pumpDashboard(tester, const Size(640, 470));
      expect(find.byType(StatBar), findsNothing);
      expect(find.text('Recent Conversations'), findsOneWidget,
          reason: 'the conversation list is the one column that never drops');
    });
  });

  /// The 8px overflow the sweep turned up, as a standalone widget so it is
  /// pinned deterministically. This fired at EVERY window size — it was never
  /// a zoom bug, just an invisible one.
  group('StatBar fits a narrow card', () {
    Future<Set<String>> pumpBar(WidgetTester tester, double width) async {
      final overflows = <String>{};
      final prior = FlutterError.onError;
      FlutterError.onError = (d) {
        final s = d.exceptionAsString();
        if (s.contains('overflow')) {
          overflows.add(s.split('\n').first);
        } else {
          prior?.call(d);
        }
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: HollowThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: SizedBox(
                  width: width,
                  child: StatBar(
                    hollow: HollowTheme.of(context),
                    icon: LucideIcons.gauge,
                    // The real pair from the relay card in the report.
                    label: 'Daily Relay Data',
                    value: '480 / 7940 MB',
                    progress: 0.5,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      FlutterError.onError = prior;
      return overflows;
    }

    // 236 = the 260px network column minus its padding, which is where this
    // was overflowing in the field. The narrower cases are the zoom headroom.
    for (final width in const [236.0, 200.0, 160.0]) {
      testWidgets('no overflow at ${width.toInt()}px wide', (tester) async {
        final overflows = await pumpBar(tester, width);
        expect(overflows, isEmpty,
            reason: 'StatBar overflowed at ${width}px:\n  '
                '${overflows.join('\n  ')}');
      });
    }

    testWidgets('the value stays whole and the label ellipses', (tester) async {
      await pumpBar(tester, 160);
      // The number is the thing you came to read — it must never be the part
      // that gets truncated.
      expect(find.text('480 / 7940 MB'), findsOneWidget);
      final label = tester.widget<Text>(find.text('Daily Relay Data'));
      expect(label.overflow, TextOverflow.ellipsis);
    });
  });
}
