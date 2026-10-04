// C-35: with the app locked, an OS notification names nobody, quotes nothing
// and offers no reply. On a phone the same holds whenever App Lock is on,
// since a banner sits on the lock screen before any unlock.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/chat_message.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/chat_provider.dart';
import 'package:hollow/src/core/providers/duress_provider.dart';
import 'package:hollow/src/core/providers/system_notification_provider.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/components/hollow_toast.dart';

import 'helpers/test_app.dart';

const _peer = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _text = 'meet me at the station at five';

class _RecordingSink extends OsNotificationSink {
  _RecordingSink({required this.mobile});

  final bool mobile;
  final calls = <String>[];
  final shown = <String>[];

  @override
  bool get isMobile => mobile;

  @override
  Future<void> hidden() async => calls.add('hidden');

  @override
  Future<void> mobileDm({
    required String personKey,
    required String displayName,
    required String messageId,
    required String text,
    Uint8List? avatarBytes,
  }) async {
    calls.add('mobileDm');
    shown.add(text);
  }

  @override
  Future<void> mobileChannel({
    required String serverId,
    required String channelId,
    required String serverName,
    required String channelName,
    required String senderName,
    required String messageId,
    required String text,
  }) async {
    calls.add('mobileChannel');
    shown.add(text);
  }

  @override
  Future<void> desktopDm({
    required String sourceKey,
    required String title,
    required String body,
    Uint8List? avatarBytes,
  }) async {
    calls.add('desktopDm');
    shown.add(body);
  }

  @override
  Future<void> desktopChannel({
    required String serverId,
    required String channelId,
    required String title,
    required String body,
    Uint8List? avatarBytes,
  }) async {
    calls.add('desktopChannel');
    shown.add(body);
  }
}

class _RecordingChat extends ChatNotifier {
  final sent = <String>[];

  @override
  Map<String, List<ChatMessage>> build() => {};

  @override
  Future<String> sendMessage(String peerId, String text,
      {String? replyToMid, network_api.LinkPreviewRef? linkPreview}) async {
    sent.add(text);
    return 'mid';
  }
}

identity_api.ProtectionStatus _status({required bool password}) =>
    identity_api.ProtectionStatus(
      isEncrypted: password,
      hasPassword: password,
      hasOsKeychain: false,
      osKeychainAvailable: false,
    );

Future<ProviderContainer> _container(
  _RecordingSink sink, {
  bool? appLockOn,
  _RecordingChat? chat,
}) async {
  final container = ProviderContainer(
    overrides: hollowTestOverrides(extra: [
      osNotificationSinkProvider.overrideWithValue(sink),
      if (appLockOn != null)
        identityProtectionProvider
            .overrideWith((ref) async => _status(password: appLockOn))
      else
        identityProtectionProvider.overrideWith(
            (ref) => Completer<identity_api.ProtectionStatus>().future),
      if (chat != null) chatProvider.overrideWith(() => chat),
    ]),
  );
  addTearDown(() {
    container.dispose();
    HollowToast.lockedOut = false;
  });
  if (appLockOn != null) await container.read(identityProtectionProvider.future);
  return container;
}

Future<void> _dmAndChannel(ProviderContainer c) async {
  final n = c.read(systemNotificationProvider.notifier);
  await n.notifyDm(fromPeerId: _peer, text: _text, replyToMid: null);
  await n.notifyChannel(
    serverId: 'server1',
    channelId: 'general',
    fromPeerId: _peer,
    text: _text,
    isMention: true,
    channelName: 'general',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('desktop', () {
    test('locked, every toast is the hidden one', () async {
      final sink = _RecordingSink(mobile: false);
      final c = await _container(sink, appLockOn: true);
      c.read(appLockedProvider.notifier).setLocked(true);

      await _dmAndChannel(c);

      expect(sink.calls, ['hidden', 'hidden']);
      expect(sink.shown, isEmpty);
      expect(c.read(systemNotificationProvider), isEmpty,
          reason: 'no in-app card waits under the cover either');
    });

    test('unlocked, the toast carries the message', () async {
      final sink = _RecordingSink(mobile: false);
      final c = await _container(sink, appLockOn: true);

      await _dmAndChannel(c);

      expect(sink.calls, ['desktopDm', 'desktopChannel']);
      expect(sink.shown.every((s) => s.contains(_text)), isTrue);
    });

    test('a toast reply never leaves a locked app', () async {
      final chat = _RecordingChat();
      final c = await _container(_RecordingSink(mobile: false),
          appLockOn: true, chat: chat);
      final n = c.read(systemNotificationProvider.notifier);

      c.read(appLockedProvider.notifier).setLocked(true);
      n.replyFromToast(_peer, 'typed on a locked screen');
      expect(chat.sent, isEmpty);

      c.read(appLockedProvider.notifier).setLocked(false);
      n.replyFromToast(_peer, 'typed after the unlock');
      expect(chat.sent, ['typed after the unlock']);
    });
  });

  group('phone in the background', () {
    Future<ProviderContainer> phone(_RecordingSink sink, {bool? appLockOn}) async {
      final c = await _container(sink, appLockOn: appLockOn);
      c.read(appLifecycleProvider.notifier).state = AppLifecycleState.paused;
      return c;
    }

    test('App Lock on, every banner is the hidden one', () async {
      final sink = _RecordingSink(mobile: true);
      await _dmAndChannel(await phone(sink, appLockOn: true));
      expect(sink.calls, ['hidden', 'hidden']);
      expect(sink.shown, isEmpty);
    });

    test('protection not known yet counts as App Lock on', () async {
      final sink = _RecordingSink(mobile: true);
      await _dmAndChannel(await phone(sink));
      expect(sink.calls, ['hidden', 'hidden']);
    });

    test('App Lock off, the banner carries the message', () async {
      final sink = _RecordingSink(mobile: true);
      await _dmAndChannel(await phone(sink, appLockOn: false));
      expect(sink.calls, ['mobileDm', 'mobileChannel']);
      expect(sink.shown, everyElement(contains(_text)));
    });
  });
}
