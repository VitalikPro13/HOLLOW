import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Writes a tiny shared "push hints" cache into the iOS App Group container so
/// the Notification Service Extension can show a friend's real name and avatar
/// on a push banner: the extension runs in a separate sandbox and cannot read
/// the app's private encrypted DB.
///
/// `{ peerId: {name, avatar} }` in `push_hints/hints.json`, plus one
/// `push_hints/<peerId>.img` per friend with an avatar. Plaintext the user
/// already displays, contained to the app-private group container and kept out
/// of device backups (AppDelegate.swift). With App Lock on it holds only the
/// locked marker. iOS-only, a no-op everywhere else. Tier B, decrypted message
/// text or images in the banner, is deliberately NOT here.
class PushHintsCache {
  PushHintsCache._();

  static const _channel = MethodChannel('hollow/app_group');

  /// Coalesce bursts of profile/friend events into one cache write.
  static Timer? _debounce;

  /// The friend ids of the last write, so a block change can rewrite without
  /// its caller knowing the friend list.
  static List<String> _lastIds = const [];

  /// Resolves the iOS App Group container path via the native MethodChannel.
  /// Null on non-iOS or when the App Group is not configured.
  static Future<String?> _appGroupDir() async {
    if (!Platform.isIOS) return null;
    try {
      return await _channel.invokeMethod<String>('containerPath');
    } catch (e) {
      debugPrint('[HOLLOW-PUSHHINTS] App Group path unavailable: $e');
      return null;
    }
  }

  /// Schedules a debounced rewrite of the hints cache from the given friend
  /// ids. Safe to call frequently; the disk write happens at most once per
  /// ~1.5s.
  static void scheduleWrite(Iterable<String> friendPeerIds) {
    if (!Platform.isIOS) return;
    final ids = friendPeerIds.toList(growable: false);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), () {
      writeNow(ids).catchError((e) {
        debugPrint('[HOLLOW-PUSHHINTS] write failed: $e');
      });
    });
  }

  /// Rewrite from the last friend list, after a block or unblock.
  static void rewriteLast() => scheduleWrite(_lastIds);

  /// Set by [forget]: a pending debounced write must not bring the names back.
  static bool _forgotten = false;

  /// The wipe's step: the hints and the extension's own log go, and with
  /// [stopWriting] nothing is written again this launch. Both sit in the App
  /// Group container, outside the data root, so the extension can read them.
  static Future<void> forget({bool stopWriting = true}) async {
    if (stopWriting) _forgotten = true;
    _debounce?.cancel();
    _lastIds = const [];
    final dir = await _appGroupDir();
    if (dir == null) return;
    for (final name in ['push_hints', 'push_diag']) {
      try {
        final d = Directory('$dir/$name');
        if (d.existsSync()) d.deleteSync(recursive: true);
      } catch (_) {}
    }
  }

  /// Rewrite the shared push-hints cache immediately. iOS-only.
  static Future<void> writeNow(List<String> friendPeerIds) async {
    if (_forgotten) return;
    _lastIds = friendPeerIds;
    final dir = await _appGroupDir();
    if (dir == null) return;

    // A hint makes the extension name the sender and fetch; a blocked friend's
    // wake must stay the generic banner, never "Name: Sent you a message".
    var blocked = const <String>{};
    try {
      blocked = (await storage_api.loadBlockedPeers()).toSet();
    } catch (e) {
      debugPrint('[HOLLOW-PUSHHINTS] loadBlockedPeers failed: $e');
    }

    final base = Directory('$dir/push_hints');
    if (_forgotten) return;
    if (!base.existsSync()) base.createSync(recursive: true);

    // App Lock on: no name or avatar waits in the clear for the extension, and
    // the marker tells it to leave every banner generic (C-35).
    if (await _appLockOn()) {
      await _swapIn(base, {lockedMarkerKey: true});
      _prune(base, const {});
      return;
    }

    // The friend ids are MASTER ids, but a push `sender` is the relay-attested
    // DEVICE id of the sending device. The NSE does a raw `map[sender]` lookup
    // and has no resolver, so each friend's hint is additionally keyed under
    // EVERY device id resolving to that master; otherwise a device-id sender
    // misses and the banner degrades to a content-free "New message".
    final aliasesFor = <String, List<String>>{};
    try {
      for (final link in await network_api.getDeviceLinks()) {
        if (link.devicePeerId == link.masterPeerId) continue; // self-map: skip
        (aliasesFor[link.masterPeerId] ??= <String>[]).add(link.devicePeerId);
      }
    } catch (e) {
      debugPrint('[HOLLOW-PUSHHINTS] getDeviceLinks failed (master-only): $e');
    }

    final map = <String, dynamic>{};
    final keep = <String>{}; // avatar files to retain this pass

    for (final peerId in friendPeerIds) {
      if (_forgotten) return;
      if (blocked.contains(peerId)) continue;
      try {
        final profile = await storage_api.getProfileLight(peerId: peerId);
        final name = (profile != null && profile.displayName.isNotEmpty)
            ? profile.displayName
            : null;

        String? avatarPath;
        final bytes = await storage_api.getAvatar(peerId: peerId);
        if (bytes != null && bytes.isNotEmpty) {
          // The avatar file is keyed by the MASTER id, one per person, and
          // every alias entry below points at this same file.
          final f = File('${base.path}/$peerId.img');
          await f.writeAsBytes(bytes, flush: true);
          avatarPath = f.path;
          keep.add('$peerId.img');
        }

        if (name != null || avatarPath != null) {
          final entry = {
            'name': ?name,
            'avatar': ?avatarPath,
          };
          // Keyed under the master AND every known device id of this friend,
          // so `map[sender]` in the NSE hits whichever device sent it.
          map[peerId] = entry;
          for (final deviceId in aliasesFor[peerId] ?? const <String>[]) {
            map[deviceId] = entry;
          }
        }
      } catch (e) {
        debugPrint('[HOLLOW-PUSHHINTS] skip $peerId: $e');
      }
    }

    await _swapIn(base, map);
    _prune(base, keep);
    debugPrint('[HOLLOW-PUSHHINTS] wrote ${map.length} hint(s)');
  }

  /// The key `NotificationService.swift` reads: present, it shows only the
  /// generic banner and fetches nothing.
  static const lockedMarkerKey = '~locked';

  static Future<bool> _appLockOn() async {
    try {
      return (await identity_api.getIdentityProtectionStatus()).hasPassword;
    } catch (_) {
      return true;
    }
  }

  /// Atomic swap so the extension never reads a half-written file.
  static Future<void> _swapIn(Directory base, Map<String, dynamic> map) async {
    if (_forgotten) return;
    try {
      final tmp = File('${base.path}/hints.json.tmp');
      await tmp.writeAsString(jsonEncode(map), flush: true);
      await tmp.rename('${base.path}/hints.json');
    } catch (e) {
      debugPrint('[HOLLOW-PUSHHINTS] hints.json write failed: $e');
    }
  }

  /// Drops avatar files for peers no longer in the list.
  static void _prune(Directory base, Set<String> keep) {
    try {
      for (final entity in base.listSync()) {
        if (entity is File && entity.path.endsWith('.img')) {
          final name = entity.uri.pathSegments.last;
          if (!keep.contains(name)) {
            entity.deleteSync();
          }
        }
      }
    } catch (_) {}
  }
}
