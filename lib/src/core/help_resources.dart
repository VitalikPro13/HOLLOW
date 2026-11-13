import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/android_platform.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:url_launcher/url_launcher.dart';

/// The bundled list behind Settings > Get help. Information only: nothing on
/// that page fetches or sends anything, so the list ships inside the app.
const kHelpResourcesAsset = 'assets/help/help_resources.json';

/// Where the person's own country pick lives, on this device only.
const kHelpCountrySetting = 'get_help_country';

/// One number to call or text, as the list writes it ("116 123",
/// "686868 (text)", "741741 (text HOME)").
class HelpPhone {
  /// The number as shown ("116 111").
  final String number;

  /// Quiet words after the number ("text", "landline").
  final String? hint;

  /// What an emergency number reaches ("police", "any emergency"). Unlike
  /// [hint] it never stops a dial.
  final String? service;

  const HelpPhone(this.number, [this.hint, this.service]);

  static final _shape = RegExp(r'^(\+?[0-9][0-9 \-]*?)\s*(?:\(([^()]+)\))?$');
  static final _textHint = RegExp(r'^text(?: ([A-Z0-9]{1,12}))?$');

  /// Null for anything that is not a plain number, so a bad entry offers no
  /// dial or copy action at all.
  static HelpPhone? parse(String raw) {
    final m = _shape.firstMatch(raw.trim());
    if (m == null) return null;
    final hint = m.group(2)?.trim();
    return HelpPhone(m.group(1)!.trim(), hint == null || hint.isEmpty ? null : hint);
  }

  /// Digits and a leading plus only: what goes after `tel:` or `sms:`.
  String get dialable => number.replaceAll(RegExp(r'[^0-9+]'), '');

  /// A text line, not a voice line.
  bool get isText => hint != null && _textHint.hasMatch(hint!);

  /// The word a text line asks for as the first message ("HOME"), if any.
  String? get keyword => hint == null ? null : _textHint.firstMatch(hint!)?.group(1);

  /// Dialable as written. A number with any other note ("landline") may be
  /// incomplete from a phone, so it is copied, never dialed.
  bool get canDial => hint == null || isText;
}

/// An organisation with a name, and the ways to reach it the list has.
class HelpContact {
  final String name;
  final String? url;

  /// A web chat page, opened like any website.
  final String? chat;
  final List<HelpPhone> phones;

  /// One plain line on what it does or who it is for.
  final String? note;

  /// When it answers, in the list's words ("24 hours, every day").
  final String? hours;

  /// When its chat answers, given only where that differs from [hours].
  final String? chatHours;
  final List<String> languages;

  /// For a hotline that reports websites: whether its form needs the link.
  /// Null when it could not be checked.
  final bool? linkRequired;

  const HelpContact({
    required this.name,
    this.url,
    this.chat,
    this.phones = const [],
    this.note,
    this.hours,
    this.chatHours,
    this.languages = const [],
    this.linkRequired,
  });

  static HelpContact? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final link = json['link_required'];
    final languages = json['languages'];
    final url = _https(json['url']);
    final chat = _https(json['chat']);
    final phones = _phones(json['phone']);
    // Something to show and nothing to reach is not worth a row.
    if (url == null && chat == null && phones.isEmpty) return null;
    return HelpContact(
      name: name,
      url: url,
      chat: chat,
      phones: phones,
      note: _text(json['note']),
      hours: _text(json['hours']),
      chatHours: chat == null ? null : _text(json['chat_hours']),
      languages: [
        if (languages is List)
          for (final l in languages)
            if (l is String && l.trim().isNotEmpty) l.trim(),
      ],
      linkRequired: link is bool ? link : null,
    );
  }
}

/// The kinds of help, in the order the page shows them.
class HelpLists {
  /// Someone to talk to now: crisis and suicide prevention lines.
  final List<HelpContact> crisis;

  /// For someone threatened with the sharing of their intimate photos.
  final List<HelpContact> photos;

  /// Helplines for children and teens.
  final List<HelpContact> children;

  /// Official online crime reports.
  final List<HelpContact> police;

  /// Hotlines that get abuse material taken off websites.
  final List<HelpContact> websites;

  const HelpLists({
    this.crisis = const [],
    this.photos = const [],
    this.children = const [],
    this.police = const [],
    this.websites = const [],
  });

  static HelpLists fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return const HelpLists();
    List<HelpContact> list(String key) => [
          if (json[key] case final List items)
            for (final c in items) ?HelpContact.fromJson(c),
        ];
    return HelpLists(
      crisis: list('crisis'),
      photos: list('photos'),
      children: list('children'),
      police: list('police'),
      websites: list('websites'),
    );
  }

  Iterable<HelpContact> get all =>
      [...crisis, ...photos, ...children, ...police, ...websites];

  /// The crisis line to show first: the first that answers around the clock,
  /// else the first listed.
  HelpContact? get mainCrisis {
    for (final c in crisis) {
      if (c.hours?.contains('24 hours') ?? false) return c;
    }
    return crisis.firstOrNull;
  }
}

/// One country's entry.
class HelpCountry {
  /// ISO 3166-1 alpha-2, upper case.
  final String code;
  final String name;
  final List<HelpPhone> emergency;
  final HelpLists help;

  /// Notes keyed by where they belong: "emergency", or a kind of help
  /// ("children", "websites"), so each sits beside the rows it explains.
  final Map<String, String> notes;

  const HelpCountry({
    required this.code,
    required this.name,
    required this.emergency,
    this.help = const HelpLists(),
    this.notes = const {},
  });

  /// A search hit on the name, or on the code typed whole ("pl", "us").
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) || code.toLowerCase() == q;
  }
}

/// The whole bundled list.
class HelpResources {
  /// The day the list was last checked against its sources.
  final DateTime? checked;
  final HelpLists worldwide;

  /// Keyed by ISO code.
  final Map<String, HelpCountry> countries;

  const HelpResources({
    required this.checked,
    required this.worldwide,
    required this.countries,
  });

  /// Countries by name, for the picker.
  List<HelpCountry> get byName =>
      countries.values.toList()..sort((a, b) => a.name.compareTo(b.name));

  static HelpResources parse(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    final countries = <String, HelpCountry>{};
    final raw = json['countries'];
    if (raw is Map<String, dynamic>) {
      for (final MapEntry(:key, :value) in raw.entries) {
        if (!RegExp(r'^[A-Z]{2}$').hasMatch(key) ||
            value is! Map<String, dynamic>) {
          continue;
        }
        final name = value['name'];
        final emergency = _emergency(value['emergency']);
        // A country with no number to call is not worth a section.
        if (name is! String || emergency.isEmpty) continue;
        countries[key] = HelpCountry(
          code: key,
          name: name,
          emergency: emergency,
          help: HelpLists.fromJson(value),
          notes: _notes(value['notes']),
        );
      }
    }
    final checked = json['checked'];
    return HelpResources(
      checked: checked is String ? DateTime.tryParse(checked) : null,
      worldwide: HelpLists.fromJson(json['worldwide']),
      countries: countries,
    );
  }
}

String? _https(Object? url) => url is String && isHttpsUrl(url) ? url : null;

String? _text(Object? s) => s is String && s.trim().isNotEmpty ? s : null;

List<HelpPhone> _phones(Object? json) => [
      if (json is List)
        for (final p in json)
          if (p is String) ?HelpPhone.parse(p),
    ];

/// Emergency numbers, each with what it reaches where the list says.
List<HelpPhone> _emergency(Object? json) => [
      if (json is List)
        for (final p in json)
          if (p is String)
            ?HelpPhone.parse(p)
          else if (p is Map<String, dynamic> && p['number'] is String)
            if (HelpPhone.parse(p['number'] as String) case final n?)
              HelpPhone(n.number, n.hint, _text(p['for'])?.trim()),
    ];

Map<String, String> _notes(Object? json) => {
      if (json is Map<String, dynamic>)
        for (final MapEntry(:key, :value) in json.entries)
          key: ?_text(value),
    };

/// The app opens these links in the browser only, never another scheme.
bool isHttpsUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

/// The two-letter region a locale names ("pl_PL", "en-US.UTF-8"), upper
/// case, or null.
@visibleForTesting
String? regionFromLocaleName(String? localeName) {
  if (localeName == null) return null;
  final base = localeName.split(RegExp(r'[.@]')).first;
  final parts = base.split(RegExp(r'[_-]'));
  for (final p in parts.skip(1)) {
    final code = regionCode(p);
    if (code != null) return code;
  }
  return null;
}

/// The device's own region setting. Never an IP lookup or anything that
/// leaves the device.
String? deviceRegion() {
  final fromFlutter = regionCode(PlatformDispatcher.instance.locale.countryCode);
  if (fromFlutter != null) return fromFlutter;
  if (kIsWeb) return null;
  try {
    return regionFromLocaleName(Platform.localeName);
  } catch (_) {
    return null;
  }
}

final helpResourcesProvider = FutureProvider<HelpResources>(
    (ref) async => HelpResources.parse(
        await rootBundle.loadString(kHelpResourcesAsset)));

/// [raw] as a two-letter region code, upper case ("pl" -> "PL"), or null.
String? regionCode(String? raw) {
  final t = raw?.trim();
  if (t == null || !RegExp(r'^[A-Za-z]{2}$').hasMatch(t)) return null;
  return t.toUpperCase(); // design-ignore: an ISO region code, not a label
}

/// Where the starting country came from, for the page to say so.
enum HelpRegionSource { network, sim, locale }

/// A region code and the source that named it.
typedef HelpRegion = ({String code, HelpRegionSource source});

/// The country Get help opens on: the mobile network the phone is on now
/// (right when abroad), then the SIM's, each only when [listed]; then the
/// locale's region, which Android takes from the language ("en_US" in Poland).
@visibleForTesting
HelpRegion? pickHelpRegion({
  String? network,
  String? sim,
  String? locale,
  required bool Function(String code) listed,
}) {
  for (final (raw, source) in [
    (network, HelpRegionSource.network),
    (sim, HelpRegionSource.sim),
  ]) {
    final code = regionCode(raw);
    if (code != null && listed(code)) return (code: code, source: source);
  }
  final code = regionCode(locale);
  return code == null ? null : (code: code, source: HelpRegionSource.locale);
}

/// [pickHelpRegion] over what this device reports. Telephony exists only on
/// Android; the read needs no permission and nothing leaves the phone.
Future<HelpRegion?> helpDeviceRegion({
  required bool Function(String code) listed,
  String? Function() locale = deviceRegion,
}) async {
  final tel = await androidTelephonyCountries();
  return pickHelpRegion(
      network: tel?.network, sim: tel?.sim, locale: locale(), listed: listed);
}

/// The device's region, read once per run. Tests override it.
final deviceRegionProvider = FutureProvider<HelpRegion?>((ref) async {
  final res = await ref.watch(helpResourcesProvider.future);
  return helpDeviceRegion(listed: res.countries.containsKey);
});

/// The country the person picked on this device, or null to follow the
/// device's region.
final helpCountryChoiceProvider =
    AsyncNotifierProvider<HelpCountryChoiceNotifier, String?>(
        HelpCountryChoiceNotifier.new);

class HelpCountryChoiceNotifier extends AsyncNotifier<String?> {
  @override
  Future<String?> build() async {
    try {
      final v = await storage_api.loadSetting(key: kHelpCountrySetting);
      return v == null || v.isEmpty ? null : v;
    } catch (_) {
      return null;
    }
  }

  /// [code] null goes back to the device's region.
  Future<void> choose(String? code) async {
    state = AsyncData(code);
    await storage_api.saveSetting(key: kHelpCountrySetting, value: code ?? '');
  }
}

/// Phones dial; a desktop copies the number instead.
bool helpCanDial() =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

/// Opens the phone's dialer or messages app on [phone]. Returns false when
/// nothing took it (a tablet without a phone app).
Future<bool> dialHelpPhone(HelpPhone phone) async {
  final digits = phone.dialable;
  if (digits.isEmpty || !phone.canDial) return false;
  try {
    final keyword = phone.keyword;
    return await helpDialLauncher(phone.isText
        ? Uri(
            scheme: 'sms',
            path: digits,
            queryParameters: keyword == null ? null : {'body': keyword})
        : Uri(scheme: 'tel', path: digits));
  } catch (_) {
    return false;
  }
}

/// Hands a `tel:` or `sms:` link to the OS. Tests swap it for a recorder.
@visibleForTesting
Future<bool> Function(Uri uri) helpDialLauncher =
    (uri) => launchUrl(uri, mode: LaunchMode.externalApplication);
