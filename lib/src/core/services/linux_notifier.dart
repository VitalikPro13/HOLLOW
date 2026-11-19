import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';

/// The .desktop id of the native (tarball) build: `linux/CMakeLists.txt`'s
/// APPLICATION_ID, the bundled `com.anonlisten.hollow.desktop` and the copy
/// `_installLinuxDesktopIntegration` writes to ~/.local/share/applications.
const String kLinuxNativeDesktopEntry = 'com.anonlisten.hollow';

/// The .desktop id this process was installed under. A flatpak exports its
/// files under the app id, which differs in case from the native id, and only
/// FLATPAK_ID names it.
String linuxDesktopEntry(Map<String, String> environment) {
  final flatpakId = environment['FLATPAK_ID']?.trim() ?? '';
  return flatpakId.isNotEmpty ? flatpakId : kLinuxNativeDesktopEntry;
}

/// The `app_icon` a server shows when it cannot resolve the desktop entry.
/// A flatpak's own files are invisible to the host's notification server, so
/// it names the icon its app id exports; the native bundle names its PNG.
String linuxNotificationIcon(
  Map<String, String> environment,
  String executable,
) {
  final flatpakId = environment['FLATPAK_ID']?.trim() ?? '';
  if (flatpakId.isNotEmpty) return flatpakId;
  final dir = File(executable).parent.path;
  return '$dir/data/flutter_assets/assets/hollow_logo_rounded.png';
}

/// [text] as a D-Bus string: a U+0000 inside an `s` argument makes the bus
/// drop our connection, and GNOME then takes back every toast we posted.
String linuxDbusText(String text) => text.replaceAll('\u0000', '');

/// [text] as literal characters for a server that reads the body as markup:
/// a peer's `<a href>`, `<img>` or `<b>` must show as typed, never render.
String linuxEscapeMarkup(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

/// The arguments of one `org.freedesktop.Notifications.Notify` call.
/// [bodyMarkup] = the server listed `body-markup`; the summary is plain text
/// by spec and so is never escaped.
List<DBusValue> linuxNotifyArgs({
  required String title,
  required String body,
  required String desktopEntry,
  required String icon,
  required bool bodyMarkup,
}) {
  final plainBody = linuxDbusText(body);
  return [
    const DBusString('Hollow'),
    const DBusUint32(0),
    DBusString(linuxDbusText(icon)),
    DBusString(linuxDbusText(title)),
    DBusString(bodyMarkup ? linuxEscapeMarkup(plainBody) : plainBody),
    DBusArray.string(const []),
    DBusDict.stringVariant(
        {'desktop-entry': DBusString(linuxDbusText(desktopEntry))}),
    const DBusInt32(-1),
  ];
}

typedef LinuxNotifyCall = Future<List<DBusValue>> Function(
  String method,
  List<DBusValue> args,
);

/// Desktop notifications on Linux over the freedesktop D-Bus API.
///
/// Every toast carries the `desktop-entry` hint, so a server that honours it
/// (KDE Plasma, XFCE, dunst, mako, GNOME when no window is mapped) shows
/// Hollow's name and icon. GNOME attributes a toast by the sender's WINDOW
/// first; the runner's WM_CLASS covers that path.
///
/// One connection for the process: GNOME ties toasts to the sending
/// connection and takes them all back when it closes, so it is replaced only
/// when it fails, never on an error reply or a slow server.
class LinuxNotifier {
  LinuxNotifier({
    LinuxNotifyCall? call,
    Map<String, String>? environment,
    String? executable,
  }) : _call = call,
       _environment = environment ?? Platform.environment,
       _executable = executable ?? Platform.resolvedExecutable;

  static const _name = 'org.freedesktop.Notifications';
  static const _path = '/org/freedesktop/Notifications';

  /// libnotify's wait for Notify: a busy server still answers with the id a
  /// later replace or withdraw needs.
  static const _notifyTimeout = Duration(seconds: 25);
  static const _timeout = Duration(seconds: 5);

  final LinuxNotifyCall? _call;
  final Map<String, String> _environment;
  final String _executable;
  DBusClient? _client;
  Future<Set<String>>? _capabilities;

  /// What the server on the session bus supports, asked once per connection.
  /// Throws when no server answers, which is how [DesktopNotificationService]
  /// learns there is nothing to post to.
  Future<Set<String>> capabilities() => _capabilities ??= _askCapabilities();

  Future<Set<String>> _askCapabilities() async {
    try {
      final reply = await _invoke('GetCapabilities', const [], _timeout);
      return (reply.first as DBusArray)
          .children
          .map((v) => (v as DBusString).value)
          .toSet();
    } catch (_) {
      _capabilities = null;
      rethrow;
    }
  }

  /// Posts a toast and returns the server's id for it.
  Future<int> show(String title, String body) async {
    final caps = await capabilities();
    final reply = await _invoke(
      'Notify',
      linuxNotifyArgs(
        title: title,
        body: body,
        desktopEntry: linuxDesktopEntry(_environment),
        icon: linuxNotificationIcon(_environment, _executable),
        bodyMarkup: caps.contains('body-markup'),
      ),
      _notifyTimeout,
    );
    return (reply.first as DBusUint32).value;
  }

  /// Takes a posted toast back. Best effort: the server may already have
  /// dropped it (an error reply by spec).
  Future<void> close(int id) async {
    try {
      await _invoke('CloseNotification', [DBusUint32(id)], _timeout);
    } catch (_) {}
  }

  Future<List<DBusValue>> _invoke(
    String method,
    List<DBusValue> args,
    Duration timeout,
  ) {
    final call = _call;
    if (call != null) return call(method, args).timeout(timeout);
    return _invokeOnBus(method, args, timeout);
  }

  Future<List<DBusValue>> _invokeOnBus(
    String method,
    List<DBusValue> args,
    Duration timeout,
  ) async {
    final client = _client ??= DBusClient.session();
    try {
      final object = DBusRemoteObject(
        client,
        name: _name,
        path: DBusObjectPath(_path),
      );
      final response = await object
          .callMethod(_name, method, args)
          .timeout(timeout);
      return response.values;
    } on DBusMethodResponseException {
      rethrow;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      // The connection itself failed: the next call opens a new one, and asks
      // the server it reaches for its capabilities again.
      if (identical(_client, client)) {
        _client = null;
        _capabilities = null;
      }
      unawaited(client.close().catchError((_) {}));
      rethrow;
    }
  }
}
