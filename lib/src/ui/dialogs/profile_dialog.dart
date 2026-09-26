import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/hollow_divider.dart';
import 'package:hollow/src/ui/components/hollow_scroll_behavior.dart';
import 'package:hollow/src/ui/components/profile_identity_column.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Opens the FULL profile view for [peerId]: on desktop the profile column
/// beside its showcase pane, on a phone the bottom sheet.
Future<void> showProfileDialog(
  BuildContext context, {
  required String peerId,
  String? nickname,
  String? role,
  List<crdt_api.LabelFfi>? labels,
  String? serverId,
}) {
  if (Platform.isAndroid || Platform.isIOS) {
    showMobileProfileSheet(
      context,
      peerId: peerId,
      role: role,
      labels: labels,
      serverId: serverId,
    );
    return Future.value();
  }
  return showHollowDialog(
    context: context,
    builder: (_) => ProfileDialog(
      peerId: peerId,
      nickname: nickname,
      role: role,
      labels: labels,
      serverId: serverId,
    ),
  );
}

/// Width of the showcase pane holding [columns] board columns.
double showcasePaneWidth(int columns) =>
    kShowcasePanePadding * 2 +
    (columns == 2 ? kShowcaseWideWidth : kShowcaseColumnWidth);

/// The profile in its own column with the showcase as a pane beside it, a
/// hairline between. The dialog is only as wide as what the person put on
/// their boards; a window too narrow for two board columns gets one, and one
/// too narrow for the pane stacks it under the profile. Widths never squeeze,
/// so the banner keeps its 2.5:1.
class ProfileDialog extends ConsumerWidget {
  final String peerId;
  final String? nickname;
  final String? role;
  final List<crdt_api.LabelFfi>? labels;
  final String? serverId;

  const ProfileDialog({
    super.key,
    required this.peerId,
    this.nickname,
    this.role,
    this.labels,
    this.serverId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched so a save from the editor updates this view live.
    final encoded = ref.watch(
      profileProvider.select((p) => p[peerId]?.showcaseBoard),
    );
    final board = ShowcaseBoard.decode(encoded);
    final available = MediaQuery.sizeOf(context).width - HollowSpacing.xl * 2;
    void close() => Navigator.of(context).pop();

    ProfileIdentityColumn identity(double width, {VoidCallback? onClose}) =>
        ProfileIdentityColumn(
          peerId: peerId,
          nickname: nickname,
          role: role,
          labels: labels,
          serverId: serverId,
          density: ProfileCardDensity.full,
          width: width,
          dismissHost: close,
          onClose: onClose,
        );

    final wanted = ShowcaseBoardView.columnsFor(board);
    int? columns;
    if (!board.isEmpty) {
      for (final c in wanted == 2 ? const [2, 1] : const [1]) {
        if (kProfileColumnWidth + 1 + showcasePaneWidth(c) <= available) {
          columns = c;
          break;
        }
      }
    }

    if (columns == null) {
      // No board, or no room beside the profile: one column, one scroll.
      final width = kProfileColumnWidth.clamp(0.0, available);
      return HollowDialogSurface(
        width: width,
        maxWidth: width,
        padded: false,
        child: _WithoutScrollbar(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identity(width, onClose: close),
                if (!board.isEmpty) ...[
                  const HollowDivider(),
                  Padding(
                    padding: const EdgeInsets.all(kShowcasePanePadding),
                    child: ShowcaseBoardView(
                      peerId: peerId,
                      board: board,
                      columns: 1,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    final paneWidth = showcasePaneWidth(columns);
    final total = kProfileColumnWidth + 1 + paneWidth;
    // The pane's scrollbar takes its gutter from the right padding, so the
    // boards keep their width and the edges stay even.
    final gutter = scrollGutterOf(context);
    return HollowDialogSurface(
      width: total,
      maxWidth: total,
      padded: false,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: kProfileColumnWidth,
              // No scrollbar here: its gutter would pull the banner off the
              // dialog's edge.
              child: _WithoutScrollbar(
                child: SingleChildScrollView(
                  child: identity(kProfileColumnWidth),
                ),
              ),
            ),
            const HollowVerticalDivider(),
            SizedBox(
              width: paneWidth,
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(
                      kShowcasePanePadding,
                      kShowcasePanePadding,
                      kShowcasePanePadding - gutter,
                      kShowcasePanePadding,
                    ),
                    child: ShowcaseBoardView(
                      peerId: peerId,
                      board: board,
                      columns: columns,
                    ),
                  ),
                  // Over a wide artwork at the top, the close button sits on
                  // the art, so it takes the art's scrim.
                  if (board.hasWide && board.wideAtTop)
                    Positioned(
                      top: kShowcasePanePadding + HollowSpacing.xs,
                      right: kShowcasePanePadding + HollowSpacing.xs,
                      child: MediaScrimIconButton(
                        icon: LucideIcons.x,
                        label: 'Close',
                        size: 32,
                        onPressed: close,
                      ),
                    )
                  else
                    Positioned(
                      top: HollowSpacing.md,
                      right: HollowSpacing.md,
                      child: HollowDialogCloseButton(onPressed: close),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A scroll view that draws no scrollbar, so nothing reserves a gutter beside
/// content that must reach the dialog's edge.
class _WithoutScrollbar extends StatelessWidget {
  final Widget child;

  const _WithoutScrollbar({required this.child});

  @override
  Widget build(BuildContext context) => ScrollConfiguration(
    behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
    child: child,
  );
}
