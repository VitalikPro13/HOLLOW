/// The bundled Get help list: it parses whole, every country has a number to
/// call, every link is https, police forms come only from official domains
/// and never where the state is a risk to the person, no page shows the same
/// link twice, and the shipped copy carries no research fields.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/help_resources.dart';

const _kinds = ['crisis', 'photos', 'children', 'police', 'websites'];

/// Police forms come only from these official domains (the host or a parent).
/// Filled from the checked list; a new country's form adds its domain here.
const _officialPolice = <String>{
  'asp.gov.al', // AL
  'gov.br', // BR
  'canada.ca', // CA
  'cyber.gov.au', // AU, ReportCyber (ASD's ACSC)
  'polizei.de', // DE
  'politi.dk', // DK
  'politsei.ee', // EE
  'poliisi.fi', // FI
  'gov.uk', // GB
  'mup.gov.hr', // HR, Red Button
  'cyberalert.gr', // GR, the Hellenic Police cyber crime division
  'police.gov.cy', // CY
  'cybercrime.gov.in', // IN
  'commissariatodips.it', // IT
  'npa.go.jp', // JP
  'police.go.kr', // KR
  'npf.gov.ng', // NG
  'police.govt.nz', // NZ
  'mai.gov.pt', // PT
  'e-uprava.gov.si', // SI, the police's anonymous form
  'genpro.gov.sk', // SK
  'cyberpolice.gov.ua', // UA
  'ic3.gov', // US
};

/// Freedom House rates these Not Free (Freedom in the World 2026): a police
/// row could send a person to the state that threatens them.
const _noPolice = {'RU', 'TR', 'TH', 'KH'};

bool _official(String url) {
  final host = Uri.parse(url).host;
  return _officialPolice.any((d) => host == d || host.endsWith('.$d'));
}

List<HelpContact> _of(HelpLists h, String kind) => switch (kind) {
  'crisis' => h.crisis,
  'photos' => h.photos,
  'children' => h.children,
  'police' => h.police,
  _ => h.websites,
};

void main() {
  final source = File('assets/help/help_resources.json').readAsStringSync();
  final raw = jsonDecode(source) as Map<String, dynamic>;
  final res = HelpResources.parse(source);
  final rawCountries = raw['countries'] as Map<String, dynamic>;
  final rawWorld = raw['worldwide'] as Map<String, dynamic>;

  test('the shipped list parses whole, with a checked date', () {
    expect(res.countries.length, rawCountries.length);
    expect(res.countries.length, greaterThanOrEqualTo(63));
    expect(res.checked, isNotNull);
    for (final kind in _kinds) {
      expect(
        rawCountries.values.every((c) => (c as Map).containsKey(kind)),
        isTrue,
        reason: kind,
      );
    }
  });

  test('every entry the list carries reaches the page', () {
    void same(Map<String, dynamic> json, HelpLists lists, String where) {
      final parsed = {
        'crisis': lists.crisis,
        'photos': lists.photos,
        'children': lists.children,
        'police': lists.police,
        'websites': lists.websites,
      };
      for (final kind in _kinds) {
        final items = (json[kind] as List?) ?? const [];
        expect(parsed[kind]!.length, items.length, reason: '$where $kind');
        for (var i = 0; i < items.length; i++) {
          expect(
            parsed[kind]![i].phones.length,
            ((items[i] as Map)['phone'] as List? ?? const []).length,
            reason:
                '$where $kind ${items[i]['name']} has a number the '
                'app cannot read',
          );
        }
      }
    }

    same(rawWorld, res.worldwide, 'worldwide');
    for (final MapEntry(:key, :value) in rawCountries.entries) {
      final emergency = (value as Map<String, dynamic>)['emergency'] as List;
      expect(emergency, isNotEmpty, reason: key);
      expect(
        res.countries[key]!.emergency.length,
        emergency.length,
        reason: '$key has a number the app cannot read',
      );
      same(value, res.countries[key]!.help, key);
    }
  });

  test('someone to talk to: worldwide finders always, and a line or them '
      'for every country', () {
    expect(res.worldwide.crisis.length, greaterThanOrEqualTo(2));
    expect(res.worldwide.photos.length, greaterThanOrEqualTo(2));
    final withLine = res.countries.values
        .where((c) => c.help.crisis.isNotEmpty)
        .length;
    // Most countries have their own line; the rest fall back to the finders.
    expect(withLine, greaterThanOrEqualTo(45));
    for (final c in res.countries.values) {
      for (final line in c.help.crisis) {
        expect(
          line.phones.isNotEmpty || line.chat != null,
          isTrue,
          reason: '${c.code} ${line.name} offers no way to talk',
        );
      }
    }
  });

  test('the main crisis line is the first that answers around the clock', () {
    expect(
      res.countries['PL']!.help.mainCrisis!.name,
      'Telefon zaufania 116 123',
    );
    // Malta lists a weekday line before a 24-hour chat.
    expect(res.countries['MT']!.help.mainCrisis!.name, 'Kellimni');
    expect(res.countries['TR']!.help.mainCrisis, isNull);
    const evenings = HelpContact(name: 'Evenings', hours: 'Every day, 18:00');
    const weekdays = HelpContact(name: 'Weekdays', hours: 'Mon to Fri');
    expect(const HelpLists(crisis: [evenings, weekdays]).mainCrisis, evenings);
  });

  test('a hotline says whether its form needs a link only when checked', () {
    final hotlines = [
      ...rawWorld['websites'] as List,
      for (final c in rawCountries.values) ...(c as Map)['websites'] as List,
    ];
    expect(hotlines.length, greaterThanOrEqualTo(40));
    for (final h in hotlines) {
      // Null means nobody could read the form; the page then says nothing.
      expect(
        (h as Map).containsKey('link_required'),
        isTrue,
        reason: '${h['name']}',
      );
      expect(
        h['link_required'],
        anyOf(isNull, isA<bool>()),
        reason: '${h['name']}',
      );
    }
    final parsed = [
      ...res.worldwide.websites,
      for (final c in res.countries.values) ...c.help.websites,
    ];
    // Each form was opened by hand where a script could not read it.
    expect(
      parsed.where((h) => h.linkRequired != null).length,
      greaterThanOrEqualTo(45),
    );
    bool? need(String code) =>
        res.countries[code]!.help.websites.single.linkRequired;
    expect(need('PL'), isTrue);
    expect(need('US'), isFalse);
    expect(need('BR'), isTrue);
    expect(need('CA'), isFalse);
    expect(need('CH'), isTrue);
    // Hungary's form asks for it only for public web pages.
    expect(need('HU'), isNull);
    // Taiwan's answer was about a different service's form.
    expect(need('TW'), isNull);
  });

  test('police forms come only from official domains', () {
    var forms = 0;
    for (final c in res.countries.values) {
      expect(c.help.police.length, lessThanOrEqualTo(1), reason: c.code);
      for (final p in c.help.police) {
        forms++;
        expect(p.url, isNotNull, reason: c.code);
        expect(_official(p.url!), isTrue, reason: '${c.code} ${p.url}');
      }
    }
    expect(forms, greaterThanOrEqualTo(22));
  });

  test('no police row where the state is a risk to the person', () {
    for (final code in _noPolice) {
      expect(res.countries[code], isNotNull, reason: code);
      expect(res.countries[code]!.help.police, isEmpty, reason: code);
      expect(rawCountries[code]['police'], isEmpty, reason: code);
    }
    // Crisis and children's help stay everywhere.
    expect(res.countries['RU']!.help.children, isNotEmpty);
  });

  test('the photo services never promise to reach encrypted apps', () {
    expect(
      res.worldwide.photos.map((c) => c.name),
      containsAll(['Take It Down', 'StopNCII.org']),
    );
    for (final c in res.worldwide.photos) {
      // They reach only the platforms that take part, never private chats.
      expect(
        c.note!.toLowerCase(),
        contains('platforms that take part'),
        reason: c.name,
      );
      // Said so it never reads as "this can't help me, I'm on Hollow".
      expect(
        c.note,
        contains("can't find copies sent in encrypted apps"),
        reason: c.name,
      );
    }
  });

  test('a note of more than one sentence ends with a full stop', () {
    final notes = [
      for (final c in [
        ...res.worldwide.all,
        for (final country in res.countries.values) ...country.help.all,
      ])
        ?c.note,
      for (final country in res.countries.values) ...country.notes.values,
    ];
    expect(notes.length, greaterThanOrEqualTo(20));
    for (final n in notes) {
      if (n.contains('. ')) expect(n.endsWith('.'), isTrue, reason: n);
    }
  });

  test('every emergency number says what it reaches', () {
    const services = {
      'any emergency',
      'police',
      'fire',
      'ambulance',
      'fire and ambulance',
      'police and ambulance',
      'police, fire and ambulance',
    };
    var several = 0;
    for (final c in res.countries.values) {
      if (c.emergency.length > 1) several++;
      for (final p in c.emergency) {
        // A button the reader cannot tell from its neighbour is no help.
        expect(p.service, isNotNull, reason: '${c.code} ${p.number}');
        expect(services, contains(p.service), reason: '${c.code} ${p.number}');
        expect(p.canDial, isTrue, reason: '${c.code} ${p.number}');
      }
      final numbers = c.emergency.map((p) => p.number).toList();
      expect(numbers.toSet().length, numbers.length, reason: c.code);
    }
    expect(several, greaterThanOrEqualTo(20));
    String of(String code, String number) => res.countries[code]!.emergency
        .firstWhere((p) => p.number == number)
        .service!;
    expect(of('RU', '103'), 'ambulance');
    expect(of('RS', '192'), 'police');
    expect(of('PL', '112'), 'any emergency');
  });

  test('each note sits with the rows it explains', () {
    const places = {'emergency', ..._kinds};
    for (final c in res.countries.values) {
      for (final MapEntry(:key, :value) in c.notes.entries) {
        expect(places, contains(key), reason: '${c.code} $key');
        // A need's note only where the country has rows of that need.
        if (key != 'emergency') {
          final rows = (rawCountries[c.code] as Map)[key] as List;
          expect(rows, isNotEmpty, reason: '${c.code} $key: $value');
        }
      }
      // The first screen's note is about the emergency numbers only.
      final first = c.notes['emergency'];
      if (first != null) {
        expect(
          first,
          isNot(matches(RegExp('child|hotline|helpline'))),
          reason: c.code,
        );
      }
    }
    expect(res.countries['KR']!.notes['children'], contains('1388'));
    expect(res.countries['UA']!.notes['children'], contains('116 111'));
    expect(res.countries['TR']!.notes['children'], contains('183'));
    expect(res.countries['IL']!.notes['children'], contains('105'));
    for (final code in ['DE', 'HU', 'IT', 'NL']) {
      expect(
        res.countries[code]!.notes['websites'],
        contains('https://'),
        reason: code,
      );
      expect(res.countries[code]!.notes.keys, ['websites'], reason: code);
    }
    expect(res.countries['AU']!.notes['emergency'], contains('mobiles'));
  });

  test('the shipped copy has no em dash and no colon outside a time', () {
    void check(Object? o, String where) {
      if (o is Map) {
        for (final MapEntry(:key, :value) in o.entries) {
          if (value is String && key != 'url' && key != 'chat') {
            expect(value.contains('\u2014'), isFalse, reason: '$where $value');
            // A note may name an address; its colon is not prose.
            expect(
              value
                  .replaceAll(RegExp(r'https://\S+'), '')
                  .replaceAll(RegExp(r'\d:\d'), '')
                  .contains(':'),
              isFalse,
              reason: '$where $value',
            );
          }
          check(value, '$where.$key');
        }
      } else if (o is List) {
        for (final v in o) {
          check(v, where);
        }
      }
    }

    check(raw, 'list');
  });

  test('every link in the shipped list is https', () {
    final urls = <String>[];
    void collect(Object? o) {
      if (o is Map) {
        for (final k in ['url', 'chat']) {
          if (o[k] case final String u) urls.add(u);
        }
        o.values.forEach(collect);
      } else if (o is List) {
        o.forEach(collect);
      }
    }

    collect(raw);
    expect(urls.length, greaterThanOrEqualTo(200));
    for (final u in urls) {
      expect(isHttpsUrl(u), isTrue, reason: u);
    }
  });

  test('no page shows the same link twice', () {
    List<String> links(Iterable<HelpContact> cs) => [
      for (final c in cs) ...[?c.url, ?c.chat],
    ];
    final world = links(res.worldwide.all);
    expect(world.toSet().length, world.length, reason: 'worldwide');
    for (final c in res.countries.values) {
      // Each need is its own page: the country's rows, then the worldwide ones.
      for (final kind in _kinds) {
        final page = [
          ...links(_of(c.help, kind)),
          ...links(_of(res.worldwide, kind)),
        ];
        final seen = <String>{};
        for (final u in page) {
          expect(seen.add(u), isTrue, reason: '${c.code} $kind shows $u twice');
        }
      }
    }
  });

  test('a line that answers anyone is the crisis line too', () {
    // Montenegro's and Georgia's 116 111 are their countries' crisis lines.
    for (final code in ['ME', 'GE']) {
      final help = res.countries[code]!.help;
      expect(help.mainCrisis?.phones.single.number, '116 111', reason: code);
      expect(
        help.children.single.phones.single.number,
        '116 111',
        reason: code,
      );
    }
    expect(
      res.countries['GE']!.help.mainCrisis!.hours,
      'Mon to Fri, 10:00 to 18:00',
    );
    // Georgia's page says any age; Montenegro's name says children and
    // young people, so its row claims no age at all.
    expect(res.countries['GE']!.help.mainCrisis!.note, 'For all ages');
    expect(res.countries['ME']!.help.mainCrisis!.note, isNull);
  });

  test('a line checked by hand keeps every way in', () {
    final ncmh = res.countries['PH']!.help.mainCrisis!;
    expect(ncmh.phones.map((p) => p.number), [
      '1553',
      '0919 057 1553',
      '0917 899 8727',
      '0966 351 4518',
    ]);
    final richmond = res.countries['MT']!.help.crisis.firstWhere(
      (c) => c.name == 'Richmond Helpline',
    );
    expect(richmond.chat, 'https://olli.chat/');
    // The chat keeps the phone's hours, so one line covers both.
    expect(richmond.chatHours, isNull);
    expect(richmond.hours, startsWith('Mon to Fri, 8:00 to 20:00'));
  });

  test('Australia keeps the rows checked by hand on its blocked sites', () {
    final au = res.countries['AU']!.help;
    expect(au.photos.map((c) => c.url), [
      'https://www.esafety.gov.au/report/image-based-abuse',
      'https://www.accce.gov.au/report',
    ]);
    expect(au.photos.last.note, startsWith('For under 18s.'));
    expect(au.websites.single.linkRequired, isFalse);
    final cyber = au.police.single;
    expect(cyber.phones.single.number, '1300 292 371');
    // It takes scams and hacking only, so the row must say it is no place for threats.
    expect(cyber.note, contains('not threats'));
  });

  test('the shipped copy leaves the research fields in reports/', () {
    for (final field in [
      '"source"',
      'emergency_source',
      'sources_used',
      '"evidence"',
      '"http_status"',
      '"display_name"',
    ]) {
      expect(source.contains(field), isFalse, reason: field);
    }
  });

  test('a number with a hint parses, and only plain numbers do', () {
    final text = HelpPhone.parse('686868 (text)')!;
    expect(text.number, '686868');
    expect(text.isText, isTrue);
    expect(text.keyword, isNull);
    final kr = HelpPhone.parse('1388 (mobile: area code + 1388)')!;
    expect(kr.number, '1388');
    expect(kr.hint, 'mobile: area code + 1388');
    expect(kr.isText, isFalse);
    expect(HelpPhone.parse('1-800-422-4453')!.dialable, '18004224453');
    expect(HelpPhone.parse('0 800 500 225')!.dialable, '0800500225');
    expect(HelpPhone.parse('+48 22 123')!.dialable, '+4822123');
    expect(HelpPhone.parse('call us'), isNull);
    expect(HelpPhone.parse('112; rm -rf'), isNull);
  });

  test('a text line may name the word to send first', () async {
    final dialed = <Uri>[];
    helpDialLauncher = (uri) async {
      dialed.add(uri);
      return true;
    };
    final home = HelpPhone.parse('741741 (text HOME)')!;
    expect(home.isText, isTrue);
    expect(home.keyword, 'HOME');
    expect(home.canDial, isTrue);
    expect(await dialHelpPhone(home), isTrue);
    expect(dialed.single.toString(), 'sms:741741?body=HOME');
    // Only a short upper-case word counts; anything else is a note.
    for (final hint in ['text home', 'text HOME NOW', 'text H&M', 'texts']) {
      final p = HelpPhone.parse('741741 ($hint)')!;
      expect(p.isText, isFalse, reason: hint);
      expect(p.canDial, isFalse, reason: hint);
    }
  });

  test('a link that is not https is dropped from an entry', () {
    final c = HelpContact.fromJson({
      'name': 'X',
      'url': 'http://example.org/',
      'chat': 'javascript:alert(1)',
      'phone': ['116 111'],
    })!;
    expect(c.url, isNull);
    expect(c.chat, isNull);
    expect(
      HelpContact.fromJson({'name': 'Y', 'url': 'file:///etc'}),
      isNull,
      reason: 'nothing left to reach',
    );
    expect(HelpContact.fromJson({'name': 'Z', 'chat': 'hollow://x'}), isNull);
  });

  test('a region comes from the locale name, never anything else', () {
    expect(regionFromLocaleName('pl_PL'), 'PL');
    expect(regionFromLocaleName('en-US.UTF-8'), 'US');
    expect(regionFromLocaleName('de_DE@euro'), 'DE');
    expect(regionFromLocaleName('en'), isNull);
    expect(regionFromLocaleName('C'), isNull);
    expect(regionFromLocaleName(null), isNull);
  });

  test('a number with a dialing note never dials', () async {
    final dialed = <Uri>[];
    helpDialLauncher = (uri) async {
      dialed.add(uri);
      return true;
    };
    final landline = HelpPhone.parse('1388 (landline)')!;
    expect(landline.canDial, isFalse);
    expect(await dialHelpPhone(landline), isFalse);
    expect(dialed, isEmpty);
    expect(HelpPhone.parse('234 (text)')!.canDial, isTrue);
    expect(HelpPhone.parse('112')!.canDial, isTrue);
  });

  test('search matches a name or a whole ISO code', () {
    final gb = res.countries['GB']!;
    expect(gb.matches('king'), isTrue);
    expect(gb.matches('gb'), isTrue);
    expect(gb.matches('zz'), isFalse);
    expect(res.countries['PL']!.matches('gb'), isFalse);
  });
}
