import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/status_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/shell/system_status_banner.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

/// The system status banner (0.14.1): a days unit on long countdowns, tabular
/// figures only where digits tick each second, and a phone layout that keeps
/// the title readable instead of squeezing title, message and countdown into
/// one line.
class _Status extends StatusNotifier {
  _Status(this.fixed);
  final StatusState fixed;

  @override
  StatusState build() => fixed;
}

const _long =
    'Hollow for iPhone and iPad is now on the App Store, and the TestFlight '
    'beta ends on November 22. The App Store version is the same app.';


const _longTitle =
    'Scheduled relay maintenance for the European region this weekend';

Future<void> _pumpNotice(WidgetTester tester, Size size,
    {required String title, required String message, String link = ''}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  await tester.pumpWidget(ProviderScope(
    overrides: hollowTestOverrides(extra: [
      statusProvider.overrideWith(() => _Status(StatusState(
            hasFetched: true,
            notices: [
              SystemStatus(
                id: 'a',
                level: StatusLevel.maintenance,
                title: title,
                message: message,
                until: DateTime.now()
                    .toUtc()
                    .add(const Duration(days: 5, hours: 10, minutes: 1)),
                untilLabel: 'Starts in',
                link: link,
                linkLabel: 'Details',
                expires: DateTime.utc(2099),
              ),
            ],
          ))),
    ]),
    child: MaterialApp(
      theme: HollowThemeData.dark(),
      home: const Scaffold(
        body: Column(children: [SystemStatusBanner(), Spacer()]),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _expand(WidgetTester tester) async {
  await tester.tap(find.byIcon(LucideIcons.chevronDown));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

bool _clipped(WidgetTester tester, Finder text) {
  final p = tester.renderObject<RenderParagraph>(text);
  return p.didExceedMaxLines ||
      p.size.height < p.getMaxIntrinsicHeight(p.size.width) - 0.5;
}

void main() {
  group('formatStatusCountdown', () {
    test('days from 48 hours on', () {
      expect(formatStatusCountdown(const Duration(hours: 130, minutes: 36)),
          '5d 10h');
      expect(formatStatusCountdown(const Duration(hours: 48)), '2d 0h');
    });

    test('hours and minutes under 48 hours', () {
      expect(formatStatusCountdown(const Duration(hours: 47, minutes: 59)),
          '47h 59m');
      expect(formatStatusCountdown(const Duration(hours: 1, minutes: 30)),
          '1h 30m');
    });

    test('minutes and seconds under an hour, seconds under a minute', () {
      expect(formatStatusCountdown(const Duration(minutes: 14, seconds: 3)),
          '14:03');
      expect(formatStatusCountdown(const Duration(seconds: 45)), '45s');
    });

    test('tabular figures only while digits tick each second', () {
      expect(countdownTicksEachSecond(const Duration(hours: 130)), isFalse);
      expect(countdownTicksEachSecond(const Duration(hours: 2)), isFalse);
      expect(countdownTicksEachSecond(const Duration(minutes: 59)), isTrue);
      expect(countdownTicksEachSecond(const Duration(seconds: 5)), isTrue);
    });
  });

  Future<void> pump(WidgetTester tester, Size size, {String link = ''}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: [
        statusProvider.overrideWith(() => _Status(StatusState(
              hasFetched: true,
              notices: [
                SystemStatus(
                  id: 'a',
                  level: StatusLevel.warning,
                  title: 'Hollow is now on the App Store',
                  message: _long,
                  until: DateTime.now()
                      .toUtc()
                      .add(const Duration(days: 5, hours: 10, minutes: 1)),
                  untilLabel: 'TestFlight ends in',
                  link: link,
                  linkLabel: 'Open App Store',
                  expires: DateTime.utc(2099),
                ),
              ],
            ))),
      ]),
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(
          body: Column(children: [SystemStatusBanner(), Spacer()]),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('the countdown names days and drops tabular figures',
      (tester) async {
    await pump(tester, const Size(1280, 300));
    final text = find.textContaining('TestFlight ends in 5d 10h');
    expect(text, findsOneWidget);
    final style = tester.widget<Text>(text).style!;
    expect(style.fontFeatures ?? const [], isEmpty,
        reason: 'tabular figures give a "1" a full digit width ("1 30h")');
  });

  testWidgets('a phone keeps the whole title, the countdown under it',
      (tester) async {
    await pump(tester, const Size(390, 600));
    final title = find.text('Hollow is now on the App Store');
    final countdown = find.textContaining('TestFlight ends in');
    expect(title, findsOneWidget);
    expect(tester.getTopLeft(countdown).dy,
        greaterThan(tester.getBottomLeft(title).dy - 1),
        reason: 'title and countdown no longer share one squeezed line');
    expect(tester.renderObject<RenderParagraph>(title).didExceedMaxLines,
        isFalse,
        reason: 'the title is not ellipsized on a 390 px phone');
    expect(find.text(_long), findsNothing, reason: 'collapsed shows no body');
  });

  testWidgets('expanding shows the body and the link as a button',
      (tester) async {
    await pump(tester, const Size(390, 600),
        link: 'https://apps.apple.com/app/id6777748033');
    await tester.tap(find.byIcon(LucideIcons.chevronDown));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(_long), findsOneWidget);
    expect(
        find.ancestor(
            of: find.text('Open App Store'),
            matching: find.byType(HollowButton)),
        findsOneWidget);
  });

  testWidgets('a desktop body keeps a readable line length', (tester) async {
    await pump(tester, const Size(2400, 300));
    await tester.tap(find.byIcon(LucideIcons.chevronDown));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getSize(find.text(_long)).width, lessThanOrEqualTo(720));
  });

  group('review round', () {
    testWidgets('phone: a notice with a link and no message still shows it',
        (tester) async {
      await _pumpNotice(tester, const Size(390, 600),
          title: 'Relay maintenance tonight',
          message: '',
          link: 'https://anonlisten.com/status');
      expect(
          find.ancestor(
              of: find.text('Details'), matching: find.byType(HollowButton)),
          findsOneWidget,
          reason: 'no message = nothing to expand, so the link shows at once');
    });

    testWidgets('desktop: an open notice never clips its title',
        (tester) async {
      await _pumpNotice(tester, const Size(720, 300),
          title: _longTitle,
          message: 'Calls may drop for a minute or two.',
          link: 'https://anonlisten.com/status');
      await _expand(tester);
      expect(_clipped(tester, find.text(_longTitle)), isFalse);
    });

    testWidgets('desktop: a long title with no message wraps in full',
        (tester) async {
      await _pumpNotice(tester, const Size(720, 300),
          title: _longTitle, message: '');
      expect(find.byIcon(LucideIcons.chevronDown), findsNothing);
      expect(_clipped(tester, find.text(_longTitle)), isFalse,
          reason: 'with nothing to expand, a clipped title could never be read');
    });

    testWidgets('desktop: an open body runs under the whole first line',
        (tester) async {
      // An iPad at 150% lays the strip out about 690 px wide: the countdown,
      // link and controls must not squeeze the message into a column.
      final long = List.filled(8, 'Calls may drop for a minute or two.')
          .join(' ');
      await _pumpNotice(tester, const Size(690, 400),
          title: 'Relay maintenance tonight',
          message: long,
          link: 'https://anonlisten.com/status');
      await _expand(tester);
      expect(tester.getSize(find.text(long)).width, greaterThan(600));
    });

    testWidgets('desktop: an open notice with no title reads as a body',
        (tester) async {
      final long = List.filled(20, 'Calls may drop for a minute or two.')
          .join(' ');
      await _pumpNotice(tester, const Size(2400, 400),
          title: '', message: long);
      await _expand(tester);
      final text = find.text(long);
      expect(tester.getSize(text).width, lessThanOrEqualTo(640));
      expect(tester.widget<Text>(text).style!.fontWeight,
          isNot(FontWeight.w600));
    });
  });
}
