import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/models/file_attachment.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/chat/file_attachment_widget.dart';
import 'package:hollow/src/ui/chat/file_card_status.dart';
import 'package:hollow/src/ui/chat/message_action_bar.dart';

import 'helpers/test_app.dart';

/// Honest file card states (tmp.txt item 1).
///
/// A file whose bytes are not on disk used to show one Download button that
/// could silently do nothing. These are the four things the card may now say
/// instead, and the control that goes with each. The strings are a contract:
/// the fleet journey asserts them verbatim, so they are written out here in
/// full rather than composed from the constants they came from.
void main() {
  const fileId = 'file-1';
  const holder = 'a1b2c3d4e5f6a7b8c9d0';

  FileAttachment attachment({int? expiredAt}) => FileAttachment(
        fileId: fileId,
        fileName: 'report.pdf',
        fileExt: 'pdf',
        mimeType: 'application/pdf',
        sizeBytes: 620000,
        isImage: false,
        totalChunks: 0,
        expiredAt: expiredAt,
      );

  FileTransferState transfer({
    FileAvailabilityState? availability,
    String? shareRootHash,
    int? seeders,
    bool isComplete = false,
  }) =>
      FileTransferState(
        fileId: fileId,
        fileName: 'report.pdf',
        sizeBytes: 620000,
        totalChunks: 0,
        isComplete: isComplete,
        shareRootHash: shareRootHash,
        seeders: seeders,
        availability: availability,
      );

  // The real resolver, with no profiles loaded: this is how a MASTER id
  // becomes a name, and how it falls back when we have never seen a profile.
  String realNameOf(String master) => displayNameFor(const {}, master);

  FileCardStatus statusFor(FileTransferState? t,
          {int? expiredAt,
          String Function(String) nameOf = _namedHolder}) =>
      fileCardStatus(
        attachment: attachment(expiredAt: expiredAt),
        transfer: t,
        nameOf: nameOf,
      );

  group('fileCardStatus: the four states', () {
    test('1. nothing known is the Download button, with no caption', () {
      final s = statusFor(null);
      expect(s.control, FileCardControl.download);
      expect(s.caption, isNull);
    });

    test('R. a request out and unanswered is a busy control', () {
      final s = statusFor(transfer(
        availability: const FileAvailabilityState(
            state: FileAvailabilityState.requesting, peerId: holder),
      ));
      expect(s.control, FileCardControl.busy);
      expect(s.caption, 'Requesting...');
    });

    test('2. a queued ask in a channel names no one', () {
      final s = statusFor(transfer(
        availability: const FileAvailabilityState(
            state: FileAvailabilityState.waiting, peerId: ''),
      ));
      expect(s.control, FileCardControl.none);
      expect(s.caption, 'Waiting for a peer who has this file');
    });

    test('2. a queued ask in a DM names the one person who can serve it', () {
      final s = statusFor(
        transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.waiting, peerId: holder),
        ),
        nameOf: (_) => 'probe-a',
      );
      expect(s.control, FileCardControl.none);
      expect(s.caption,
          'probe-a is offline. Hollow will fetch it when they return.');
    });

    test('2. an unresolved DM peer falls back to its short id', () {
      final s = statusFor(
        transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.waiting, peerId: holder),
        ),
        nameOf: realNameOf,
      );
      expect(s.caption,
          'a1b2c3d4... is offline. Hollow will fetch it when they return.');
    });

    test('3. a holder that answered "I do not have it" is named', () {
      final s = statusFor(
        transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.gone, peerId: holder),
        ),
        nameOf: (_) => 'probe-a',
      );
      expect(s.control, FileCardControl.none);
      expect(s.caption, 'probe-a no longer has this file');
    });

    test('3. an unresolved holder falls back to its short id', () {
      final s = statusFor(
        transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.gone, peerId: holder),
        ),
        nameOf: realNameOf,
      );
      expect(s.caption, 'a1b2c3d4... no longer has this file');
    });

    test('4. retention removal is final, and says whose policy it was', () {
      final s = statusFor(null, expiredAt: 1757000000);
      expect(s.control, FileCardControl.none);
      expect(s.caption, "Removed by this server's retention policy");
    });

    test('4. the event says expired before the row is reloaded', () {
      // The row's own flag lands a beat later (the event reloads the chat).
      final s = statusFor(transfer(
        availability: const FileAvailabilityState(
            state: FileAvailabilityState.expired, peerId: ''),
      ));
      expect(s.control, FileCardControl.none);
      expect(s.caption, "Removed by this server's retention policy");
    });

    test('a share with no seeders borrows the channel wording, keeps retry',
        () {
      final s = statusFor(transfer(shareRootHash: 'deadbeef', seeders: 0));
      expect(s.control, FileCardControl.retry);
      expect(s.caption, 'Waiting for a peer who has this file');
    });

    test('a share with seeders is an ordinary Download', () {
      final s = statusFor(transfer(shareRootHash: 'deadbeef', seeders: 2));
      expect(s.control, FileCardControl.download);
      expect(s.caption, isNull);
    });

    test('an unknown state from a newer Rust reads as nothing known', () {
      final s = statusFor(transfer(
        availability:
            const FileAvailabilityState(state: 'teleporting', peerId: holder),
      ));
      expect(s.control, FileCardControl.download);
      expect(s.caption, isNull);
    });
  });

  group('fileCardStatus: precedence', () {
    test('expired beats a share with no seeders', () {
      final s = statusFor(
        transfer(shareRootHash: 'deadbeef', seeders: 0),
        expiredAt: 1757000000,
      );
      expect(s.control, FileCardControl.none);
      expect(s.caption, "Removed by this server's retention policy");
    });

    test('expired beats an availability state', () {
      final s = statusFor(
        transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.requesting, peerId: holder),
        ),
        expiredAt: 1757000000,
      );
      expect(s.control, FileCardControl.none);
      expect(s.caption, "Removed by this server's retention policy");
    });

    test('a share with no seeders beats an availability state', () {
      final s = statusFor(transfer(
        shareRootHash: 'deadbeef',
        seeders: 0,
        availability: const FileAvailabilityState(
            state: FileAvailabilityState.gone, peerId: holder),
      ));
      expect(s.control, FileCardControl.retry);
      expect(s.caption, 'Waiting for a peer who has this file');
    });

    test('a completed share is never the no-seeders card', () {
      final s = statusFor(
          transfer(shareRootHash: 'deadbeef', seeders: 0, isComplete: true));
      expect(s.control, FileCardControl.download);
    });
  });

  group('the transfer row', () {
    ProviderContainer container() {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      return c;
    }

    test('an availability event creates a row when there is none', () {
      final c = container();
      c
          .read(fileTransferProvider.notifier)
          .onFileAvailability(fileId, FileAvailabilityState.waiting, holder);
      final row = c.read(fileTransferProvider)[fileId];
      expect(row?.availability?.state, FileAvailabilityState.waiting);
      expect(row?.availability?.peerId, holder);
    });

    test('progress clears it: bytes are moving, the explanation is over', () {
      final c = container();
      final n = c.read(fileTransferProvider.notifier);
      n.onFileHeaderReceived(
          fileId: fileId, fileName: 'report.pdf', sizeBytes: 620000,
          isImage: false);
      n.onFileAvailability(fileId, FileAvailabilityState.requesting, holder);
      n.onFileProgress(fileId, 1, 4);
      n.onFileProgress(fileId, 2, 4);
      expect(c.read(fileTransferProvider)[fileId]?.availability, isNull);
    });

    test('completion clears it', () {
      final c = container();
      final n = c.read(fileTransferProvider.notifier);
      n.onFileAvailability(fileId, FileAvailabilityState.waiting, holder);
      n.onFileCompleted(fileId, 'C:/files/report.pdf');
      expect(c.read(fileTransferProvider)[fileId]?.availability, isNull);
    });

    test('a header for a file we were asking about is the positive answer', () {
      final c = container();
      final n = c.read(fileTransferProvider.notifier);
      n.onFileAvailability(fileId, FileAvailabilityState.requesting, holder);
      n.onFileHeaderReceived(
          fileId: fileId, fileName: 'report.pdf', sizeBytes: 620000,
          isImage: false);
      expect(c.read(fileTransferProvider)[fileId]?.availability, isNull);
    });

    test('asking again lifts a stale auto-download-gate pin', () {
      final c = container();
      final n = c.read(fileTransferProvider.notifier);
      n.markDeclined(fileId);
      expect(c.read(fileTransferProvider)[fileId]?.declined, isTrue);
      n.onFileAvailability(fileId, FileAvailabilityState.requesting, holder);
      expect(c.read(fileTransferProvider)[fileId]?.declined, isFalse);
    });

    test('a completed file is never re-explained', () {
      final c = container();
      final n = c.read(fileTransferProvider.notifier);
      n.onFileCompleted(fileId, 'C:/files/report.pdf');
      n.onFileAvailability(fileId, FileAvailabilityState.gone, holder);
      expect(c.read(fileTransferProvider)[fileId]?.availability, isNull);
    });
  });

  group('the hover bar mirrors the card', () {
    FileBarAction actionFor(FileTransferState? t, {int? expiredAt}) =>
        fileBarAction(
          attachment: attachment(expiredAt: expiredAt),
          transfer: t,
        );

    test('nothing known offers Download', () {
      expect(actionFor(null), FileBarAction.download);
      expect(fileBarActionLabel(FileBarAction.download), 'Download');
    });

    test('a share with no seeders still offers Download', () {
      expect(actionFor(transfer(shareRootHash: 'deadbeef', seeders: 0)),
          FileBarAction.download);
    });

    test('requesting offers the stop control', () {
      expect(
        actionFor(transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.requesting, peerId: holder),
        )),
        FileBarAction.stopWaiting,
      );
      expect(fileBarActionLabel(FileBarAction.stopWaiting),
          'Stop waiting for this file');
    });

    test('waiting offers the stop control, in a DM and in a channel', () {
      for (final peer in [holder, '']) {
        expect(
          actionFor(transfer(
            availability: FileAvailabilityState(
                state: FileAvailabilityState.waiting, peerId: peer),
          )),
          FileBarAction.stopWaiting,
        );
      }
    });

    test('gone offers Try again: an explicit ask re-walks the holders', () {
      expect(
        actionFor(transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.gone, peerId: holder),
        )),
        FileBarAction.tryAgain,
      );
      expect(fileBarActionLabel(FileBarAction.tryAgain), 'Try again');
    });

    test('expired offers nothing at all', () {
      expect(actionFor(null, expiredAt: 1757000000), FileBarAction.none);
      expect(
        actionFor(transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.expired, peerId: ''),
        )),
        FileBarAction.none,
      );
    });

    test('a surface may keep its own word for the plain action', () {
      expect(fileBarActionLabel(FileBarAction.download, download: 'Save File'),
          'Save File');
      // The two honest states read the same everywhere.
      expect(
          fileBarActionLabel(FileBarAction.stopWaiting, download: 'Save File'),
          'Stop waiting for this file');
    });
  });

  group('the hover bar itself', () {
    Future<void> hoverMessage(
      WidgetTester tester, {
      FileTransferState? row,
      int? expiredAt,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: hollowTestOverrides(extra: [
            fileTransferProvider.overrideWith(
              () => _SeededTransfers(row == null ? {} : {fileId: row}),
            ),
          ]),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Center(
                child: MessageHoverWrapper(
                  isMe: false,
                  messageId: 'm-1',
                  currentText: 'here is the file',
                  onDownload: () {},
                  fileAttachment: attachment(expiredAt: expiredAt),
                  child: const Text('here is the file'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.text('here is the file')));
      // Not pumpAndSettle: the tooltip and the bar keep timers running.
      await tester.pump();
    }

    testWidgets('nothing known: the plain Download action', (tester) async {
      final handle = tester.ensureSemantics();
      await hoverMessage(tester);

      expect(find.bySemanticsLabel('Download'), findsWidgets);
      expect(find.bySemanticsLabel('Stop waiting for this file'), findsNothing);
      handle.dispose();
    });

    testWidgets('waiting: a stop control, and no Download to re-ask with',
        (tester) async {
      final handle = tester.ensureSemantics();
      await hoverMessage(
        tester,
        row: transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.waiting, peerId: holder),
        ),
      );

      expect(find.bySemanticsLabel('Stop waiting for this file'), findsWidgets);
      expect(find.bySemanticsLabel('Download'), findsNothing);
      handle.dispose();
    });

    testWidgets('gone: Try again, because an explicit ask really re-walks',
        (tester) async {
      final handle = tester.ensureSemantics();
      await hoverMessage(
        tester,
        row: transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.gone, peerId: holder),
        ),
      );

      expect(find.bySemanticsLabel('Try again'), findsWidgets);
      expect(find.bySemanticsLabel('Download'), findsNothing);
      handle.dispose();
    });

    testWidgets('expired: no file action at all', (tester) async {
      final handle = tester.ensureSemantics();
      await hoverMessage(tester, expiredAt: 1757000000);

      expect(find.bySemanticsLabel('Download'), findsNothing);
      expect(find.bySemanticsLabel('Try again'), findsNothing);
      expect(find.bySemanticsLabel('Stop waiting for this file'), findsNothing);
      handle.dispose();
    });
  });

  group('the card itself', () {
    Future<void> pumpCard(
      WidgetTester tester, {
      FileTransferState? row,
      int? expiredAt,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: hollowTestOverrides(extra: [
            fileTransferProvider.overrideWith(
              () => _SeededTransfers(row == null ? {} : {fileId: row}),
            ),
          ]),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: HollowThemeData.dark(),
            home: Scaffold(
              body: Center(
                child: FileAttachmentWidget(
                    attachment: attachment(expiredAt: expiredAt)),
              ),
            ),
          ),
        ),
      );
      // Not pumpAndSettle: the busy state runs a spinner that never settles.
      await tester.pump();
    }

    testWidgets('nothing known: the Download button, no caption',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(tester);

      expect(find.bySemanticsLabel('Download report.pdf'), findsWidgets);
      expect(find.text('Waiting for a peer who has this file'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      handle.dispose();
    });

    testWidgets('requesting: a busy indicator, and nothing to tap',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(
        tester,
        row: transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.requesting, peerId: holder),
        ),
      );

      expect(find.text('Requesting...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.bySemanticsLabel('Download report.pdf'), findsNothing);
      handle.dispose();
    });

    testWidgets('waiting in a channel: the caption, and nothing to tap',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(
        tester,
        row: transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.waiting, peerId: ''),
        ),
      );

      expect(find.text('Waiting for a peer who has this file'), findsOneWidget);
      expect(find.bySemanticsLabel('Download report.pdf'), findsNothing);
      handle.dispose();
    });

    testWidgets('waiting in a DM names the peer, short id when unresolved',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(
        tester,
        row: transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.waiting, peerId: holder),
        ),
      );

      expect(
        find.text('a1b2c3d4... is offline. Hollow will fetch it when they '
            'return.'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Download report.pdf'), findsNothing);
      handle.dispose();
    });

    testWidgets('gone: the holder is named, and nothing to tap',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(
        tester,
        row: transfer(
          availability: const FileAvailabilityState(
              state: FileAvailabilityState.gone, peerId: holder),
        ),
      );

      expect(find.text('a1b2c3d4... no longer has this file'), findsOneWidget);
      expect(find.bySemanticsLabel('Download report.pdf'), findsNothing);
      handle.dispose();
    });

    testWidgets('expired: the retention wording, and nothing to tap',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(tester, expiredAt: 1757000000);

      expect(find.text("Removed by this server's retention policy"),
          findsOneWidget);
      expect(find.bySemanticsLabel('Download report.pdf'), findsNothing);
      handle.dispose();
    });

    testWidgets('a share with no seeders keeps its tap-to-retry',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCard(
        tester,
        row: transfer(shareRootHash: 'deadbeef', seeders: 0),
      );

      expect(find.text('Waiting for a peer who has this file'), findsOneWidget);
      expect(find.bySemanticsLabel('Retry download of report.pdf'),
          findsWidgets);
      handle.dispose();
    });
  });
}

/// The name a card shows when the profile IS known.
String _namedHolder(String master) => 'probe-a';

class _SeededTransfers extends FileTransferNotifier {
  final Map<String, FileTransferState> seed;
  _SeededTransfers(this.seed);

  @override
  Map<String, FileTransferState> build() => seed;
}
