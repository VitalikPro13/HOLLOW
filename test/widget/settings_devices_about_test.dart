import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/pages/about_page.dart';
import 'package:hollow/src/ui/settings/pages/devices_page.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../helpers/test_app.dart';

/// Settings > Devices and Settings > About as the redesign left them: removal
/// behind More, never a red icon at rest, and one updater row that follows the
/// updater's state.
void main() {
  Future<void> pumpPage(WidgetTester tester, Widget page,
      {List<Override> extra = const []}) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1.0;
    // On a Linux runner the updater row asks Rust for the install kind, and
    // the bridge is never initialised in a widget test.
    linuxInstallKindOverride = 'tarball';
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      linuxInstallKindOverride = null;
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: hollowTestOverrides(extra: extra),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: HollowThemeData.dark(),
          home: Scaffold(body: SingleChildScrollView(child: page)),
        ),
      ),
    );
    await tester.pump();
  }

  const devices = [
    MyDevice(peerId: 'aaaaaaaaaaaaaaaa1111', isThisDevice: true, online: true, label: 'Desk'),
    MyDevice(peerId: 'bbbbbbbbbbbbbbbb2222', isThisDevice: false, online: false, label: 'Phone'),
  ];

  testWidgets('devices: removal sits in the More menu', (tester) async {
    await pumpPage(tester, const DevicesSettingsPage(), extra: [
      myDevicesProvider.overrideWithValue(devices),
    ]);
    expect(find.text('Your devices'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('Link a device'), findsOneWidget);
    expect(find.byIcon(LucideIcons.trash2), findsNothing);

    await tester.tap(find.byIcon(LucideIcons.ellipsis));
    await tester.pumpAndSettle();
    expect(find.text('Sync servers and friends from this device'), findsOneWidget);
    expect(find.text('Remove device'), findsOneWidget);
  });

  testWidgets('devices: one device reads as the only one', (tester) async {
    await pumpPage(tester, const DevicesSettingsPage(), extra: [
      myDevicesProvider.overrideWithValue(devices.take(1).toList()),
    ]);
    expect(find.textContaining('Only this device is linked'), findsOneWidget);
    expect(find.byIcon(LucideIcons.ellipsis), findsNothing);
  });

  testWidgets('about: a ready update offers install and restart',
      (tester) async {
    await pumpPage(tester, const AboutSettingsPage(), extra: [
      updaterProvider.overrideWith(() => _ReadyUpdater()),
    ]);
    expect(find.text('Hollow'), findsOneWidget);
    expect(find.text('Ready to install v9.9.9'), findsOneWidget);
    expect(find.text('Install and restart'), findsOneWidget);
    expect(find.text('Privacy'), findsOneWidget);
  });

  testWidgets('about: the updater row says when it last checked',
      (tester) async {
    await pumpPage(tester, const AboutSettingsPage(), extra: [
      updaterProvider.overrideWith(() => _CheckedUpdater()),
    ]);
    expect(find.text("You're up to date"), findsOneWidget);
    expect(find.text('Last checked 3 hours ago'), findsOneWidget);
  });
}

class _CheckedUpdater extends UpdateNotifier {
  @override
  UpdateState build() => UpdateState(
        currentVersion: '0.11.1',
        manifest: const VersionManifest(latest: '0.11.1', versions: []),
        lastChecked: DateTime.now().subtract(const Duration(hours: 3)),
      );

  @override
  Future<void> checkForUpdates({bool background = false}) async {}
}

class _ReadyUpdater extends UpdateNotifier {
  @override
  UpdateState build() => const UpdateState(
        status: UpdateStatus.readyToInstall,
        selectedVersion: '9.9.9',
        currentVersion: '0.11.1',
      );
}
