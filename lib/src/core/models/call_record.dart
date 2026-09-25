/// How a DM call ended, as the side that stores it saw it.
enum CallOutcome {
  /// Connected, then someone hung up or the link died.
  answered,

  /// Rang here and nobody picked up: timed out, or the caller gave up.
  missed,

  /// Rang here and we declined it.
  declined,

  /// We called and hung up before it connected.
  cancelled,

  /// We called and it never connected on their side: no answer, a decline or
  /// busy. A decline and a ring timeout look the same from here.
  unanswered,

  /// It was being set up and the link failed.
  failed,

  /// A word this version does not know, written by a newer one.
  unknown;

  static CallOutcome parse(String word) =>
      CallOutcome.values.firstWhere((o) => o.name == word,
          orElse: () => CallOutcome.unknown);
}

/// What ended a DM call, noted by the path that tore it down.
enum CallEndCause {
  localHangup,
  localDecline,
  ringTimeout,
  remoteReject,
  remoteEnd,
  remoteBusy,
  linkLost,
}

/// The stored outcome for a call that ended by [cause]. [pickedUp] = the
/// callee accepted (it reached connecting), [connected] = media flowed.
CallOutcome classifyCallEnd({
  required bool outgoing,
  required bool pickedUp,
  required bool connected,
  required CallEndCause cause,
}) {
  if (connected) return CallOutcome.answered;
  final local =
      cause == CallEndCause.localHangup || cause == CallEndCause.localDecline;
  if (outgoing) {
    if (local) return CallOutcome.cancelled;
    if (cause == CallEndCause.linkLost || pickedUp) return CallOutcome.failed;
    return CallOutcome.unanswered;
  }
  if (!pickedUp) return local ? CallOutcome.declined : CallOutcome.missed;
  return local ? CallOutcome.cancelled : CallOutcome.failed;
}

/// One ended DM call. Local to this device: it never rides the wire and it is
/// not a message, so it is never counted as unread, synced or exported.
class DmCallRecord {
  final String callId;

  /// The conversation's MASTER id.
  final String peer;
  final bool outgoing;
  final bool video;
  final CallOutcome outcome;

  /// When it began ringing; the chat places it here.
  final DateTime startedAt;
  final DateTime? connectedAt;
  final DateTime endedAt;

  const DmCallRecord({
    required this.callId,
    required this.peer,
    required this.outgoing,
    required this.video,
    required this.outcome,
    required this.startedAt,
    required this.connectedAt,
    required this.endedAt,
  });

  /// How long it was connected; null for a call that never connected.
  Duration? get talked {
    final from = connectedAt;
    if (from == null) return null;
    final d = endedAt.difference(from);
    return d.isNegative ? Duration.zero : d;
  }

  /// What the chat line says: "Voice call, 4 minutes", "Missed call".
  String get label {
    final kind = video ? 'Video call' : 'Voice call';
    return switch (outcome) {
      CallOutcome.answered => '$kind, ${callLengthWords(talked ?? Duration.zero)}',
      CallOutcome.missed => video ? 'Missed video call' : 'Missed call',
      CallOutcome.declined => 'Declined call',
      CallOutcome.cancelled => 'Cancelled call',
      CallOutcome.unanswered => '$kind, no answer',
      CallOutcome.failed => "$kind, didn't connect",
      CallOutcome.unknown => kind,
    };
  }
}

/// "45 seconds", "1 minute", "4 minutes", "1 hour 5 minutes".
String callLengthWords(Duration d) {
  String unit(int n, String one) => n == 1 ? '1 $one' : '$n ${one}s';
  if (d.inMinutes < 1) return unit(d.inSeconds, 'second');
  if (d.inHours < 1) return unit(d.inMinutes, 'minute');
  final minutes = d.inMinutes % 60;
  final hours = unit(d.inHours, 'hour');
  return minutes == 0 ? hours : '$hours ${unit(minutes, 'minute')}';
}

/// The calls a chat row carries: [before] sit above it (after the previous
/// row, up to this one), [after] below it, only on the newest row. Calls older
/// than the oldest loaded row show only when [historyComplete], or they would
/// pile up above a window that starts mid-conversation.
({List<DmCallRecord> before, List<DmCallRecord> after}) callRecordsAround({
  required List<DmCallRecord> records,
  required DateTime? previous,
  required DateTime current,
  required bool isNewest,
  required bool historyComplete,
}) {
  if (records.isEmpty) return (before: const [], after: const []);
  final before = <DmCallRecord>[];
  final after = <DmCallRecord>[];
  for (final r in records) {
    final t = r.startedAt;
    if (t.isAfter(current)) {
      if (isNewest) after.add(r);
      continue;
    }
    if (previous == null ? historyComplete : t.isAfter(previous)) before.add(r);
  }
  return (before: before, after: after);
}
