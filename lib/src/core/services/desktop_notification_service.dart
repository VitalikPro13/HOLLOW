import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    show
        DarwinInitializationSettings,
        DarwinNotificationAction,
        DarwinNotificationAttachment,
        DarwinNotificationCategory,
        DarwinNotificationDetails,
        MacOSFlutterLocalNotificationsPlugin;
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart'
    show NotificationResponse;
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/chat/emote_image.dart'
    show emoteTokensToShortcodes;
import 'package:local_notifier/local_notifier.dart';

/// Notification-routing breadcrumbs into hollow_debug.log.
///
/// `debugPrint` goes nowhere in a release build, and "no notification
/// appeared" is only ever reported FROM a release build, so a completely dead
/// toast path used to look identical to a healthy one.
void notifLog(String msg) {
  network_api
      .logFromDart(message: '[HOLLOW-NOTIF] $msg')
      .catchError((_) {});
}

/// Desktop OS-level notifications (Windows / macOS / Linux).
///
/// Windows talks to `FlutterLocalNotificationsWindows()` directly, because the
/// unified facade does not route Windows in v18. That is the RICH path (avatar,
/// text, an inline Reply, rendered as an Action Center toast) and it needs the
/// registered Start-menu shortcut the Inno Setup installer creates. macOS goes
/// through `UNUserNotificationCenter` (avatar, inline Reply, per-conversation
/// thread): the `NSUserNotificationCenter` that `local_notifier` uses is
/// deprecated and delivers nothing on current macOS, so a posted toast never
/// reached Notification Center. Linux keeps `local_notifier`, since rich
/// actions and images are unreliable across desktop environments.
///
/// [SystemNotificationNotifier] decides WHEN to call this; this decides HOW.
/// Windows carries the toast's launch arguments in `payload`, so a Reply
/// encodes its target as `reply:<peerId>` and the typed text arrives in
/// `response.data[<inputId>]`.
class DesktopNotificationService {
  DesktopNotificationService._();
  static final DesktopNotificationService instance =
      DesktopNotificationService._();

  /// Windows rich-toast plugin, constructed LAZILY and only on Windows: the
  /// constructor dlopen's `flutter_local_notifications_windows.dll`, which
  /// throws elsewhere, and an eager field initializer broke Linux DM toasts.
  FlutterLocalNotificationsWindows? _winPlugin;
  FlutterLocalNotificationsWindows get _win =>
      _winPlugin ??= FlutterLocalNotificationsWindows();

  MacOSFlutterLocalNotificationsPlugin? _macPlugin;
  MacOSFlutterLocalNotificationsPlugin get _mac =>
      _macPlugin ??= MacOSFlutterLocalNotificationsPlugin();

  /// The DM category carries the inline Reply action; channel toasts have none.
  static const String _macDmCategory = 'hollow_dm';

  bool _initialized = false;

  /// Single-flight guard for [init]: a burst of messages during startup could
  /// otherwise run `_win.initialize()` several times concurrently, and that
  /// registers a COM class object for a fixed GUID.
  Future<void>? _initFuture;

  /// Absolute path to the bundled brand icon, written to a temp file at init
  /// because Flutter assets have no on-disk path. The peer avatar uses the
  /// separate app-logo-override slot, so both appear.
  String? _brandIconPath;

  /// Every posted message gets its OWN toast id so a new one never replaces an
  /// earlier toast: replacing wipes any reply the user is mid-typing.
  int _toastCounter = 0;

  /// Last local_notifier instance per source, so a follow-up can close it.
  final Map<String, LocalNotification> _activeNative = {};

  /// Tap on a toast opens this conversation. Payload matches the mobile push
  /// path: a bare peer id for a DM, `channel:<serverId>:<channelId>` otherwise.
  static void Function(String payload)? _openHandler;

  /// The user submitted an inline Reply on a DM toast. Windows only.
  static void Function(String peerId, String text)? _replyHandler;

  static void registerOpenHandler(void Function(String payload) handler) {
    _openHandler = handler;
  }

  static void registerReplyHandler(
      void Function(String peerId, String text) handler) {
    _replyHandler = handler;
  }

  static bool get isSupported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (_initialized || !isSupported) return;
    try {
      if (Platform.isWindows) {
        _brandIconPath = await _writeBrandIcon();
        await _win.initialize(
          WindowsInitializationSettings(
            appName: 'Hollow',
            // Must match the AppUserModelID on the installed Start-menu
            // shortcut, or toasts lose the app name and grouping.
            appUserModelId: 'com.anonlisten.hollow',
            // Stable activation-callback GUID; keep constant across releases.
            guid: 'b6f4c0de-7a21-4e9f-9c3a-7d2f1e0a55c1',
            iconPath: _brandIconPath,
          ),
          onNotificationReceived: _onWindowsResponse,
        );
      } else if (Platform.isMacOS) {
        // The permission prompt shows once, on the first message that needs a
        // toast; the answer lands in System Settings > Notifications > Hollow.
        final granted = await _mac.initialize(
          DarwinInitializationSettings(
            requestBadgePermission: false,
            defaultPresentBadge: false,
            notificationCategories: [
              DarwinNotificationCategory(_macDmCategory, actions: [
                DarwinNotificationAction.text(
                  _replyActionId,
                  'Reply',
                  buttonTitle: 'Send',
                  placeholder: 'Reply…',
                ),
              ]),
            ],
          ),
          onDidReceiveNotificationResponse: _onDarwinResponse,
        );
        notifLog('macOS notification permission granted=$granted');
      } else {
        // local_notifier needs a one-time setup with a shortcut.
        await localNotifier.setup(
          appName: 'Hollow',
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
      }
      _initialized = true;
      notifLog('backend ready (${Platform.operatingSystem}, '
          'brandIcon=${_brandIconPath != null})');
    } catch (e) {
      // On Windows this covers `_win.initialize()`. If it throws,
      // `_initialized` stays false and EVERY toast below returns silently
      // for the rest of the session.
      debugPrint('[HOLLOW] DesktopNotificationService init failed: $e');
      notifLog('BACKEND INIT FAILED — no OS toast will fire this session: $e');
      // Let a later message retry rather than caching the failure forever.
      _initFuture = null;
    }
  }

  /// Writes the bundled icon to a temp file and returns its path, since the
  /// Windows toast needs a real on-disk one. Null on failure, which costs
  /// only the header icon.
  Future<String?> _writeBrandIcon() async {
    try {
      final data = await rootBundle.load('assets/hollow_logo_rounded.png');
      final f = File('${Directory.systemTemp.path}/hollow_brand_icon.png');
      await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return f.path;
    } catch (e) {
      debugPrint('[HOLLOW] brand icon write failed: $e');
      return null;
    }
  }

  /// Windows response router. `response.payload` carries the toast's launch
  /// arguments: our payload for a body tap, the action's for a button press.
  void _onWindowsResponse(NotificationResponse response) {
    final args = response.payload ?? '';
    if (args.startsWith('$_replyActionId:')) {
      final peerId = args.substring(_replyActionId.length + 1);
      final text = (response.data[_replyTextId] ?? '').trim();
      if (peerId.isNotEmpty && text.isNotEmpty) {
        _replyHandler?.call(peerId, text);
      }
      return;
    }
    if (args.isNotEmpty) {
      _openHandler?.call(args);
    }
  }

  /// macOS response router: the Reply action carries its text in `input`, a
  /// body tap only the payload.
  void _onDarwinResponse(NotificationResponse response) {
    final payload = response.payload ?? '';
    if (response.actionId == _replyActionId) {
      final text = (response.input ?? '').trim();
      if (payload.isNotEmpty && text.isNotEmpty) {
        _replyHandler?.call(payload, text);
      }
      return;
    }
    if (payload.isNotEmpty) {
      _openHandler?.call(payload);
    }
  }

  static const String _replyActionId = 'reply';
  static const String _replyTextId = 'replyText';

  /// Posts a DM toast; [body] is the SINGLE new message line. On Windows each
  /// message stacks its own toast rather than replacing an earlier one, which
  /// would wipe a reply in progress.
  Future<void> showDm({
    required String sourceKey,
    required String title,
    required String body,
    Uint8List? avatarBytes,
  }) async {
    await init();
    if (!_initialized) {
      notifLog('DROPPED DM toast — backend never initialized');
      return;
    }
    // OS toasts cannot render emote images; show ':name:' not the wire token.
    body = emoteTokensToShortcodes(body);
    if (Platform.isWindows) {
      await _showWindows(
        sourceHash: sourceKey.hashCode & 0x7fffffff,
        title: title,
        body: body,
        avatarBytes: avatarBytes,
        payload: sourceKey,
        replyTarget: sourceKey,
      );
    } else if (Platform.isMacOS) {
      await _showMac(
        threadKey: 'dm:$sourceKey',
        title: title,
        body: body,
        avatarBytes: avatarBytes,
        payload: sourceKey,
        reply: true,
      );
    } else {
      await _showNative(sourceKey: 'dm:$sourceKey', title: title, body: body);
    }
  }

  /// Posts a channel toast. No Reply action: a channel send needs the right
  /// context and posting-permission checks a toast cannot do cleanly.
  Future<void> showChannel({
    required String serverId,
    required String channelId,
    required String title,
    required String body,
    Uint8List? avatarBytes,
  }) async {
    await init();
    if (!_initialized) {
      notifLog('DROPPED channel toast — backend never initialized');
      return;
    }
    body = emoteTokensToShortcodes(body);
    final key = '$serverId:$channelId';
    if (Platform.isWindows) {
      await _showWindows(
        sourceHash: key.hashCode & 0x7fffffff,
        title: title,
        body: body,
        avatarBytes: avatarBytes,
        payload: 'channel:$serverId:$channelId',
        replyTarget: null,
      );
    } else if (Platform.isMacOS) {
      await _showMac(
        threadKey: 'ch:$key',
        title: title,
        body: body,
        avatarBytes: avatarBytes,
        payload: 'channel:$serverId:$channelId',
        reply: false,
      );
    } else {
      await _showNative(sourceKey: 'ch:$key', title: title, body: body);
    }
  }

  /// Notification Center accepts PNG, JPEG and GIF attachments and rejects the
  /// whole post for anything else, so an avatar in another format is skipped.
  static String? _attachmentExt(Uint8List b) {
    if (b.length < 4) return null;
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return 'png';
    }
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'jpg';
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
    return null;
  }

  Future<void> _showMac({
    required String threadKey,
    required String title,
    required String body,
    required String payload,
    required bool reply,
    Uint8List? avatarBytes,
  }) async {
    // Fresh id per message so it stacks, and a fresh file per attachment: the
    // system MOVES an attached file into its own store.
    final id = (_toastCounter++) & 0x7fffffff;
    String? avatarPath;
    final ext = avatarBytes == null ? null : _attachmentExt(avatarBytes);
    if (avatarBytes != null && ext != null) {
      try {
        final f = File('${Directory.systemTemp.path}/hollow_notif_$id.$ext');
        await f.writeAsBytes(avatarBytes, flush: true);
        avatarPath = f.path;
      } catch (_) {}
    }
    try {
      await _mac.show(
        id,
        title,
        body,
        payload: payload,
        notificationDetails: DarwinNotificationDetails(
          threadIdentifier: threadKey,
          categoryIdentifier: reply ? _macDmCategory : null,
          attachments: avatarPath == null
              ? null
              : [DarwinNotificationAttachment(avatarPath, identifier: 'avatar')],
        ),
      );
      notifLog('macOS notification posted id=$id avatar=${avatarPath != null}');
    } catch (e) {
      debugPrint('[HOLLOW] macOS notification failed: $e');
      notifLog('macOS notification FAILED id=$id: $e');
    }
  }

  Future<void> _showWindows({
    required int sourceHash,
    required String title,
    required String body,
    required String payload,
    required String? replyTarget,
    Uint8List? avatarBytes,
  }) async {
    // The avatar is written per-SOURCE, not per-message, so it is reused
    // across a peer's toasts. WindowsImage wants a file URI.
    String? avatarPath;
    if (avatarBytes != null && avatarBytes.isNotEmpty) {
      try {
        final f =
            File('${Directory.systemTemp.path}/hollow_notif_$sourceHash.png');
        await f.writeAsBytes(avatarBytes, flush: true);
        avatarPath = f.path;
      } catch (_) {}
    }

    final images = <WindowsImage>[
      if (avatarPath != null)
        WindowsImage(
          Uri.file(avatarPath, windows: true),
          altText: 'avatar',
          crop: WindowsImageCrop.circle,
          placement: WindowsImagePlacement.appLogoOverride,
        ),
    ];

    final inputs = <WindowsInput>[
      if (replyTarget != null)
        const WindowsTextInput(
          id: _replyTextId,
          placeHolderContent: 'Reply…',
        ),
    ];

    final actions = <WindowsAction>[
      if (replyTarget != null)
        WindowsAction(
          content: 'Send',
          // Encode the target so the response callback can recover who to DM.
          arguments: '$_replyActionId:$replyTarget',
          inputId: _replyTextId,
        ),
    ];

    // Fresh id per message: the new toast STACKS beside any earlier one
    // rather than replacing it. 31-bit positive.
    final id = (_toastCounter++) & 0x7fffffff;

    try {
      await _win.show(
        id,
        title,
        body,
        payload: payload,
        details: WindowsNotificationDetails(
          images: images,
          inputs: inputs,
          actions: actions,
        ),
      );
      // A success line matters as much as the failure one: if this appears
      // with no toast on screen, the OS suppressed it (Focus assist, or
      // Hollow switched off in Windows notification settings).
      notifLog('Windows toast posted id=$id avatar=${avatarPath != null}');
    } catch (e) {
      debugPrint('[HOLLOW] Windows toast failed: $e');
      notifLog('Windows toast FAILED id=$id: $e');
    }
  }

  Future<void> _showNative({
    required String sourceKey,
    required String title,
    required String body,
  }) async {
    try {
      _activeNative.remove(sourceKey)?.close();
    } catch (_) {}
    final notification = LocalNotification(title: title, body: body);
    notification.onClick = () {
      // local_notifier has no per-action payload; map the click to the
      // source. sourceKey is "dm:<peer>" or "ch:<server>:<channel>".
      if (sourceKey.startsWith('dm:')) {
        _openHandler?.call(sourceKey.substring(3));
      } else if (sourceKey.startsWith('ch:')) {
        _openHandler?.call('channel:${sourceKey.substring(3)}');
      }
    };
    _activeNative[sourceKey] = notification;
    try {
      await notification.show();
      notifLog('native toast posted $sourceKey');
    } catch (e) {
      debugPrint('[HOLLOW] native toast failed: $e');
      notifLog('native toast FAILED $sourceKey: $e');
    }
  }
}
