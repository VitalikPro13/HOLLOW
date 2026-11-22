import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../hidden_notification.dart';
import '../models/call_record.dart';
import '../providers/app_lock_provider.dart';
import '../providers/call_provider.dart';
import '../providers/conference_provider.dart';
import '../providers/duress_provider.dart';
import '../providers/os_call_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shell_tab.dart' show ProviderRead;
import '../providers/voice_channel_provider.dart';
import '../../rust/api/network.dart' as network_api;

/// The `hollow/os_call` channel (DESIGN_OS_CALLS 1.2), behind an interface so
/// tests can stand in for CallKit and Telecom.
abstract class OsCallChannel {
  Future<Object?> invoke(String method, [Map<String, Object?>? args]);
  void setHandler(
      Future<Object?> Function(String method, Map<Object?, Object?> args)?
          handler);
}

class MethodOsCallChannel implements OsCallChannel {
  static const _channel = MethodChannel('hollow/os_call');

  const MethodOsCallChannel();

  @override
  Future<Object?> invoke(String method, [Map<String, Object?>? args]) =>
      _channel.invokeMethod<Object?>(method, args);

  @override
  void setHandler(
      Future<Object?> Function(String method, Map<Object?, Object?> args)?
          handler) {
    _channel.setMethodCallHandler(handler == null
        ? null
        : (call) => handler(call.method,
            (call.arguments as Map<Object?, Object?>?) ?? const {}));
  }
}

final osCallChannelProvider =
    Provider<OsCallChannel>((_) => const MethodOsCallChannel());

/// The OS call mirror, or null where nothing is mirrored (desktops).
final osCallServiceProvider = Provider<OsCallService?>((ref) {
  if (!osCallPlatform) return null;
  final service = OsCallService(ref.read, ref.watch(osCallChannelProvider));
  // The SOURCES, never the derived providers: Riverpod refreshes a derived
  // provider only on a Flutter frame and a locked phone draws none, so a
  // remote hang-up would leave the OS call up until the app is opened. A
  // read recomputes a derived provider at once.
  void poke(_, _) => service.poke();
  ref.listen(callProvider, poke);
  ref.listen(voiceChannelProvider, poke);
  ref.listen(conferenceProvider, poke);
  ref.listen(appLockedProvider, poke);
  ref.listen(identityProtectionProvider, poke);
  ref.onDispose(service.dispose);
  service.start();
  return service;
});

/// True when the OS holds our call (a carrier call took it): the caller must
/// not act locally; the OS is asked to resume and decides (A2-4).
bool osCallHoldIntercept(ProviderRead read) {
  final service = read(osCallServiceProvider);
  if (service == null || !service.held) return false;
  service.requestUnhold();
  return true;
}

/// [act] behind the hold guard, for the in-call unmute, undeafen and similar
/// controls; null stays null so a disabled control stays disabled.
VoidCallback? unlessOsHeld(ProviderRead read, VoidCallback? act) =>
    act == null
        ? null
        : () {
            if (osCallHoldIntercept(read)) return;
            act();
          };

class _Mirror {
  final String key;
  final OsCallKind kind;
  String uuid;
  String title;
  bool connected = false;
  bool sentMuted = false;
  bool sentVideo;

  /// Native runs it without the OS (CallKit refused or late, Telecom absent):
  /// never begun again on a reset, still ended.
  bool unmirrored = false;
  bool held = false;
  ({bool muted, bool deafened})? beforeHold;

  _Mirror(this.key, this.kind, this.uuid, this.title, this.sentVideo);
}

/// Mirrors the one live call, voice room or meeting to the OS (#154,
/// DESIGN_OS_CALLS). Every native call goes through ONE queue, one at a time
/// and in order, and each step reconciles against the session as it is THEN,
/// so a burst of state changes converges on the latest. OS actions run through
/// the app's own paths; nothing here decides admission.
class OsCallService {
  final ProviderRead _read;
  final OsCallChannel _channel;
  final Random _random;
  final Duration nativeTimeout;

  /// File-visible log (hollow_debug.log); tests swap it out.
  @visibleForTesting
  static void Function(String line) log = _logToFile;

  /// Stands in for the build's `HOLLOW_OS_CALL_FALLBACK` define in tests.
  @visibleForTesting
  static bool? debugForceFallback;

  /// Debug builds only (`--dart-define=HOLLOW_OS_CALL_FALLBACK=1`): native
  /// runs every session without the OS call, for the device checks of the
  /// fallback path. A release or profile build never sends it.
  static bool get _forceFallback =>
      kDebugMode &&
      (debugForceFallback ??
          const String.fromEnvironment('HOLLOW_OS_CALL_FALLBACK') == '1');

  OsCallService(this._read, this._channel,
      {Random? random, this.nativeTimeout = const Duration(seconds: 5)})
      : _random = random ?? Random.secure();

  _Mirror? _live;

  /// Every uuid begun and not yet ended, oldest first: `begin` hands native the
  /// set so it can drop anything it still holds outside it (N2).
  final List<String> _open = [];
  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// Whether the OS holds our call right now.
  bool get held => _live?.held ?? false;

  @visibleForTesting
  String? get liveUuid => _live?.uuid;

  /// What the fleet probe reads: the mirrored session as the queue last left
  /// it (`osCall`: none, or kind and phase), whether CallKit or Telecom holds
  /// it, and the mute the OS was last told.
  Map<String, Object> get probe {
    final mirror = _live;
    if (mirror == null) return const {'osCall': 'none'};
    return {
      'osCall': '${mirror.kind.name} ${mirror.connected ? 'live' : 'placing'}',
      'osCallMirrored': !mirror.unmirrored,
      'osCallMuted': mirror.sentMuted,
      'osCallHeld': mirror.held,
    };
  }

  /// The queue's tail, for tests that wait for it to drain.
  @visibleForTesting
  Future<void> get settled => _tail;

  void start() {
    _channel.setHandler(_onNative);
    _enqueue(() async {
      final available = await _send(
          'available', _forceFallback ? const {'forceFallback': true} : null);
      log('[HOLLOW-OSCALL] available=$available');
    });
    poke();
  }

  void dispose() {
    _disposed = true;
    _channel.setHandler(null);
  }

  /// Reconcile with the current session, after whatever is queued.
  void poke() => _enqueue(_reconcile);

  void _enqueue(Future<void> Function() step) {
    _tail = _tail.then((_) async {
      if (_disposed) return;
      try {
        await step();
      } catch (e) {
        log('[HOLLOW-OSCALL] step failed: $e');
      }
    });
  }

  Future<void> _reconcile() async {
    final want = _read(osSessionProvider);
    var mirror = _live;
    if (mirror != null && (want == null || want.key != mirror.key)) {
      _live = null;
      await _end(mirror);
      mirror = null;
    }
    if (want == null) return;
    mirror ??= await _begin(want);
    if (want.live && !mirror.connected) {
      mirror.connected = true;
      await _send('connected', {'uuid': mirror.uuid});
    }
    if (want.muted != mirror.sentMuted) {
      mirror.sentMuted = want.muted;
      await _send('setMuted', {'uuid': mirror.uuid, 'muted': want.muted});
    }
    // One way only: a title that may no longer show turns "Hollow" and is
    // never named again in this session (1.6).
    var retitle = false;
    if (mirror.title != kHiddenNotificationTitle &&
        !_read(osContentAllowedProvider)) {
      mirror.title = kHiddenNotificationTitle;
      retitle = true;
    }
    if (retitle || want.video != mirror.sentVideo) {
      mirror.sentVideo = want.video;
      await _send('update',
          {'uuid': mirror.uuid, 'title': mirror.title, 'video': want.video});
    }
  }

  Future<_Mirror> _begin(OsSession want) async {
    final mirror = _Mirror(want.key, want.kind, _mintUuid(),
        osCallTitle(_read, want), want.video);
    _live = mirror;
    await _sendBegin(mirror, outgoing: want.outgoing);
    return mirror;
  }

  Future<void> _sendBegin(_Mirror mirror, {required bool outgoing}) async {
    _open.add(mirror.uuid);
    final answer = await _send('begin', {
      'uuid': mirror.uuid,
      'kind': mirror.kind.name,
      'title': mirror.title,
      'video': mirror.sentVideo,
      'outgoing': outgoing,
      'loud': _startsLoud(mirror),
      'live': List<String>.of(_open),
    });
    if (answer is! Map || answer['ok'] != true) {
      mirror.unmirrored = true;
      log(mirror.kind == OsCallKind.dm
          ? '[HOLLOW-OSCALL] dm runs without the OS call'
          : '[HOLLOW-OSCALL] ${mirror.kind.name} runs in the app');
    }
  }

  bool _startsLoud(_Mirror mirror) {
    if (mirror.kind != OsCallKind.dm) return true;
    bool stored;
    try {
      stored = _read(startCallsOnSpeakerProvider).valueOrNull ??
          kStartCallsOnSpeakerDefault;
    } catch (_) {
      stored = kStartCallsOnSpeakerDefault;
    }
    return dmCallStartsLoud(video: mirror.sentVideo, startOnSpeaker: stored);
  }

  Future<void> _end(_Mirror mirror) async {
    _open.remove(mirror.uuid);
    await _send('end', {'uuid': mirror.uuid, 'reason': _endReason(mirror)});
  }

  String _endReason(_Mirror mirror) {
    if (mirror.kind != OsCallKind.dm) return 'local';
    CallEndCause? cause;
    try {
      cause = _read(callProvider.notifier).lastEndCause;
    } catch (_) {}
    return switch (cause) {
      CallEndCause.linkLost => 'failed',
      CallEndCause.remoteEnd ||
      CallEndCause.remoteReject ||
      CallEndCause.remoteBusy ||
      CallEndCause.ringTimeout ||
      CallEndCause.answeredElsewhere =>
        'remote',
      _ => 'local',
    };
  }

  /// A native call that never throws into the queue: a missing or wedged
  /// native side costs a log line and the call goes on as before.
  Future<Object?> _send(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invoke(method, args).timeout(nativeTimeout);
    } catch (e) {
      log('[HOLLOW-OSCALL] $method failed: $e');
      return null;
    }
  }

  /// Asks the OS to take our call off hold; it answers with `osHold(false)`.
  void requestUnhold() {
    final mirror = _live;
    if (mirror == null || !mirror.held) return;
    _enqueue(() => _send('requestUnhold', {'uuid': mirror.uuid}));
  }

  Future<Object?> _onNative(String method, Map<Object?, Object?> args) async {
    final uuid = args['uuid'];
    if (method == 'osReset') {
      _enqueue(_rebeginAfterReset);
      return null;
    }
    final mirror = _live;
    if (mirror == null || uuid != mirror.uuid) {
      log('[HOLLOW-OSCALL] $method for a call we do not hold');
      return null;
    }
    switch (method) {
      case 'osEnd':
        _osEnd(mirror);
      case 'osMute':
        _osMute(mirror, args['muted'] == true);
      case 'osHold':
        _osHold(mirror, args['held'] == true);
      case 'osFailed':
        mirror.unmirrored = true;
        // A room or meeting always runs in the app (begin logged it); only a
        // DM call that the OS refused is news.
        if (mirror.kind == OsCallKind.dm) {
          log('[HOLLOW-OSCALL] OS call failed (${args['why']}); '
              'the dm goes on without it');
        }
    }
    return null;
  }

  /// The person hung up from the lock screen, the island, a headset or a car:
  /// the app's own leave. A meeting guest leaves the meeting, a host steps out
  /// (it runs on), a room is left; never a bare voice leave.
  void _osEnd(_Mirror mirror) {
    if (_read(osSessionProvider)?.key != mirror.key) return;
    final Future<void> leaving = mirror.kind == OsCallKind.dm
        ? _read(callProvider.notifier).endCall()
        : leaveVoiceForDmCall(_read);
    unawaited(leaving.catchError((Object e) {
      log('[HOLLOW-OSCALL] OS hang-up failed: $e');
    }));
  }

  ({bool muted, bool deafened}) _audio(OsCallKind kind) {
    if (kind == OsCallKind.dm) {
      final call = _read(callProvider);
      return (muted: call.isMuted, deafened: call.isDeafened);
    }
    final voice = _read(voiceChannelProvider);
    return (muted: voice.isMuted, deafened: voice.isDeafened);
  }

  void _toggleMute(OsCallKind kind) => kind == OsCallKind.dm
      ? _read(callProvider.notifier).toggleMute()
      : _read(voiceChannelProvider.notifier).toggleMute();

  void _toggleDeafen(OsCallKind kind) => kind == OsCallKind.dm
      ? _read(callProvider.notifier).toggleDeafen()
      : _read(voiceChannelProvider.notifier).toggleDeafen();

  /// The OS muted or unmuted us. The app's own toggle decides (it may refuse:
  /// a moderator's mute, push-to-talk, not connected yet), and the OS is then
  /// told the truth, so it never shows a state we are not in (A2-8). A value
  /// that only repeats what we last told it is our own echo.
  void _osMute(_Mirror mirror, bool muted) {
    if (muted == _audio(mirror.kind).muted && muted == mirror.sentMuted) return;
    if (muted != _audio(mirror.kind).muted) _toggleMute(mirror.kind);
    _enqueue(() async {
      if (!identical(_live, mirror)) return;
      final truth = _audio(mirror.kind).muted;
      mirror.sentMuted = truth;
      await _send('setMuted', {'uuid': mirror.uuid, 'muted': truth});
    });
  }

  /// A carrier call, headset or car put us on hold: deafen (which mutes the
  /// mic and tells the others), and give back exactly what we had once the OS
  /// resumes us. Only the OS resumes (A2-4).
  void _osHold(_Mirror mirror, bool held) {
    if (held) {
      if (mirror.held) return;
      final before = _audio(mirror.kind);
      mirror
        ..held = true
        ..beforeHold = before;
      if (!before.deafened) _toggleDeafen(mirror.kind);
      return;
    }
    if (!mirror.held) return;
    mirror.held = false;
    final before = mirror.beforeHold;
    mirror.beforeHold = null;
    if (before == null) return;
    if (_audio(mirror.kind).deafened != before.deafened) {
      _toggleDeafen(mirror.kind);
    }
    if (_audio(mirror.kind).muted != before.muted) _toggleMute(mirror.kind);
  }

  /// CallKit restarted and forgot its calls: the live session is begun again
  /// under a new uuid. An app session is never ended by it.
  Future<void> _rebeginAfterReset() async {
    final mirror = _live;
    if (mirror == null || mirror.unmirrored) return;
    // The forgotten call can never be resumed, so a hold gives its audio back.
    if (mirror.held) _osHold(mirror, false);
    _open.remove(mirror.uuid);
    mirror
      ..uuid = _mintUuid()
      ..connected = false
      ..sentMuted = false;
    final want = _read(osSessionProvider);
    await _sendBegin(mirror, outgoing: want?.outgoing ?? true);
    await _reconcile();
  }

  /// A random v4 uuid: never derived from a call, server, meeting or peer id.
  String _mintUuid() {
    final b = List<int>.generate(16, (_) => _random.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
        '${h.substring(16, 20)}-${h.substring(20)}';
  }
}

void _logToFile(String line) {
  debugPrint(line);
  try {
    unawaited(network_api.logFromDart(message: line).catchError((_) {}));
  } catch (_) {}
}
