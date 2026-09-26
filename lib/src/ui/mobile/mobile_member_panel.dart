import 'package:flutter/material.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/components/hollow_sheet.dart';
import 'package:hollow/src/ui/shell/member_list.dart';

/// The server's members as a sheet: the same list as the desktop panel, at
/// phone metrics.
void showMobileMemberPanel(BuildContext context, String serverId) {
  showHollowSheet(
    context: context,
    scrollControlled: true,
    handle: false,
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const HollowSheetHandle(),
          const Padding(
            padding: EdgeInsets.fromLTRB(
                HollowSpacing.lg, HollowSpacing.sm, HollowSpacing.lg, 0),
            child: HollowSectionHeader('Members'),
          ),
          const HollowDivider(),
          Expanded(
            child: MemberList(
              serverId: serverId,
              touch: true,
              scrollController: scrollController,
              bottomInset:
                  MediaQuery.of(context).viewPadding.bottom + HollowSpacing.lg,
            ),
          ),
        ],
      ),
    ),
  );
}
