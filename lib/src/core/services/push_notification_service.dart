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

/// Dismiss the OS notification for [sender] (call when the user opens that
/// chat). With Android grouping, also removes the lingering group SUMMARY when
/// no per-peer message children remain — otherwise an empty "Hollow" header
/// banner stays in the tray. Safe to call on any platform.
Future<void> dismissPeerNotification(String sender) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.cancel(sender.hashCode);
  if (!Platform.isAndroid) return;
  try {
    final android = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final active = await android?.getActiveNotifications() ?? const [];
    // If the only thing left in our group is the summary itself, drop it.
    final messageChildren = active.where((n) =>
        n.id != null && n.id != _groupSummaryId && n.id != 0);
    if (messageChildren.isEmpty) {
      await plugin.cancel(_groupSummaryId);
    }
  } catch (_) {
    // getActiveNotifications is unsupported below API 23 — harmless to skip.
  }
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

  // Resolve the cached profile (name + avatar) but DO NOT post yet. On the
  // happy path we wait for the fetched message content and post ONE already-
  // populated notification — no generic "Sent you a message" flash, no visible
  // swap. We only fall back to a content-free banner if the fetch fails / times
  // out / returns nothing (or Rust never initialized).
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

  // Tier 2: fetch + decrypt the message content BEFORE showing the banner so the
  // user sees a correct, populated notification on its first appearance.
  bool contentShown = false;
  if (rustReady) {
    try {
      await _pushLog('Starting fetch for $sender...');
      // The relay replays buffered offline messages immediately on join, so the
      // fetch node collects them within ~1-1.5s (short idle window in fetch.rs);
      // the timeout only bounds the empty case. Kept well under Android's
      // background window.
      final messages = await network_api.startFetchNode(
        senderPeerId: sender,
        timeoutSecs: 12,
      );
      await _pushLog('Fetch returned ${messages.length} messages');
      if (messages.isNotEmpty) {
        // FIFO order — oldest first. Truncate each, then merge with previously
        // cached lines (keyed by message_id so edits replace, not stack).
        // Image DMs show a lightweight "📷 Image" line — NOT a BigPicture
        // preview. The image still arrives (fetch decrypts + writes it to disk
        // and inserts the DB row); we just skip rendering the photo in the
        // banner because the BigPicture path (decode + downscale on the
        // notification thread) made the whole notification noticeably slow. An
        // image DM whose text is the "[file:<id>]" sentinel OR that carries an
        // image_path is rendered as the "📷 Image" placeholder; a captioned
        // image shows its caption text (the caption is the real message text).
        // A captionless image's text is the "[file:<id>]" sentinel → "📷 Image".
        // A captioned image carries the real caption as its text AND has its
        // image_path attached (the fetch merges the inlined-image path onto the
        // caption entry by message_id), so prefix the caption with 📷 to signal
        // the attachment: "📷 <caption>". Plain text messages have no image_path
        // → shown as-is. The 📷 always means "there's a photo here."
        String previewText(network_api.FetchedMessage m) {
          if (m.text.isEmpty || m.text.startsWith('[file:')) {
            return '📷 Image';
          }
          final clipped =
              m.text.length > 200 ? '${m.text.substring(0, 200)}...' : m.text;
          return m.imagePath != null ? '📷 $clipped' : clipped;
        }

        final batch = messages
            .map((m) => MapEntry(m.messageId, previewText(m)))
            .toList();
        final texts = await _accumulateLines(sender, batch);

        // iOS: the APNs alert banner (rewritten by the NSE to name+avatar) is
        // ALREADY on screen — it grabbed attention. Remove it now and post ONE
        // silent content banner in its place so the user ends up with a single
        // per-peer notification that swapped generic → real text, never two
        // stacked. The APNs notification's identifier is the apns-collapse-id
        // (the sidecar set it to _iosCollapseId(sender)); cancel by that exact
        // integer. The content post is SILENT (no re-buzz) since the alert
        // already sounded. On Android this is one alerting post (no prior
        // banner to replace — the handler is the first thing that shows).
        final iosReplace = Platform.isIOS;
        if (iosReplace) {
          try {
            await FlutterLocalNotificationsPlugin()
                .cancel(_iosCollapseId(sender));
            await _pushLog('iOS: cancelled APNs banner id=${_iosCollapseId(sender)}');
          } catch (e) {
            await _pushLog('iOS: cancel APNs banner failed: $e');
          }
        }

        // First (and only) post on the happy path — already populated.
        // No imagePath: BigPicture is intentionally omitted for speed (see above).
        await _showNotification(
          sender: sender,
          title: displayName,
          body: texts.last,
          lines: texts,
          avatarBytes: avatarBytes,
          // iOS content banner is silent (alert already sounded); Android alerts.
          silent: iosReplace,
        );
        contentShown = true;
        await _pushLog(
            'Populated notification shown with ${texts.length} line(s)');
      }
    } catch (e) {
      await _pushLog('Fetch FAILED: $e');
    }
  }

  // Fallback: only if we couldn't show real content (fetch failed/empty/timed
  // out, or Rust never initialized).
  //
  // iOS: the NSE has ALREADY shown a name+avatar banner ("Sent you a message")
  // from the same push. Posting our own generic banner here would create a
  // SECOND entry. So on iOS we leave the NSE banner standing and post nothing —
  // the message still synced to the DB via the fetch (when it ran), it's just
  // not in the banner. This keeps the single-banner guarantee on the failure
  // path too.
  //
  // Android: the background handler is the ONLY source of a banner (there's no
  // NSE), so we must post the name+avatar + generic-body fallback — never a
  // silent miss.
  if (!contentShown && !Platform.isIOS) {
    await _showNotification(
      sender: sender,
      title: displayName,
      body: 'Sent you a message',
      avatarBytes: avatarBytes,
    );
    await _pushLog('Fallback notification shown: $displayName');
  } else if (!contentShown) {
    await _pushLog('iOS: no content — leaving NSE banner as-is (no double post)');
  }

  await _pushLog('Handler complete');
}

String _truncatePeerId(String peerId) {
  if (peerId.length > 12) return '${peerId.substring(0, 12)}...';
  return peerId;
}

/// Deterministic 31-bit hash of a peer_id. MUST match the sidecar's
/// `iosCollapseId` (push-sidecar/index.js) byte-for-byte. The sidecar sets this
/// value as the iOS `apns-collapse-id`, which iOS then uses as the delivered
/// notification's identifier. `flutter_local_notifications`' `cancel(id)` removes
/// a delivered iOS notification by its stringified integer id — so to remove the
/// APNs/NSE banner from the background isolate (where no MethodChannel exists) we
/// reproduce the same integer here and call `cancel(_iosCollapseId(sender))`.
/// FNV-1a, masked to 31 bits (positive, fits a Dart int). NOT security-relevant.
int _iosCollapseId(String peerId) {
  var h = 0x811c9dc5; // FNV offset basis
  for (final c in peerId.codeUnits) {
    h ^= c & 0xff;
    h = (h * 0x01000193) & 0xffffffff; // FNV prime, keep 32-bit
  }
  return h & 0x7fffffff; // 31-bit positive
}

// ── Android notification grouping ──────────────────────────────────────────
// Every per-peer message notification shares this group key so Android bundles
// them under ONE expandable "Hollow" header instead of N loose banners when
// several different peers message you. A separate summary notification (fixed
// ID) is the bundle header. iOS ignores groupKey (it threads by its own rules).
const String _dmGroupKey = 'hollow_dm_group';
// Fixed ID for the group-summary notification. Per-peer notifications use
// sender.hashCode; this constant must never collide with one. Generic/fallback
// uses 0, so we pick a distinct sentinel far from typical hashCodes.
const int _groupSummaryId = 0x40000001;

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
        icon: '@drawable/ic_stat_hollow',
        // Join the Hollow group so a generic notification bundles with the
        // per-peer cards rather than floating as a stray banner.
        groupKey: _dmGroupKey,
        groupAlertBehavior: GroupAlertBehavior.all,
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
  bool silent = false,
}) async {
  final plugin = FlutterLocalNotificationsPlugin();
  await _initNotificationPlugin(plugin);

  AndroidBitmap<Object>? largeIcon;
  if (avatarBytes != null && avatarBytes.isNotEmpty) {
    largeIcon = ByteArrayAndroidBitmap(avatarBytes);
  }

  // Inbox style when there are multiple messages — most recent few + "+N more".
  // Image DMs render as a lightweight "📷 Image" line within this stack; we do
  // NOT use BigPictureStyleInformation: decoding + downscaling the photo on the
  // notification thread made the whole banner noticeably slow to appear. The
  // image itself still syncs to the DB via the fetch — only the heavy preview
  // render is dropped.
  StyleInformation? style;
  if (lines != null && lines.length > 1) {
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

  // The populated content banner alerts (sound + heads-up). The `silent` flag is
  // reserved for in-place updates (Phase 3 iOS) that must not re-buzz —
  // onlyAlertOnce + low importance.
  //
  // Grouping: this per-peer notification joins the Hollow group (groupKey). The
  // CHILD alerts (GroupAlertBehavior.children) so the peer's message buzzes; the
  // summary posted below stays silent — otherwise both would alert (double buzz).
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
        icon: '@drawable/ic_stat_hollow',
        largeIcon: largeIcon,
        onlyAlertOnce: true,
        silent: silent,
        styleInformation: style,
        number: lines != null && lines.length > 1 ? lines.length : null,
        groupKey: _dmGroupKey,
        setAsGroupSummary: false,
        groupAlertBehavior: GroupAlertBehavior.children,
      ),
      iOS: DarwinNotificationDetails(
        threadIdentifier: sender,
        // CRITICAL iOS: `silent` here means "don't re-buzz" — NOT "don't show".
        // On the iOS happy path we cancel the NSE banner and post THIS one as
        // the replacement, so it MUST still be displayed as a banner (otherwise
        // the user sees nothing pop up after the swap). Decouple sound from
        // visibility: silent → no sound, but STILL an active heads-up banner.
        // (Don't use .passive — that only drops it into the notification list
        // without a heads-up, so the content swap would be invisible if the
        // alert banner already auto-dismissed.)
        presentSound: !silent,
        presentBanner: true,
        presentAlert: true,
        interruptionLevel: InterruptionLevel.active,
      ),
    ),
  );

  // Post/refresh the group SUMMARY (the bundle header). Android only visibly
  // bundles when ≥2 children share the group, but posting the summary
  // unconditionally is harmless for a single child. Summary is SILENT so it
  // never adds a second buzz alongside the child that just alerted.
  if (Platform.isAndroid) {
    await plugin.show(
      _groupSummaryId,
      'Hollow',
      'New messages',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'hollow_messages',
          'Messages',
          channelDescription: 'Hollow message notifications',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@drawable/ic_stat_hollow',
          onlyAlertOnce: true,
          silent: true,
          groupKey: _dmGroupKey,
          setAsGroupSummary: true,
          groupAlertBehavior: GroupAlertBehavior.children,
        ),
      ),
    );
  }
}

Future<void> _initNotificationPlugin(
    FlutterLocalNotificationsPlugin plugin) async {
  // Status-bar small icon = the white-silhouette H vector. Android keeps only
  // the alpha channel, so a full-color '@mipmap/ic_launcher' would render as a
  // white blob/circle — use the dedicated monochrome drawable instead.
  const androidSettings =
      AndroidInitializationSettings('@drawable/ic_stat_hollow');
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
    // Monochrome status-bar icon (see _initNotificationPlugin note).
    const androidSettings =
        AndroidInitializationSettings('@drawable/ic_stat_hollow');
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
