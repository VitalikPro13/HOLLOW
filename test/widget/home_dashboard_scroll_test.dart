/// Home must stay reachable and unbroken as the interface zoom shrinks the
/// logical viewport (a 1596x991 window at 200% leaves ~798x480).
///
/// Home is an inbox that fills the width plus a side panel anchored to the
/// right edge (design language 5.2). The inbox is ONE scroll view, so its
/// variable strips (Needs Attention, Get Set Up) can never push the list off
/// the bottom; the panel leaves below [kHomeRailBreakpoint].
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/changelog.dart';
import 'package:hollow/src/core/providers/home_setup_provider.dart';
import 'package:hollow/src/core/providers/news_provider.dart';
import 'package:hollow/src/core/providers/relay_stats_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/stat_bar.dart';
import 'package:hollow/src/ui/shell/home_dashboard.dart';
import 'package:hollow/src/ui/shell/home_rail.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

/// The notifiers reach for the network/FFI from `build()`, which cannot work
/// headless. A long post keeps the What's New card worth measuring.
class _StubNews extends NewsNotifier {
  @override
  NewsState build() => NewsState(hasFetched: true, posts: [
        NewsPost(
          id: '1',
          date: 'September 10, 2026',
          title: 'Linux call audio, self-hosted relays and personal emotes',
          body: 'A body long enough that the teaser has to clamp it. ' * 6,
        ),
      ]);
}

class _StubUpdater extends UpdateNotifier {
  @override
  UpdateState build() => const UpdateState(currentVersion: '0.11.1');
}

/// A person whose last opened changelog is older than the running build.
class _StubJustUpdated extends HomeSetupNotifier {
  @override
  HomeSetupState build() =>
      const HomeSetupState(loaded: true, changelogSeen: '0.11');
}

/// Polls the relay over HTTP on a timer from `build()`.
class _StubRelayStats extends RelayStatsNotifier {
  @override
  RelayStats build() => const RelayStats();
}

/// First run with the checklist showing: the tallest Home there is.
class _StubSetup extends HomeSetupNotifier {
  @override
  HomeSetupState build() => const HomeSetupState(loaded: true);
}

const _viewports = [
  Size(1280, 800),
  Size(967, 581),
  Size(798, 480),
  Size(640, 470),
];

Future<Set<String>> _pumpHome(WidgetTester tester, Size size,
    {HomeSetupNotifier Function() setup = _StubSetup.new}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final overflows = <String>{};
  final prior = FlutterError.onError;
  // Collect from the handler, not `takeException`, which surfaces only the
  // first of several. Everything else is forwarded.
  FlutterError.onError = (d) {
    final s = d.exceptionAsString();
    if (s.contains('overflow')) {
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
        homeSetupProvider.overrideWith(setup),
        relayStatsProvider.overrideWith(_StubRelayStats.new),
        // The real file, read here rather than through the asset bundle,
        // whose async load does not settle inside a widget test's fake clock.
        changelogProvider.overrideWith((ref) async =>
            parseChangelog(File('changelog.txt').readAsStringSync())),
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
  group('no overflow as the zoom shrinks the viewport', () {
    for (final size in _viewports) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}',
          (tester) async {
        final overflows = await _pumpHome(tester, size);
        // Landmark: if the tree had failed to build there would be nothing
        // left to overflow and this would pass vacuously. The inbox's own
        // scroll view, not its header: on a short viewport the checklist
        // pushes the header past the fold, where a sliver is never built.
        expect(find.byType(CustomScrollView), findsOneWidget);
        expect(overflows, isEmpty,
            reason: 'Home overflowed at $size:\n  ${overflows.join('\n  ')}');
      });
    }
  });

  group('layout follows the width', () {
    test('the rail shows from the breakpoint up and leaves below it', () {
      expect(homeShowsRail(1600), isTrue);
      expect(homeShowsRail(kHomeRailBreakpoint), isTrue);
      expect(homeShowsRail(kHomeRailBreakpoint - 1), isFalse);
    });

    testWidgets('the rail is anchored to the right edge, no gutter beyond it',
        (tester) async {
      await _pumpHome(tester, const Size(1280, 800));
      final panel = find
          .ancestor(of: find.byType(HomeRail), matching: find.byType(Container))
          .first;
      expect(tester.getTopRight(panel).dx, 1280,
          reason: 'an app pane runs to the window edge; a centred group with '
              'gutters beside it is a web-page layout');
      expect(tester.getSize(panel).width, kHomeRailWidth);
    });

    testWidgets('the rail is present at 1280 wide and gone at 798',
        (tester) async {
      await _pumpHome(tester, const Size(1280, 800));
      expect(find.byType(HomeRail), findsOneWidget);

      await _pumpHome(tester, const Size(798, 480));
      expect(find.byType(HomeRail), findsNothing);
      expect(find.byType(CustomScrollView), findsOneWidget,
          reason: 'the inbox is the column that never leaves');
    });

    testWidgets('a first run shows the setup checklist', (tester) async {
      await _pumpHome(tester, const Size(1280, 800));
      expect(find.text('Get Set Up'), findsOneWidget);
      expect(find.text('Back up your recovery phrase'), findsOneWidget);
    });
  });

  testWidgets('the panel is News, Relay and Active Now', (tester) async {
    await _pumpHome(tester, const Size(1280, 800));
    await tester.pump();
    expect(find.text('News'), findsOneWidget);
    expect(find.text('Relay'), findsOneWidget);
    expect(find.text('Active Now'), findsOneWidget);
    expect(find.text("What's new in 0.11.1"), findsOneWidget);
  });

  testWidgets('the first launch after an update leads with what changed',
      (tester) async {
    await _pumpHome(tester, const Size(1280, 800),
        setup: _StubJustUpdated.new);
    await tester.pump();
    expect(find.text('Updated to 0.11.1'), findsOneWidget);
    expect(find.text("See everything that's new"), findsOneWidget);
  });

  test('the news teaser is plain text from the first paragraph', () {
    expect(
      plainNewsExcerpt('## Heading\n\nCalls got **steadier**, see '
          '[the post](https://x.y).\n\nSecond paragraph.'),
      'Calls got steadier, see the post.',
    );
  });

  /// StatBar now lives in Settings > Network (the relay card), where it still
  /// shares a row with its value at narrow widths.
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
                    label: 'Daily relay data',
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
      expect(find.text('480 / 7940 MB'), findsOneWidget);
      final label = tester.widget<Text>(find.text('Daily relay data'));
      expect(label.overflow, TextOverflow.ellipsis);
    });
  });
}
