import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/rust/api/storage.dart' as storage_api;

/// Ids of messages known to be deleted, so a reply to one reads "Deleted
/// message". A reply whose original is merely missing from the loaded page is
/// not in here: the original may just be older than the history we show.
class DeletedMessagesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const {};

  void markDeleted(String messageId) {
    if (state.contains(messageId)) return;
    state = {...state, messageId};
  }

  /// Asks the store about the reply targets in a freshly loaded page that the
  /// page itself does not hold.
  Future<void> resolveReplyTargets(
      Iterable<String?> replyTargets, Iterable<String?> loadedIds) async {
    final loaded = loadedIds.whereType<String>().toSet();
    final unknown = replyTargets
        .whereType<String>()
        .where((id) => !loaded.contains(id) && !state.contains(id))
        .toSet()
        .toList();
    if (unknown.isEmpty) return;
    try {
      final deleted =
          await storage_api.deletedMessageIds(messageIds: unknown);
      if (deleted.isEmpty) return;
      state = {...state, ...deleted};
    } catch (_) {
      // The quote just stays hidden, as it did before this existed.
    }
  }
}

final deletedMessagesProvider =
    NotifierProvider<DeletedMessagesNotifier, Set<String>>(
        DeletedMessagesNotifier.new);
