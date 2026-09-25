import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/archive/archive_conversation_list.dart';
import 'package:hollow/src/ui/archive/archive_message_viewer.dart';

/// The width of the Archive's list pane, a navigation sidebar's (design
/// language 5.2).
const double kArchiveListWidth = 280;

/// A list pane beside a viewer, the shape both Messages and Imported take.
class ArchiveSplit extends StatelessWidget {
  final Widget list;
  final Widget viewer;

  const ArchiveSplit({super.key, required this.list, required this.viewer});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      children: [
        Container(
          width: kArchiveListWidth,
          decoration: BoxDecoration(
            color: hollow.surface,
            border: Border(right: BorderSide(color: hollow.border)),
          ),
          child: list,
        ),
        Expanded(child: viewer),
      ],
    );
  }
}

/// Messages: every conversation this device keeps, and the one being read.
class MyDataView extends StatelessWidget {
  const MyDataView({super.key});

  @override
  Widget build(BuildContext context) => const ArchiveSplit(
        list: ArchiveConversationList(),
        viewer: ArchiveMessageViewer(),
      );
}
