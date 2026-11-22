import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/hollow_data_dir.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/service_providers.dart';
import 'package:hollow/src/core/services/network_service.dart';

/// The probe's production relay guard: a probe or fleet peer never reaches the
/// official relay (anything under anonlisten.com, or its addresses) unless the
/// run sets UI_PROBE_ALLOW_PRODUCTION=1, and with UI_PROBE_EXPECT_RELAY set (a
/// comma list: the relay it boots on, then any test relay a journey moves it to)
/// it reaches no relay but those.
///
/// It refuses by ending the process before the dial: at the relay setting
/// (loaded or changed), at node start, and at any Dart HTTP request to the
/// official relay. The verdict lands in `relay_guard.json` in the out dir,
/// which fleet.ps1 reads. The tooling half is scripts/fleet_relay_guard.ps1.
const kProbeUnstampedRelay = 'no-relay-stamped.invalid';
const kRelayGuardExitCode = 86;
/// The relay a fleet fixture carries, one line in its data directory; the
/// tooling reads it before every launch (scripts/fleet_relay_guard.ps1).
const kFleetRelayStampFile = 'fleet_relay';
const _productionSuffix = 'anonlisten.com';
const _productionRelayHosts = {'relay.anonlisten.com'};
const _productionAddresses = {'141.227.186.209', '2001:41d0:ab01::4:0:d'};

/// `host[:port]` of a relay setting, lowercased, without scheme, user, path or
/// trailing dot.
String relayHostPort(String raw) {
  var s = raw.trim().toLowerCase();
  final scheme = s.indexOf('://');
  if (scheme >= 0) s = s.substring(scheme + 3);
  final end = s.indexOf(RegExp(r'[/?#]'));
  if (end >= 0) s = s.substring(0, end);
  final at = s.lastIndexOf('@');
  if (at >= 0) s = s.substring(at + 1);
  if (s.startsWith('[')) return s;
  if (':'.allMatches(s).length == 1) {
    final parts = s.split(':');
    return '${_trimDots(parts[0])}:${parts[1]}';
  }
  return _trimDots(s);
}

/// Just the host of a relay setting (an IPv6 literal without brackets).
String relayHost(String raw) {
  final s = relayHostPort(raw);
  if (s.startsWith('[')) {
    final end = s.indexOf(']');
    return end > 0 ? s.substring(1, end) : s.substring(1);
  }
  if (':'.allMatches(s).length == 1) return s.split(':').first;
  return s;
}

String _trimDots(String s) {
  var out = s;
  while (out.endsWith('.')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}

bool isProductionAddress(InternetAddress ip) {
  final mine = _plain(ip);
  return _productionAddresses.any((a) {
    final other = InternetAddress.tryParse(a);
    return other != null && _plain(other) == mine;
  });
}

/// Raw bytes of an address, an IPv4-mapped IPv6 one as its IPv4.
String _plain(InternetAddress ip) {
  final raw = ip.rawAddress;
  if (raw.length == 16 &&
      raw.sublist(0, 10).every((b) => b == 0) &&
      raw[10] == 0xff &&
      raw[11] == 0xff) {
    return raw.sublist(12).join('.');
  }
  return raw.length == 4 ? raw.join('.') : raw.join(',');
}

/// Why [domain] is the official relay, judged by its text; null when not.
String? productionReason(String domain) {
  final host = relayHost(domain);
  if (host.isEmpty) return 'names no relay, which means the official one';
  if (host == _productionSuffix || host.endsWith('.$_productionSuffix')) {
    return '$host is under $_productionSuffix, the official relay';
  }
  final ip = InternetAddress.tryParse(host);
  if (ip != null && isProductionAddress(ip)) {
    return "$host is the official relay's address";
  }
  return null;
}

/// Why a peer may not use [domain] as its relay; null when it may.
/// [production] says whether the reason is the official relay (which the
/// opt-in lifts) rather than a mismatch with the run's relay (which it never
/// does).
({String reason, bool production})? relayVerdict(String domain,
    {String? expect}) {
  final prod = productionReason(domain);
  if (prod != null) return (reason: prod, production: true);
  if (relayHost(domain) == kProbeUnstampedRelay) {
    return (
      reason: 'this data directory names no relay, which means the official one',
      production: true,
    );
  }
  final allowed = expectedRelays(expect);
  if (allowed.isNotEmpty && !allowed.contains(relayHostPort(domain))) {
    return (
      reason: 'the relay is ${relayHostPort(domain)}, not this run\'s '
          '${allowed.join(' or ')}',
      production: false,
    );
  }
  return null;
}

/// UI_PROBE_EXPECT_RELAY as the set of relays a peer may use; empty = any
/// relay that is not the official one.
List<String> expectedRelays(String? expect) => [
      for (final entry in (expect ?? '').split(','))
        if (relayHostPort(entry).isNotEmpty) relayHostPort(entry),
    ];

/// Why a Dart HTTP request to [url] would reach the official relay; null when
/// it would not. The website, shop and GIF hosts under the same domain pass.
String? httpProductionReason(Uri url) {
  final host = relayHost(url.host);
  if (_productionRelayHosts.contains(host)) {
    return '$host is the official relay';
  }
  final ip = InternetAddress.tryParse(host);
  if (ip != null && isProductionAddress(ip)) {
    return "$host is the official relay's address";
  }
  if (url.path.startsWith('/relay-status') && productionReason(host) != null) {
    return '$host answers as a relay under $_productionSuffix';
  }
  return null;
}

class ProbeRelayGuard {
  ProbeRelayGuard({
    required this.outDir,
    required this.allowProduction,
    this.expect,
    this.dataDir,
    void Function(String where, String reason)? onRefuse,
  }) : _onRefuse = onRefuse;

  factory ProbeRelayGuard.fromEnv(Map<String, String> env, String outDir) =>
      ProbeRelayGuard(
        outDir: outDir,
        allowProduction: env['UI_PROBE_ALLOW_PRODUCTION'] == '1',
        expect: env['UI_PROBE_EXPECT_RELAY'],
        dataDir: env['HOLLOW_DATA_DIR'],
      );

  final String outDir;
  final bool allowProduction;
  final String? expect;
  final String? dataDir;
  final void Function(String where, String reason)? _onRefuse;

  /// The provider overrides that put the guard in front of the relay setting
  /// and the node start.
  List<Override> get overrides => [
        relayDomainProvider.overrideWith(() => GuardedRelayDomainNotifier(this)),
        networkServiceProvider.overrideWith((ref) =>
            GuardedNetworkService(this, () => ref.read(relayDomainProvider))),
      ];

  /// Proof for the tooling that this build guards, written before anything dials.
  void announce() {
    _mark({'verdict': 'armed'});
    if (allowProduction) {
      debugPrint('[ui-probe] !!! RELAY GUARD: production relay ALLOWED '
          '(UI_PROBE_ALLOW_PRODUCTION=1); throwaway identities may reach the '
          'official relay');
    } else {
      debugPrint('[ui-probe] relay guard armed'
          '${(expect ?? '').isEmpty ? '' : ', expecting $expect'}');
    }
  }

  void check(String domain, String where) {
    final verdict = relayVerdict(domain, expect: expect);
    if (verdict == null) return;
    if (verdict.production && allowProduction) {
      debugPrint('[ui-probe] !!! RELAY GUARD ($where): ${verdict.reason}; '
          'allowed by UI_PROBE_ALLOW_PRODUCTION');
      return;
    }
    refuse(where, verdict.reason, domain: domain);
  }

  /// Everything [check] judges, plus where the relay resolves and the fleet's
  /// dial override, for the moment before the node dials.
  Future<void> checkBeforeNodeStart(String domain) async {
    check(domain, 'node start');
    if (allowProduction) return;
    final override = _dialOverride();
    if (override != null) {
      final why = productionReason(override);
      if (why != null) refuse('node start', 'relay_connect: $why', domain: domain);
    }
    final host = relayHost(domain);
    var found = const <InternetAddress>[];
    try {
      found = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      // A name that does not resolve cannot be dialled either.
    }
    for (final ip in found) {
      if (isProductionAddress(ip)) {
        refuse('node start',
            '$host resolves to the official relay (${ip.address})',
            domain: domain);
      }
    }
    _mark({'verdict': 'passed', 'where': 'node start', 'domain': domain});
  }

  void checkHttp(Uri url) {
    if (allowProduction) return;
    final why = httpProductionReason(url);
    if (why != null) refuse('http ${url.host}${url.path}', why, domain: url.host);
  }

  Never refuse(String where, String reason, {String? domain}) {
    _mark({
      'verdict': 'refused',
      'where': where,
      'domain': domain,
      'reason': reason,
    });
    debugPrint('[ui-probe] RELAY GUARD REFUSED ($where): $reason. Fleet and '
        'probe peers never reach the official relay; onboard them with -Relay '
        '<test relay>, or opt in with -AllowProduction.');
    final hook = _onRefuse;
    if (hook == null) exit(kRelayGuardExitCode);
    hook(where, reason);
    throw RelayGuardRefusal(where, reason);
  }

  /// The fixture's relay stamp follows a relay change the guard let through,
  /// so the next launch is judged by the relay the data now carries.
  void restamp(String domain) {
    final dir = _dataDir();
    if (dir == null) return;
    try {
      File('$dir/$kFleetRelayStampFile')
          .writeAsStringSync('${relayHostPort(domain)}\n');
    } catch (_) {
      // The tooling then refuses the stale stamp, which fails closed.
    }
  }

  String? _dataDir() =>
      (dataDir == null || dataDir!.isEmpty) ? _safeDataDir() : dataDir;

  String? _dialOverride() {
    final dir = _dataDir();
    if (dir == null) return null;
    try {
      final file = File('$dir/relay_connect');
      if (!file.existsSync()) return null;
      return file.readAsStringSync().trim();
    } catch (_) {
      return null;
    }
  }

  String? _safeDataDir() {
    try {
      return hollowDataDir;
    } catch (_) {
      return null;
    }
  }

  void _mark(Map<String, Object?> fields) {
    try {
      final dir = Directory(outDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File('$outDir/relay_guard.json').writeAsStringSync(jsonEncode({
        'guard': 'on',
        'allow': allowProduction,
        'expect': expect ?? '',
        'at': DateTime.now().toIso8601String(),
        ...fields,
      }));
    } catch (_) {
      // The verdict still stops the process; only the record is lost.
    }
  }
}

/// What [ProbeRelayGuard.refuse] throws where a test replaced the exit.
class RelayGuardRefusal implements Exception {
  RelayGuardRefusal(this.where, this.reason);

  final String where;
  final String reason;

  @override
  String toString() => 'RelayGuardRefusal($where): $reason';
}

/// The relay setting with the guard in front: unless the run opted in, a
/// probe's default is never the official relay, and a loaded or newly chosen
/// relay is judged before anything can use it.
class GuardedRelayDomainNotifier extends RelayDomainNotifier {
  GuardedRelayDomainNotifier(this.guard);

  final ProbeRelayGuard guard;

  /// Opted in, an unstamped data directory means the official relay, as in
  /// the real app; refused, the sentinel that node start refuses.
  @override
  String build() =>
      guard.allowProduction ? kDefaultRelayDomain : kProbeUnstampedRelay;

  @override
  Future<bool> loadCached() async {
    final tookSwitch = await super.loadCached();
    if (state != kProbeUnstampedRelay) guard.check(state, 'relay setting');
    return tookSwitch;
  }

  /// Stamped at the save, like [setDomain]: the tooling reads the stamp to
  /// judge what the next launch may dial.
  @override
  Future<void> saveForNextLaunch(String domain) async {
    guard.check(domain, 'relay change');
    await super.saveForNextLaunch(domain);
    guard.restamp(domain);
  }

  @override
  Future<void> setDomain(String domain) async {
    guard.check(domain, 'relay change');
    await super.setDomain(domain);
    guard.restamp(domain);
  }
}

class GuardedNetworkService extends NetworkService {
  GuardedNetworkService(this.guard, this.relayDomain);

  final ProbeRelayGuard guard;
  final String Function() relayDomain;

  @override
  Future<String> startNode() async {
    await guard.checkBeforeNodeStart(relayDomain());
    return super.startNode();
  }
}

/// Every dart:io HttpClient asks this for its proxy before it connects, so the
/// guard sees each request's URL first.
class RelayGuardHttpOverrides extends HttpOverrides {
  RelayGuardHttpOverrides(this.guard);

  final ProbeRelayGuard guard;

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    guard.checkHttp(url);
    return super.findProxyFromEnvironment(url, environment);
  }
}
