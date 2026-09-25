import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/recording_provider.dart';
import 'package:hollow/src/ui/components/hollow_toast.dart';

/// Says where a finished call recording was saved, or why one failed, from
/// wherever the user is. Draws nothing.
class CallRecordingToasts extends ConsumerWidget {
  const CallRecordingToasts({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<RecordingState>(recordingProvider, (prev, next) {
      final finished = next.lastFinished;
      if (finished != null && finished != prev?.lastFinished) {
        HollowToast.show(
          context,
          'Recording saved to ${finished.filePath}',
          type: HollowToastType.success,
          duration: const Duration(seconds: 15),
        );
        ref.read(recordingProvider.notifier).acknowledgeLastFinished();
      }
      final error = next.lastError;
      if (error != null && error != prev?.lastError) {
        HollowToast.show(context, 'Recording: $error',
            type: HollowToastType.error);
        ref.read(recordingProvider.notifier).acknowledgeLastError();
      }
    });
    return const SizedBox.shrink();
  }
}
