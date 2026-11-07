import 'package:flutter/widgets.dart' show AppLifecycleState, immutable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/app_lifecycle_provider.dart';
import 'package:hollow/src/rust/api/device_proof.dart' as dp;

/// A member's view of a server its owner is restoring (DEVICE_PROOF_DESIGN
/// 8.8). Refreshed on `ServerUpdated`; a read that fails shows no banner, since
/// the banner only explains what the node already enforces.
final serverRecoveryProvider = FutureProvider.autoDispose
    .family<dp.ServerRecovery, String>((ref, serverId) async {
  try {
    return await dp.serverRecovery(serverId: serverId);
  } catch (_) {
    return const dp.ServerRecovery(steppedBack: false);
  }
});

/// The owner's reviews of members' lost devices in a server (section 8.3),
/// empty for anyone else. Refreshed on `ServerUpdated`. A failed read is an
/// error here, so the settings page says so instead of looking answered.
final refoldReviewsProvider = FutureProvider.autoDispose
    .family<dp.RefoldReviews, String>(
        (ref, serverId) => dp.refoldReviews(serverId: serverId));

/// The reviews the owner still has to answer: listed and unanswered.
List<dp.RefoldReview> openRefoldReviews(dp.RefoldReviews? all) => [
      for (final r in all?.reviews ?? const <dp.RefoldReview>[])
        if (r.listed && r.answered == null) r,
    ];

/// Whether the server's settings show the Lost devices page: any review, open
/// or answered, or more waiting.
bool hasRefoldReviews(dp.RefoldReviews? all) =>
    all != null &&
    (all.moreReports > 0 || all.reviews.any((r) => r.listed));

/// Whether the settings rail lists Lost devices for someone of [role]: while
/// there are reviews, and for the owner also while the first read failed, so
/// the page's Retry stays reachable.
bool showsLostDevices(AsyncValue<dp.RefoldReviews> reviews,
        {required String role}) =>
    hasRefoldReviews(reviews.valueOrNull) ||
    (role == 'owner' && reviews.hasError && !reviews.hasValue);

/// The chosen item keys and put-back channel ids someone changed since, which
/// therefore stay.
extension RefoldAppliedStays on dp.RefoldApplied {
  List<String> get itemsChangedSince => _changedSince(items);
  List<String> get putBackChangedSince => _changedSince(putBack);
}

List<String> _changedSince(List<dp.RefoldItemOutcome> all) => [
      for (final o in all)
        if (o.outcome == dp.RefoldOutcome.changedSince) o.key,
    ];

/// The restore chooser's state after a phrase recovery (section 8.4). The
/// chooser re-reads it every 2 s while it is open; the Security row's copy is
/// refreshed on `ServerUpdated` and whenever the app comes back to the front.
final restoreChoicesProvider = FutureProvider.autoDispose<dp.Restores>((ref) {
  ref.listen<AppLifecycleState>(appLifecycleProvider, (prev, next) {
    if (next == AppLifecycleState.resumed && prev != next) ref.invalidateSelf();
  });
  return dp.restoreChoices();
});

/// One phrase recovery asking the shell to offer the chooser. [fresh] is the
/// roster lock's path, a device the roster did not count yet: the only one
/// that may hear "Hollow doesn't know your servers yet".
@immutable
class RestoreChooserAsk {
  final int seq;
  final bool fresh;
  const RestoreChooserAsk({required this.seq, required this.fresh});
}

/// The latest ask; the shell offers the chooser once no lock covers the app.
final restoreChooserAskProvider =
    StateProvider<RestoreChooserAsk?>((_) => null);

/// Records a finished phrase recovery. Takes the container, which outlives a
/// screen the recovery itself may have closed.
void askForRestoreChooser(ProviderContainer container, {required bool fresh}) {
  final last = container.read(restoreChooserAskProvider)?.seq ?? 0;
  container.read(restoreChooserAskProvider.notifier).state =
      RestoreChooserAsk(seq: last + 1, fresh: fresh);
}

/// A server still needing the person or the members.
bool restorePending(dp.RestoreChoices c) => c.stage != dp.RestoreStage.done;

/// A server waiting for the person to choose.
bool restoreNeedsChoice(dp.RestoreChoices c) =>
    c.stage == dp.RestoreStage.pick ||
    c.stage == dp.RestoreStage.points ||
    c.stage == dp.RestoreStage.onlyOne;

/// Whether "Hollow doesn't know your servers yet" may show: only after a
/// [fresh] recovery, on a device that holds no server, so a node that cannot
/// answer yet never tells someone with servers that it lost them.
bool restoreUnknownShown(dp.Restores r,
        {required bool fresh, required bool holdsServers}) =>
    fresh && !r.serversKnown && r.servers.isEmpty && !holdsServers;

/// Whether the chooser has something to show after a recovery.
bool restoreChooserDue(dp.Restores r,
        {required bool fresh, required bool holdsServers}) =>
    r.servers.any(restorePending) ||
    restoreUnknownShown(r, fresh: fresh, holdsServers: holdsServers);
