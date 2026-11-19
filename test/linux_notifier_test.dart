import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/desktop_notification_service.dart';
import 'package:hollow/src/core/services/linux_notifier.dart';

/// Linux toasts name the .desktop file of the artifact they run from, so a
/// notification server shows Hollow's name and icon.
String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

String _flatpakAppId() => RegExp(r'^app-id:\s*(\S+)', multiLine: true)
    .firstMatch(_read('flatpak/com.anonlisten.Hollow.yml'))!
    .group(1)!;

/// A notification server: ids count up from 42, [hold] parks the next
/// Notify until the test completes it.
class _Recorder {
  _Recorder({this.caps = const ['body']});

  final List<String> caps;
  final calls = <(String, List<DBusValue>)>[];
  Object? failWith;
  Object? capsFailWith;
  Completer<void>? hold;
  int _next = 42;

  Future<List<DBusValue>> call(String method, List<DBusValue> args) async {
    calls.add((method, args));
    if (method == 'GetCapabilities') {
      if (capsFailWith != null) throw capsFailWith!;
      return [DBusArray.string(caps)];
    }
    if (failWith != null) throw failWith!;
    if (method != 'Notify') return const [];
    final id = _next++;
    final gate = hold;
    if (gate != null) {
      hold = null;
      await gate.future;
    }
    return [DBusUint32(id)];
  }

  List<List<DBusValue>> of(String method) =>
      [for (final c in calls) if (c.$1 == method) c.$2];

  List<int> get closed => [
        for (final args in of('CloseNotification'))
          (args.single as DBusUint32).value
      ];
}

Iterable<String> _strings(DBusValue v) sync* {
  if (v is DBusString) yield v.value;
  if (v is DBusVariant) yield* _strings(v.value);
  if (v is DBusArray) {
    for (final c in v.children) {
      yield* _strings(c);
    }
  }
  if (v is DBusDict) {
    for (final e in v.children.entries) {
      yield* _strings(e.key);
      yield* _strings(e.value);
    }
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

Map<String, DBusValue> _hints(List<DBusValue> args) => (args[6] as DBusDict)
    .children
    .map((k, v) => MapEntry((k as DBusString).value, (v as DBusVariant).value));

void main() {
  group('desktop entry per artifact', () {
    test('the native build names its own .desktop id', () {
      expect(linuxDesktopEntry(const {}), 'com.anonlisten.hollow');
      expect(linuxDesktopEntry(const {'FLATPAK_ID': '  '}),
          'com.anonlisten.hollow');
    });

    test('a flatpak names the app id it was installed under', () {
      expect(linuxDesktopEntry(const {'FLATPAK_ID': 'com.anonlisten.Hollow'}),
          'com.anonlisten.Hollow');
    });

    test('the native id is the one the tarball installs', () {
      final cmake = _read('linux/CMakeLists.txt');
      expect(cmake, contains('set(APPLICATION_ID "$kLinuxNativeDesktopEntry")'));
      expect(cmake, contains('"\${CMAKE_CURRENT_SOURCE_DIR}/'
          '$kLinuxNativeDesktopEntry.desktop"'));
      expect(File('linux/$kLinuxNativeDesktopEntry.desktop').existsSync(),
          isTrue);
      // The copy the app writes to ~/.local/share/applications at startup.
      expect(_read('lib/main.dart'),
          contains("'\${appsDir.path}/$kLinuxNativeDesktopEntry.desktop'"));
    });

    test('the flatpak exports its .desktop file and icon under its app id',
        () {
      final appId = _flatpakAppId();
      expect(appId, 'com.anonlisten.Hollow');
      final manifest = _read('flatpak/com.anonlisten.Hollow.yml');
      expect(manifest, contains('/app/share/applications/$appId.desktop'));
      expect(manifest, contains('/app/share/icons/hicolor/256x256/apps/$appId.png'));
      expect(File('flatpak/$appId.desktop').existsSync(), isTrue);
      expect(_read('flatpak/$appId.desktop'), contains('Icon=$appId\n'));
    });

    test('both .desktop files match the window by its WM_CLASS instance', () {
      for (final path in [
        'linux/$kLinuxNativeDesktopEntry.desktop',
        'flatpak/${_flatpakAppId()}.desktop',
      ]) {
        expect(_read(path), contains('Name=Hollow\n'), reason: path);
        expect(_read(path),
            contains('StartupWMClass=$kLinuxNativeDesktopEntry\n'),
            reason: path);
      }
      final runner = _read('linux/runner/my_application.cc');
      int statement(String code) =>
          RegExp('^\\s*${RegExp.escape(code)}', multiLine: true)
              .firstMatch(runner)
              ?.start ??
          -1;
      expect(statement('g_set_prgname(APPLICATION_ID);'), greaterThan(-1));
      // GNOME names a window it cannot match by the WM_CLASS class part, and
      // gtk_init (the parent's startup) overwrites any earlier class.
      final setClass = statement('gdk_set_program_class("Hollow");');
      final gtkInit = statement(
          'G_APPLICATION_CLASS(my_application_parent_class)->startup(application);');
      expect(setClass, greaterThan(-1));
      expect(gtkInit, greaterThan(-1));
      expect(setClass, greaterThan(gtkInit));
      expect(setClass, lessThan(runner.indexOf('my_application_shutdown')));
    });
  });

  group('LinuxNotifier', () {
    test('every toast carries the native desktop entry', () async {
      final bus = _Recorder();
      final notifier = LinuxNotifier(
        call: bus.call,
        environment: const {},
        executable: '/opt/hollow/bundle/hollow',
      );
      expect(await notifier.show('Ada', 'hi'), 42);
      final args = bus.of('Notify').single;
      expect((args[0] as DBusString).value, 'Hollow');
      expect((args[2] as DBusString).value,
          '/opt/hollow/bundle/data/flutter_assets/assets/hollow_logo_rounded.png');
      expect((args[3] as DBusString).value, 'Ada');
      expect((args[4] as DBusString).value, 'hi');
      expect(_hints(args)['desktop-entry'],
          const DBusString('com.anonlisten.hollow'));
    });

    test('a flatpak toast carries the flatpak desktop entry and icon',
        () async {
      final bus = _Recorder();
      final notifier = LinuxNotifier(
        call: bus.call,
        environment: const {'FLATPAK_ID': 'com.anonlisten.Hollow'},
        executable: '/app/bin/hollow',
      );
      await notifier.show('Ada', 'hi');
      final args = bus.of('Notify').single;
      expect((args[2] as DBusString).value, 'com.anonlisten.Hollow');
      expect(_hints(args)['desktop-entry'],
          const DBusString('com.anonlisten.Hollow'));
    });

    test('close names the toast and never throws', () async {
      final bus = _Recorder();
      final notifier =
          LinuxNotifier(call: bus.call, environment: const {}, executable: '');
      await notifier.close(7);
      expect(bus.calls.single.$1, 'CloseNotification');
      expect(bus.calls.single.$2.single, const DBusUint32(7));
      bus.failWith = StateError('bus gone');
      await notifier.close(8);
    });

    test('a markup server gets peer markup as literal text', () async {
      final bus = _Recorder(caps: const ['body', 'body-markup']);
      final notifier =
          LinuxNotifier(call: bus.call, environment: const {}, executable: '');
      const peer = '<a href="https://x.invalid">verify</a> <b>now</b> & a<b';
      await notifier.show('<b>Ada</b>', peer);
      final args = bus.of('Notify').single;
      expect((args[4] as DBusString).value,
          '&lt;a href="https://x.invalid"&gt;verify&lt;/a&gt; '
          '&lt;b&gt;now&lt;/b&gt; &amp; a&lt;b');
      // The summary is plain text by spec: escaping would show "&lt;".
      expect((args[3] as DBusString).value, '<b>Ada</b>');
    });

    test('a plain-text server gets the body as typed', () async {
      final bus = _Recorder(caps: const ['body', 'actions']);
      final notifier =
          LinuxNotifier(call: bus.call, environment: const {}, executable: '');
      await notifier.show('Ada', 'a<b & c');
      expect((bus.of('Notify').single[4] as DBusString).value, 'a<b & c');
    });

    test('capabilities are asked once, and again after a failure', () async {
      final bus = _Recorder()..capsFailWith = StateError('no server');
      final notifier =
          LinuxNotifier(call: bus.call, environment: const {}, executable: '');
      await expectLater(notifier.show('a', 'b'), throwsStateError);
      bus.capsFailWith = null;
      await notifier.show('a', 'b');
      await notifier.show('a', 'c');
      expect(bus.of('GetCapabilities'), hasLength(2));
      expect(bus.of('Notify'), hasLength(2));
    });

    test('no string reaches the bus with a U+0000 in it', () async {
      for (final markup in [false, true]) {
        final bus =
            _Recorder(caps: markup ? const ['body-markup'] : const ['body']);
        final notifier = LinuxNotifier(
          call: bus.call,
          environment: const {'FLATPAK_ID': 'com.anon\u0000listen.Hollow'},
          executable: '/app/bin/hollow',
        );
        await notifier.show('A\u0000da', 'hi\u0000there');
        final args = bus.of('Notify').single;
        for (final v in args) {
          for (final text in _strings(v)) {
            expect(text, isNot(contains('\u0000')), reason: 'markup=$markup');
          }
        }
        expect((args[3] as DBusString).value, 'Ada');
        expect((args[4] as DBusString).value, 'hithere');
      }
    });

    test('a failed post reaches the caller', () async {
      final bus = _Recorder()..failWith = StateError('no server');
      final notifier =
          LinuxNotifier(call: bus.call, environment: const {}, executable: '');
      await expectLater(notifier.show('a', 'b'), throwsStateError);
    });
  });

  group('DesktopNotificationService on Linux', () {
    (DesktopNotificationService, _Recorder) service({List<String>? caps}) {
      final bus = _Recorder(caps: caps ?? const ['body']);
      final linux =
          LinuxNotifier(call: bus.call, environment: const {}, executable: '');
      return (
        DesktopNotificationService.forTest(os: 'linux', linux: linux),
        bus
      );
    }

    test('is ready only when a notification server answers', () async {
      final (up, _) = service();
      await up.init();
      expect(up.isReady, isTrue);

      final (down, bus) = service();
      bus.capsFailWith = StateError('org.freedesktop.DBus.Error.ServiceUnknown');
      await down.init();
      expect(down.isReady, isFalse);
      await down.showDm(sourceKey: 'peerA', title: 'Ada', body: 'hi');
      await _settle();
      expect(bus.of('Notify'), isEmpty);
    });

    test('a second toast from one source replaces the first', () async {
      final (svc, bus) = service();
      await svc.showDm(sourceKey: 'peerA', title: 'Ada', body: 'one');
      await _settle();
      await svc.showDm(sourceKey: 'peerA', title: 'Ada', body: 'two');
      await _settle();
      expect(bus.of('Notify'), hasLength(2));
      expect(bus.closed, [42]);
    });

    test('withdrawDm closes only the blocked person\'s toast', () async {
      final (svc, bus) = service();
      await svc.showDm(sourceKey: 'peerA', title: 'Ada', body: 'hi');
      await svc.showDm(sourceKey: 'peerB', title: 'Bo', body: 'hi');
      await svc.showChannel(
          serverId: 's', channelId: 'c', title: 'general', body: 'hi');
      await _settle();
      await svc.withdrawDm({'peerB'});
      expect(bus.closed, [43]);
    });

    test('withdrawAll closes a toast whose post is still in flight', () async {
      final (svc, bus) = service();
      await svc.init();
      final gate = Completer<void>();
      bus.hold = gate;
      await svc.showDm(sourceKey: 'peerA', title: 'Ada', body: 'hi');
      await _settle();
      expect(bus.of('Notify'), hasLength(1));
      final withdrawn = svc.withdrawAll();
      await _settle();
      expect(bus.closed, isEmpty);
      gate.complete();
      await withdrawn;
      expect(bus.closed, [42]);
    });
  });
}
