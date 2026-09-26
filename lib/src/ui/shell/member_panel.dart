import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/layout_prefs_provider.dart';
import 'package:hollow/src/core/providers/server_provider.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/chat/chat_pane_shared.dart';
import 'package:hollow/src/ui/components/ui_scale.dart';
import 'package:hollow/src/ui/shell/member_list.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The selected server's members, on the right of the shell.
class MemberPanel extends ConsumerWidget {
  /// Overrides the user's saved width. Null uses [memberPanelWidthProvider],
  /// which the seam on its left edge drags.
  final double? width;

  /// Whether to draw this panel's own divider on the edge facing the chat.
  ///
  /// False wherever a [PanelResizeHandle] sits against that edge: the seam
  /// paints the divider itself, and two of them put a second line just inside
  /// the first.
  final bool edgeBorder;

  const MemberPanel({super.key, this.width, this.edgeBorder = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final serverId = ref.watch(selectedServerProvider);

    return Container(
      width: width ?? ref.watch(memberPanelWidthProvider),
      decoration: BoxDecoration(
        color: hollow.surface,
        border: Border(
          left: edgeBorder ? BorderSide(color: hollow.border) : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ChatHeaderBar(
            leading:
                Icon(LucideIcons.users, size: 20, color: hollow.textTertiary),
            title: 'Members',
          ),
          if (serverId != null)
            Expanded(
              // Panel zoom (issue #54) sizes the rows, not the header, so it
              // stays level with the chat's. Switching servers swaps the list
              // instantly.
              child: PanelScale(
                child: MemberList(
                    key: ValueKey('members:$serverId'), serverId: serverId),
              ),
            ),
        ],
      ),
    );
  }
}
