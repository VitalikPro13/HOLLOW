import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/providers/file_transfer_provider.dart';

void main() {
  test('a late stream progress tick cannot reopen a completed download', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(fileTransferProvider.notifier);
    notifier.onFileHeaderReceived(fileId: 'log', fileName: 'crash.log',
        sizeBytes: 99600, isImage: false);
    notifier.onFileCompleted('log', '/files/reporter_crash.log');
    notifier.onFileProgress('log', 1, 1);
    final file = c.read(fileTransferProvider)['log']!;
    expect(file.isComplete, isTrue);
    expect(file.isDownloading, isFalse);
    expect(file.diskPath, '/files/reporter_crash.log');
  });

  test('stream progress preserves file metadata', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final notifier = c.read(fileTransferProvider.notifier);
    notifier.onFileHeaderReceived(fileId: 'log', fileName: 'crash.log',
        sizeBytes: 99600, isImage: false, shareRootHash: 'share-hash');
    notifier.onFileProgress('log', 1, 1);
    final progressed = c.read(fileTransferProvider)['log']!;
    expect(progressed.totalChunks, 1);
    expect(progressed.shareRootHash, 'share-hash');
    expect(progressed.sizeBytes, 99600);
  });
}
