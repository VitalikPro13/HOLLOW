import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';

/// Honest file card states (tmp.txt item 1).
///
/// A file whose bytes are not on disk used to show one Download button that
/// could silently do nothing: the holder was offline, or had evicted the file,
/// or the server's retention had removed it, and the card said none of that.
/// Rust's ask walk now reports which case it is, and THIS is the one place
/// that turns it into a caption and a control, so every surface that draws a
/// file (the generic card, the image placeholder, the audio bubble, the video
/// bubble, the sticker pack card) says exactly the same thing.

/// What the card offers while the bytes are not local.
enum FileCardControl {
  /// The plain Download button (a holder is reachable, or nothing is known).
  download,

  /// A request is out: the button's footprint holds a spinner and takes no
  /// taps, so a second press cannot queue a second ask.
  busy,

  /// Nothing to press. The ask is queued and self-heals when a holder shows
  /// up; the hover-bar Download still re-issues it by hand.
  none,

  /// Tap to try again (a share-backed file whose swarm currently has no
  /// seeders keeps today's tap-to-retry).
  retry,
}

/// The caption under the file name, and what the control does.
class FileCardStatus {
  /// Null in the default state: the card keeps its ordinary size line.
  final String? caption;
  final FileCardControl control;

  const FileCardStatus({required this.control, this.caption});

  /// True when the caption replaces the card's ordinary metadata line.
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

/// The server's retention policy removed the file. Nobody can serve it again,
/// so there is nothing to press.
const String kFileCardExpiredCaption =
    "Removed by this server's retention policy";

/// Nobody who has the file is reachable. The channel wording, and the wording
/// a share-backed file with no seeders borrows.
const String kFileCardWaitingCaption = 'Waiting for a peer who has this file';

/// A request is out and unanswered.
const String kFileCardRequestingCaption = 'Requesting...';

/// The DM wording for [kFileCardWaitingCaption]: in a DM there is exactly one
/// person who can serve the file, so the card names them.
String fileCardOfflineCaption(String name) =>
    '$name is offline. Hollow will fetch it when they return.';

/// A holder answered "I do not have it".
String fileCardGoneCaption(String name) => '$name no longer has this file';

/// The caption + control for [attachment], given its live [transfer] row.
///
/// [nameOf] turns a MASTER identity into a display name the way the DM header
/// does (short peer id as the fallback). It is only ever called with the
/// availability peer, so a caller may resolve that one profile alone.
///
/// Precedence, most certain first:
///   1. the row is expired (the retention sweep stamped it) — final;
///   2. a share-backed file whose swarm has no seeders — today's retry card;
///   3. what Rust's ask walk last said;
///   4. nothing known: the Download button, unchanged.
///
/// Callers use this on the IDLE path only. A transfer in flight draws its own
/// progress, and a complete one draws its content.
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
  // Share-backed (>34 MB) with an empty swarm. The share ref rides the live
  // transfer row, which is where the seeder count lands too.
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
        // A named peer means a DM: one person can serve this, and they are
        // offline. No name means a channel, where any member might have it.
        return FileCardStatus(
          control: FileCardControl.none,
          caption: peer.isEmpty
              ? kFileCardWaitingCaption
              : fileCardOfflineCaption(nameOf(peer)),
        );
      case FileAvailabilityState.gone:
        // Rust names the peer that answered. Without one there is nobody to
        // blame, and "waiting" is the honest half of what we know.
        return FileCardStatus(
          control: FileCardControl.none,
          caption: peer.isEmpty
              ? kFileCardWaitingCaption
              : fileCardGoneCaption(nameOf(peer)),
        );
      case FileAvailabilityState.expired:
        // The row's own flag is authoritative and arrives a beat later (the
        // event reloads the chat); this keeps the card honest until it does.
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

  /// The same action, labelled `Try again`: a holder said no, and an explicit
  /// request makes Rust re-walk the holders instead of resting on a settled
  /// ask.
  tryAgain,

  /// Cancel the outstanding ask. A tap on Download here would re-issue a
  /// request that visibly does nothing, which is the whole complaint.
  stopWaiting,

  /// No file action at all: retention removed it, so nobody can serve it.
  none,
}

/// The bar's action for [attachment], from the same status the card draws.
///
/// The card's control is the source of truth; only `none` needs the raw
/// availability state to tell a queued ask (still stoppable) from a dead one
/// (worth another walk) from a retention removal (nothing to offer).
FileBarAction fileBarAction({
  required FileAttachment attachment,
  FileTransferState? transfer,
}) {
  // The caption is not used here, so the name never has to be resolved.
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

/// The wording for [action], shared by the hover bar, the message menu and
/// the mobile action sheet so the three can never drift.
///
/// [download] lets a surface keep its own name for the plain action (the
/// mobile sheet has always called it "Save File"); the two honest states are
/// the same everywhere.
String fileBarActionLabel(FileBarAction action,
        {String download = 'Download'}) =>
    switch (action) {
      FileBarAction.download => download,
      FileBarAction.tryAgain => 'Try again',
      FileBarAction.stopWaiting => 'Stop waiting for this file',
      FileBarAction.none => '',
    };
