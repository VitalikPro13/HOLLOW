/// Settings > Get help: the country comes from the device's region, the first
/// screen holds the emergency number and the main crisis line, every other
/// kind of help is a choice that opens its own page (country rows first, then
/// the ones that work anywhere), the picker searches by name and code, notes
/// show, phones dial and desktops copy.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/help_resources.dart';
import 'package:hollow/src/core/providers/settings_place_provider.dart';
import 'package:hollow/src/core/services/untrusted_link.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/beside_or_below.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/mobile/mobile_shell.dart';
import 'package:hollow/src/ui/mobile/tabs/mobile_settings_tab.dart';
import 'package:hollow/src/ui/settings/pages/get_help_page.dart';
import 'package:hollow/src/ui/settings/settings_catalog.dart';
import 'package:hollow/src/ui/settings/settings_kit.dart';
import 'package:hollow/src/ui/settings/settings_place.dart';
import 'package:hollow/src/ui/shell/mobile_nav.dart';

import '../helpers/test_app.dart';

class _Choice extends HelpCountryChoiceNotifier {
  final String? initial;
  _Choice(this.initial);
  String? saved;

  @override
  Future<String?> build() async => initial;

  @override
  Future<void> choose(String? code) async {
    saved = code;
    state = AsyncData(code);
  }
}

List<Override> _overrides(
  String? region, {
  String? chosen,
  HelpRegionSource source = HelpRegionSource.locale,
}) => [
  deviceRegionProvider.overrideWith(
    (ref) async => region == null ? null : (code: region, source: source),
  ),
  helpCountryChoiceProvider.overrideWith(() => _Choice(chosen)),
];

Future<ProviderContainer> _pumpDesktop(
  WidgetTester tester,
  String? region, {
  String? chosen,
  HelpRegionSource source = HelpRegionSource.locale,
  Size size = const Size(1280, 900),
  double scale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  final container = ProviderContainer(
    overrides: hollowTestOverrides(
      extra: _overrides(region, chosen: chosen, source: source),
    ),
  );
  addTearDown(container.dispose);
  openSettings(container.read, category: SettingsCategory.help);
  await tester.runAsync(() => container.read(helpResourcesProvider.future));
  // A fresh tree: a page left open by an earlier pump must not carry over.
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: SettingsPlace()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Finder _inRow(String key, Finder f) =>
    find.descendant(of: find.byKey(ValueKey(key)), matching: f);

/// [text] inside the row of the contact called [name].
Finder _inContact(String name, String text) => find.descendant(
  of: find.ancestor(of: find.text(name), matching: find.byType(SettingsRow)),
  matching: find.textContaining(text),
);

Finder _inDialog(Finder f) =>
    find.descendant(of: find.byType(HollowDialog), matching: f);

/// Desktop tests run as macOS: copy, never dial.
void testDesk(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.macOS),
);

void testPhone(String name, WidgetTesterCallback body) => testWidgets(
  name,
  body,
  variant: TargetPlatformVariant.only(TargetPlatform.iOS),
);

/// Opens the need page behind its choice on the first screen.
Future<void> _open(WidgetTester tester, String need) async {
  final row = find.byKey(ValueKey('help-open-$need'));
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

/// [a] sits above [b] on the screen.
bool _above(WidgetTester tester, Finder a, Finder b) =>
    tester.getTopLeft(a).dy < tester.getTopLeft(b).dy;

/// Whether keyboard focus is inside the widget keyed [key].
bool _focusIn(String key) {
  var inside = false;
  FocusManager.instance.primaryFocus?.context?.visitAncestorElements((e) {
    if (e.widget.key == ValueKey(key)) inside = true;
    return !inside;
  });
  return inside;
}

void main() {
  testDesk('the device region picks the country', (tester) async {
    await _pumpDesktop(tester, 'PL');
    expect(find.text('Poland'), findsOneWidget);
    expect(find.text("From your device's region settings"), findsOneWidget);
    expect(_inRow('help-emergency', find.text('112')), findsOneWidget);
    expect(_inRow('help-crisis-main', find.text('116 123')), findsOneWidget);
    expect(
      _inRow('help-other', find.textContaining('Checked in November 2026')),
      findsOneWidget,
    );
    // Every other kind of help waits behind its choice.
    expect(find.text('Take It Down'), findsNothing);
    expect(find.text('Dyżurnet.pl'), findsNothing);
  });

  testDesk('the main crisis line sits on the first screen', (tester) async {
    await _pumpDesktop(tester, 'PL');
    expect(
      _inRow('help-crisis', find.text('Telefon zaufania 116 123')),
      findsOneWidget,
    );
    expect(find.text('Centrum Wsparcia'), findsNothing);
    expect(
      _inRow(
        'help-open-crisis',
        find.text(
          'Another line, and services that find one in any '
          'country',
        ),
      ),
      findsOneWidget,
    );
    await _pumpDesktop(tester, 'US');
    expect(
      _inRow('help-crisis-main', find.text('988 Suicide & Crisis Lifeline')),
      findsOneWidget,
    );
    await _pumpDesktop(tester, 'IE');
    expect(
      find.text('2 more lines, and services that find one in any country'),
      findsOneWidget,
    );
    await _pumpDesktop(tester, 'GR');
    expect(
      find.text('Services that find a line in any country'),
      findsOneWidget,
    );
    // The one that answers around the clock leads, even when listed second.
    await _pumpDesktop(tester, 'MT');
    expect(_inRow('help-crisis-main', find.text('Kellimni')), findsOneWidget);
    expect(find.text('Richmond Helpline'), findsNothing);
  });

  testDesk('a country with no crisis line gets the finders up front', (
    tester,
  ) async {
    await _pumpDesktop(tester, 'TR');
    expect(_inRow('help-crisis', find.text('Find A Helpline')), findsOneWidget);
    expect(
      _inRow('help-crisis', find.text('Befrienders Worldwide')),
      findsOneWidget,
    );
    expect(
      find.textContaining("couldn't confirm a crisis line for Türkiye"),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('help-open-crisis')), findsNothing);
  });

  testDesk('the police choice only where a form takes these reports', (
    tester,
  ) async {
    for (final code in ['PL', 'RU', 'TR', 'TH', 'KH']) {
      await _pumpDesktop(tester, code);
      expect(
        find.byKey(const ValueKey('help-open-police')),
        findsNothing,
        reason: code,
      );
    }
    await _pumpDesktop(tester, 'GB');
    await _open(tester, 'police');
    expect(
      _inRow('help-need-police', find.text('Report a crime online')),
      findsOneWidget,
    );
    // Someone here from a threat has no link in mind; the page never asks.
    expect(find.textContaining('link'), findsNothing);
    expect(
      _above(
        tester,
        find.text(
          'The messages on your device are the evidence, so keep '
          'them.',
        ),
        find.text('Report a crime online'),
      ),
      isTrue,
    );
    // Police forms are national: nothing worldwide joins them.
    expect(find.text('Anywhere in the world'), findsNothing);
    expect(find.text('Take It Down'), findsNothing);
    // Russia keeps the help that does not go through the state.
    await _pumpDesktop(tester, 'RU');
    await _open(tester, 'crisis');
    expect(
      _inRow('help-need-crisis', find.text('Твоя территория')),
      findsOneWidget,
    );
    await _pumpDesktop(tester, 'RU');
    await _open(tester, 'children');
    expect(
      _inRow('help-need-children', find.text('8-800-2000-122')),
      findsOneWidget,
    );
  });

  testDesk('a need page lists the country first, then help that works '
      'anywhere', (tester) async {
    final cases = {
      'crisis': ('Centrum Wsparcia', 'Find A Helpline'),
      'photos': ('Dyżurnet.pl', 'Take It Down'),
      'children': ('Telefon zaufania 116 111', 'Child Helpline International'),
      'websites': ('Dyżurnet.pl', 'INHOPE member hotlines'),
    };
    for (final MapEntry(key: need, value: (here, anywhere)) in cases.entries) {
      await _pumpDesktop(tester, 'PL');
      await _open(tester, need);
      final page = 'help-need-$need';
      final caption = _inRow(page, find.text('Anywhere in the world'));
      expect(caption, findsOneWidget, reason: need);
      expect(
        _above(tester, _inRow(page, find.text(here)), caption),
        isTrue,
        reason: need,
      );
      expect(
        _above(tester, caption, _inRow(page, find.text(anywhere))),
        isTrue,
        reason: need,
      );
      // One list: no second heading level, and each service once.
      expect(find.text('Worldwide'), findsNothing);
      expect(find.text(anywhere), findsOneWidget, reason: need);
      expect(find.byKey(const ValueKey('help-crisis')), findsNothing);
    }
  });

  testDesk('the photos page starts with what to do', (tester) async {
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'photos');
    final advice = find.textContaining(
      "Don't pay and don't send anything more",
    );
    expect(advice, findsOneWidget);
    expect(_above(tester, advice, find.text('Dyżurnet.pl')), isTrue);
  });

  testDesk('a hotline row says whether it needs the link, only when checked', (
    tester,
  ) async {
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'websites');
    expect(find.textContaining('most need the link to act'), findsOneWidget);
    expect(
      _inContact('Dyżurnet.pl', 'Needs the link to the website'),
      findsOneWidget,
    );
    await _pumpDesktop(tester, 'US');
    await _open(tester, 'websites');
    expect(
      _inContact('NCMEC CyberTipline', 'You can report without a link'),
      findsOneWidget,
    );
    // Hungary's form asks for the link only for public web pages: it depends.
    await _pumpDesktop(tester, 'HU');
    await _open(tester, 'websites');
    expect(
      _inRow('help-need-websites', find.text('Biztonsagosinternet')),
      findsOneWidget,
    );
    expect(
      _inContact('Biztonsagosinternet', 'the link to the website'),
      findsNothing,
    );
    expect(_inContact('Biztonsagosinternet', 'without a link'), findsNothing);
  });

  testDesk('a chat with hours of its own gets its own line', (tester) async {
    await _pumpDesktop(tester, 'CZ');
    await _open(tester, 'crisis');
    expect(
      _inRow(
        'help-need-crisis',
        find.textContaining(
          'Phone 24 hours, every day, in Czech and '
          'Slovak\nChat Tue to Thu, 13:00 to 18:00',
        ),
      ),
      findsOneWidget,
    );
    // Chat hours nobody could read are never implied by the call hours.
    await _pumpDesktop(tester, 'NO');
    await _open(tester, 'crisis');
    expect(
      _inRow(
        'help-need-crisis',
        find.textContaining('Phone 24 hours, every day, in Norwegian'),
      ),
      findsOneWidget,
    );
  });

  for (final code in [null, 'AQ']) {
    testDesk('with no country the first screen asks for one, once ($code)', (
      tester,
    ) async {
      await _pumpDesktop(tester, code);
      // What to do comes first; the country that would name the number next.
      expect(
        _above(
          tester,
          find.byKey(const ValueKey('help-emergency')),
          find.byKey(const ValueKey('help-country')),
        ),
        isTrue,
      );
      expect(
        _inRow('help-country', find.text('Choose a country')),
        findsOneWidget,
      );
      expect(
        find.textContaining(RegExp('[Cc]hoose (a|your) country')),
        findsOneWidget,
        reason: 'the button asks; nothing asks again',
      );
      expect(
        find.text("Your device's region isn't on the list"),
        code == null ? findsNothing : findsOneWidget,
      );
      expect(
        _inRow(
          'help-emergency',
          find.textContaining('Call your local emergency number'),
        ),
        findsOneWidget,
      );
      expect(
        _inRow('help-crisis', find.text('Find A Helpline')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('help-open-crisis')), findsNothing);
      expect(find.byKey(const ValueKey('help-open-police')), findsNothing);
      expect(
        _inRow('help-emergency', find.byType(HollowButton)),
        findsNothing,
        reason: 'no number to call yet',
      );
      await _open(tester, 'photos');
      expect(
        _inRow('help-need-photos', find.text('Take It Down')),
        findsOneWidget,
      );
      expect(find.text('Anywhere in the world'), findsNothing);
    });
  }

  testDesk('a remembered pick wins over the region', (tester) async {
    await _pumpDesktop(tester, 'PL', chosen: 'GB');
    expect(find.text('United Kingdom'), findsOneWidget);
    expect(find.text('You chose this'), findsOneWidget);
    expect(
      _inRow('help-emergency', find.text('999 (any emergency)')),
      findsOneWidget,
    );
    await _pumpDesktop(tester, null, chosen: 'GB');
    expect(
      _inRow('help-emergency', find.text('999 (any emergency)')),
      findsOneWidget,
    );
  });

  testDesk('nothing shows until the region is read', (tester) async {
    final read = Completer<HelpRegion?>();
    final container = ProviderContainer(
      overrides: hollowTestOverrides(
        extra: [
          deviceRegionProvider.overrideWith((ref) => read.future),
          helpCountryChoiceProvider.overrideWith(() => _Choice(null)),
        ],
      ),
    );
    addTearDown(container.dispose);
    openSettings(container.read, category: SettingsCategory.help);
    await tester.runAsync(() => container.read(helpResourcesProvider.future));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: HollowThemeData.dark(),
          home: const Scaffold(body: SettingsPlace()),
        ),
      ),
    );
    await tester.pump();
    // A no-country screen and then a swap would move the page under the
    // reader.
    expect(find.byKey(const ValueKey('help-emergency-section')), findsNothing);
    read.complete((code: 'PL', source: HelpRegionSource.locale));
    await tester.pumpAndSettle();
    expect(_inRow('help-emergency', find.text('112')), findsOneWidget);
  });

  testDesk('a need page with no rows of its own shows the worldwide ones', (
    tester,
  ) async {
    // Andorra has no child helpline.
    await _pumpDesktop(tester, 'AD');
    await _open(tester, 'children');
    expect(
      _inRow('help-need-children', find.text('Child Helpline International')),
      findsOneWidget,
    );
    expect(find.text('Anywhere in the world'), findsNothing);
    // Singapore has no abuse-material hotline of its own.
    await _pumpDesktop(tester, 'SG');
    await _open(tester, 'websites');
    expect(
      _inRow('help-need-websites', find.text('INHOPE member hotlines')),
      findsOneWidget,
    );
    expect(find.text('Anywhere in the world'), findsNothing);
  });

  testDesk('a note sits with the rows it explains, links named by host', (
    tester,
  ) async {
    Finder note(String words) => find.textContaining(words, findRichText: true);
    // The child line notes: on the children page, never the first screen.
    for (final (code, words) in [
      ('UA', 'partly disrupted'),
      ('KR', 'area code before 1388'),
      ('TR', 'neglect and abuse reports'),
      ('IL', '105 is a government line'),
      ('ES', 'works nationwide'),
    ]) {
      await _pumpDesktop(tester, code);
      expect(note(words), findsNothing, reason: '$code first screen');
      await _open(tester, 'children');
      expect(
        _inRow('help-need-children', note(words)),
        findsOneWidget,
        reason: code,
      );
      // Under the country's rows, above the help that works anywhere.
      expect(
        _above(tester, note(words), find.text('Anywhere in the world')),
        isTrue,
        reason: code,
      );
    }
    // More abuse-material hotlines: on the link page.
    for (final (code, words) in [
      ('DE', 'fsm.de'),
      ('HU', 'ekapu.nmhh.hu'),
      ('IT', 'stop-it.savethechildren.it'),
      ('NL', 'atkm.nl'),
    ]) {
      await _pumpDesktop(tester, code);
      expect(find.text(words), findsNothing, reason: '$code first screen');
      await _open(tester, 'websites');
      expect(
        _inRow('help-need-websites', find.text(words)),
        findsOneWidget,
        reason: code,
      );
    }
    await _pumpDesktop(tester, 'DE');
    await _open(tester, 'children');
    expect(find.text('fsm.de'), findsNothing);
    // A note about the emergency numbers stays with them.
    await _pumpDesktop(tester, 'AU');
    expect(
      _inRow('help-emergency-section', note('112 works from mobiles')),
      findsOneWidget,
    );
    await _pumpDesktop(tester, 'PL');
    expect(note('partly disrupted'), findsNothing);
  });

  testDesk('the picker searches by name and by code', (tester) async {
    final c = await _pumpDesktop(tester, 'PL');
    await tester.tap(find.text('Poland'));
    await tester.pumpAndSettle();
    expect(_inDialog(find.text('Choose a country')), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'ukr');
    await tester.pump();
    expect(_inDialog(find.text('Ukraine')), findsOneWidget);
    expect(_inDialog(find.text('Poland')), findsNothing);

    await tester.enterText(find.byType(TextField).last, 'gb');
    await tester.pump();
    expect(_inDialog(find.text('United Kingdom')), findsOneWidget);
    expect(_inDialog(find.text('Ukraine')), findsNothing);

    await tester.enterText(find.byType(TextField).last, 'qqq');
    await tester.pump();
    expect(find.text('No country matches that'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'gb');
    await tester.pump();
    await tester.tap(find.text('United Kingdom'));
    await tester.pumpAndSettle();
    expect(c.read(helpCountryChoiceProvider).value, 'GB');
    expect(
      _inRow('help-emergency', find.text('999 (any emergency)')),
      findsOneWidget,
    );
  });

  testDesk('with no country the button opens the picker', (tester) async {
    final c = await _pumpDesktop(tester, null);
    await tester.tap(_inRow('help-country', find.text('Choose a country')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'pl');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(c.read(helpCountryChoiceProvider).value, 'PL');
    expect(_inRow('help-emergency', find.text('112')), findsOneWidget);
  });

  testDesk("the picker goes back to the device's region", (tester) async {
    final c = await _pumpDesktop(tester, 'PL', chosen: 'GB');
    await tester.tap(find.text('United Kingdom'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Use my device's region"));
    await tester.pumpAndSettle();
    expect(c.read(helpCountryChoiceProvider).value, isNull);
    expect(find.text('Poland'), findsOneWidget);
  });

  testDesk('a desktop copies a number instead of dialing', (tester) async {
    final dialed = <Uri>[];
    helpDialLauncher = (uri) async {
      dialed.add(uri);
      return true;
    };
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pumpDesktop(tester, 'PL');
    final number = _inRow('help-emergency', find.text('112'));
    await tester.tap(number);
    await tester.pump();
    expect(copied, '112');
    expect(dialed, isEmpty);
    expect(find.text('Copied 112'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 4));
  });

  testDesk('a website opens through the untrusted-link opener', (tester) async {
    final opened = <Uri>[];
    final saved = untrustedLinkLauncher;
    untrustedLinkLauncher = (uri) async {
      opened.add(uri);
      return true;
    };
    addTearDown(() => untrustedLinkLauncher = saved);
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'websites');
    final open = _inRow('help-need-websites', find.text('Open website')).first;
    await tester.tap(open);
    await tester.pump();
    expect(
      opened.single.toString(),
      'https://dyzurnet.pl/formularz-zgloszeniowy',
    );
  });

  testDesk('back returns to the first screen, by button or Escape', (
    tester,
  ) async {
    final c = await _pumpDesktop(tester, 'PL');
    await _open(tester, 'photos');
    expect(find.byKey(const ValueKey('help-crisis')), findsNothing);
    await tester.tap(find.bySemanticsLabel('Back to Get help'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('help-need-photos')), findsNothing);
    expect(_inRow('help-crisis-main', find.text('116 123')), findsOneWidget);
    // Focus lands back on the choice it came from.
    expect(_focusIn('help-open-photos'), isTrue);

    await _open(tester, 'websites');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('help-need-websites')), findsNothing);
    expect(find.byKey(const ValueKey('help-crisis')), findsOneWidget);
    expect(
      c.read(settingsTabOpenProvider),
      isTrue,
      reason: 'Escape on a need page goes back, it does not close Settings',
    );
    // On the first screen Escape closes Settings as before.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(c.read(settingsTabOpenProvider), isFalse);
  });

  testDesk('a need page opens at its top', (tester) async {
    // Large text: the page is taller than the window, so a kept scroll would
    // show its middle.
    await _pumpDesktop(tester, 'PL', size: const Size(800, 400), scale: 2.0);
    await _open(tester, 'photos');
    final back = find.bySemanticsLabel('Back to Get help');
    expect(Scrollable.of(tester.element(back)).position.pixels, 0);
    expect(tester.getTopLeft(back).dy, inInclusiveRange(0, 120));
  });

  testDesk('the keyboard reaches every choice, top to bottom', (tester) async {
    await _pumpDesktop(tester, 'GB');
    final order = <String>[];
    const keys = ['crisis', 'photos', 'children', 'police', 'websites'];
    for (var i = 0; i < 40 && order.length < keys.length; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      for (final k in keys) {
        if (_focusIn('help-open-$k') && !order.contains(k)) order.add(k);
      }
    }
    expect(order, keys);
    // Enter on the focused choice opens it.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('help-need-websites')), findsOneWidget);
  });

  testDesk('a screen reader hears each choice as a button with its words', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pumpDesktop(tester, 'GB');
    for (final (key, words) in [
      ('crisis', 'More ways to talk'),
      ('photos', 'Someone threatens to share your photos'),
      ('children', 'Help for children and teens'),
      ('police', 'Report a crime to the police'),
      ('websites', 'Someone sent you a link to child sexual abuse material'),
    ]) {
      final node = tester.getSemantics(
        find
            .descendant(
              of: find.byKey(ValueKey('help-open-$key')),
              matching: find.byType(MergeSemantics),
            )
            .first,
      );
      expect(node.getSemanticsData().label, contains(words), reason: key);
      expect(
        node,
        isSemantics(isButton: true, hasTapAction: true),
        reason: key,
      );
    }
    handle.dispose();
  });

  testDesk('settings search finds the page by its words', (tester) async {
    await _pumpDesktop(tester, 'PL');
    for (final q in [
      'emergency',
      '112',
      '911',
      'hotline',
      'abuse',
      'report',
      'suicide',
      'crisis',
      'talk',
      'self-harm',
      'self harm',
      'depressed',
      'sextortion',
      'blackmail',
      'nude',
      'police',
      'child',
      'csam',
    ]) {
      await tester.enterText(find.byType(TextField).first, q);
      await tester.pump();
      // The rail always names the page; a hit adds a result row naming it.
      expect(find.text('No setting matches that'), findsNothing, reason: q);
      expect(find.text('Get help'), findsAtLeastNWidgets(2), reason: q);
    }
  });

  testDesk('every Get help search entry names a row the page shows', (
    tester,
  ) async {
    final labels = [
      for (final e in kSettingsSearchIndex)
        if (e.category == SettingsCategory.help) e.label,
    ];
    expect(labels.length, greaterThanOrEqualTo(6));
    // The United Kingdom shows every choice, the police one included.
    await _pumpDesktop(tester, 'GB');
    for (final label in labels) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  /// Whether [a]'s top sits below [b]'s bottom: stacked, not beside.
  bool below(WidgetTester tester, Finder a, Finder b) =>
      tester.getTopLeft(a).dy >= tester.getBottomLeft(b).dy;

  /// A row title on one line is as tall as one line of its own style.
  void oneLine(WidgetTester tester, String title) {
    final found = find.text(title).first;
    final painter = TextPainter(
      text: TextSpan(text: 'A', style: tester.widget<Text>(found).style),
      textScaler: MediaQuery.textScalerOf(tester.element(found)),
      textDirection: TextDirection.ltr,
    )..layout();
    expect(
      tester.getSize(found).height,
      painter.height,
      reason: '$title wraps',
    );
    painter.dispose();
  }

  testDesk('buttons that fit stay beside their row title', (tester) async {
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'websites');
    expect(
      below(
        tester,
        _inRow('help-need-websites', find.text('Open website')).first,
        _inRow('help-need-websites', find.text('Dyżurnet.pl')),
      ),
      isFalse,
    );
  });

  for (final scale in [1.0, 1.5, 2.0]) {
    testDesk('buttons that do not fit go under the title at 800 px x$scale', (
      tester,
    ) async {
      await _pumpDesktop(
        tester,
        'CA',
        size: const Size(800, 900),
        scale: scale,
      );
      await _open(tester, 'children');
      final child = find.text('Kids Help Phone');
      oneLine(tester, 'Kids Help Phone');
      expect(
        below(
          tester,
          _inRow('help-need-children', find.text('1-800-668-6868')),
          child,
        ),
        isTrue,
      );
      await _pumpDesktop(
        tester,
        'KR',
        size: const Size(800, 900),
        scale: scale,
      );
      await _open(tester, 'children');
      // Squeezed beside its buttons a title may wrap at a space, never
      // letter by letter.
      final youth = find.text('Youth Hotline 1388');
      final line = TextPainter(
        text: TextSpan(text: 'A', style: tester.widget<Text>(youth).style),
        textScaler: MediaQuery.textScalerOf(tester.element(youth)),
        textDirection: TextDirection.ltr,
      )..layout();
      expect(tester.getSize(youth).height, lessThanOrEqualTo(2 * line.height));
      line.dispose();
    });
  }

  testDesk('the Country row names where the country came from', (tester) async {
    final cases = {
      ('US', HelpRegionSource.network): 'From your mobile network',
      ('US', HelpRegionSource.sim): 'From your SIM card',
      ('US', HelpRegionSource.locale): "From your device's region settings",
      ('AQ', HelpRegionSource.locale): "Your device's region isn't on the list",
    };
    for (final MapEntry(key: (code, source), value: line) in cases.entries) {
      await _pumpDesktop(tester, code, source: source);
      expect(find.text(line), findsOneWidget, reason: '$source');
    }
    await _pumpDesktop(
      tester,
      'US',
      source: HelpRegionSource.network,
      chosen: 'GB',
    );
    expect(find.text('You chose this'), findsOneWidget);
  });

  testDesk('Enter in an empty search picks nothing', (tester) async {
    final c = await _pumpDesktop(tester, 'PL');
    await tester.tap(find.text('Poland'));
    await tester.pumpAndSettle();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(HollowDialog), findsOneWidget);
    expect(c.read(helpCountryChoiceProvider).value, isNull);

    await tester.enterText(find.byType(TextField).last, 'ukr');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(HollowDialog), findsNothing);
    expect(c.read(helpCountryChoiceProvider).value, 'UA');
  });

  testDesk('the emergency number comes first and carries the most weight', (
    tester,
  ) async {
    await _pumpDesktop(tester, 'PL');
    final heading = find.text('Emergency');
    final title = tester.widget<Text>(heading);
    final crisis = tester.widget<Text>(find.text('Talk to someone now'));
    // As heavy as any section, and the first thing under the page title.
    expect(title.style!.fontWeight, crisis.style!.fontWeight);
    expect(title.style!.fontSize, crisis.style!.fontSize);
    expect(
      tester.getTopLeft(heading).dy -
          tester.getBottomLeft(find.text('Get help').last).dy,
      lessThan(48),
      reason: 'nothing stands between the page title and Emergency',
    );
    expect(
      _above(tester, heading, find.byKey(const ValueKey('help-crisis'))),
      isTrue,
    );
    // What Hollow can and can't see is reassurance, so it closes the page.
    final privacy = find.textContaining("Hollow can't read your messages");
    expect(privacy, findsOneWidget);
    expect(
      _above(tester, find.byKey(const ValueKey('help-open-websites')), privacy),
      isTrue,
    );
    expect(_above(tester, privacy, find.textContaining('Checked in')), isTrue);
  });

  testDesk('each emergency number says what it reaches', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpDesktop(tester, 'RU');
    for (final label in [
      '112 (any emergency)',
      '101 (fire)',
      '102 (police)',
      '103 (ambulance)',
    ]) {
      expect(
        _inRow('help-emergency', find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
    expect(find.bySemanticsLabel('Copy 103, ambulance'), findsOneWidget);
    // One number needs no label on screen; a screen reader still hears it.
    await _pumpDesktop(tester, 'PL');
    expect(_inRow('help-emergency', find.text('112')), findsOneWidget);
    expect(find.bySemanticsLabel('Copy 112, any emergency'), findsOneWidget);
    handle.dispose();
  });

  testDesk('the link page starts with what not to do', (tester) async {
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'websites');
    final warning = find.textContaining(
      "Don't download, screenshot or forward it.",
    );
    expect(warning, findsOneWidget);
    expect(_above(tester, warning, find.text('Dyżurnet.pl')), isTrue);
    expect(
      find.text('Someone sent you a link to child sexual abuse material'),
      findsOneWidget,
    );
  });

  testDesk('a desktop need page keeps one left edge', (tester) async {
    await _pumpDesktop(tester, 'PL');
    final edge = tester.getTopLeft(find.text('Talk to someone now')).dx;
    await _open(tester, 'photos');
    final arrow = find.descendant(
      of: find.bySemanticsLabel('Back to Get help'),
      matching: find.byType(Icon),
    );
    expect(tester.getTopLeft(arrow).dx, moreOrLessEquals(edge, epsilon: 1));
    expect(
      tester.getTopLeft(find.text('Someone threatens to share your photos')).dx,
      moreOrLessEquals(edge, epsilon: 1),
    );
    expect(
      tester.getTopLeft(find.textContaining("Don't pay and don't send")).dx,
      moreOrLessEquals(edge, epsilon: 1),
    );
  });

  testDesk('opening a need puts focus on its title, a heading', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'children');
    final focused = FocusManager.instance.primaryFocus;
    expect(focused?.debugLabel, 'help-need-title');
    final title = find.text('Help for children and teens');
    expect(
      tester.getSemantics(title),
      isSemantics(
        isHeader: true,
        isFocusable: true,
        isFocused: true,
        label: 'Help for children and teens',
      ),
    );
    // Escape from the title still goes back.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('help-crisis')), findsOneWidget);
    handle.dispose();
  });

  testDesk('choosing Get help in the rail again returns to the first screen', (
    tester,
  ) async {
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'photos');
    expect(find.byKey(const ValueKey('help-need-photos')), findsOneWidget);
    await tester.tap(find.byType(SettingsRailItem).last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('help-need-photos')), findsNothing);
    expect(find.byKey(const ValueKey('help-crisis')), findsOneWidget);
  });

  testDesk('the line before worldwide help is a heading', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpDesktop(tester, 'PL');
    await _open(tester, 'crisis');
    expect(
      tester.getSemantics(find.text('Anywhere in the world')),
      isSemantics(isHeader: true, label: 'Anywhere in the world'),
    );
    handle.dispose();
  });

  group('phone', () {
    Future<void> openOnPhone(
      WidgetTester tester,
      String? region, {
      Size size = const Size(390, 844),
      double scale = 1.0,
    }) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpHollowMobile(
        tester,
        viewportSize: size,
        extraOverrides: _overrides(region),
      );
      final c = ProviderScope.containerOf(
        tester.element(find.byType(MobileShell)),
      );
      await tester.runAsync(() => c.read(helpResourcesProvider.future));
      c.read(mobileTabProvider.notifier).state = MobileTab.settings;
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Get help'),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(find.text('Get help'));
      await tester.pumpAndSettle();
    }

    testPhone('the Settings tab opens Get help and a number dials', (
      tester,
    ) async {
      final dialed = <Uri>[];
      helpDialLauncher = (uri) async {
        dialed.add(uri);
        return true;
      };
      await openOnPhone(tester, 'UA');
      expect(find.byType(GetHelpSettingsPage), findsOneWidget);
      expect(find.text('Ukraine'), findsOneWidget);
      final number = _inRow('help-emergency', find.text('112 (any emergency)'));
      await tester.ensureVisible(number);
      await tester.tap(number);
      await tester.pump();
      expect(dialed.single.toString(), 'tel:112');

      await _open(tester, 'children');
      expect(
        find.textContaining('partly disrupted', findRichText: true),
        findsOneWidget,
      );
      final child = _inRow('help-need-children', find.text('0 800 500 225'));
      await tester.ensureVisible(child);
      await tester.tap(child);
      await tester.pump();
      expect(dialed.last.toString(), 'tel:0800500225');
    });

    testPhone('a need opens as its own page and Back returns', (tester) async {
      await openOnPhone(tester, 'PL');
      final pages = find.byType(MobileSettingsSubPage, skipOffstage: false);
      expect(pages, findsOneWidget);
      await _open(tester, 'photos');
      expect(pages, findsNWidgets(2));
      expect(find.byKey(const ValueKey('help-need-photos')), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Back').last);
      await tester.pumpAndSettle();
      expect(pages, findsOneWidget);
      expect(find.byKey(const ValueKey('help-need-photos')), findsNothing);
      expect(_inRow('help-crisis-main', find.text('116 123')), findsOneWidget);
    });

    for (final scale in [1.5, 2.0]) {
      testPhone('a 320 px phone at x$scale keeps every title whole', (
        tester,
      ) async {
        await openOnPhone(
          tester,
          'KR',
          size: const Size(320, 700),
          scale: scale,
        );
        oneLine(tester, 'Country');
        expect(
          below(tester, find.text('South Korea'), find.text('Country')),
          isTrue,
        );

        // A choice's words wrap; nothing ends in an ellipsis.
        for (final t in [
          'Someone threatens to share your photos',
          'Someone sent you a link to child sexual abuse material',
        ]) {
          final text = tester.widget<Text>(find.text(t));
          expect(text.overflow, isNot(TextOverflow.ellipsis), reason: t);
          expect(text.maxLines, isNull, reason: t);
        }
        await _open(tester, 'children');
        final child = find.text('Youth Hotline 1388');
        await tester.ensureVisible(child);
        await tester.pumpAndSettle();
        // The title keeps the row's width; its button goes under it.
        expect(tester.getSize(child).width, greaterThan(150));
        expect(
          below(
            tester,
            _inRow('help-need-children', find.text('1388 (landline)')),
            child,
          ),
          isTrue,
        );
      });
    }

    testPhone('a 320 px phone at x2.0 puts a short country under its title', (
      tester,
    ) async {
      // "Poland" fits beside the title, but the subtitle would break a word a
      // line there.
      await openOnPhone(tester, 'PL', size: const Size(320, 700), scale: 2.0);
      expect(below(tester, find.text('Poland'), find.text('Country')), isTrue);
      // The test font is wider than the app's, so pin the rule as well: the
      // title keeps three fifths of the row beside the chip, or the chip moves.
      final row = tester.widget<BesideOrBelow>(
        find.ancestor(
          of: find.text('Country'),
          matching: find.byType(BesideOrBelow),
        ),
      );
      expect(row.leadShare, greaterThanOrEqualTo(0.6));
    });

    testPhone('a number with a dialing note is copied, never dialed', (
      tester,
    ) async {
      final dialed = <Uri>[];
      helpDialLauncher = (uri) async {
        dialed.add(uri);
        return true;
      };
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await openOnPhone(tester, 'KR');
      await _open(tester, 'children');
      final landline = _inRow(
        'help-need-children',
        find.text('1388 (landline)'),
      );
      await tester.ensureVisible(landline);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Copy 1388, landline'), findsOneWidget);
      await tester.tap(landline);
      await tester.pump();
      expect(dialed, isEmpty);
      expect(copied, '1388');
      await tester.pumpAndSettle(const Duration(seconds: 4));
    });

    testPhone('a text line opens messages, not the dialer', (tester) async {
      final dialed = <Uri>[];
      helpDialLauncher = (uri) async {
        dialed.add(uri);
        return true;
      };
      await openOnPhone(tester, 'NZ');
      await _open(tester, 'children');
      final text = _inRow('help-need-children', find.text('234 (text)'));
      await tester.ensureVisible(text);
      await tester.tap(text);
      await tester.pump();
      expect(dialed.single.toString(), 'sms:234');
    });

    testPhone('a text line sends its first word', (tester) async {
      final dialed = <Uri>[];
      helpDialLauncher = (uri) async {
        dialed.add(uri);
        return true;
      };
      await openOnPhone(tester, 'US');
      await _open(tester, 'crisis');
      final text = _inRow('help-need-crisis', find.text('741741 (text)'));
      await tester.ensureVisible(text);
      await tester.pumpAndSettle();
      expect(
        _inRow('help-need-crisis', find.textContaining('Text HOME to 741741')),
        findsOneWidget,
      );
      await tester.tap(text);
      await tester.pump();
      expect(dialed.single.toString(), 'sms:741741?body=HOME');
    });
  });
}
