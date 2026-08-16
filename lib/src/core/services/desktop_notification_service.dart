import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart'
    show NotificationResponse;
import 'package:flutter_local_notifications_windows/flutter_local_notifications_windows.dart';
import 'package:hollow/src/rust/api/network.dart' as network_api;
import 'package:hollow/src/ui/chat/emote_image.dart'
    show emoteTokensToShortcodes;
import 'package:local_notifier/local_notifier.dart';

/// Notification-routing breadcrumbs into hollow_debug.log.
///
/// `debugPrint` is NOT enough here and never was: it goes nowhere in a release
/// build, and "no notification appeared" is only ever reported FROM a release
/// build. Every silent failure on this path (init threw, service not
/// initialized, `show()` threw) used to be a `debugPrint` or nothing at all,
/// so a completely dead toast path looked identical to a healthy one.
void notifLog(String msg) {
  network_api
      .logFromDart(message: '[HOLLOW-NOTIF] $msg')
      .catchError((_) {});
}

/// Desktop OS-level notifications (Windows / macOS / Linux).
///
/// Two backends:
/// - **Windows** uses `flutter_local_notifications_windows` directly (the
///   unified `FlutterLocalNotificationsPlugin` facade does NOT route Windows in
///   v18 — there is no `InitializationSettings.windows`/`NotificationDetails.
///   windows`, so we talk to `FlutterLocalNotificationsWindows()` itself). This
///   is the RICH path: an avatar app-logo image, sender name, message text
///   (recent lines joined), and an inline **Reply** action. Windows renders it
///   via the native Action Center toast XML — no Qt, no custom window. It needs
///   the app to have a registered Start-menu shortcut (AppUserModelID), which
///   the Inno Setup installer creates.
/// - **macOS / Linux** use `local_notifier` (title + body + click). Rich
///   actions/images there are unreliable across desktop environments, so we keep
///   the simple, robust path and just fire it in more window states.
///
/// The provider layer ([SystemNotificationNotifier]) decides WHEN to call this
/// (window hidden OR unfocused); this service only decides HOW to render.
///
/// Reply (Windows): the toast's text-input value returns through the
/// notification-response callback while the app is RUNNING — which is exactly
/// our case, since native toasts only fire when the window is unfocused, never
/// when the app is dead. On Windows BOTH `payload` and `actionId` carry the
/// toast's launch arguments and the typed text rides in `response.data[<inputId>]`,
/// so we encode the target into the action arguments (`reply:<peerId>`) to
/// recover who to reply to.
class DesktopNotificationService {
  DesktopNotificationService._();
  static final DesktopNotificationService instance =
      DesktopNotificationService._();

  /// Windows rich-toast plugin (direct, not via the unified facade).
  ///
  /// Constructed LAZILY and only on Windows — the constructor dlopen's
  /// `flutter_local_notifications_windows.dll`, which throws on Linux/macOS
  /// ("cannot open shared object file"). An eager field initializer ran that on
  /// every platform and broke DM notifications on Linux. Every use site is
  /// already inside an `if (Platform.isWindows)` guard, so this is only ever
  /// touched on Windows.
  FlutterLocalNotificationsWindows? _winPlugin;
  FlutterLocalNotificationsWindows get _win =>
      _winPlugin ??= FlutterLocalNotificationsWindows();

  bool _initialized = false;

  /// Single-flight guard for [init].
  ///
  /// `init()` is awaited from the shell bootstrap AND from every `showDm` /
  /// `showChannel`. The old `if (_initialized) return;` was checked BEFORE two
  /// awaits, so a burst of messages arriving during startup could run
  /// `_win.initialize()` several times concurrently — and that registers a COM
  /// class object for a fixed GUID, which is not something to do twice.
  Future<void>? _initFuture;

  /// Absolute path to the bundled Hollow brand icon, written to a temp file at
  /// init (Flutter assets have no stable on-disk path). Shown next to the
  /// "Hollow" app name in the toast header. The peer avatar uses the separate
  /// app-logo-override slot, so both appear.
  String? _brandIconPath;

  /// Monotonic counter giving every posted message its OWN toast id so a new
  /// message NEVER replaces an earlier toast — critical because replacing a
  /// toast wipes any reply text the user is mid-typing. Windows stacks the
  /// separate toasts under our app in the Action Center.
  int _toastCounter = 0;

  /// Keeps the last local_notifier instance per source so a follow-up message
  /// can close the previous toast before posting the new one (mac/Linux only).
  final Map<String, LocalNotification> _activeNative = {};

  /// Routed to the app: tap on a toast → open this conversation. Payload format
  /// matches the mobile push path: a bare peer id for a DM, or
  /// `channel:<serverId>:<channelId>` for a channel.
  static void Function(String payload)? _openHandler;

  /// Routed to the app: the user submitted an inline Reply on a DM toast.
  /// (peerId, replyText). Only fires on Windows where the input action exists.
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
        // Write the bundled brand icon to disk so the toast can reference it by
        // absolute path (shows next to the "Hollow" app name in the header).
        _brandIconPath = await _writeBrandIcon();
        await _win.initialize(
          WindowsInitializationSettings(
            appName: 'Hollow',
            // Must match the AppUserModelID set on the installed Start-menu
            // shortcut (Inno Setup) so toasts render with the app name + icon
            // and group under one identity.
            appUserModelId: 'com.anonlisten.hollow',
            // Stable GUID identifying the activation callback. Generated once for
            // Hollow; keep constant across releases. NOT security-relevant.
            guid: 'b6f4c0de-7a21-4e9f-9c3a-7d2f1e0a55c1',
            iconPath: _brandIconPath,
          ),
          onNotificationReceived: _onWindowsResponse,
        );
      } else {
        // macOS / Linux: local_notifier needs a one-time setup with a shortcut.
        await localNotifier.setup(
          appName: 'Hollow',
          shortcutPolicy: ShortcutPolicy.requireCreate,
        );
      }
      _initialized = true;
      notifLog('backend ready (${Platform.operatingSystem}, '
          'brandIcon=${_brandIconPath != null})');
    } catch (e) {
      // The one that mattered: on Windows this covers `_win.initialize()`,
      // which registers the AUMID in HKCU and CoRegisterClassObject's the
      // activation GUID. If it throws, `_initialized` stays false and EVERY
      // toast below returns silently for the rest of the session.
      debugPrint('[HOLLOW] DesktopNotificationService init failed: $e');
      notifLog('BACKEND INIT FAILED — no OS toast will fire this session: $e');
      // Let a later message retry rather than caching the failure forever.
      _initFuture = null;
    }
  }

  /// Write the bundled Hollow icon to a temp file and return its absolute path
  /// (Windows toast `iconPath` needs a real on-disk path; Flutter assets live in
  /// the bundle). Returns null on failure (toast falls back to no header icon).
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

  /// Windows response router. On Windows `response.payload` carries the toast's
  /// launch arguments: our [payload] string for a body tap, or the action's
  /// `arguments` for a button press. A Reply submission carries `reply:<peerId>`
  /// plus the typed text in `response.data[_replyTextId]`.
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

  static const String _replyActionId = 'reply';
  static const String _replyTextId = 'replyText';

  /// Post a DM toast. [body] is the SINGLE new message line. On Windows each
  /// message gets its own stacked toast (never replaces an earlier one — that
  /// would wipe a reply-in-progress). On mac/Linux the previous toast for this
  /// source is closed first.
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
    // OS toasts can't render emote images — show ':name:' instead of the
    // raw [e:name:hash] wire token.
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
    } else {
      await _showNative(sourceKey: 'dm:$sourceKey', title: title, body: body);
    }
  }

  /// Post a channel toast. No Reply action (a channel send needs the right
  /// channel context + posting-permission checks the toast can't do cleanly).
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
    } else {
      await _showNative(sourceKey: 'ch:$key', title: title, body: body);
    }
  }

  // ── Windows (rich) ─────────────────────────────────────────────────────────

  Future<void> _showWindows({
    required int sourceHash,
    required String title,
    required String body,
    required String payload,
    required String? replyTarget,
    Uint8List? avatarBytes,
  }) async {
    // Avatar: write per-SOURCE (not per-message) so it's reused across a peer's
    // toasts. WindowsImage wants a file URI.
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

    // Fresh id per message → the new toast STACKS beside any earlier one rather
    // than replacing it (replacing wipes a mid-typed reply). 31-bit positive.
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
      // A success line matters as much as the failure one: if this appears and
      // no toast is on screen, the app did its job and the OS suppressed it
      // (Do not disturb / Focus assist, or Hollow switched off under Windows
      // Settings > System > Notifications).
      notifLog('Windows toast posted id=$id avatar=${avatarPath != null}');
    } catch (e) {
      debugPrint('[HOLLOW] Windows toast failed: $e');
      notifLog('Windows toast FAILED id=$id: $e');
    }
  }

  // ── macOS / Linux (plain) ──────────────────────────────────────────────────

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
      // local_notifier has no per-action payload; map the click to "open this
      // source". sourceKey is "dm:<peer>" or "ch:<server>:<channel>".
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
