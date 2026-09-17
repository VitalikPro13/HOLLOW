import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:unifiedpush/unifiedpush.dart';

export 'package:unifiedpush/unifiedpush.dart' show FailedReason;

/// The argument the UnifiedPush plugin starts `main()` with when a push
/// arrives while the app process is dead.
const kUnifiedPushBackgroundArg = '--unifiedpush-bg';

/// The relay's `platform` for a UnifiedPush registration; the sidecar sends
/// Web Push instead of FCM for it.
const _relayPlatform = 'unifiedpush';

/// Friendly names for the distributors people actually install. Anything else
/// shows its package name.
const _knownDistributors = {
  'io.heckel.ntfy': 'ntfy',
  'org.unifiedpush.distributor.nextpush': 'NextPush',
  'org.unifiedpush.distributor.sunup': 'Sunup',
  'org.unifiedpush.distributor.fcm': 'FCM distributor',
  'org.unifiedpush.distributor.conversations': 'Conversations',
};

String distributorLabel(String packageName) =>
    _knownDistributors[packageName] ?? packageName;

enum UnifiedPushPhase {
  /// No distributor chosen; Firebase carries the wake-ups.
  off,

  /// A distributor is chosen and has not answered with an endpoint yet.
  registering,

  /// The relay has this device's endpoint.
  active,

  /// The distributor refused or could not register.
  failed,
}

@immutable
class UnifiedPushStatus {
  final UnifiedPushPhase phase;
  final String? distributor;
  final FailedReason? failure;

  const UnifiedPushStatus(this.phase, {this.distributor, this.failure});

  static const off = UnifiedPushStatus(UnifiedPushPhase.off);
}

/// Entry point when the plugin started the process for a push: no UI, no
/// lock, no node, only the wake handler.
Future<void> runUnifiedPushBackground() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  await UnifiedPush.initialize(onMessage: _onBackgroundMessage);
}

@pragma('vm:entry-point')
void _onBackgroundMessage(PushMessage message, String instance) {
  final data = _decodeWake(message);
  if (data == null) return;
  handlePushWake(data).catchError((_) {});
}

/// The sidecar always encrypts, so an undecryptable or malformed message did
/// not come from it and is dropped.
Map<String, dynamic>? _decodeWake(PushMessage message) {
  if (!message.decrypted) return null;
  try {
    final decoded = jsonDecode(utf8.decode(message.content));
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

/// Android-only UnifiedPush state for the live app. The connector's saved
/// distributor is the one record of the choice: present means UnifiedPush
/// carries the wake-ups, absent means Firebase does.
class UnifiedPushController {
  UnifiedPushController._();
  static final UnifiedPushController instance = UnifiedPushController._();

  final ValueNotifier<UnifiedPushStatus> status =
      ValueNotifier(UnifiedPushStatus.off);

  bool _initialized = false;

  /// Called when UnifiedPush stops carrying wake-ups, so Firebase's token goes
  /// back to the relay.
  VoidCallback? onFallBackToFirebase;

  /// Whether UnifiedPush, not Firebase, owns the relay's push token.
  bool get isActive => switch (status.value.phase) {
        UnifiedPushPhase.registering || UnifiedPushPhase.active => true,
        UnifiedPushPhase.off || UnifiedPushPhase.failed => false,
      };

  static bool get supported => Platform.isAndroid;

  /// Wires the callbacks and, when a distributor was chosen before,
  /// registers again: the distributor answers every registration with the
  /// endpoint, which is how a restart re-sends it to the relay.
  Future<void> init() async {
    if (!supported || _initialized) return;
    _initialized = true;
    await UnifiedPush.initialize(
      onNewEndpoint: _onNewEndpoint,
      onRegistrationFailed: _onRegistrationFailed,
      onUnregistered: _onUnregistered,
      onMessage: _onMessage,
    );
    final distributor = await UnifiedPush.getDistributor();
    if (distributor == null) return;
    status.value = UnifiedPushStatus(UnifiedPushPhase.registering,
        distributor: distributor);
    await UnifiedPush.register();
  }

  /// Installed distributors, by package name.
  Future<List<String>> distributors() async {
    if (!supported) return const [];
    return UnifiedPush.getDistributors();
  }

  /// Switches the wake-ups to [distributor]. The relay gets the endpoint
  /// when the distributor answers.
  Future<void> use(String distributor) async {
    await init();
    final current = await UnifiedPush.getDistributor();
    if (current != null && current != distributor) {
      await UnifiedPush.unregister();
    }
    await UnifiedPush.saveDistributor(distributor);
    status.value = UnifiedPushStatus(UnifiedPushPhase.registering,
        distributor: distributor);
    await UnifiedPush.register();
  }

  /// Goes back to Firebase.
  Future<void> useFirebase() async {
    if (!supported) return;
    await init();
    await UnifiedPush.unregister();
    _fallBack();
  }

  void _fallBack() {
    status.value = UnifiedPushStatus.off;
    onFallBackToFirebase?.call();
  }

  void _onNewEndpoint(PushEndpoint endpoint, String instance) {
    final keys = endpoint.pubKeySet;
    final distributor = status.value.distributor;
    if (keys == null) {
      // Without Web Push keys the push server would read the sender id, so
      // such a distributor is never used.
      status.value = UnifiedPushStatus(UnifiedPushPhase.failed,
          distributor: distributor, failure: FailedReason.internalError);
      onFallBackToFirebase?.call();
      return;
    }
    final token = jsonEncode({
      'v': 1,
      'endpoint': endpoint.url,
      'p256dh': keys.pubKey,
      'auth': keys.auth,
    });
    network_api
        .registerPushToken(token: token, platform: _relayPlatform)
        .catchError((_) {});
    status.value =
        UnifiedPushStatus(UnifiedPushPhase.active, distributor: distributor);
  }

  void _onRegistrationFailed(FailedReason reason, String instance) {
    status.value = UnifiedPushStatus(UnifiedPushPhase.failed,
        distributor: status.value.distributor, failure: reason);
    // Until the user fixes or leaves the distributor, Firebase keeps waking
    // the phone rather than nothing.
    onFallBackToFirebase?.call();
  }

  Future<void> _onUnregistered(String instance) async {
    // A late answer for a distributor the user already switched away from.
    if (await UnifiedPush.getDistributor() != null) return;
    _fallBack();
  }

  void _onMessage(PushMessage message, String instance) {
    // In the foreground the socket is live and the relay already delivered.
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return;
    }
    final data = _decodeWake(message);
    if (data == null) return;
    handlePushWake(data).catchError((_) {});
  }
}
