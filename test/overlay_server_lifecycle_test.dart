import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/overlay_settings_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/rust/frb_generated.dart';

import 'helpers/fake_overlay_api.dart';

/// The OBS server's lifecycle (plan 7): it comes back at start only after the
/// app is unlocked, is unlocked only AFTER it started, and App Lock or a
/// roster lock blanks every page at once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = FakeOverlayApi();
  setUpAll(() => RustLib.initMock(api: api));

  late ProviderContainer c;
  setUp(() {
    api
      ..calls.clear()
      ..enabled = false
      ..running = false
      ..port = 0
      ..portChanged = false
      ..locked = null
      ..linksEverRan = false
      ..setEnabledError = null;
    overlayServerSupported = () => true;
    c = ProviderContainer();
  });
  tearDown(() => c.dispose());

  List<String> serverCalls() =>
      api.calls.where((x) => x.startsWith('set_')).toList();

  test('a saved "on" restarts at start: enable first, then unlock', () async {
    api.enabled = true;
    await c.read(overlayServerProvider.notifier).restore();
    expect(serverCalls(), ['set_enabled(true)', 'set_locked(false)']);
    expect(c.read(overlayServerRunningProvider), isTrue);
    final s = c.read(overlayServerProvider);
    expect(s.status.running, isTrue);
    expect(s.links?.room, endsWith('/room'));
  });

  test('a saved "off" stays off and never unlocks', () async {
    await c.read(overlayServerProvider.notifier).restore();
    expect(serverCalls(), isEmpty);
    expect(c.read(overlayServerRunningProvider), isFalse);
    // The app unlocking says nothing to a server that is not running.
    c.read(appLockedProvider.notifier).setLocked(true);
    c.read(appLockedProvider.notifier).setLocked(false);
    await pumpEventQueue();
    expect(serverCalls(), ['set_locked(true)']);
  });

  test('started under App Lock: stays locked until the app unlocks', () async {
    api.enabled = true;
    c.read(appLockedProvider.notifier).setLocked(true);
    await pumpEventQueue();
    api.calls.clear();
    await c.read(overlayServerProvider.notifier).restore();
    expect(serverCalls(), ['set_enabled(true)', 'set_locked(true)']);
    c.read(appLockedProvider.notifier).setLocked(false);
    await pumpEventQueue();
    expect(serverCalls().last, 'set_locked(false)');
    expect(api.locked, isFalse);
  });

  test('App Lock and a roster lock blank the pages; unlock resumes', () async {
    await c.read(overlayServerProvider.notifier).setEnabled(true);
    expect(api.locked, isFalse);
    c.read(appLockedProvider.notifier).setLocked(true);
    await pumpEventQueue();
    expect(api.locked, isTrue);
    c.read(appLockedProvider.notifier).setLocked(false);
    await pumpEventQueue();
    expect(api.locked, isFalse);
    c.read(rosterGateProvider.notifier).removed('other', 0);
    await pumpEventQueue();
    expect(api.locked, isTrue);
    c.read(rosterGateProvider.notifier).restored();
    await pumpEventQueue();
    expect(api.locked, isFalse);
  });

  test('turning it off stops it and says so to listeners', () async {
    await c.read(overlayServerProvider.notifier).setEnabled(true);
    expect(c.read(overlayServerRunningProvider), isTrue);
    await c.read(overlayServerProvider.notifier).setEnabled(false);
    expect(c.read(overlayServerRunningProvider), isFalse);
    expect(serverCalls().last, 'set_enabled(false)');
    // Links stay readable: the server ran once.
    expect(c.read(overlayServerProvider).links, isNotNull);
  });

  test('a failed start rethrows and leaves it stopped', () async {
    api.setEnabledError = 'No free port for the overlay';
    await expectLater(
        c.read(overlayServerProvider.notifier).setEnabled(true), throwsA(isA<String>()));
    expect(c.read(overlayServerRunningProvider), isFalse);
    expect(serverCalls(), ['set_enabled(true)']);
  });

  test('a port change refreshes the status; a reset link clears the warning',
      () async {
    await c.read(overlayServerProvider.notifier).setEnabled(true);
    api.port = 31000;
    api.portChanged = true;
    c.read(overlayPortChangedProvider.notifier).state = 31000;
    await pumpEventQueue();
    expect(c.read(overlayServerProvider).status.port, 31000);
    expect(c.read(overlayServerProvider).status.portChanged, isTrue);
    final before = c.read(overlayServerProvider).links!.room;
    await c.read(overlayServerProvider.notifier).resetLink();
    expect(c.read(overlayPortChangedProvider), isNull);
    expect(c.read(overlayServerProvider).status.portChanged, isFalse);
    expect(c.read(overlayServerProvider).links!.room, isNot(before));
  });

  test('open streams follow the event', () async {
    await c.read(overlayServerProvider.notifier).setEnabled(true);
    c.read(overlayOpenStreamsProvider.notifier).state = 3;
    expect(c.read(overlayServerProvider).status.openStreams, 3);
  });

  test('a read made before the node ran is made again once it runs', () async {
    final c2 = ProviderContainer(overrides: [nodeProvider.overrideWith(_Node.new)]);
    addTearDown(c2.dispose);
    api.getSettingsError = 'Node is not running';
    final sub = c2.listen(overlayOwnProvider, (_, _) {});
    addTearDown(sub.close);
    await pumpEventQueue();
    expect(c2.read(overlayOwnProvider).hasError, isTrue);
    api.getSettingsError = null;
    (c2.read(nodeProvider.notifier) as _Node).connect();
    await pumpEventQueue();
    expect(c2.read(overlayOwnProvider).valueOrNull?.allow, isTrue);
  });

  test('phones never start it', () async {
    overlayServerSupported = () => false;
    api.enabled = true;
    await c.read(overlayServerProvider.notifier).restore();
    expect(serverCalls(), isEmpty);
    await expectLater(c.read(overlayServerProvider.notifier).setEnabled(true),
        throwsStateError);
  });
}

class _Node extends NodeNotifier {
  void connect() => state = const NodeState(status: NodeStatus.connected);
}
