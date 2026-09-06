import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

/// System status feed, served alongside news.json / manifest.json on the
/// WEBSITE host (independent of the relay VPS), so it loads even when the relay
/// is down: exactly when we most need to say "relay maintenance, back at 02:00".
/// Plain HTTPS GET, unsigned unlike the update manifest; nothing touches the WS.
const kStatusUrl = 'https://anonlisten.com/hollow/releases/status.json';

/// Key under which the last DISMISSED status id is persisted (SQLCipher KV).
/// A dismissed banner stays gone for THAT incident id; publishing a new id
/// re-shows it. Empty/absent = nothing dismissed.
const _kDismissedStatusKey = 'dismissed_status_id';

/// Severity / tone of a status notice. Drives colour, icon, and whether it
/// surfaces in the global shell banner at all.
///
/// Ordering matters: `operational` is the quiet healthy default (the banner
/// shows NOTHING) and `info` is the neutral channel, kept visually distinct
/// from the amber/red levels so a light note never reads as an incident.
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

/// A parsed system-status notice. Every field is defensively defaulted (mirrors
/// [NewsPost.fromJson]) so a partial / malformed feed degrades gracefully
/// rather than throwing.
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
  });

  /// The empty / healthy default used before the first fetch and on any error.
  static const SystemStatus healthy = SystemStatus();

  factory SystemStatus.fromJson(Map<String, dynamic> json) {
    final rawUntil = (json['until'] as String?)?.trim() ?? '';
    final parsedUntil = _parseUntilUtc(rawUntil);
    return SystemStatus(
      id: (json['id'] as String?)?.trim() ?? '',
      level: StatusLevel.fromString(json['level'] as String?),
      title: (json['title'] as String?)?.trim() ?? '',
      message: (json['message'] as String?)?.trim() ?? '',
      until: parsedUntil,
      untilLabel: (json['until_label'] as String?)?.trim() ?? '',
      link: (json['link'] as String?)?.trim() ?? '',
      linkLabel: (json['link_label'] as String?)?.trim() ?? '',
      // Default true; only an explicit `false` makes it non-dismissible.
      dismissible: json['dismissible'] as bool? ?? true,
    );
  }

  /// Parse the `until` timestamp as an absolute UTC instant, robust to the
  /// author forgetting the trailing `Z`.
  ///
  /// The countdown is correct in every timezone only because it compares two
  /// absolute UTC instants. `DateTime.tryParse` treats a suffix-less string as
  /// the USER'S LOCAL time, so a suffix-less value is re-labelled (not
  /// converted) as UTC. Returns null for empty/garbage.
  static DateTime? _parseUntilUtc(String raw) {
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    // Already zone-aware: normalise to UTC and we're done.
    if (parsed.isUtc) return parsed.toUtc();
    // No zone in the string → Dart assumed local. Rebuild the identical
    // year/month/day/hh:mm:ss as a UTC instant so it's zone-independent.
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
    );
  }

  /// True when there is genuinely nothing to announce: operational level with no
  /// message. Keeps even the Home line from rendering a stray empty card.
  bool get isEmpty =>
      level == StatusLevel.operational && title.isEmpty && message.isEmpty;

  /// Whether this notice has any text body worth showing.
  bool get hasContent => title.isNotEmpty || message.isNotEmpty;
}

class StatusState {
  final SystemStatus status;
  final bool hasFetched;

  /// The status id the user has dismissed (persisted). When it equals the
  /// current [status.id] the global banner stays hidden for this incident.
  final String dismissedId;

  const StatusState({
    this.status = SystemStatus.healthy,
    this.hasFetched = false,
    this.dismissedId = '',
  });

  StatusState copyWith({
    SystemStatus? status,
    bool? hasFetched,
    String? dismissedId,
  }) =>
      StatusState(
        status: status ?? this.status,
        hasFetched: hasFetched ?? this.hasFetched,
        dismissedId: dismissedId ?? this.dismissedId,
      );

  /// Whether the global shell banner should currently render: a banner-worthy
  /// level, with content, that hasn't been dismissed for this exact id. A
  /// notice with no id can't be dismissed (always shows while live).
  bool get showBanner {
    if (!status.level.showsInBanner || !status.hasContent) return false;
    if (status.id.isNotEmpty && status.id == dismissedId) return false;
    return true;
  }
}

class StatusNotifier extends Notifier<StatusState> {
  Timer? _timer;

  /// The status file changes a few times a MONTH, so a frequent poll is waste;
  /// once a minute is ample lead time at a cost a machine won't notice. Its OWN
  /// timer, hitting ONLY the website, so it keeps refreshing while the relay is
  /// down: exactly when an outage notice matters most.
  static const _pollInterval = Duration(seconds: 60);

  @override
  StatusState build() {
    // Fetch the network feed eagerly (independent of the DB). The persisted
    // dismissal loads separately via [loadDismissed], from the shell bootstrap.
    Future.microtask(_fetch);

    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _doFetch());
    ref.onDispose(() => _timer?.cancel());

    return const StatusState();
  }

  /// Load the persisted dismissed-id from the local DB. Called from the shell
  /// `_bootstrap` alongside the other `.load()` providers.
  ///
  /// It MUST be driven from bootstrap, not eagerly in [build]: this provider is
  /// created the instant the shell banner first watches it, which during the
  /// local-first render can be BEFORE the store opens, and `loadSetting` throws.
  Future<void> loadDismissed() async {
    try {
      final v = await storage_api.loadSetting(key: _kDismissedStatusKey);
      if (v != null && v.isNotEmpty) {
        state = state.copyWith(dismissedId: v);
      }
    } catch (_) {
      // Non-fatal: worst case a previously-dismissed banner re-appears once.
    }
  }

  Future<void> _fetch() async {
    if (state.hasFetched) return;
    await _doFetch();
  }

  Future<bool> refresh() async => _doFetch();

  /// Raw JSON of the last applied feed — the file changes rarely (monthly),
  /// so identical polls skip the state write entirely instead of rebuilding
  /// the banner + home card every 60s.
  String? _lastAppliedJson;

  Future<bool> _doFetch() async {
    try {
      final bustCache = DateTime.now().millisecondsSinceEpoch;
      // Plain fetch: status.json is display-only and has no signature sidecar
      // (fetchVersionManifest would demand status.json.sig).
      final json = await updater_api.fetchReleaseFeed(
          url: '$kStatusUrl?t=$bustCache');
      if (json == _lastAppliedJson && state.hasFetched) return true;
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      _lastAppliedJson = json;
      state = state.copyWith(
        status: SystemStatus.fromJson(decoded),
        hasFetched: true,
      );
      return true;
    } catch (_) {
      // Any failure (offline, 404, malformed) → stay healthy + silent. Never
      // surface an error as a banner.
      _lastAppliedJson = null;
      if (!(state.hasFetched && identical(state.status, SystemStatus.healthy))) {
        state = state.copyWith(status: SystemStatus.healthy, hasFetched: true);
      }
      return false;
    }
  }

  /// Dismiss the current notice for its id (persisted so it stays gone across
  /// launches until a NEW id is published).
  Future<void> dismissCurrent() async {
    final id = state.status.id;
    if (id.isEmpty) {
      // No id to remember, so hide for this session by marking a sentinel.
      state = state.copyWith(dismissedId: ' session-dismiss');
      return;
    }
    state = state.copyWith(dismissedId: id);
    try {
      await storage_api.saveSetting(key: _kDismissedStatusKey, value: id);
    } catch (_) {
      // Non-fatal: the in-memory dismissal already hid it for this session.
    }
  }
}

final statusProvider =
    NotifierProvider<StatusNotifier, StatusState>(StatusNotifier.new);
