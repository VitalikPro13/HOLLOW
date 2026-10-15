import 'dart:typed_data';

import 'package:hollow/src/rust/api/overlay.dart';
import 'package:hollow/src/rust/api/overlay_server.dart';
import 'package:hollow/src/rust/frb_generated.dart';

/// The FFI the stream overlay's data layer and publisher use, in memory. Every
/// call is recorded in [calls] in order; anything else is a no-op.
class FakeOverlayApi implements RustLibApi {
  final List<String> calls = [];
  final Map<String, String> settings = {};

  bool enabled = false;
  bool running = false;
  int port = 0;
  bool portChanged = false;
  int openStreams = 0;
  bool? locked;
  bool linksEverRan = false;
  int tokenSeq = 0;

  final List<String> published = [];
  final List<String> live = [];

  bool allow = true;
  bool share = true;
  String ownLookJson = '{"v":1,"stamp":0,"states":{},"effects":{}}';
  List<OverlayPersonFfi> people = [];
  Map<String, String> fields = {};
  Object? setEnabledError;
  Object? getSettingsError;

  OverlayServerStatusFfi get _status => OverlayServerStatusFfi(
        enabled: enabled,
        running: running,
        port: port,
        portChanged: portChanged,
        openStreams: openStreams,
      );

  OverlayLinksFfi get _links {
    final base = 'http://127.0.0.1:$port/t$tokenSeq';
    return OverlayLinksFfi(
        room: '$base/room', me: '$base/me', personBase: '$base/p/');
  }

  @override
  Future<String?> crateApiStorageLoadSetting({required String key}) async =>
      settings[key];

  @override
  Future<void> crateApiStorageSaveSetting(
      {required String key, required String value}) async {
    calls.add('save $key');
    settings[key] = value;
  }

  @override
  Future<OverlayServerStatusFfi> crateApiOverlayServerOverlayServerStatus()
      async {
    calls.add('status');
    return _status;
  }

  @override
  Future<OverlayServerStatusFfi> crateApiOverlayServerOverlayServerSetEnabled(
      {required bool enabled}) async {
    calls.add('set_enabled($enabled)');
    if (setEnabledError != null) throw setEnabledError!;
    this.enabled = enabled;
    running = enabled;
    if (enabled) {
      if (port == 0) port = 23456;
      linksEverRan = true;
    } else {
      portChanged = false;
    }
    return _status;
  }

  @override
  Future<void> crateApiOverlayServerOverlayServerSetLocked(
      {required bool locked}) async {
    calls.add('set_locked($locked)');
    this.locked = locked;
  }

  @override
  Future<OverlayLinksFfi> crateApiOverlayServerOverlayServerLinks() async {
    if (!linksEverRan) throw 'The overlay has not run yet';
    return _links;
  }

  @override
  Future<OverlayLinksFfi> crateApiOverlayServerOverlayServerResetLink() async {
    calls.add('reset_link');
    tokenSeq++;
    portChanged = false;
    return _links;
  }

  @override
  Future<void> crateApiOverlayServerOverlayPublish(
      {required String snapshotJson}) async {
    published.add(snapshotJson);
  }

  @override
  Future<void> crateApiOverlayServerOverlayPublishLive(
      {required String liveJson}) async {
    live.add(liveJson);
  }

  @override
  Future<OverlaySettingsFfi> crateApiOverlayOverlayGetSettings() async {
    if (getSettingsError != null) throw getSettingsError!;
    return OverlaySettingsFfi(
        allow: allow, share: share, ownLookJson: ownLookJson);
  }

  @override
  Future<void> crateApiOverlayOverlaySetFlags(
      {required bool allow, required bool share}) async {
    calls.add('set_flags($allow,$share)');
    this.allow = allow;
    this.share = allow && share;
  }

  @override
  Future<String> crateApiOverlayOverlaySetOwnLook(
      {required String lookJson}) async {
    calls.add('set_own_look');
    ownLookJson = lookJson;
    return lookJson;
  }

  @override
  Future<List<OverlayPersonFfi>> crateApiOverlayOverlayPeople() async =>
      List.of(people);

  @override
  Future<int> crateApiOverlayOverlayAddPerson({required String master}) async {
    calls.add('add($master)');
    final slot = people.length + 1;
    people.add(OverlayPersonFfi(
      master: master,
      slot: slot,
      field: fields[master] ?? 'show',
      effectiveLookJson: '{"v":1,"stamp":0,"states":{},"effects":{}}',
    ));
    return slot;
  }

  @override
  Future<bool> crateApiOverlayOverlayRemovePerson(
      {required String master}) async {
    calls.add('remove($master)');
    final before = people.length;
    people.removeWhere((p) => p.master == master);
    return people.length != before;
  }

  @override
  Future<void> crateApiOverlayOverlaySetLocalLook(
      {required String master, String? lookJson}) async {
    calls.add('set_local($master,${lookJson == null ? 'null' : 'look'})');
  }

  @override
  String crateApiOverlayOverlayFieldOf({required String master}) =>
      fields[master] ?? 'show';

  @override
  Future<Uint8List?> crateApiEmotesGetEmoteBytes({required String hash}) async {
    calls.add('emote_bytes($hash)');
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<Uint8List?> crateApiOverlayOverlayImageBytes(
      {required String hash}) async {
    calls.add('overlay_bytes($hash)');
    return Uint8List.fromList([4, 5, 6]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.memberName.toString().contains('crateApi')
          ? Future<void>.value()
          : super.noSuchMethod(invocation);
}
