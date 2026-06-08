import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/rust/api/identity.dart' as identity_api;
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/rust/frb_generated.dart';

/// Tracks whether `RustLib.init()` has run in THIS isolate. Android reuses the
/// FCM background isolate across pushes, and a second init() call throws. This
/// flag (plus the error guard below) makes the handler robust to reuse.
bool _rustInitializedInIsolate = false;

/// True if [e] is flutter_rust_bridge's "already initialized" error, which means
/// Rust is ready (not a real failure).
bool _isAlreadyInitializedError(Object e) {
  final s = e.toString().toLowerCase();
  return s.contains('initialize flutter_rust_bridge twice') ||
      s.contains('should not initialize') ||
      s.contains('already init');
}

// ── Notification line cache ────────────────────────────────────────────────
// Accumulates recent message previews per sender across SEPARATE push wakeups so
// the notification stacks them (inbox style) instead of replacing. Each fetch
// only returns its own batch; this bridges batches that arrive in different
// pushes. Capped + TTL'd so it can't grow unbounded; reset when the chat is
// opened (clearNotificationLines, called from the foreground).
const int _maxCachedLines = 6;
const int _lineCacheTtlMs = 60 * 60 * 1000; // 1 hour

Future<File> _lineCacheFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File('${dir.path}/hollow/push_lines.json');
}

/// Merge [newItems] (message_id → text) for [sender] into the cached list and
/// return the accumulated, most-recent window (oldest first, capped at
/// [_maxCachedLines]). Entries are keyed by message_id so an EDIT (same id with
/// new text) REPLACES the previous line in place rather than stacking a second
/// entry — that's what makes an edited message update its notification line
/// instead of appearing as a separate message.
Future<List<String>> _accumulateLines(
    String sender, List<MapEntry<String, String>> newItems) async {
  Map<String, dynamic> data = {};
  try {
    final f = await _lineCacheFile();
    if (await f.exists()) {
      data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    }
  } catch (_) {}

  final nowMs = DateTime.now().millisecondsSinceEpoch;
  final entry = (data[sender] as Map<String, dynamic>?) ?? {};
  final lastMs = (entry['ts'] as int?) ?? 0;
  final expired = (nowMs - lastMs) > _lineCacheTtlMs;

  // Ordered list of {id, text}. Preserve order; replace by id on edit.
  final items = <Map<String, String>>[];
  if (!expired) {
    for (final e in (entry['items'] as List?) ?? const []) {
      final m = (e as Map).cast<String, dynamic>();
      items.add({'id': '${m['id']}', 'text': '${m['text']}'});
    }
  }

  for (final it in newItems) {
    final id = it.key;
    final text = it.value;
    final idx = id.isNotEmpty ? items.indexWhere((m) => m['id'] == id) : -1;
    if (idx >= 0) {
      items[idx]['text'] = text; // edit: replace in place, keep position
    } else {
      items.add({'id': id, 'text': text});
    }
  }

  final windowed = items.length > _maxCachedLines
      ? items.sublist(items.length - _maxCachedLines)
      : items;

  data[sender] = {'ts': nowMs, 'items': windowed};
  try {
    final f = await _lineCacheFile();
    await f.writeAsString(jsonEncode(data));
  } catch (_) {}
  return windowed.map((m) => m['text'] ?? '').toList();
}

/// Clear cached notification lines for a sender (call when the user opens that
/// chat so the next message starts a fresh stack). Pass null to clear all.
Future<void> clearNotificationLines(String? sender) async {
  try {
    final f = await _lineCacheFile();
    if (!await f.exists()) return;
    if (sender == null) {
      await f.writeAsString('{}');
      return;
    }
    final data = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    data.remove(sender);
    await f.writeAsString(jsonEncode(data));
  } catch (_) {}
}

Future<void> _pushLog(String msg) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/hollow/push_debug.log');
    // Cap the log: if it exceeds 1MB, keep only the last ~256KB (trim to the
    // next line boundary) so it can't grow unbounded across many pushes.
    const maxBytes = 1024 * 1024;
    const keepBytes = 256 * 1024;
    try {
      if (await file.exists() && await file.length() > maxBytes) {
        final data = await file.readAsBytes();
        var start = data.length - keepBytes;
        if (start < 0) start = 0;
        final nl = data.indexOf(0x0a, start);
        if (nl != -1 && nl + 1 < data.length) start = nl + 1;
        await file.writeAsBytes(data.sublist(start));
      }
    } catch (_) {}
    final ts = DateTime.now().toIso8601String();
    await file.writeAsString('$ts $msg\n', mode: FileMode.append);
  } catch (_) {}
}

@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}

  await _pushLog('Handler started, data=${message.data}');

  final sender = message.data['sender'] as String?;
  if (sender == null || sender.isEmpty) {
    await _pushLog('No sender in payload, showing generic');
    await _showGenericNotification();
    return;
  }

  // Initialize Rust FFI. CRITICAL: Android reuses the background isolate across
  // multiple FCM messages, but `RustLib.init()` is NOT idempotent — calling it a
  // second time in the same isolate throws "Should not initialize
  // flutter_rust_bridge twice". When that happens Rust is ALREADY initialized
  // and fully usable, so we must treat it as success (not failure). The previous
  // code aborted here, which is exactly why every push after the first degraded
  // to peer-ID-with-no-avatar.
  bool rustReady = false;
  try {
    await initHollowDataDir();
    await _pushLog('Data dir initialized: $hollowDataDir');

    if (_rustInitializedInIsolate) {
      await _pushLog('RustLib already initialized in this isolate — reusing');
    } else {
      try {
        await RustLib.init();
        _rustInitializedInIsolate = true;
        await _pushLog('RustLib.init() OK');
      } catch (e) {
        // Idempotency guard: a second init in a reused isolate throws but Rust
        // is in fact ready. Any other init error is a real failure.
        if (_isAlreadyInitializedError(e)) {
          _rustInitializedInIsolate = true;
          await _pushLog('RustLib.init() reported already-initialized — treating as ready');
        } else {
          rethrow;
        }
      }
    }

    if (Platform.isAndroid || Platform.isIOS) {
      // set_data_dir uses a OnceLock on the Rust side — safe to call repeatedly.
      await identity_api.setDataDir(path: hollowDataDir);
      await _pushLog('setDataDir OK');
    }
    rustReady = true;
  } catch (e) {
    await _pushLog('Rust init FAILED: $e');
  }

  // Tier 1: Show notification from cached profile (no node needed).
  String displayName = _truncatePeerId(sender);
  Uint8List? avatarBytes;

  if (rustReady) {
    try {
      final profile = await network_api.getPushProfile(peerId: sender);
      await _pushLog('getPushProfile: name=${profile?.displayName}, hasAvatar=${profile?.avatarBytes != null}');
      if (profile != null && profile.displayName.isNotEmpty) {
        displayName = profile.displayName;
      }
      avatarBytes = profile?.avatarBytes;
    } catch (e) {
      await _pushLog('getPushProfile FAILED: $e');
    }
  }

  await _showNotification(
    sender: sender,
    title: displayName,
    body: 'Sent you a message',
    avatarBytes: avatarBytes,
  );
  await _pushLog('Tier 1 notification shown: $displayName');

  // Tier 2: Attempt background fetch for message preview.
  if (rustReady) {
    try {
      await _pushLog('Starting Tier 2 fetch for $sender...');
      // Keep this well under Android's background window. The relay now replays
      // buffered offline messages immediately on join, so the fetch node
      // collects them within ~1-2s; the timeout only bounds the empty case.
      final messages = await network_api.startFetchNode(
        senderPeerId: sender,
        timeoutSecs: 12,
      );
      await _pushLog('Tier 2 returned ${messages.length} messages');
      if (messages.isNotEmpty) {
        // FIFO order — oldest first. Truncate each, then merge with previously
        // cached lines (keyed by message_id so edits replace, not stack).
        // An image DM's caption is the literal "[file:<id>]" sentinel when it has
        // no text — show a friendly "📷 Photo" line instead.
        String previewText(network_api.FetchedMessage m) {
          if (m.text.isEmpty || m.text.startsWith('[file:')) {
            return m.imagePath != null ? '📷 Photo' : m.text;
          }
          return m.text.length > 200 ? '${m.text.substring(0, 200)}...' : m.text;
        }

        final batch = messages
            .map((m) => MapEntry(m.messageId, previewText(m)))
            .toList();
        final texts = await _accumulateLines(sender, batch);

        // If the most recent fetched message carries an image, show a BigPicture
        // preview. Only ONE image can be previewed per notification (Android), and
        // we send one notification per peer, so we use the latest image only.
        final latestImage = messages.lastWhere(
          (m) => m.imagePath != null &&
              File(m.imagePath!).existsSync(),
          orElse: () => messages.first,
        );
        final imagePath = (latestImage.imagePath != null &&
                File(latestImage.imagePath!).existsSync())
            ? latestImage.imagePath
            : null;

        await _showNotification(
          sender: sender,
          title: displayName,
          body: texts.last,
          lines: texts,
          avatarBytes: avatarBytes,
          imagePath: imagePath,
          silent: true, // update in place without re-alerting
        );
        await _pushLog(
            'Tier 2 notification updated with ${texts.length} line(s)'
            '${imagePath != null ? " + image preview" : ""}');
      }
    } catch (e) {
      await _pushLog('Tier 2 FAILED: $e');
    }
  }

  await _pushLog('Handler complete');
}

String _truncatePeerId(String peerId) {
  if (peerId.length > 12) return '${peerId.substring(0, 12)}...';
  return peerId;
}

Future<void> _showGenericNotification() async {
  final plugin = FlutterLocalNotificationsPlugin();
  await _initNotificationPlugin(plugin);
  await plugin.show(
    0,
    'Hollow',
    'You have a new message',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'hollow_messages',
        'Messages',
        channelDescription: 'Hollow message notifications',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    ),
  );
}

Future<void> _showNotification({
  required String sender,
  required String title,
  required String body,
  List<String>? lines,
  Uint8List? avatarBytes,
  String? imagePath,
  bool silent = false,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await _initNotificationPlugin(plugin);

  AndroidBitmap<Object>? largeIcon;
  if (avatarBytes != null && avatarBytes.isNotEmpty) {
    largeIcon = ByteArrayAndroidBitmap(avatarBytes);
  }

  // Style priority:
  //   1. BigPicture — when the message carries an image (shows the photo
  //      expanded). Android can preview only ONE image, so this wins over the
  //      inbox stack when present.
  //   2. Inbox — multiple text messages stacked (most recent few + "+N more").
  StyleInformation? style;
  if (imagePath != null) {
    style = BigPictureStyleInformation(
      FilePathAndroidBitmap(imagePath),
      largeIcon: largeIcon,
      contentTitle: title,
      summaryText: body,
      hideExpandedLargeIcon: false,
    );
  } else if (lines != null && lines.length > 1) {
    const maxLines = 3;
    final shown = lines.length > maxLines
        ? lines.sublist(lines.length - maxLines)
        : lines;
    final hidden = lines.length - shown.length;
    style = InboxStyleInformation(
      shown,
      contentTitle: title,
      summaryText: hidden > 0
          ? '+$hidden more · ${lines.length} new messages'
          : '${lines.length} new messages',
    );
  }

  // Tier 1 alerts (sound + heads-up). Tier 2 reuses the SAME notification ID to
  // swap in the real message text, but does so silently (onlyAlertOnce + silent)
  // so it updates in place without a second buzz/peek. This is the two-tier
  // design: fast alert first, content quietly filled in a moment later.
  await plugin.show(
    sender.hashCode,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        'hollow_messages',
        'Messages',
        channelDescription: 'Hollow message notifications',
        importance: silent ? Importance.low : Importance.high,
        priority: silent ? Priority.low : Priority.high,
        largeIcon: largeIcon,
        onlyAlertOnce: true,
        silent: silent,
        styleInformation: style,
        number: lines != null && lines.length > 1 ? lines.length : null,
      ),
      iOS: DarwinNotificationDetails(
        presentSound: !silent,
        presentBanner: !silent,
        presentAlert: !silent,
      ),
    ),
  );
}

Future<void> _initNotificationPlugin(
    FlutterLocalNotificationsPlugin plugin) async {
  const androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const iosSettings = DarwinInitializationSettings(
    requestAlertPermission: false,
    requestBadgePermission: false,
    requestSoundPermission: false,
  );
  await plugin.initialize(
    const InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    ),
  );
  if (Platform.isAndroid) {
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          'hollow_messages',
          'Messages',
          description: 'Hollow message notifications',
          importance: Importance.high,
        ));
  }
}

class PushNotificationService {
  static final PushNotificationService _instance = PushNotificationService._();
  factory PushNotificationService() => _instance;
  PushNotificationService._();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  String? _currentToken;

  String? get currentToken => _currentToken;

  Future<void> initialize() async {
    if (_initialized) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    debugPrint('████ [HOLLOW-PUSH] Initializing push notifications...');

    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

    await _initLocalNotifications();

    try {
      final settings = await _messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      debugPrint('████ [HOLLOW-PUSH] Permission status: ${settings.authorizationStatus}');

      if (settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional) {
        // iOS only: the APNs device token arrives asynchronously from Apple
        // AFTER requestPermission returns. FirebaseMessaging.getToken() returns
        // null / throws if it has no APNs token yet, so wait for it first.
        // No-op on Android (getAPNSToken returns null there immediately).
        if (Platform.isIOS) {
          await _waitForApnsToken();
        }
        _currentToken = await _messaging.getToken();
        debugPrint('████ [HOLLOW-PUSH] FCM token: ${_currentToken != null ? "${_currentToken!.substring(0, 20)}..." : "NULL"}');
        if (_currentToken != null) {
          _registerTokenWithRelay(_currentToken!);
          debugPrint('████ [HOLLOW-PUSH] Token sent to relay');
        }
      } else {
        debugPrint('████ [HOLLOW-PUSH] Notifications NOT authorized');
      }
    } catch (e) {
      debugPrint('████ [HOLLOW-PUSH] getToken/permission FAILED: $e');
    }

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    _messaging.onTokenRefresh.listen((newToken) {
      _currentToken = newToken;
      _registerTokenWithRelay(newToken);
    });

    _initialized = true;
    debugPrint('[HOLLOW-PUSH] Push notification service initialized');
  }

  /// iOS: poll for the APNs device token (delivered async by Apple after
  /// permission is granted) before requesting the FCM token. Returns once the
  /// token is available or after ~10s. On the Simulator the token never
  /// arrives — we time out and let getToken() fail gracefully.
  Future<void> _waitForApnsToken() async {
    for (var i = 0; i < 20; i++) {
      try {
        final apnsToken = await _messaging.getAPNSToken();
        if (apnsToken != null) {
          debugPrint('████ [HOLLOW-PUSH] APNs token acquired after ${i * 500}ms');
          return;
        }
      } catch (e) {
        debugPrint('████ [HOLLOW-PUSH] getAPNSToken attempt $i failed: $e');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    debugPrint('████ [HOLLOW-PUSH] APNs token unavailable after 10s '
        '(Simulator, or APNs not configured) — FCM token may be null');
  }

  Future<void> _initLocalNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _localNotifications.initialize(
      const InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      ),
    );

    if (Platform.isAndroid) {
      await _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            'hollow_messages',
            'Messages',
            description: 'Hollow message notifications',
            importance: Importance.high,
          ));
    }
  }

  void _registerTokenWithRelay(String token) {
    final platform = Platform.isAndroid ? 'android' : 'ios';
    try {
      network_api.registerPushToken(token: token, platform: platform);
    } catch (_) {
      // Node may not be running yet — token will be re-registered on next connect
    }
  }

  void _handleForegroundMessage(RemoteMessage message) {
    // Empty wake-up push — no content to show.
    // The app is already in foreground, so the WS is active.
  }

  Future<void> reregisterToken() async {
    if (_currentToken != null) {
      _registerTokenWithRelay(_currentToken!);
    }
  }
}
