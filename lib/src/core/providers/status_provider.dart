import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;
import 'package:hollow/src/rust/api/updater.dart' as updater_api;

/// System status feed — a single object served alongside news.json / manifest.json
/// on the WEBSITE host (anonlisten.com, independent of the relay VPS), so it
/// loads even when the relay is down — which is exactly when we most need to
/// tell users "relay maintenance, back at 02:00". Pure HTTPS GET via the same
/// `fetchVersionManifest` helper the news + updater use; nothing touches the WS.
const kStatusUrl = 'https://anonlisten.com/hollow/releases/status.json';

/// Key under which the last DISMISSED status id is persisted (SQLCipher KV).
/// A dismissed banner stays gone for THAT incident id; publishing a new id
/// re-shows it. Empty/absent = nothing dismissed.
const _kDismissedStatusKey = 'dismissed_status_id';

/// Severity / tone of a status notice. Drives colour, icon, and whether it
/// surfaces in the global shell banner at all.
///
/// Ordering matters: `operational` is the quiet healthy default (banner shows
/// NOTHING); everything else escalates. `info` is the neutral/playful channel
/// (announcements, and — sparingly — jokes) kept visually distinct from the
/// amber/red alarm levels so a light-hearted note never reads as an incident.
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

  /// Absolute UTC instant the countdown targets (e.g. when maintenance starts).
  /// Null when the notice has no timer. Authored in UTC; rendered as a live
  /// countdown ("Remaining 14:23") so every timezone sees a correct value.
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

  /// Parse the `until` timestamp as an absolute UTC instant — robust to the
  /// author forgetting the trailing `Z`.
  ///
  /// The countdown ("Remaining 14:23") is correct in EVERY timezone *because*
  /// it compares two absolute UTC instants. That only holds if `until` is truly
  /// UTC. `DateTime.tryParse` honours an explicit `Z`/offset, but treats a
  /// suffix-less string ("2026-06-28T02:00:00") as the USER'S LOCAL time — so
  /// the same JSON would mean a different instant on PCs in different zones
  /// (the bug Vitalik flagged). When that happens we re-interpret the SAME
  /// wall-clock components AS UTC (a re-label, not a conversion), so an
  /// authored "02:00:00" always means 02:00 UTC regardless of the reader's
  /// clock zone. Returns null for empty/garbage.
  static DateTime? _parseUntilUtc(String raw) {
    if (raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    // Already carried a zone (Z or ±offset) → DateTime parsed it as UTC-aware;
    // normalise to UTC and we're done.
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

  /// True when there is genuinely nothing to announce — operational level with
  /// no accompanying message. Used to keep even the Home line from rendering a
  /// stray empty card.
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

  /// The status file changes a few times a MONTH, so a frequent poll would be
  /// pure waste. Once a minute makes a notice appear within ~60s of publishing
  /// — ample lead time — at a cost (one tiny HTTPS GET/min) a machine won't
  /// even notice. Deliberately its OWN timer hitting ONLY the website: the
  /// status feed is independent of the relay, so it keeps working (and keeps
  /// refreshing) even when the relay is down — exactly when an outage notice
  /// matters most.
  static const _pollInterval = Duration(seconds: 60);

  @override
  StatusState build() {
    // Fetch the network feed eagerly (independent of the DB). The persisted
    // dismissal is loaded separately via [loadDismissed], called from the shell
    // bootstrap AFTER the SQLCipher store is open — see the note there.
    Future.microtask(_fetch);

    _timer?.cancel();
    _timer = Timer.periodic(_pollInterval, (_) => _doFetch());
    ref.onDispose(() => _timer?.cancel());

    return const StatusState();
  }

  /// Load the persisted dismissed-id from the local DB. Called from the shell
  /// `_bootstrap` alongside the other `.load()` providers (theme, layout, …),
  /// which run AFTER the SQLCipher store is open.
  ///
  /// It MUST be driven from bootstrap, not eagerly in [build]: `statusProvider`
  /// is created the instant the shell banner first watches it, which during the
  /// local-first render can be BEFORE the store opens — and `loadSetting` throws
  /// "Message store is not open" then. The original eager load swallowed that
  /// error, losing the dismissal on every launch (it worked per-session, since
  /// the store is long-open by the time you press X, but never survived a
  /// restart — the exact symptom). Bootstrap ordering removes the race entirely.
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

  Future<bool> _doFetch() async {
    try {
      final bustCache = DateTime.now().millisecondsSinceEpoch;
      final json = await updater_api.fetchVersionManifest(
          manifestUrl: '$kStatusUrl?t=$bustCache');
      final decoded = jsonDecode(json) as Map<String, dynamic>;
      state = state.copyWith(
        status: SystemStatus.fromJson(decoded),
        hasFetched: true,
      );
      return true;
    } catch (_) {
      // Any failure (offline, 404, malformed) → stay healthy + silent. Never
      // surface an error as a banner.
      state = state.copyWith(status: SystemStatus.healthy, hasFetched: true);
      return false;
    }
  }

  /// Dismiss the current notice for its id (persisted so it stays gone across
  /// launches until a NEW id is published).
  Future<void> dismissCurrent() async {
    final id = state.status.id;
    if (id.isEmpty) {
      // No id to remember — just hide for this session by marking a sentinel.
      // (Rare: authored notices should always carry an id.)
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
