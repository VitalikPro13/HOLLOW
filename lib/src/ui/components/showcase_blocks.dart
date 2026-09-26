import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/core/providers/showcase_assets_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:hollow/src/ui/components/hollow_list_row.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_section_header.dart';
import 'package:hollow/src/ui/dialogs/game_card_dialog.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Width of one showcase board column, sized for game covers and artwork.
const double kShowcaseColumnWidth = 340.0;

/// Space between the two board columns, and between blocks in a column.
const double kShowcaseGap = HollowSpacing.xl;

/// Inset of the showcase pane on every side.
const double kShowcasePanePadding = HollowSpacing.xl;

/// Width of a wide artwork: both columns and the gap between them, as one.
const double kShowcaseWideWidth = kShowcaseColumnWidth * 2 + kShowcaseGap;

/// One side of a showcase board: its blocks stacked, directly on the surface.
///
/// Everything here is replicated, self-curated profile data, and NOTHING is
/// fetched at display time. No relational blocks
/// (feedback_no_relational_profile_blocks, vetoed).
class ShowcaseBoardColumn extends ConsumerWidget {
  final String peerId;
  final List<ShowcaseBlock> blocks;

  const ShowcaseBoardColumn({
    super.key,
    required this.peerId,
    required this.blocks,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets =
        ref.watch(showcaseAssetsProvider(peerId)).valueOrNull ?? const {};
    final views = [
      for (final b in blocks)
        if (b.type != ShowcaseBlockType.unknown)
          ShowcaseBlockView(block: b, assets: assets, ownerPeerId: peerId),
    ];
    if (views.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < views.length; i++) ...[
          if (i > 0) const SizedBox(height: kShowcaseGap),
          views[i],
        ],
      ],
    );
  }
}

/// One block as every viewer sees it: its header, then its body. A block type
/// this client does not know renders as nothing, so a newer client's block
/// never breaks an older profile.
class ShowcaseBlockView extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;

  /// Whose showcase this is, so a game card says why it is there.
  final String? ownerPeerId;

  const ShowcaseBlockView({
    super.key,
    required this.block,
    required this.assets,
    this.ownerPeerId,
  });

  /// The header a block shows above its body; empty for artwork.
  static String headerOf(ShowcaseBlock block) => switch (block.type) {
    ShowcaseBlockType.text => block.textTitle,
    ShowcaseBlockType.nowPlaying => 'Now playing',
    ShowcaseBlockType.favoriteGame => 'Favourite game',
    ShowcaseBlockType.gameShelf =>
      block.shelfLabel.isNotEmpty ? block.shelfLabel : 'Game shelf',
    ShowcaseBlockType.artwork || ShowcaseBlockType.unknown => '',
  };

  @override
  Widget build(BuildContext context) {
    final body = switch (block.type) {
      ShowcaseBlockType.text => _TextBody(body: block.textBody),
      ShowcaseBlockType.nowPlaying => ShowcaseGameRow(
        block: block,
        assets: assets,
        ownerPeerId: ownerPeerId,
      ),
      ShowcaseBlockType.favoriteGame => _FavoriteGameBody(
        block: block,
        assets: assets,
        ownerPeerId: ownerPeerId,
      ),
      ShowcaseBlockType.gameShelf => _GameShelfBody(
        block: block,
        assets: assets,
        ownerPeerId: ownerPeerId,
      ),
      ShowcaseBlockType.artwork => ShowcaseArtwork(
        block: block,
        assets: assets,
      ),
      ShowcaseBlockType.unknown => null,
    };
    if (body == null) return const SizedBox.shrink();
    final header = headerOf(block);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header.isNotEmpty) HollowSectionHeader(header, dense: true),
        body,
      ],
    );
  }
}

/// The artwork that spans both boards as one piece, caption under it. The
/// caller sizes it: [kShowcaseWideWidth] in the pane, the full width on a
/// phone.
class ShowcaseWideArtwork extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;

  const ShowcaseWideArtwork({
    super.key,
    required this.block,
    required this.assets,
  });

  @override
  Widget build(BuildContext context) =>
      ShowcaseArtwork(block: block, assets: assets, placeholderHeight: 240);
}

/// A board laid out as viewers see it in the profile's showcase pane: two
/// columns side by side, or both boards in one column when [columns] is 1, with
/// the wide artwork above or below them.
class ShowcaseBoardView extends ConsumerWidget {
  final String peerId;
  final ShowcaseBoard board;

  /// 2 = left and right side by side; 1 = left, then right, in one column.
  final int columns;

  const ShowcaseBoardView({
    super.key,
    required this.peerId,
    required this.board,
    this.columns = 2,
  });

  /// Columns the pane needs for [board]: two when both sides hold something
  /// or a wide artwork spans them, one otherwise.
  static int columnsFor(ShowcaseBoard board) =>
      board.hasWide || (board.hasLeft && board.hasRight) ? 2 : 1;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets =
        ref.watch(showcaseAssetsProvider(peerId)).valueOrNull ?? const {};
    final Widget boards;
    if (columns == 2) {
      boards = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: kShowcaseColumnWidth,
            child: ShowcaseBoardColumn(peerId: peerId, blocks: board.left),
          ),
          const SizedBox(width: kShowcaseGap),
          SizedBox(
            width: kShowcaseColumnWidth,
            child: ShowcaseBoardColumn(peerId: peerId, blocks: board.right),
          ),
        ],
      );
    } else {
      boards = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (board.hasLeft)
            ShowcaseBoardColumn(peerId: peerId, blocks: board.left),
          if (board.hasLeft && board.hasRight)
            const SizedBox(height: kShowcaseGap),
          if (board.hasRight)
            ShowcaseBoardColumn(peerId: peerId, blocks: board.right),
        ],
      );
    }
    final wide = board.wide;
    if (wide == null) return boards;
    final hasBoards = board.hasLeft || board.hasRight;
    // Pinned to the two columns: a stretch would take the pane's scroll
    // gutter too and run past the right board.
    final art = columns == 2
        ? SizedBox(
            width: kShowcaseWideWidth,
            child: ShowcaseWideArtwork(block: wide, assets: assets),
          )
        : ShowcaseWideArtwork(block: wide, assets: assets);
    return Column(
      crossAxisAlignment: columns == 2
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (board.wideAtTop) art,
        if (board.wideAtTop && hasBoards) const SizedBox(height: kShowcaseGap),
        if (hasBoards) boards,
        if (!board.wideAtTop && hasBoards) const SizedBox(height: kShowcaseGap),
        if (!board.wideAtTop) art,
      ],
    );
  }
}

/// Text body via the chat parser: links open only on an explicit tap, and
/// nothing is fetched while rendering.
class _TextBody extends StatelessWidget {
  final String body;

  const _TextBody({required this.body});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    if (body.isEmpty) return const SizedBox.shrink();
    return buildMessageText(
      body,
      context,
      baseStyle: HollowTypography.body.copyWith(color: hollow.textSecondary),
    );
  }
}

/// A game cover from the replicated asset bundle at 3:4, with a placeholder
/// until the bytes arrive.
class ShowcaseCover extends StatelessWidget {
  final Uint8List? bytes;
  final double width;

  const ShowcaseCover({super.key, required this.bytes, required this.width});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final height = width * 4 / 3;
    final radius = BorderRadius.circular(hollow.radiusXs);
    if (bytes == null || bytes!.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: hollow.elevated, borderRadius: radius),
        child: Icon(
          LucideIcons.gamepad2,
          size: width >= 64 ? 24 : 16,
          color: hollow.textTertiary,
        ),
      );
    }
    return ClipRRect(
      borderRadius: radius,
      child: Image.memory(
        bytes!,
        width: width,
        height: height,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      ),
    );
  }
}

/// The owner's name as this viewer sees it, for "Mira's favourite".
String? _ownerName(BuildContext context, String? ownerPeerId) {
  if (ownerPeerId == null) return null;
  final profiles = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(profileProvider);
  return displayNameForPeer(profiles[ownerPeerId], ownerPeerId);
}

/// Opens the game card for a game block. A block with no resolvable details
/// still opens: the card renders what it has.
void _openGameCard(
  BuildContext context,
  ShowcaseBlock block,
  Map<String, Uint8List> assets,
  String? ownerPeerId,
) {
  showGameCardDialog(
    context,
    name: block.gameName,
    year: block.gameYear,
    blurb: block.gameBlurb,
    coverBytes: assets[block.coverHash],
    artBytes: assets[block.artHash],
    details:
        GameDetails.resolve(block.detailsField, assets) ?? const GameDetails(),
    assets: assets,
    ownerName: _ownerName(context, ownerPeerId),
    ownerPeerId: ownerPeerId,
    source: block.type == ShowcaseBlockType.nowPlaying
        ? GameCardSource.nowPlaying
        : GameCardSource.favourite,
  );
}

/// A row that opens something, hovering as one piece; its content sits on the
/// column's text edge and the hover bleeds past it.
class _BlockRowButton extends StatelessWidget {
  final VoidCallback onTap;
  final String semanticLabel;
  final Widget child;

  const _BlockRowButton({
    required this.onTap,
    required this.semanticLabel,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowBleed(
      horizontal: HollowSpacing.sm,
      child: HollowPressable(
        onTap: onTap,
        subtle: true,
        semanticLabel: semanticLabel,
        hoverColor: hollow.hover,
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        padding: const EdgeInsets.all(HollowSpacing.sm),
        child: child,
      ),
    );
  }
}

/// A game with its cover beside its name and year, opening the game card.
class ShowcaseGameRow extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;
  final String? ownerPeerId;

  const ShowcaseGameRow({
    super.key,
    required this.block,
    required this.assets,
    this.ownerPeerId,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return _BlockRowButton(
      onTap: () => _openGameCard(context, block, assets, ownerPeerId),
      semanticLabel: 'View ${block.gameName} details',
      child: Row(
        children: [
          ShowcaseCover(bytes: assets[block.coverHash], width: 48),
          const SizedBox(width: HollowSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  block.gameName,
                  style: HollowTypography.body.copyWith(
                    color: hollow.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (block.gameYear != null)
                  Text(
                    '${block.gameYear}',
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textTertiary,
                    ),
                  ),
              ],
            ),
          ),
          Icon(LucideIcons.chevronRight, size: 16, color: hollow.textTertiary),
        ],
      ),
    );
  }
}

/// Favourite game: the big cover beside its name, year and the person's line.
class _FavoriteGameBody extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;
  final String? ownerPeerId;

  const _FavoriteGameBody({
    required this.block,
    required this.assets,
    this.ownerPeerId,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return _BlockRowButton(
      onTap: () => _openGameCard(context, block, assets, ownerPeerId),
      semanticLabel: 'View ${block.gameName} details',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ShowcaseCover(bytes: assets[block.coverHash], width: 96),
          const SizedBox(width: HollowSpacing.lg),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: HollowSpacing.xs),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    block.gameName,
                    style: HollowTypography.subheading.copyWith(
                      color: hollow.textPrimary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (block.gameYear != null)
                    Padding(
                      padding: const EdgeInsets.only(top: HollowSpacing.xxs),
                      child: Text(
                        '${block.gameYear}',
                        style: HollowTypography.caption.copyWith(
                          color: hollow.textTertiary,
                        ),
                      ),
                    ),
                  if (block.gameBlurb.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: HollowSpacing.md),
                      // Older clients never capped the line, so the view
                      // clamps it to the cover's height.
                      child: Text(
                        '“${block.gameBlurb}”',
                        style: HollowTypography.body.copyWith(
                          color: hollow.textPrimary,
                        ),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Game shelf: covers four to a row, names underneath.
class _GameShelfBody extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;
  final String? ownerPeerId;

  const _GameShelfBody({
    required this.block,
    required this.assets,
    this.ownerPeerId,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Wrap(
      spacing: HollowSpacing.md,
      runSpacing: HollowSpacing.md,
      children: [
        for (final game in block.shelfGames)
          HollowPressable(
            onTap: () => showGameCardDialog(
              context,
              name: (game['name'] as String?) ?? '',
              year: game['year'] as int?,
              blurb: '',
              coverBytes: assets[(game['cover'] as String?) ?? ''],
              artBytes: assets[(game['art'] as String?) ?? ''],
              details:
                  GameDetails.resolve(game['details'], assets) ??
                  const GameDetails(),
              assets: assets,
              ownerName: _ownerName(context, ownerPeerId),
              ownerPeerId: ownerPeerId,
              source: GameCardSource.shelf,
              shelfLabel: block.shelfLabel,
            ),
            subtle: true,
            hoverColor: hollow.hover,
            semanticLabel:
                'View ${(game['name'] as String?) ?? 'game'} details',
            borderRadius: BorderRadius.circular(hollow.radiusMd),
            padding: const EdgeInsets.all(HollowSpacing.xs),
            child: SizedBox(
              width: _kShelfCoverWidth,
              child: Column(
                children: [
                  ShowcaseCover(
                    bytes: assets[(game['cover'] as String?) ?? ''],
                    width: _kShelfCoverWidth,
                  ),
                  const SizedBox(height: HollowSpacing.xs),
                  Text(
                    (game['name'] as String?) ?? '',
                    textAlign: TextAlign.center,
                    style: HollowTypography.caption.copyWith(
                      color: hollow.textSecondary,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Four covers and their padding fill a 340 column exactly.
const double _kShelfCoverWidth = 68.0;

/// An artwork: the replicated image or GIF at its own aspect, caption under
/// it.
class ShowcaseArtwork extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;
  final double placeholderHeight;

  const ShowcaseArtwork({
    super.key,
    required this.block,
    required this.assets,
    this.placeholderHeight = 160,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final bytes = assets[block.artworkHash];
    final radius = BorderRadius.circular(hollow.radiusMd);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (bytes == null || bytes.isEmpty)
          Container(
            height: placeholderHeight,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: radius,
            ),
            child: Icon(
              LucideIcons.image,
              size: 24,
              color: hollow.textTertiary,
            ),
          )
        else
          ClipRRect(
            borderRadius: radius,
            child: AnimatedGifImage(
              bytes: bytes,
              width: double.infinity,
              fit: BoxFit.fitWidth,
            ),
          ),
        if (block.artworkCaption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: HollowSpacing.sm),
            child: Text(
              block.artworkCaption,
              style: HollowTypography.bodySmall.copyWith(
                color: hollow.textTertiary,
              ),
            ),
          ),
      ],
    );
  }
}
