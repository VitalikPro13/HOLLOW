import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/relay_domain_provider.dart';
import 'package:hollow/src/core/providers/updater_provider.dart';
import 'package:hollow/src/core/version_compare.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// System status feed, served alongside news.json / manifest.json on the
/// WEBSITE host (independent of the relay VPS), so it loads even when the relay
/// is down: exactly when we most need to say "relay maintenance, back at 02:00".
/// Signed like the manifest (`status.json.sig`), under its own feed name.
const kStatusUrl = 'https://anonlisten.com/hollow/releases/status.json';

/// Dismissed notice ids, a JSON list, newest last (SQLCipher KV).
const _kDismissedIdsKey = 'dismissed_status_ids';

/// The single dismissed id builds up to 0.12.1 kept; read once so a dismissal
/// made there still holds.
const _kLegacyDismissedKey = 'dismissed_status_id';

/// The highest signed `issued` this install has accepted. A feed stamped
/// earlier is a re-served old copy and is dropped, so a stale notice cannot
/// come back.
const _kIssuedKey = 'status_feed_issued';

/// Enough for every notice that is live at once, with room to spare; older
/// dismissals fall off the front.
const _kMaxDismissed = 32;

/// What the status feed reads from the device; tests replace it.
class StatusFeedEnv {
  final Future<String?> Function(String key) load;
  final Future<void> Function(String key, String value) save;
  final DateTime Function() now;

  /// `Platform.operatingSystem`: windows, linux, macos, android or ios.
  final String platform;

  const StatusFeedEnv({
    required this.load,
    required this.save,
    required this.now,
    required this.platform,
  });
}

final statusFeedEnvProvider = Provider<StatusFeedEnv>((ref) => StatusFeedEnv(
      load: (key) => storage_api.loadSetting(key: key),
      save: (key, value) => storage_api.saveSetting(key: key, value: value),
      now: () => DateTime.now().toUtc(),
      platform: Platform.operatingSystem,
    ));

/// Severity / tone of a status notice. Drives colour, icon, and whether it
/// surfaces in the global shell banner at all.
///
/// Ordering matters: `operational` is the quiet healthy default (the banner
/// shows NOTHING) and `info` is the neutral channel, kept visually distinct
/// from the amber/red levels so a light note never reads as an incident. The
/// declaration order is also the severity order.
enum StatusLevel {
  operational,
  info,
  maintenance,
  warning,
  critical;

  static StatusLevel fromString(String? raw) {
    switch (raw?.toLowerCase().trim()) {
      case 'info':
        return StatusLevel.info;
      case 'maintenance':
        return StatusLevel.maintenance;
      case 'warning':
        return StatusLevel.warning;
      case 'critical':
        return StatusLevel.critical;
      case 'operational':
      default:
        // Unknown / missing / malformed → assume healthy. Fail-safe: a bad feed
        // must NEVER produce a scary banner.
        return StatusLevel.operational;
    }
  }

  /// Levels that warrant the unmissable global banner. `operational` never does
  /// (silence = healthy); the green state only appears on the calm Home line.
  bool get showsInBanner => this != StatusLevel.operational;
}

/// Which relay's users a notice is for.
enum StatusAudience { official, selfHosted, all }

/// A parsed system-status notice. Every display field is defensively defaulted
/// so a partial notice degrades gracefully rather than throwing.
class SystemStatus {
  final String id;
  final StatusLevel level;
  final String title;
  final String message;

  /// Absolute UTC instant the countdown targets; null when the notice has no
  /// timer. Authored in UTC, rendered as a live countdown in every timezone.
  final DateTime? until;

  /// Short label preceding the countdown, e.g. "Starts in" / "Back online in".
  final String untilLabel;

  final String link;
  final String linkLabel;

  /// Whether the user may dismiss the banner. Force `false` for a `critical`
  /// notice that must not be hidden-and-forgotten.
  final bool dismissible;

  /// After this instant the notice is gone, whatever the host keeps serving.
  final DateTime? expires;
  final StatusAudience audience;

  /// Null = every platform.
  final Set<String>? platforms;

  /// Shown only to builds older than [below] and at least [from].
  final ReleaseId? below;
  final ReleaseId? from;

  const SystemStatus({
    this.id = '',
    this.level = StatusLevel.operational,
    this.title = '',
    this.message = '',
    this.until,
    this.untilLabel = '',
    this.link = '',
    this.linkLabel = '',
    this.dismissible = true,
    this.expires,
    this.audience = StatusAudience.official,
    this.platforms,
    this.below,
    this.from,
  });

  /// The empty / healthy default used before the first fetch and on any error.
  static const SystemStatus healthy = SystemStatus();

  /// One entry of `notices[]`, or null when it cannot be shown safely: no id,
  /// no valid `expires`, or targeting this build cannot read. A notice whose
  /// audience is unclear reaches nobody rather than the wrong people.
  static SystemStatus? fromNotice(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final id = _str(raw['id']);
    final expires = parseUtc(_str(raw['expires']));
    if (id.isEmpty || expires == null) return null;
    final level = raw['level'];
    if (level != null && level is! String) return null;

    final StatusAudience audience;
    switch (raw['relay'] ?? 'official') {
      case 'official':
        audience = StatusAudience.official;
      case 'self_hosted':
        audience = StatusAudience.selfHosted;
      case 'all':
        audience = StatusAudience.all;
      default:
        return null;
    }

    Set<String>? platforms;
    final rawPlatforms = raw['platforms'];
    if (raw.containsKey('platforms')) {
      if (rawPlatforms is! List) return null;
      platforms = {for (final p in rawPlatforms) if (p is String) p};
    }

    ReleaseId? gate(String key) => ReleaseId.parse(_str(raw[key]));
    final below = raw.containsKey('below') ? gate('below') : null;
    final from = raw.containsKey('from') ? gate('from') : null;
    if ((raw.containsKey('below') && below == null) ||
        (raw.containsKey('from') && from == null)) {
      return null;
    }

    return SystemStatus(
      id: id,
      level: StatusLevel.fromString(level as String?),
      title: _str(raw['title']),
      message: _str(raw['message']),
      until: parseUtc(_str(raw['until'])),
      untilLabel: _str(raw['until_label']),
      link: _str(raw['link']),
      linkLabel: _str(raw['link_label']),
      // Default true; only an explicit `false` makes it non-dismissible.
      dismissible: raw['dismissible'] is bool ? raw['dismissible'] as bool : true,
      expires: expires,
      audience: audience,
      platforms: platforms,
      below: below,
      from: from,
    );
  }

  static String _str(Object? v) => v is String ? v.trim() : '';

  /// Parse a feed timestamp as an absolute UTC instant, robust to the author
  /// forgetting the trailing `Z`.
  ///
  /// `DateTime.tryParse` treats a suffix-less string as the USER'S LOCAL time,
  /// so a suffix-less value is re-labelled (not converted) as UTC. Returns null
  /// for empty/garbage.
  static DateTime? parseUtc(String raw) {
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    if (parsed.isUtc) return parsed.toUtc();
    // A local time at DateTime's edge has no UTC twin: unreadable, not a throw.
    try {
      return DateTime.utc(
        parsed.year,
        parsed.month,
        parsed.day,
        parsed.hour,
        parsed.minute,
        parsed.second,
        parsed.millisecond,
      );
    } on ArgumentError {
      return null;
    }
  }

  /// Whether this notice is for this install right now.
  bool appliesTo({
    required bool selfHosted,
    required String platform,
    required ReleaseId running,
    required DateTime now,
  }) {
    if (expires == null || !now.isBefore(expires!)) return false;
    final relayOk = switch (audience) {
      StatusAudience.official => !selfHosted,
      StatusAudience.selfHosted => selfHosted,
      StatusAudience.all => true,
    };
    if (!relayOk) return false;
    if (platforms != null && !platforms!.contains(platform)) return false;
    if (below != null && running.compareTo(below!) >= 0) return false;
    if (from != null && running.compareTo(from!) < 0) return false;
    return true;
  }

  /// True when there is genuinely nothing to announce: operational level with no
  /// message. Keeps even the Home line from rendering a stray empty card.
  bool get isEmpty =>
      level == StatusLevel.operational && title.isEmpty && message.isEmpty;

  /// Whether this notice has any text body worth showing.
  bool get hasContent => title.isNotEmpty || message.isNotEmpty;
}

/// A verified `status.json`: its signed stamp and every notice this build can
/// read. The top-level fields beside `notices` belong to apps up to 0.12.1 and
/// are never read here.
class StatusFeed {
  final int issued;
  final List<SystemStatus> notices;

  const StatusFeed(this.issued, this.notices);

  /// Null unless the feed carries a positive integer `issued` and a `notices`
  /// list: without the stamp there is no telling a fresh copy from a re-served
  /// old one.
  static StatusFeed? parse(String json) {
    final Object? doc;
    try {
      doc = jsonDecode(json);
    } catch (_) {
      return null;
    }
    if (doc is! Map<String, dynamic>) return null;
    final issued = doc['issued'];
    final notices = doc['notices'];
    if (issued is! int || issued <= 0 || notices is! List) return null;
    return StatusFeed(issued, [
      for (final n in notices) ?readNotice(n),
    ]);
  }

  /// One notice, or null: whatever it holds, it never takes the others down.
  @visibleForTesting
  static SystemStatus? readNotice(Object? raw) {
    try {
      return SystemStatus.fromNotice(raw);
    } catch (_) {
      return null;
    }
  }
}

class StatusState {
  /// The notices meant for this install, in feed order.
  final List<SystemStatus> notices;
  final bool hasFetched;
  final Set<String> dismissedIds;

  const StatusState({
    this.notices = const [],
    this.hasFetched = false,
    this.dismissedIds = const {},
  });

  StatusState copyWith({
    List<SystemStatus>? notices,
    bool? hasFetched,
    Set<String>? dismissedIds,
  }) =>
      StatusState(
        notices: notices ?? this.notices,
        hasFetched: hasFetched ?? this.hasFetched,
        dismissedIds: dismissedIds ?? this.dismissedIds,
      );

  /// What the calm Home and Settings card shows: the most severe notice, the
  /// first in the feed among equals, dismissed or not.
  SystemStatus get status => _mostSevere(notices) ?? SystemStatus.healthy;

  /// What the global banner shows: the most severe banner-worthy notice that
  /// has not been dismissed. Dismissing it lets the next one through.
  SystemStatus? get bannerNotice => _mostSevere([
        for (final n in notices)
          if (n.level.showsInBanner &&
              n.hasContent &&
              !dismissedIds.contains(n.id))
            n
      ]);

  bool get showBanner => bannerNotice != null;

  static SystemStatus? _mostSevere(List<SystemStatus> list) {
    SystemStatus? best;
    for (final n in list) {
      if (best == null || n.level.index > best.level.index) best = n;
    }
    return best;
  }
}

class StatusNotifier extends Notifier<StatusState> {
  Timer? _timer;

  /// The status file changes a few times a MONTH, so a frequent poll is waste;
  /// once a minute is ample lead time at a cost a machine won't notice. Its OWN
  /// timer, hitting ONLY the website, so it keeps refreshing while the relay is
  /// down: exactly when an outage notice matters most.
  static const _pollInterval = Duration(seconds: 60);

  /// The last verified feed this install accepted; its notices are filtered
  /// again on every poll, since `expires` passes without the file changing.
  StatusFeed? _feed;
  String? _feedJson;

  int _highestIssued = 0;

  /// Until the stored stamp is read, a fetched stamp is held in memory only:
  /// writing it earlier could lower the stored one.
  bool _storeLoaded = false;

  /// Nothing shows until the stored stamp has been read (or its read failed):
  /// before that a re-served older copy cannot be told from a fresh one.
  bool _storeChecked = false;

  /// How far past this device's clock a kept stamp may sit. A signed stamp
  /// from the future still shows, but adopting it whole would hide every later
  /// feed until that time; capped, it hides them for at most this long.
  static const _maxIssuedAhead = Duration(hours: 1);

  @override
  StatusState build() {
    // Fetch the network feed eagerly (independent of the DB). The persisted
    // state loads separately via [loadDismissed], from the shell bootstrap.
    Future.microtask(_fetch);

    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _doFetch());
    ref.onDispose(() => _timer?.cancel());
    ref.listen(relayDomainProvider, (_, _) => _apply());

    return const StatusState();
  }

  /// Load the dismissed ids and the stamp high-water mark from the local DB.
  /// Called from the shell `_bootstrap` alongside the other `.load()` providers.
  ///
  /// It MUST be driven from bootstrap, not eagerly in [build]: this provider is
  /// created the instant the shell banner first watches it, which during the
  /// local-first render can be BEFORE the store opens, and `loadSetting` throws.
  Future<void> loadDismissed() async {
    final env = ref.read(statusFeedEnvProvider);
    final dismissed = <String>{...state.dismissedIds};
    try {
      final raw = await env.load(_kDismissedIdsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = jsonDecode(raw);
        if (list is List) dismissed.addAll(list.whereType<String>());
      }
      final legacy = await env.load(_kLegacyDismissedKey);
      if (legacy != null && legacy.isNotEmpty) dismissed.add(legacy);
    } catch (_) {
      // Non-fatal: worst case a previously-dismissed banner re-appears once.
    }
    try {
      final stored = int.tryParse(await env.load(_kIssuedKey) ?? '') ?? 0;
      _raiseIssued(stored, env);
      _storeLoaded = true;
      await _persistIssued(env);
    } catch (_) {
      // An unreadable store guards this session from memory only.
    }
    _storeChecked = true;
    state = state.copyWith(dismissedIds: dismissed);
    _apply();
  }

  Future<void> _fetch() async {
    if (state.hasFetched) return;
    await _doFetch();
  }

  Future<bool> refresh() async => _doFetch();

  /// Kept for the shell bootstrap: the relay domain just loaded, so the
  /// audience filter runs again.
  void onRelayLoaded() => _apply();

  bool get _isSelfHosted =>
      ref.read(relayDomainProvider) != kDefaultRelayDomain;

  Future<bool> _doFetch() async {
    final StatusFeed? feed;
    String? json;
    try {
      final bustCache = DateTime.now().millisecondsSinceEpoch;
      json = await ref
          .read(signedFeedFetchProvider)('$kStatusUrl?t=$bustCache', 'status');
      feed = json == _feedJson ? _feed : StatusFeed.parse(json);
    } catch (_) {
      // Offline, missing, unsigned or a bad signature: silent, never a banner.
      _accept(null, null);
      return false;
    }
    if (feed == null) {
      _accept(null, null);
      return false;
    }
    final env = ref.read(statusFeedEnvProvider);
    if (_raiseIssued(feed.issued, env)) unawaited(_persistIssued(env));
    _accept(feed, json);
    return true;
  }

  /// Raises the high-water mark to [issued], never past this clock plus
  /// [_maxIssuedAhead]. True when it moved.
  bool _raiseIssued(int issued, StatusFeedEnv env) {
    final ceiling =
        env.now().add(_maxIssuedAhead).millisecondsSinceEpoch ~/ 1000;
    final next = issued < ceiling ? issued : ceiling;
    if (next <= _highestIssued) return false;
    _highestIssued = next;
    return true;
  }

  Future<void> _persistIssued(StatusFeedEnv env) async {
    if (!_storeLoaded || _highestIssued <= 0) return;
    try {
      await env.save(_kIssuedKey, '$_highestIssued');
    } catch (_) {}
  }

  void _accept(StatusFeed? feed, String? json) {
    _feed = feed;
    _feedJson = json;
    _apply(fetched: true);
  }

  /// Filters the held feed for this install and writes state only when the
  /// visible notices changed, so the banner and card do not rebuild every poll.
  void _apply({bool fetched = false}) {
    final feed = _feed;
    // The ONE rollback check: a copy stamped before one already accepted, here
    // or on an earlier launch, shows nothing.
    final visible =
        feed == null || !_storeChecked || feed.issued < _highestIssued
            ? const <SystemStatus>[]
            : _visible(feed.notices);
    final same = visible.length == state.notices.length &&
        [
          for (var i = 0; i < visible.length; i++)
            identical(visible[i], state.notices[i])
        ].every((e) => e);
    if (same && (state.hasFetched || !fetched)) return;
    state = state.copyWith(
        notices: visible, hasFetched: state.hasFetched || fetched);
  }

  List<SystemStatus> _visible(List<SystemStatus> all) {
    final env = ref.read(statusFeedEnvProvider);
    final running = ref.read(runningReleaseProvider);
    final now = env.now();
    final selfHosted = _isSelfHosted;
    return [
      for (final n in all)
        if (n.appliesTo(
            selfHosted: selfHosted,
            platform: env.platform,
            running: running,
            now: now))
          n
    ];
  }

  /// Dismiss one notice for its id, remembered across launches; a newly
  /// published id shows again.
  Future<void> dismiss(String id) async {
    if (id.isEmpty) return;
    final next = [...state.dismissedIds.where((d) => d != id), id];
    final kept = next.length > _kMaxDismissed
        ? next.sublist(next.length - _kMaxDismissed)
        : next;
    state = state.copyWith(dismissedIds: kept.toSet());
    try {
      await ref
          .read(statusFeedEnvProvider)
          .save(_kDismissedIdsKey, jsonEncode(kept));
    } catch (_) {
      // Non-fatal: the in-memory dismissal already hid it for this session.
    }
  }
}

final statusProvider =
    NotifierProvider<StatusNotifier, StatusState>(StatusNotifier.new);
