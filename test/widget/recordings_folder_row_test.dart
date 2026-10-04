import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hollow/src/core/services/recording_service.dart';
import 'package:hollow/src/theme/hollow_theme_data.dart';
import 'package:hollow/src/ui/settings/storage_settings_cards.dart';

/// Recordings live outside the data folder, in a folder every profile shares,
/// so Settings says where they go and that an erase takes the ones this
/// identity made.
void main() {
  testWidgets('the recordings row names the folder and what an erase takes',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: HollowThemeData.dark(),
      home: const Scaffold(body: RecordingsFolderRow()),
    ));

    expect(find.text('Recordings'), findsOneWidget);
    expect(RecordingService.recordingsFolderPath, endsWith('Hollow Recordings'));
    expect(find.text(RecordingService.recordingsFolderPath), findsOneWidget);
    expect(find.textContaining('also deletes the ones you made with it'),
        findsOneWidget);
  });
}
