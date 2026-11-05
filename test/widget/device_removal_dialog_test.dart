/// Removing a device asks why it goes (DEVICE_PROOF_DESIGN 8.1): retiring keeps
/// what it did, lost or stolen asks when the person last had it. What it added
/// goes by that answer (8.6): the dialog names what goes regardless, offers the
/// rest, and removes exactly what it says. Desktop and phone share the one page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/settings/device_management_shared.dart';
import 'package:hollow/src/ui/settings/pages/devices_page.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

const _me = '12D3KooWThisDeviceThisDeviceThisDeviceThis';
const _laptop = '12D3KooWLaptopLaptopLaptopLaptopLaptopLapt';
const _phone = '12D3KooWPhonePhonePhonePhonePhonePhonePhon';
const _tablet = '12D3KooWTabletTabletTabletTabletTabletTabl';

typedef _Revoke = ({String device, int? since, bool withDependents});

/// The laptop linked the phone long ago and the tablet just now.
class _Api implements RustLibApi {
  final revoked = <_Revoke>[];
  final asked = <int?>[];
  bool takesEffect = true;

  @override
  Future<void> crateApiNetworkRevokeDevice({
    required String devicePeerId,
    int? lostSinceMs,
    required bool withDependents,
  }) async =>
      revoked.add((device: devicePeerId, since: lostSinceMs, withDependents: withDependents));

  @override
  Future<roster_api.DeviceRemovalPlan> crateApiRosterRemoveDevicePlan({
    required String devicePeerId,
    int? lostSinceMs,
  }) async {
    asked.add(lostSinceMs);
    final lost = lostSinceMs != null;
    return roster_api.DeviceRemovalPlan(
      forced: lost ? const [_tablet] : const [],
      optional: lost ? const [_phone] : const [_phone, _tablet],
      optionalOn: lost,
      takesEffectForServers: takesEffect,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Kinds extends DeviceKindNotifier {
  @override
  Map<String, String> build() => const {_phone: 'phone', _tablet: 'phone'};
}

const _devices = [
  MyDevice(peerId: _me, isThisDevice: true, online: true, label: 'Desk'),
  MyDevice(peerId: _laptop, isThisDevice: false, online: true, label: 'Laptop'),
  MyDevice(peerId: _phone, isThisDevice: false, online: false, label: '', kind: 'phone'),
];

List<Override> _overrides() => [
      myDevicesProvider.overrideWithValue(_devices),
      deviceKindProvider.overrideWith(_Kinds.new),
    ];

/// Lets the success toast run out, so no timer outlives the test.
Future<void> settleToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

Finder get _removeButton => find.byKey(const ValueKey('remove-device-confirm'));

bool _removeEnabled(WidgetTester tester) => tester.widget<HollowButton>(_removeButton).onPressed != null;

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(() {
    api.revoked.clear();
    api.asked.clear();
    api.takesEffect = true;
  });

  Future<void> pumpDesktop(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: _overrides()),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HollowThemeData.dark(),
        home: const Scaffold(body: SingleChildScrollView(child: DevicesSettingsPage())),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Only the laptop shows its More: the phone is offline and unlabelled.
  Future<void> openRemoval(WidgetTester tester) async {
    await tester.tap(find.byIcon(LucideIcons.ellipsis));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove device'));
    await tester.pumpAndSettle();
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('nothing is picked first and Remove waits for a choice', (tester) async {
    await pumpDesktop(tester);
    await openRemoval(tester);

    expect(find.text('Remove Laptop?'), findsOneWidget);
    expect(find.text("I'm retiring this device"), findsOneWidget);
    expect(find.text('It was lost or stolen'), findsOneWidget);
    expect(find.text('When did you last have it?'), findsNothing);
    expect(find.textContaining('in your servers'), findsNothing,
        reason: 'what a choice does shows once it is picked');
    expect(_removeEnabled(tester), isFalse);
    expect(api.asked, isEmpty);
  });

  testWidgets('a picked choice says what it does in full', (tester) async {
    await pumpDesktop(tester);
    await openRemoval(tester);

    await tapKey(tester, 'remove-retire');
    expect(find.text('What it did in your servers stays. If someone else could '
        'still use it, pick lost or stolen.'), findsOneWidget);
    await tapKey(tester, 'remove-lost');
    expect(find.text('Changes it made in your servers after you last had it can be undone.'),
        findsOneWidget);
    expect(find.textContaining('What it did in your servers'), findsNothing);
  });

  testWidgets('retiring keeps what it added unless the toggle is turned on', (tester) async {
    await pumpDesktop(tester);
    await openRemoval(tester);
    await tapKey(tester, 'remove-retire');

    expect(api.asked, [null]);
    expect(find.byKey(const ValueKey('added-$_phone')), findsOneWidget);
    expect(find.byKey(const ValueKey('added-$_tablet')), findsOneWidget);
    expect(find.text('Also remove the devices it added'), findsOneWidget);
    expect(tester.widget<HollowToggle>(find.byType(HollowToggle)).value, isFalse);
    expect(find.textContaining('removed too, because'), findsNothing);
    expect(_removeEnabled(tester), isTrue);

    await tester.tap(_removeButton);
    await tester.pumpAndSettle();
    expect(api.revoked, [(device: _laptop, since: null, withDependents: false)]);
    expect(find.text('Laptop is removed. What it did in your servers stays.'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('lost or stolen asks when, names what goes, and removes the rest by the toggle', (tester) async {
    await pumpDesktop(tester);
    await openRemoval(tester);
    await tapKey(tester, 'remove-lost');

    expect(find.text('When did you last have it?'), findsOneWidget);
    expect(_removeEnabled(tester), isFalse, reason: 'no time picked yet');
    expect(api.asked, isEmpty);

    final before = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    await tapKey(tester, 'last-had-last7Days');
    final after = DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
    expect(api.asked, hasLength(1));
    final t = api.asked.single!;
    expect(t, inInclusiveRange(before, after));

    expect(find.textContaining('These devices are removed too, because it added them after'), findsOneWidget);
    expect(find.byKey(const ValueKey('added-$_tablet')), findsOneWidget);
    expect(find.text('If one of them is yours, pick a later time.'), findsOneWidget);
    expect(find.text('Also remove the devices it added earlier'), findsOneWidget);
    expect(tester.widget<HollowToggle>(find.byType(HollowToggle)).value, isTrue);

    await tester.tap(_removeButton);
    await tester.pumpAndSettle();
    expect(api.revoked, [(device: _laptop, since: t, withDependents: true)]);
    expect(find.textContaining('Laptop is removed. Changes it made in your servers after'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('turning the toggle off keeps the older devices', (tester) async {
    await pumpDesktop(tester);
    await openRemoval(tester);
    await tapKey(tester, 'remove-lost');
    await tapKey(tester, 'last-had-yesterday');
    await tester.tap(find.byType(HollowToggle));
    await tester.pumpAndSettle();
    await tester.tap(_removeButton);
    await tester.pumpAndSettle();
    expect(api.revoked.single.withDependents, isFalse);
    await settleToast(tester);
  });

  testWidgets('not sure judges from the start and names no date', (tester) async {
    await pumpDesktop(tester);
    await openRemoval(tester);
    await tapKey(tester, 'remove-lost');
    await tapKey(tester, 'last-had-notSure');

    expect(api.asked, [0]);
    expect(find.text('These devices are removed too, because it added them.'), findsOneWidget);
    await tester.tap(_removeButton);
    await tester.pumpAndSettle();
    expect(api.revoked.single.since, 0);
    expect(find.text('Laptop is removed. Changes it made in your servers are being undone.'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('a removal that does not reach servers says so', (tester) async {
    api.takesEffect = false;
    await pumpDesktop(tester);
    await openRemoval(tester);
    await tapKey(tester, 'remove-retire');
    expect(find.text('Not removed for servers yet. Use your recovery phrase to take your account back.'), findsOneWidget);
  });

  test('each answer judges from its earliest moment', () {
    final now = DateTime(2026, 11, 4, 15, 30);
    int ms(DateTime d) => d.millisecondsSinceEpoch;
    expect(lostSinceMs(LastHadAnswer.lessThanAnHour, now: now), ms(DateTime(2026, 11, 4, 14, 30)));
    expect(lostSinceMs(LastHadAnswer.earlierToday, now: now), ms(DateTime(2026, 11, 4)));
    expect(lostSinceMs(LastHadAnswer.yesterday, now: now), ms(DateTime(2026, 11, 3)));
    expect(lostSinceMs(LastHadAnswer.last7Days, now: now), ms(now.subtract(const Duration(days: 7))));
    expect(lostSinceMs(LastHadAnswer.last30Days, now: now), ms(now.subtract(const Duration(days: 30))));
    expect(lostSinceMs(LastHadAnswer.picked, now: now, picked: DateTime(2026, 10, 1, 9)), ms(DateTime(2026, 10, 1, 9)));
    expect(lostSinceMs(LastHadAnswer.picked, now: now, picked: DateTime(2027)), ms(now), reason: 'never in the future');
    expect(lostSinceMs(LastHadAnswer.notSure, now: now), 0);
    expect(lostSinceMs(LastHadAnswer.yesterday, now: DateTime(2026, 11, 1, 8)), ms(DateTime(2026, 10, 31)),
        reason: 'yesterday crosses a month');
  });

  testWidgets('phone: the same question on the pushed Devices page', (tester) async {
    await pumpHollowMobile(tester, viewportSize: const Size(400, 1600), extraOverrides: _overrides());
    await tester.tap(find.descendant(of: find.byType(MobileNavBar), matching: find.text('Settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    await openRemoval(tester);

    expect(_removeEnabled(tester), isFalse);
    await tapKey(tester, 'remove-lost');
    await tapKey(tester, 'last-had-lessThanAnHour');
    expect(find.byKey(const ValueKey('added-$_tablet')), findsOneWidget);
    await tester.ensureVisible(_removeButton);
    await tester.tap(_removeButton);
    await tester.pumpAndSettle();
    expect(api.revoked.single.withDependents, isTrue);
    await settleToast(tester);
  });
}
