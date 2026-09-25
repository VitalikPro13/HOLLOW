import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/call_record.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// How many calls a conversation loads: the chat shows them only beside the
/// messages it has loaded, which is a window of the same size.
const int kCallRecordWindow = 200;

/// The calls this device had with one person (MASTER id), oldest first.
final dmCallRecordsProvider = NotifierProvider.family<DmCallRecordsNotifier,
    List<DmCallRecord>, String>(DmCallRecordsNotifier.new);

class DmCallRecordsNotifier extends FamilyNotifier<List<DmCallRecord>, String> {
  @override
  List<DmCallRecord> build(String peer) {
    _load(peer);
    return const [];
  }

  Future<void> _load(String peer) async {
    try {
      final rows =
          await storage_api.loadDmCallRecords(peerId: peer, limit: kCallRecordWindow);
      _merge([for (final r in rows) fromStored(r)]);
    } catch (e) {
      // No store yet (locked, tests): the chat simply shows no call lines.
      debugPrint('[HOLLOW-CALL] call records for $peer did not load: $e');
    }
  }

  /// A call that just ended, shown at once; the write runs in the background.
  void add(DmCallRecord record) => _merge([record]);

  void _merge(List<DmCallRecord> incoming) {
    final byId = {for (final r in state) r.callId: r};
    for (final r in incoming) {
      byId.putIfAbsent(r.callId, () => r);
    }
    final merged = byId.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    state = merged;
  }

  static DmCallRecord fromStored(storage_api.CallRecord r) => DmCallRecord(
        callId: r.callId,
        peer: r.peerId,
        outgoing: r.outgoing,
        video: r.video,
        outcome: CallOutcome.parse(r.outcome),
        startedAt: DateTime.fromMillisecondsSinceEpoch(r.startedAt),
        connectedAt: r.connectedAt == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r.connectedAt!),
        endedAt: DateTime.fromMillisecondsSinceEpoch(r.endedAt),
      );
}

/// Stores [record] and shows it in its conversation. Never throws: a call line
/// that failed to save is a missing line, not a broken hang-up.
void saveDmCallRecord(Ref ref, DmCallRecord record) {
  ref.read(dmCallRecordsProvider(record.peer).notifier).add(record);
  try {
    storage_api
        .recordDmCall(
          record: storage_api.CallRecord(
            callId: record.callId,
            peerId: record.peer,
            outgoing: record.outgoing,
            video: record.video,
            outcome: record.outcome.name,
            startedAt: record.startedAt.millisecondsSinceEpoch,
            connectedAt: record.connectedAt?.millisecondsSinceEpoch,
            endedAt: record.endedAt.millisecondsSinceEpoch,
          ),
        )
        .catchError((Object e) {
      debugPrint('[HOLLOW-CALL] call record not saved: $e');
    });
  } catch (e) {
    debugPrint('[HOLLOW-CALL] call record not saved: $e');
  }
}
