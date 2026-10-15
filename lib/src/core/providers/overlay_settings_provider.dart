import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/overlay_look.dart';
import 'package:hollow/src/core/providers/app_lock_provider.dart';
import 'package:hollow/src/core/providers/device_link_provider.dart';
import 'package:hollow/src/core/models/node_status.dart';
import 'package:hollow/src/core/providers/identity_provider.dart';
import 'package:hollow/src/core/providers/node_provider.dart';
import 'package:hollow/src/core/providers/overlay_mic_provider.dart';
import 'package:hollow/src/core/providers/overlay_runtime_provider.dart';
import 'package:hollow/src/core/providers/roster_provider.dart';
import 'package:hollow/src/core/services/overlay_mic.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/overlay.dart' as overlay_api;
import 'package:hollow/src/rust/api/overlay.dart' show OverlayImageFfi;
import 'package:hollow/src/rust/api/overlay_server.dart' as server_api;
import 'package:hollow/src/rust/api/overlay_server.dart'
    show OverlayLinksFfi, OverlayServerStatusFfi;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

export 'package:hollow/src/rust/api/overlay.dart' show OverlayImageFfi;
export 'package:hollow/src/rust/api/overlay_server.dart'
    show OverlayLinksFfi, OverlayServerStatusFfi;

/// The stream overlay's settings for the UI and the publisher (#97, plan 3):
/// our own look and the two identity-wide toggles, the people on our overlay,
/// each person's field, the OBS layout, the server, and listening.

void _log(String message) {
  debugPrint(message);
  try {
    network_api.logFromDart(message: message).catchError((_) {});
  } catch (_) {}
}

// ---------------------------------------------------------------------------
// Our own look and the two toggles (identity-wide, Rust keeps them)

typedef OverlayOwn = ({bool allow, bool share, OverlayLook look});

/// "Let others show me", "Share my overlay images" and our own look. Reads
/// need the node running.
final overlayOwnProvider =
    AsyncNotifierProvider<OverlayOwnNotifier, OverlayOwn>(
        OverlayOwnNotifier.new);

class OverlayOwnNotifier extends AsyncNotifier<OverlayOwn> {
  @override
  Future<OverlayOwn> build() async {
    // A sibling saved a look or flipped a toggle.
    ref.listen<String?>(overlayLookReceivedProvider, (_, master) {
      if (master != null && master == ref.read(identityProvider).peerId) {
        ref.invalidateSelf();
      }
    });
    ref.listen<int>(overlayFieldRevisionProvider, (_, _) => ref.invalidateSelf());
    _retryOnceTheNodeRuns(ref, () => state.hasError);
    final s = await overlay_api.overlayGetSettings();
    return (
      allow: s.allow,
      share: s.allow && s.share,
      look: _parseOwnLook(s.ownLookJson),
    );
  }

  /// Both toggles; [share] is forced off while [allow] is off. Rethrows, with
  /// the previous values back in place.
  Future<void> setFlags({required bool allow, required bool share}) async {
    final share2 = allow && share;
    final before = state.valueOrNull;
    if (before != null) {
      state = AsyncData((allow: allow, share: share2, look: before.look));
    }
    try {
      await overlay_api.overlaySetFlags(allow: allow, share: share2);
    } catch (_) {
      if (before != null) state = AsyncData(before);
      rethrow;
    }
  }

  /// Saves our look and returns it as Rust stored it (canonical, new stamp).
  Future<OverlayLook> saveLook(OverlayLook look) async {
    final canonical =
        await overlay_api.overlaySetOwnLook(lookJson: look.toJson());
    final saved = _parseOwnLook(canonical);
    final now = state.valueOrNull;
    if (now != null) {
      state = AsyncData((allow: now.allow, share: now.share, look: saved));
    } else {
      ref.invalidateSelf();
    }
    return saved;
  }

  /// Turns a picked file into a look image (stored, not yet saved in a look).
  Future<OverlayImageFfi> processImage(String path) =>
      overlay_api.overlayProcessImage(path: path);
}

/// A read made before the node ran failed; it is made again once it runs.
void _retryOnceTheNodeRuns(Ref ref, bool Function() failed) {
  ref.listen<NodeStatus>(nodeProvider.select((n) => n.status), (_, status) {
    if (status == NodeStatus.connected && failed()) ref.invalidateSelf();
  });
}

OverlayLook _parseOwnLook(String json) {
  try {
    return OverlayLook.fromJson(json);
  } on FormatException {
    return OverlayLook(effects: OverlayEffects.defaults);
  }
}

// ---------------------------------------------------------------------------
// People on our overlay (this device and profile only)

/// Everyone we added, by slot. Reloads whenever a look arrives, a field
/// changes or the list itself changed.
final overlayPeopleProvider =
    AsyncNotifierProvider<OverlayPeopleNotifier, List<OverlayPerson>>(
        OverlayPeopleNotifier.new);

class OverlayPeopleNotifier extends AsyncNotifier<List<OverlayPerson>> {
  @override
  Future<List<OverlayPerson>> build() async {
    ref.watch(overlayPeopleRevisionProvider);
    _retryOnceTheNodeRuns(ref, () => state.hasError);
    final rows = await overlay_api.overlayPeople();
    return [for (final r in rows) OverlayPerson.fromFfi(r)]
      ..sort((a, b) => a.slot.compareTo(b.slot));
  }

  /// Adds a person and returns their slot. A device id is collapsed to its
  /// master first. Refused (throws) for ourselves, a blocked identity, or a
  /// field that says off.
  Future<int> add(String master) async {
    final slot =
        await overlay_api.overlayAddPerson(master: _identity(master));
    _changed();
    return slot.toInt();
  }

  Future<bool> remove(String master) async {
    final removed =
        await overlay_api.overlayRemovePerson(master: _identity(master));
    _changed();
    return removed;
  }

  /// Our picks for a person; null or an empty look clears them.
  Future<void> setLocal(String master, OverlayLook? look) async {
    await overlay_api.overlaySetLocalLook(
      master: _identity(master),
      lookJson: look == null || look.isEmpty ? null : look.toJson(),
    );
    _changed();
  }

  String _identity(String id) => ref.read(deviceLinkProvider).identityOf(id);

  void _changed() => ref.read(overlayPeopleRevisionProvider.notifier).state++;
}

/// A person's field ("off" | "show" | "share", by MASTER id); "show" when it
/// cannot be read, as for a client that predates the field.
final overlayFieldProvider =
    Provider.autoDispose.family<String, String>((ref, master) {
  ref.watch(overlayFieldRevisionProvider);
  try {
    return overlay_api.overlayFieldOf(master: master);
  } catch (_) {
    return 'show';
  }
});

// ---------------------------------------------------------------------------
// OBS layout (this computer, per profile)

const _kLayoutKey = 'overlay_layout';

final overlayLayoutProvider =
    NotifierProvider<OverlayLayoutNotifier, OverlayLayout>(
        OverlayLayoutNotifier.new);

class OverlayLayoutNotifier extends Notifier<OverlayLayout> {
  @override
  OverlayLayout build() => OverlayLayout();

  /// From the shell's bootstrap, once the store is open.
  Future<void> load() async {
    try {
      state = OverlayLayout.decode(
          await storage_api.loadSetting(key: _kLayoutKey));
    } catch (e) {
      _log('[OVERLAY] layout load failed: $e');
    }
  }

  /// Shows the new layout at once and saves it; rethrows a failed save.
  Future<void> update(OverlayLayout layout) async {
    state = layout;
    await storage_api.saveSetting(key: _kLayoutKey, value: layout.encode());
  }
}

// ---------------------------------------------------------------------------
// The server for OBS (desktop, this computer, per profile)

typedef OverlayServer = ({
  OverlayServerStatusFfi status,
  OverlayLinksFfi? links,
});

/// Whether this platform runs the server: phones have no OBS. Swappable in
/// tests.
bool Function() overlayServerSupported =
    () => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

const _stopped = OverlayServerStatusFfi(
  enabled: false,
  running: false,
  port: 0,
  portChanged: false,
  openStreams: 0,
);

/// "Run the overlay for OBS": the status, the links, and the lock. Pages
/// serve only while the app is unlocked: the server is unlocked only after it
/// started, and App Lock or a roster lock locks it at once.
final overlayServerProvider =
    NotifierProvider<OverlayServerNotifier, OverlayServer>(
        OverlayServerNotifier.new);

class OverlayServerNotifier extends Notifier<OverlayServer> {
  @override
  OverlayServer build() {
    ref.listen<bool>(appLockedProvider, (_, _) => _syncLock());
    ref.listen<RosterGate>(rosterGateProvider, (_, _) => _syncLock());
    ref.listen<int?>(overlayPortChangedProvider, (_, port) {
      if (port != null) refresh().catchError((_) {});
    });
    ref.listen<int>(overlayOpenStreamsProvider, (_, open) {
      final s = state.status;
      if (s.openStreams == open) return;
      state = (
        status: OverlayServerStatusFfi(
          enabled: s.enabled,
          running: s.running,
          port: s.port,
          portChanged: s.portChanged,
          openStreams: open,
        ),
        links: state.links,
      );
    });
    return (status: _stopped, links: null);
  }

  bool get _appLocked =>
      ref.read(appLockedProvider) ||
      ref.read(rosterGateProvider).kind != RosterGateKind.none;

  /// From the shell's bootstrap, after the node started: starts the server
  /// again when it was on. Never throws.
  Future<void> restore() async {
    if (!overlayServerSupported()) return;
    try {
      final status = await server_api.overlayServerStatus();
      _set(status, state.links);
      if (status.enabled) {
        await _start();
      } else {
        await _loadLinks();
      }
    } catch (e) {
      _log('[OVERLAY] server restore failed: $e');
    }
  }

  /// Turns the server on or off and saves the choice. Rethrows a failure.
  Future<void> setEnabled(bool enabled) async {
    if (enabled) {
      if (!overlayServerSupported()) {
        throw StateError('The overlay for OBS runs on desktop only.');
      }
      await _start();
      return;
    }
    final status =
        await server_api.overlayServerSetEnabled(enabled: false);
    _set(status, state.links);
    ref.read(overlayPortChangedProvider.notifier).state = null;
  }

  /// A new token: every old link stops working.
  Future<void> resetLink() async {
    final links = await server_api.overlayServerResetLink();
    final status = await server_api.overlayServerStatus();
    _set(status, links);
    ref.read(overlayPortChangedProvider.notifier).state = null;
  }

  Future<void> refresh() async {
    final status = await server_api.overlayServerStatus();
    _set(status, state.links);
    await _loadLinks();
  }

  /// Enable, THEN unlock: the server starts locked, so a page never sees
  /// anything before we know the app is open.
  Future<void> _start() async {
    final status = await server_api.overlayServerSetEnabled(enabled: true);
    _set(status, state.links);
    await _syncLock();
    await _loadLinks();
  }

  Future<void> _loadLinks() async {
    try {
      final links = await server_api.overlayServerLinks();
      _set(state.status, links);
    } catch (_) {
      // Never ran on this profile: no links yet.
    }
  }

  /// Locking is sent whenever it happens; unlocking only to a running server.
  Future<void> _syncLock() async {
    final locked = _appLocked;
    if (!locked && !state.status.running) return;
    try {
      await server_api.overlayServerSetLocked(locked: locked);
    } catch (e) {
      _log('[OVERLAY] set_locked($locked) failed: $e');
    }
  }

  void _set(OverlayServerStatusFfi status, OverlayLinksFfi? links) {
    state = (status: status, links: links);
    ref.read(overlayServerRunningProvider.notifier).state = status.running;
    ref.read(overlayOpenStreamsProvider.notifier).state = status.openStreams;
  }
}

// ---------------------------------------------------------------------------
// Listening outside a call (desktop)

typedef OverlayListenSettings = ({double thresholdDb, bool showIdleWhenInactive});

const _kThresholdKey = 'overlay_listen_threshold_db';

/// The sensitivity slider's range, in dBFS.
const double kOverlayListenThresholdMinDb = -70;
const double kOverlayListenThresholdMaxDb = -10;

/// The sensitivity and what "just me" shows while we neither talk in a call
/// nor listen. The "Listen to my mic now" button itself is never saved.
final overlayListenSettingsProvider =
    NotifierProvider<OverlayListenSettingsNotifier, OverlayListenSettings>(
        OverlayListenSettingsNotifier.new);

class OverlayListenSettingsNotifier extends Notifier<OverlayListenSettings> {
  double _thresholdDb = OverlayMic.defaultThresholdDb;

  @override
  OverlayListenSettings build() {
    // One saved value: the layout's `self_when_inactive`, which the page reads.
    final idle = ref.watch(
        overlayLayoutProvider.select((l) => l.selfWhenInactive == 'idle'));
    return (thresholdDb: _thresholdDb, showIdleWhenInactive: idle);
  }

  /// From the shell's bootstrap, once the store is open.
  Future<void> load() async {
    try {
      final raw = await storage_api.loadSetting(key: _kThresholdKey);
      final db = double.tryParse(raw ?? '');
      if (db != null && db.isFinite) _setThreshold(db);
    } catch (e) {
      _log('[OVERLAY] listen settings load failed: $e');
    }
    _apply();
  }

  Future<void> setThresholdDb(double db) async {
    _setThreshold(db);
    _apply();
    await storage_api.saveSetting(
        key: _kThresholdKey, value: _thresholdDb.toString());
  }

  Future<void> setShowIdleWhenInactive(bool show) {
    final layouts = ref.read(overlayLayoutProvider.notifier);
    return layouts.update(ref
        .read(overlayLayoutProvider)
        .copyWith(selfWhenInactive: show ? 'idle' : 'hidden'));
  }

  void _setThreshold(double db) {
    _thresholdDb = db
        .clamp(kOverlayListenThresholdMinDb, kOverlayListenThresholdMaxDb)
        .toDouble();
    state = (
      thresholdDb: _thresholdDb,
      showIdleWhenInactive: state.showIdleWhenInactive,
    );
  }

  void _apply() =>
      ref.read(overlayMicProvider.notifier).setThresholdDb(_thresholdDb);
}

// ---------------------------------------------------------------------------
// Image bytes

final _hashShape = RegExp(r'^[0-9a-f]{64}$');

/// A look image's bytes (WebP), or null when we do not hold it. The ONE way
/// Dart reads overlay images.
Future<Uint8List?> overlayImageBytes(String hash) async {
  if (!_hashShape.hasMatch(hash)) return null;
  try {
    return await overlay_api.overlayImageBytes(hash: hash);
  } catch (_) {
    return null;
  }
}
