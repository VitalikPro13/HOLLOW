import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/device_link_sync_provider.dart';

/// This device shows a link code, asks to add a device or sends it: the other
/// device's ask and the transfer need the network while the person looks at it.
final linkPresentingProvider = Provider<bool>((ref) =>
    ref.watch(deviceLinkSyncProvider.select((s) => switch (s.phase) {
          LinkPhase.showingCode ||
          LinkPhase.renewingCode ||
          LinkPhase.confirmPush ||
          LinkPhase.sending =>
            true,
          _ => false,
        })));

/// Android cuts a backgrounded app's network within seconds unless it runs a
/// foreground service, so a presenting phone holds a short one until the link
/// ends; the person is typing the code on the other device meanwhile.
class LinkKeepAlive {
  static const channelName = 'hollow/link_keep_alive';
  static const _channel = MethodChannel(channelName);

  LinkKeepAlive({required this.enabled, Future<void> Function(String method)? invoke})
      : _invoke = invoke ?? ((method) => _channel.invokeMethod<void>(method));

  final bool enabled;
  final Future<void> Function(String method) _invoke;
  bool _held = false;

  void hold(bool presenting) {
    if (!enabled || presenting == _held) return;
    _held = presenting;
    _invoke(presenting ? 'start' : 'stop').catchError((Object _) {});
  }
}

/// Whether this platform has the service (`LinkKeepAliveService.kt`): Android only.
final linkKeepAliveSupportedProvider = Provider<bool>((_) => Platform.isAndroid);

/// The app's one [LinkKeepAlive], following [linkPresentingProvider].
final linkKeepAliveProvider = Provider<LinkKeepAlive>((ref) {
  final keepAlive = LinkKeepAlive(enabled: ref.watch(linkKeepAliveSupportedProvider));
  ref.listen<bool>(linkPresentingProvider, (_, presenting) => keepAlive.hold(presenting),
      fireImmediately: true);
  ref.onDispose(() => keepAlive.hold(false));
  return keepAlive;
});
