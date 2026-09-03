import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/rust/api/crdt.dart' as crdt_api;
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/ui/components/hollow_dialog.dart';
import 'package:hollow/src/ui/components/profile_card_body.dart';
import 'package:hollow/src/ui/components/showcase_blocks.dart';
import 'package:hollow/src/ui/mobile/mobile_profile_sheet.dart';

/// Opens the FULL profile view for [peerId].
///
/// Desktop: the center profile card flanked by SEPARATE showcase board
/// panels — the card stays a self-contained column and the boards read as
/// its continuation to the left/right. The adaptive rule: no boards →
/// center card only; right only → two panels; both → three.
/// Mobile: routes to the existing bottom sheet for parity.
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

/// Width of the center profile card.
const double kProfileDialogCenterWidth = 560.0;

/// Width of one flanking showcase board panel — sized for real content:
/// game covers and artwork, not just text scraps.
const double kShowcasePanelWidth = 340.0;

/// Minimum height of the board ensemble — a sparse board still reads as a
/// full profile page, not a floating scrap.
const double _kEnsembleMinHeight = 560.0;

/// Gap between the card and its board panels.
const double _kPanelGap = HollowSpacing.md;

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

  /// The shared panel/card surface decoration.
  BoxDecoration _surface(HollowTheme hollow) => BoxDecoration(
        color: hollow.elevated.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(hollow.radiusLg),
        border: Border.all(color: hollow.accent.withValues(alpha: 0.15)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      );

  Widget _boardPanel(
      HollowTheme hollow, List<ShowcaseBlock> blocks, double width) {
    return Container(
      width: width,
      decoration: _surface(hollow),
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(HollowSpacing.md),
      child: ShowcaseBoardColumn(peerId: peerId, blocks: blocks),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final screenSize = MediaQuery.sizeOf(context);
    final maxHeight = (screenSize.height - HollowSpacing.xl * 2)
        .clamp(0.0, double.infinity);

    // Watch the board so a save from the composer updates this view live.
    final encoded = ref.watch(
        profileProvider.select((p) => p[peerId]?.showcaseBoard));
    final board = ShowcaseBoard.decode(encoded);

    // Each filled side adds one flanking panel. When the window can't fit
    // the full-size ensemble, SCALE the columns down proportionally so the
    // three-panel shape survives window resizes; only genuinely tiny
    // windows fall back to stacking below the card.
    final sides = (board.hasLeft ? 1 : 0) + (board.hasRight ? 1 : 0);
    final columnsWidth =
        kProfileDialogCenterWidth + kShowcasePanelWidth * sides;
    final gaps = _kPanelGap * sides;
    final available = screenSize.width - HollowSpacing.xl * 2;
    final scale = sides == 0
        ? 1.0
        : ((available - gaps) / columnsWidth).clamp(0.0, 1.0);
    final stacked = sides > 0 && scale < 0.62;
    final centerWidth = stacked || sides == 0
        ? kProfileDialogCenterWidth.clamp(0.0, available)
        : kProfileDialogCenterWidth * scale;
    final panelWidth = kShowcasePanelWidth * scale;
    final width = stacked
        ? centerWidth
        : centerWidth + (panelWidth + _kPanelGap) * sides;

    final centerCard = Container(
      width: centerWidth,
      decoration: _surface(hollow),
      clipBehavior: Clip.antiAlias,
      child: ProfileCardBody(
        peerId: peerId,
        nickname: nickname,
        role: role,
        labels: labels,
        serverId: serverId,
        density: ProfileCardDensity.full,
        dismissHost: () => Navigator.of(context).pop(),
      ),
    );

    final Widget content;
    if (board.isEmpty) {
      content = centerCard;
    } else if (stacked) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          centerCard,
          if (board.hasLeft) ...[
            const SizedBox(height: _kPanelGap),
            _boardPanel(hollow, board.left, centerWidth),
          ],
          if (board.hasRight) ...[
            const SizedBox(height: _kPanelGap),
            _boardPanel(hollow, board.right, centerWidth),
          ],
        ],
      );
    } else {
      // Panels stretch to the card's height so they read as its wings;
      // a panel with more content than the card grows the row instead.
      content = IntrinsicHeight(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: _kEnsembleMinHeight),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (board.hasLeft) ...[
                _boardPanel(hollow, board.left, panelWidth),
                const SizedBox(width: _kPanelGap),
              ],
              centerCard,
              if (board.hasRight) ...[
                const SizedBox(width: _kPanelGap),
                _boardPanel(hollow, board.right, panelWidth),
              ],
            ],
          ),
        ),
      );
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: width,
            maxHeight: maxHeight,
          ),
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
