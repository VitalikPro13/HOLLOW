import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/services/push_notification_service.dart';
import 'package:hollow/src/core/services/relay_triggers.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:unifiedpush/unifiedpush.dart';

export 'package:unifiedpush/unifiedpush.dart' show FailedReason;

/// The argument the UnifiedPush plugin starts `main()` with when a push
/// arrives while the app process is dead.
const kUnifiedPushBackgroundArg = '--unifiedpush-bg';

/// The relay's `platform` for a UnifiedPush registration; the sidecar sends
/// Web Push instead of FCM for it.
const _relayPlatform = 'unifiedpush';

/// The saved "Fall back to Google" choice: `0` keeps Google out while a chosen
/// distributor fails, anything else (or nothing saved) lets it wake the phone.
const kFirebaseFallbackSetting = 'push_firebase_fallback';

/// The distributor the person picked, kept because the connector forgets one
/// that was uninstalled or turned off; empty only once they pick Google.
const kChosenDistributorSetting = 'push_unifiedpush_distributor';

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

  /// The chosen distributor is broken: refused, unreachable, uninstalled or
  /// turned off. It stays the choice and is retried.
  failed,
}

@immutable
class UnifiedPushStatus {
  final UnifiedPushPhase phase;
  final String? distributor;
  final FailedReason? failure;

  /// Installed again, but silent after a retry registered with it: Android
  /// keeps a freshly installed app stopped until it is opened once.
  final bool unanswered;

  const UnifiedPushStatus(this.phase,
      {this.distributor, this.failure, this.unanswered = false});

  static const off = UnifiedPushStatus(UnifiedPushPhase.off);
}

/// A broken chosen service shows on Home only after this long, past the first
/// automatic retry ([kPushRetryDelays] first entry), so a blip never flickers.
const kPushAttentionGrace = Duration(seconds: 20);

/// How long a retry waits for the distributor to answer before the person is
/// told to open it once.
const kPushAnswerWait = Duration(seconds: 5);

/// The automatic retries of a broken chosen service while the app runs; the
/// last delay repeats.
const kPushRetryDelays = [
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 10),
];

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

/// The connector calls the controller makes, replaceable in tests.
class UnifiedPushConnector {
  const UnifiedPushConnector();

  Future<void> initialize({
    required void Function(PushEndpoint, String) onNewEndpoint,
    required void Function(FailedReason, String) onRegistrationFailed,
    required void Function(String) onUnregistered,
    required void Function(PushMessage, String) onMessage,
  }) =>
      UnifiedPush.initialize(
        onNewEndpoint: onNewEndpoint,
        onRegistrationFailed: onRegistrationFailed,
        onUnregistered: onUnregistered,
        onMessage: onMessage,
      );

  Future<String?> getDistributor() => UnifiedPush.getDistributor();
  Future<List<String>> getDistributors() => UnifiedPush.getDistributors();
  Future<void> saveDistributor(String distributor) =>
      UnifiedPush.saveDistributor(distributor);
  Future<void> register() => UnifiedPush.register();
  Future<void> unregister() => UnifiedPush.unregister();
}

/// Android-only UnifiedPush state for the live app. The person's pick is
/// sticky: only they change it. While it is broken, Google covers if they
/// allow it, the app keeps retrying, and everything returns on its own once
/// the service works again.
class UnifiedPushController with WidgetsBindingObserver {
  UnifiedPushController._();
  static final UnifiedPushController instance = UnifiedPushController._();

  @visibleForTesting
  factory UnifiedPushController.forTest(
          {UnifiedPushConnector connector = const UnifiedPushConnector()}) =>
      UnifiedPushController._()..connector = connector;

  @visibleForTesting
  UnifiedPushConnector connector = const UnifiedPushConnector();

  final ValueNotifier<UnifiedPushStatus> status =
      ValueNotifier(UnifiedPushStatus.off);

  /// Whether Google may wake the phone while the chosen service is broken
  /// (AR-33). Null until the setting is read.
  final ValueNotifier<bool?> firebaseFallback = ValueNotifier(null);

  /// The chosen service has been broken past [kPushAttentionGrace].
  final ValueNotifier<bool> needsAttention = ValueNotifier(false);

  bool _initialized = false;

  /// The distributor the person picked; null means Google.
  String? _chosen;

  /// This run sent the relay a UnifiedPush endpoint, which may stay there
  /// while the service is broken; anything else is Google's or unknown.
  bool _relayHoldsEndpoint = false;

  bool _retrying = false;
  int _retryStep = 0;
  Timer? _retryTimer;
  Timer? _attentionTimer;
  Timer? _answerTimer;

  /// Counts the distributor's answers, so a retry can tell whether any came.
  int _answers = 0;

  /// Called while the chosen service is broken and the person lets Google
  /// cover, so Firebase's token goes back to the relay.
  VoidCallback? onFallBackToFirebase;

  /// Whether UnifiedPush, not Firebase, owns the relay's push token. A broken
  /// service keeps it unless the person lets Google cover.
  bool get isActive => switch (status.value.phase) {
        UnifiedPushPhase.registering || UnifiedPushPhase.active => true,
        UnifiedPushPhase.failed => firebaseFallback.value != true,
        UnifiedPushPhase.off => false,
      };

  @visibleForTesting
  static bool? supportedForTest;

  static bool get supported => supportedForTest ?? Platform.isAndroid;

  /// Reads the saved "Fall back to Google" choice. An unreadable setting keeps
  /// what was known, and nothing known counts as no fallback.
  Future<bool> loadFirebaseFallback() async {
    try {
      final saved = await storage_api.loadSetting(key: kFirebaseFallbackSetting);
      firebaseFallback.value = saved != '0';
    } catch (_) {}
    return firebaseFallback.value ?? false;
  }

  /// Saves the choice; on a broken service it takes effect at once. Throws
  /// when the setting cannot be saved, and then changes nothing.
  Future<void> setFirebaseFallback(bool allowed) async {
    await storage_api.saveSetting(
        key: kFirebaseFallbackSetting, value: allowed ? '1' : '0');
    firebaseFallback.value = allowed;
    if (status.value.phase == UnifiedPushPhase.failed) await _coverOrWithdraw();
  }

  Future<String?> _loadChosen() async {
    try {
      final saved =
          await storage_api.loadSetting(key: kChosenDistributorSetting);
      return saved == null || saved.isEmpty ? null : saved;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveChosen(String? distributor) => storage_api
      .saveSetting(key: kChosenDistributorSetting, value: distributor ?? '')
      .catchError((_) {});

  /// Wires the callbacks and the retry triggers, then connects the chosen
  /// service: the distributor answers every registration with the endpoint,
  /// which is how a restart re-sends it to the relay.
  Future<void> init() async {
    if (!supported || _initialized) return;
    _initialized = true;
    await loadFirebaseFallback();
    await connector.initialize(
      onNewEndpoint: _onNewEndpoint,
      onRegistrationFailed: _onRegistrationFailed,
      onUnregistered: _onUnregistered,
      onMessage: _onMessage,
    );
    WidgetsBinding.instance.addObserver(this);
    RelayTriggers.networkChanges.addListener(_onNetworkChanged);
    final saved = await connector.getDistributor();
    var chosen = await _loadChosen();
    // Installs from before the choice was kept learn it here.
    if (saved != null && saved != chosen) {
      chosen = saved;
      await _saveChosen(saved);
    }
    _chosen = chosen;
    if (chosen == null) return;
    status.value =
        UnifiedPushStatus(UnifiedPushPhase.registering, distributor: chosen);
    await _connectOrBreak(chosen);
  }

  /// Installed distributors, by package name.
  Future<List<String>> distributors() async {
    if (!supported) return const [];
    return connector.getDistributors();
  }

  /// Switches the wake-ups to [distributor]. The relay gets the endpoint
  /// when the distributor answers.
  Future<void> use(String distributor) async {
    await init();
    final current = await connector.getDistributor();
    if (current != null && current != distributor) {
      await connector.unregister();
    }
    _chosen = distributor;
    await _saveChosen(distributor);
    _calm();
    status.value = UnifiedPushStatus(UnifiedPushPhase.registering,
        distributor: distributor);
    await connector.saveDistributor(distributor);
    await connector.register();
  }

  /// Tells the distributor this install no longer takes wake-ups, with no
  /// fallback to Firebase: the identity they were for is gone.
  Future<void> forget() async {
    if (!supported) return;
    onFallBackToFirebase = null;
    _chosen = null;
    _calm();
    status.value = UnifiedPushStatus.off;
    if (await connector.getDistributor() == null) return;
    await connector.unregister();
  }

  /// Goes back to Firebase: the person's own choice of Google.
  Future<void> useFirebase() async {
    if (!supported) return;
    await init();
    _chosen = null;
    await _saveChosen(null);
    _calm();
    await connector.unregister();
    _fallBack();
  }

  void _fallBack() {
    status.value = UnifiedPushStatus.off;
    _relayHoldsEndpoint = false;
    onFallBackToFirebase?.call();
  }

  /// Tries the chosen service again if it is broken. Safe to call often.
  Future<void> retry() async {
    final chosen = _chosen;
    if (chosen == null ||
        status.value.phase != UnifiedPushPhase.failed ||
        _retrying) {
      return;
    }
    _retrying = true;
    final answers = _answers;
    try {
      if (await _connect(chosen)) {
        _awaitAnswer(chosen, answers);
      } else {
        _setUnanswered(false);
      }
    } catch (_) {
    } finally {
      _retrying = false;
    }
  }

  /// [answers] is the count before the retry: an answer can beat the
  /// register call's own return.
  void _awaitAnswer(String chosen, int answers) {
    _answerTimer?.cancel();
    _answerTimer = Timer(kPushAnswerWait, () {
      if (_answers == answers && _chosen == chosen) _setUnanswered(true);
    });
  }

  void _setUnanswered(bool unanswered) {
    final s = status.value;
    if (s.phase != UnifiedPushPhase.failed || s.unanswered == unanswered) {
      return;
    }
    status.value = UnifiedPushStatus(UnifiedPushPhase.failed,
        distributor: s.distributor, failure: s.failure, unanswered: unanswered);
  }

  /// Registers with [chosen], first saving it to the connector again when the
  /// connector forgot it. False while it is uninstalled or turned off.
  Future<bool> _connect(String chosen) async {
    if (await connector.getDistributor() == null) {
      if (!(await connector.getDistributors()).contains(chosen)) return false;
      await connector.saveDistributor(chosen);
    }
    await connector.register();
    return true;
  }

  Future<void> _connectOrBreak(String chosen) async {
    var connected = false;
    try {
      connected = await _connect(chosen);
    } catch (_) {}
    if (!connected) await _broken(FailedReason.internalError);
  }

  /// On a trigger: retry a broken pick, or notice a working one that went
  /// away silently (ntfy turned off in its own app tells no one).
  Future<void> _recheck() async {
    if (_chosen != null && status.value.phase == UnifiedPushPhase.active) {
      try {
        if (await connector.getDistributor() == null) {
          await _broken(FailedReason.internalError);
        }
      } catch (_) {}
      return;
    }
    await retry();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _recheck().ignore();
  }

  void _onNetworkChanged() => _recheck().ignore();

  Future<void> _onNewEndpoint(PushEndpoint endpoint, String instance) async {
    _answers++;
    final keys = endpoint.pubKeySet;
    final chosen = _chosen;
    if (chosen == null) return;
    if (keys == null) {
      // Without Web Push keys the push server would read the sender id, so
      // such an endpoint is never used.
      await _broken(FailedReason.internalError);
      return;
    }
    _endpointReady(chosen, endpoint.url, keys.pubKey, keys.auth);
  }

  void _endpointReady(String chosen, String url, String p256dh, String auth) {
    final token =
        jsonEncode({'v': 1, 'endpoint': url, 'p256dh': p256dh, 'auth': auth});
    network_api
        .registerPushToken(token: token, platform: _relayPlatform)
        .catchError((_) {});
    _relayHoldsEndpoint = true;
    if (status.value.phase == UnifiedPushPhase.failed) {
      debugPrint('[HOLLOW-PUSH] UnifiedPush $chosen works again');
    }
    _calm();
    status.value =
        UnifiedPushStatus(UnifiedPushPhase.active, distributor: chosen);
  }

  Future<void> _onRegistrationFailed(FailedReason reason, String instance) {
    _answers++;
    return _broken(reason);
  }

  Future<void> _onUnregistered(String instance) async {
    // A late answer for a distributor the person already switched away from.
    if (await connector.getDistributor() != null) return;
    if (_chosen == null) {
      _fallBack();
      return;
    }
    // Uninstalled, or turned off in its own app: the pick stays.
    await _broken(FailedReason.internalError);
  }

  @visibleForTesting
  Future<void> registrationFailedForTest(FailedReason reason) =>
      _onRegistrationFailed(reason, '');

  @visibleForTesting
  Future<void> newEndpointForTest(PushEndpoint endpoint) =>
      _onNewEndpoint(endpoint, '');

  /// The chosen distributor answers with a keyed endpoint.
  @visibleForTesting
  void endpointForTest() {
    final chosen = _chosen;
    if (chosen != null) {
      _endpointReady(chosen, 'https://push.example/up', 'p256dh', 'auth');
    }
  }

  @visibleForTesting
  Future<void> unregisteredForTest() => _onUnregistered('');

  @visibleForTesting
  void networkChangedForTest() => _onNetworkChanged();

  /// The chosen service stopped working. The pick stays; only the first
  /// report of an outage covers or withdraws and starts the retries.
  Future<void> _broken(FailedReason reason) async {
    final chosen = _chosen;
    if (chosen == null) return;
    final already = status.value.phase == UnifiedPushPhase.failed;
    status.value = UnifiedPushStatus(UnifiedPushPhase.failed,
        distributor: chosen, failure: reason);
    if (already) return;
    _attentionTimer?.cancel();
    _attentionTimer = Timer(kPushAttentionGrace, () {
      if (status.value.phase == UnifiedPushPhase.failed) {
        needsAttention.value = true;
      }
    });
    _retryStep = 0;
    _armRetry();
    await _coverOrWithdraw();
  }

  /// While broken: Google covers if allowed, else the relay keeps no Google
  /// token (a UnifiedPush endpoint may stay, it costs nothing).
  Future<void> _coverOrWithdraw() async {
    final allowed = firebaseFallback.value ?? await loadFirebaseFallback();
    if (status.value.phase != UnifiedPushPhase.failed) return;
    debugPrint('[HOLLOW-PUSH] UnifiedPush ${status.value.distributor} broken: '
        '${allowed ? 'Google covers' : 'no Google, notifications off'}');
    if (allowed) {
      _relayHoldsEndpoint = false;
      onFallBackToFirebase?.call();
    } else if (!_relayHoldsEndpoint) {
      network_api.unregisterPushToken().catchError((_) {});
    }
  }

  void _armRetry() {
    _retryTimer?.cancel();
    final delay = kPushRetryDelays[
        _retryStep.clamp(0, kPushRetryDelays.length - 1)];
    _retryTimer = Timer(delay, () async {
      _retryStep++;
      await retry();
      if (status.value.phase == UnifiedPushPhase.failed) _armRetry();
    });
  }

  /// Ends an outage's timers and its Home item.
  void _calm() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _answerTimer?.cancel();
    _answerTimer = null;
    _attentionTimer?.cancel();
    _attentionTimer = null;
    needsAttention.value = false;
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

/// The phone's Home item for a broken chosen service, past the grace.
typedef PushAttention = ({
  String distributor,
  bool googleWakes,
  bool unanswered,
});

final pushAttentionProvider = Provider<PushAttention?>((ref) {
  final c = UnifiedPushController.instance;
  void changed() => ref.invalidateSelf();
  c.needsAttention.addListener(changed);
  c.firebaseFallback.addListener(changed);
  c.status.addListener(changed);
  ref.onDispose(() {
    c.needsAttention.removeListener(changed);
    c.firebaseFallback.removeListener(changed);
    c.status.removeListener(changed);
  });
  final distributor = c.status.value.distributor;
  if (!c.needsAttention.value || distributor == null) return null;
  return (
    distributor: distributor,
    googleWakes: !c.isActive,
    unanswered: c.status.value.unanswered,
  );
});
