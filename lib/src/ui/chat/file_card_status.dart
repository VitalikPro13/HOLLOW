import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';

/// Honest file card states: the one place that turns Rust's ask walk into a
/// caption and a control, so every surface that draws a file (generic card,
/// image placeholder, audio bubble, video bubble, sticker pack card) says the
/// same thing about bytes that are not on disk.

/// What the card offers while the bytes are not local.
enum FileCardControl {
  /// The plain Download button (a holder is reachable, or nothing is known).
  download,

  /// A request is out: a spinner takes the button's footprint and no taps, so
  /// a second press cannot queue a second ask.
  busy,

  /// Nothing to press: the queued ask self-heals when a holder shows up, and
  /// the hover-bar Download still re-issues it by hand.
  none,

  /// Tap to try again: a share-backed file whose swarm has no seeders.
  retry,
}

/// The caption under the file name, and what the control does.
class FileCardStatus {
  /// Null in the default state: the card keeps its ordinary size line.
  final String? caption;
  final FileCardControl control;

  const FileCardStatus({required this.control, this.caption});

  bool get hasCaption => caption != null;

  @override
  bool operator ==(Object other) =>
      other is FileCardStatus &&
      other.caption == caption &&
      other.control == control;

  @override
  int get hashCode => Object.hash(caption, control);

  @override
  String toString() => 'FileCardStatus($control, $caption)';
}

/// The retention policy removed the file, so nobody can serve it again.
const String kFileCardExpiredCaption =
    "Removed by this server's retention policy";

/// Nobody who has the file is reachable: the channel wording, borrowed by a
/// share-backed file with no seeders.
const String kFileCardWaitingCaption = 'Waiting for a peer who has this file';

/// A request is out and unanswered.
const String kFileCardRequestingCaption = 'Requesting...';

/// The DM wording for [kFileCardWaitingCaption]: exactly one person can serve
/// the file, so the card names them.
String fileCardOfflineCaption(String name) =>
    '$name is offline. Hollow will fetch it when they return.';

/// A holder answered "I do not have it".
String fileCardGoneCaption(String name) => '$name no longer has this file';

/// The caption and control for [attachment], given its live [transfer] row.
///
/// [nameOf] maps a MASTER identity to a display name and is only ever called
/// with the availability peer, so a caller may resolve that one profile alone.
/// Precedence runs most certain first: expired row, then a share-backed file
/// with no seeders, then Rust's ask walk, then the plain Download button.
/// Idle path only: a transfer in flight draws progress, a complete one content.
FileCardStatus fileCardStatus({
  required FileAttachment attachment,
  FileTransferState? transfer,
  required String Function(String master) nameOf,
}) {
  if (attachment.isExpired) {
    return const FileCardStatus(
      control: FileCardControl.none,
      caption: kFileCardExpiredCaption,
    );
  }

  final isComplete = attachment.isComplete || (transfer?.isComplete ?? false);
  // Share-backed (>34 MB) with an empty swarm.
  if (transfer?.shareRootHash != null &&
      !isComplete &&
      (transfer?.seeders ?? -1) == 0 &&
      (transfer?.chunksReceived ?? 0) == 0) {
    return const FileCardStatus(
      control: FileCardControl.retry,
      caption: kFileCardWaitingCaption,
    );
  }

  final availability = transfer?.availability;
  if (availability != null) {
    final peer = availability.peerId;
    switch (availability.state) {
      case FileAvailabilityState.requesting:
        return const FileCardStatus(
          control: FileCardControl.busy,
          caption: kFileCardRequestingCaption,
        );
      case FileAvailabilityState.waiting:
        // A named peer means a DM, where that one person is offline; no name
        // means a channel, where any member might have it.
        return FileCardStatus(
          control: FileCardControl.none,
          caption: peer.isEmpty
              ? kFileCardWaitingCaption
              : fileCardOfflineCaption(nameOf(peer)),
        );
      case FileAvailabilityState.gone:
        // Without a named peer there is nobody to blame, and "waiting" is the
        // honest half of what we know.
        return FileCardStatus(
          control: FileCardControl.none,
          caption: peer.isEmpty
              ? kFileCardWaitingCaption
              : fileCardGoneCaption(nameOf(peer)),
        );
      case FileAvailabilityState.expired:
        // The row's own flag is authoritative and lands a beat later; this
        // keeps the card honest until it does.
        return const FileCardStatus(
          control: FileCardControl.none,
          caption: kFileCardExpiredCaption,
        );
    }
  }

  return const FileCardStatus(control: FileCardControl.download);
}

/// What the message hover bar (and the mobile long-press sheet, and the
/// right-click menu) offers for a file, mirroring the card.
enum FileBarAction {
  /// Today's Download action, labelled `Download`.
  download,

  /// The same action labelled `Try again`: an explicit request makes Rust
  /// re-walk the holders instead of resting on a settled ask.
  tryAgain,

  /// Cancel the outstanding ask; Download here would re-issue a request that
  /// visibly does nothing.
  stopWaiting,

  /// No file action at all: retention removed it, so nobody can serve it.
  none,
}

/// The bar's action for [attachment], from the same status the card draws.
///
/// The card's control is the source of truth; only `none` needs the raw
/// availability state to tell a queued ask from a dead one from a removal.
FileBarAction fileBarAction({
  required FileAttachment attachment,
  FileTransferState? transfer,
}) {
  // The caption is unused here, so no name has to be resolved.
  final status = fileCardStatus(
    attachment: attachment,
    transfer: transfer,
    nameOf: _asIs,
  );
  switch (status.control) {
    case FileCardControl.download:
    case FileCardControl.retry:
      return FileBarAction.download;
    case FileCardControl.busy:
      return FileBarAction.stopWaiting;
    case FileCardControl.none:
      if (attachment.isExpired) return FileBarAction.none;
      switch (transfer?.availability?.state) {
        case FileAvailabilityState.waiting:
          return FileBarAction.stopWaiting;
        case FileAvailabilityState.gone:
          return FileBarAction.tryAgain;
        default:
          return FileBarAction.none;
      }
  }
}

String _asIs(String master) => master;

/// The wording for [action], shared by the hover bar, the message menu and the
/// mobile action sheet so the three can never drift.
///
/// [download] lets a surface keep its own name for the plain action; the honest
/// states read the same everywhere.
String fileBarActionLabel(FileBarAction action,
        {String download = 'Download'}) =>
    switch (action) {
      FileBarAction.download => download,
      FileBarAction.tryAgain => 'Try again',
      FileBarAction.stopWaiting => 'Stop waiting for this file',
      FileBarAction.none => '',
    };
