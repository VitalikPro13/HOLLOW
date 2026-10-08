/// Removing a device keeps the devices it added unless the person removes them
/// too (C-IDENTITY-09): the dialog lists them, says which way they go, and
/// removes exactly what it says. Desktop and phone share the one page.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/api/roster.dart' as roster_api;
import 'package:hollow/src/rust/frb_generated.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/components/hollow_toggle.dart';
import 'package:hollow/src/ui/mobile/mobile_nav_bar.dart';
import 'package:hollow/src/ui/settings/pages/devices_page.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

const _me = '12D3KooWThisDeviceThisDeviceThisDeviceThis';
const _laptop = '12D3KooWLaptopLaptopLaptopLaptopLaptopLapt';
const _phone = '12D3KooWPhonePhonePhonePhonePhonePhonePhon';
const _tablet = '12D3KooWTabletTabletTabletTabletTabletTabl';

class _Api implements RustLibApi {
  final revoked = <String>[];

  @override
  Future<void> crateApiNetworkRevokeDevice({required String devicePeerId}) async =>
      revoked.add(devicePeerId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Kinds extends DeviceKindNotifier {
  @override
  Map<String, String> build() => const {_phone: 'phone', _tablet: 'phone'};
}

/// The laptop linked the phone and this device; the phone linked nothing.
roster_api.RosterStatus _roster({List<String> laptopAdded = const [_phone, _me]}) =>
    roster_api.RosterStatus(
      member: true,
      protected: true,
      backupWait: true,
      devices: [
        const roster_api.RosterDevice(devicePeerId: _me, state: 'member', thisDevice: true, added: []),
        roster_api.RosterDevice(devicePeerId: _laptop, state: 'member', thisDevice: false, added: laptopAdded),
        const roster_api.RosterDevice(devicePeerId: _phone, state: 'member', thisDevice: false, added: []),
      ],
    );

const _devices = [
  MyDevice(peerId: _me, isThisDevice: true, online: true, label: 'Desk'),
  MyDevice(peerId: _laptop, isThisDevice: false, online: true, label: 'Laptop'),
  MyDevice(peerId: _phone, isThisDevice: false, online: false, label: '', kind: 'phone'),
];

List<Override> _overrides(roster_api.RosterStatus roster) => [
      myDevicesProvider.overrideWithValue(_devices),
      deviceKindProvider.overrideWith(_Kinds.new),
      rosterStatusProvider.overrideWith((ref) async => roster),
    ];

/// Lets the success toast run out, so no timer outlives the test.
Future<void> settleToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  setUp(api.revoked.clear);

  Future<void> pumpDesktop(WidgetTester tester, roster_api.RosterStatus roster) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: hollowTestOverrides(extra: _overrides(roster)),
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

  testWidgets('removing a device that added others lists them and keeps them by default',
      (tester) async {
    await pumpDesktop(tester, _roster());
    await openRemoval(tester);

    expect(find.text('Remove "Laptop"?'), findsOneWidget);
    expect(find.text('It added this device'), findsOneWidget, reason: 'this device is never listed');
    expect(find.text('Phone'), findsWidgets);
    expect(find.text('It stays and keeps getting your messages.'), findsOneWidget);
    expect(tester.widget<HollowToggle>(find.byType(HollowToggle)).value, isFalse);

    await tester.tap(find.text('Remove device').last);
    await tester.pumpAndSettle();
    expect(api.revoked, [_laptop], reason: 'the kept device must stay');
    expect(find.text('Device removed'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('turning on removing them too removes them as well', (tester) async {
    await pumpDesktop(tester, _roster());
    await openRemoval(tester);

    await tester.tap(find.byType(HollowToggle));
    await tester.pumpAndSettle();
    expect(find.text("It's removed too and locks the same way."), findsOneWidget);
    expect(find.text('Remove 2 devices'), findsOneWidget);

    await tester.tap(find.text('Remove 2 devices'));
    await tester.pumpAndSettle();
    expect(api.revoked, [_laptop, _phone]);
    expect(find.text('2 devices removed'), findsOneWidget);
    await settleToast(tester);
  });

  testWidgets('a device that added nothing gets the plain question', (tester) async {
    await pumpDesktop(tester, _roster(laptopAdded: const [_me]));
    await openRemoval(tester);

    expect(find.text('Remove "Laptop"?'), findsOneWidget);
    expect(find.textContaining('It added'), findsNothing);
    expect(find.byType(HollowToggle), findsNothing);
    await tester.tap(find.text('Remove device').last);
    await tester.pumpAndSettle();
    expect(api.revoked, [_laptop]);
    await settleToast(tester);
  });

  testWidgets('phone: the same list and choice on the pushed Devices page', (tester) async {
    await pumpHollowMobile(tester,
        viewportSize: const Size(400, 1400), extraOverrides: _overrides(_roster(laptopAdded: const [_phone, _tablet])));
    await tester.tap(find.descendant(of: find.byType(MobileNavBar), matching: find.text('Settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();
    await openRemoval(tester);

    expect(find.text('It added these devices'), findsOneWidget);
    expect(find.byKey(const ValueKey('added-$_phone')), findsOneWidget);
    expect(find.byKey(const ValueKey('added-$_tablet')), findsOneWidget);
    expect(find.text('They stay and keep getting your messages.'), findsOneWidget);
    await tester.tap(find.byType(HollowToggle));
    await tester.pumpAndSettle();
    expect(find.text("They're removed too and lock the same way."), findsOneWidget);
    await tester.tap(find.text('Remove 3 devices'));
    await tester.pumpAndSettle();
    expect(api.revoked, [_laptop, _phone, _tablet]);
    await settleToast(tester);
  });
}
