import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/services/video_stream_server.dart';

class VideoStreamState {
  final String rootHash;
  final Uri serverUri;
  final int availableBytes;
  final int totalSize;
  final bool completed;

  const VideoStreamState({
    required this.rootHash,
    required this.serverUri,
    required this.availableBytes,
    required this.totalSize,
    this.completed = false,
  });

  VideoStreamState copyWith({
    int? availableBytes,
    bool? completed,
  }) {
    return VideoStreamState(
      rootHash: rootHash,
      serverUri: serverUri,
      availableBytes: availableBytes ?? this.availableBytes,
      totalSize: totalSize,
      completed: completed ?? this.completed,
    );
  }
}

class VideoStreamNotifier extends Notifier<VideoStreamState?> {
  final VideoStreamServer _server = VideoStreamServer();

  @override
  VideoStreamState? build() {
    // Release the HTTP server's bound socket + open RandomAccessFile on dispose,
    // or a started server lingers both until process exit.
    ref.onDispose(() {
      _server.stop();
    });
    return null;
  }

  Future<Uri?> startStream(
    String partialFilePath,
    int totalSize,
    String mimeType,
    String rootHash,
  ) async {
    await _server.stop();
    try {
      final uri = await _server.start(partialFilePath, totalSize, mimeType);
      state = VideoStreamState(
        rootHash: rootHash,
        serverUri: uri,
        availableBytes: 0,
        totalSize: totalSize,
      );
      return uri;
    } catch (e) {
      debugPrint('[HOLLOW-STREAM] Failed to start stream server: $e');
      return null;
    }
  }

  void updateProgress(String rootHash, int chunksHave, int chunksTotal, int chunkSize) {
    if (state == null || state!.rootHash != rootHash) return;
    final bytes = chunksHave * chunkSize;
    _server.updateAvailableBytes(bytes);
    state = state!.copyWith(availableBytes: bytes);
  }

  void markCompleted(String rootHash) {
    if (state == null || state!.rootHash != rootHash) return;
    _server.updateAvailableBytes(state!.totalSize);
    state = state!.copyWith(availableBytes: state!.totalSize, completed: true);
  }

  Future<void> stopStream() async {
    await _server.stop();
    state = null;
  }
}

final videoStreamProvider =
    NotifierProvider<VideoStreamNotifier, VideoStreamState?>(
        VideoStreamNotifier.new);
