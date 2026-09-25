import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/friendly_error.dart';
import 'package:hollow/src/core/providers/favourite_friends_provider.dart';
import 'package:hollow/src/core/providers/friends_provider.dart';
import 'package:hollow/src/core/providers/selected_peer_provider.dart';
import 'package:hollow/src/core/providers/split_view_provider.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Asks before removing [peerId] (a MASTER id) as a friend, removes them inside
/// the confirm, and toasts once it is done. Every surface that offers "Remove
/// friend" calls this, so the question reads the same everywhere.
///
/// Resolves true when the friend was removed.
Future<bool> confirmRemoveFriend(
  BuildContext context,
  WidgetRef ref, {
  required String peerId,
  required String name,
}) async {
  // The removal rebuilds the friends list, which often unmounts the row that
  // asked, so the toast goes to an overlay captured now.
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  final removed = await showHollowConfirm(
    context: context,
    title: 'Remove $name?',
    message: "You'll both drop off each other's friend list. Your "
        'conversation stays on this device.',
    confirmLabel: 'Remove friend',
    destructive: true,
    onConfirm: () async {
      try {
        await removeFriendAndTidy(ref, peerId);
      } catch (e) {
        throw FriendlyException(
            friendlyError(e, fallback: "Couldn't remove $name. Try again."));
      }
    },
  );
  if (removed && overlay != null && overlay.mounted) {
    HollowToast.show(overlay.context, 'Friend removed',
        type: HollowToastType.success, overlayState: overlay);
  }
  return removed;
}

/// Removes a friend and closes whatever still shows them: the favourite, the
/// open DM, the split pane. Throws when the removal fails, and then nothing
/// else changes.
Future<void> removeFriendAndTidy(WidgetRef ref, String peerId) async {
  // Read up front: the awaited removal may unmount whoever owns [ref].
  final favourites = ref.read(favouriteFriendsProvider.notifier);
  final selectedPeer = ref.read(selectedPeerProvider.notifier);
  final wasSelected = ref.read(selectedPeerProvider) == peerId;
  final splitView = ref.read(splitViewProvider.notifier);
  final split = ref.read(splitViewProvider);
  final shownInSplit = split.isSplit && split.rightPane?.peerId == peerId;
  await ref.read(friendsProvider.notifier).removeFriend(peerId);
  favourites.remove(peerId);
  if (wasSelected) selectedPeer.state = null;
  if (shownInSplit) splitView.closeSplit();
}
