import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/models/showcase_board.dart';
import 'package:hollow/src/core/providers/showcase_assets_provider.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/chat/message_text_parser.dart';
import 'package:hollow/src/ui/components/animated_gif_image.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// One side of a showcase board: the composed blocks stacked vertically.
///
/// Pure display — everything rendered here is replicated, self-curated
/// profile data. Covers/artwork come from the replicated asset bundle
/// ([showcaseAssetsProvider]); NOTHING is fetched at display time. No
/// relational blocks (feedback_no_relational_profile_blocks — vetoed).
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
    final cards = blocks
        .map((b) => buildShowcaseBlockCard(b, assets))
        .whereType<Widget>()
        .toList();
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: HollowSpacing.sm),
          cards[i],
        ],
      ],
    );
  }
}

/// Builds the display card for one block; null for blocks this client
/// can't render (unknown types from newer clients render as nothing).
Widget? buildShowcaseBlockCard(
    ShowcaseBlock block, Map<String, Uint8List> assets) {
  return switch (block.type) {
    ShowcaseBlockType.text => _BlockCard(
        label: block.textTitle,
        child: _TextBody(body: block.textBody),
      ),
    ShowcaseBlockType.nowPlaying => _BlockCard(
        label: 'NOW PLAYING',
        child: _GameRow(block: block, assets: assets),
      ),
    ShowcaseBlockType.favoriteGame => _BlockCard(
        label: 'FAVORITE GAME',
        child: _FavoriteGameBody(block: block, assets: assets),
      ),
    ShowcaseBlockType.gameShelf => _BlockCard(
        label: block.shelfLabel.isNotEmpty ? block.shelfLabel : 'GAME SHELF',
        child: _GameShelfBody(block: block, assets: assets),
      ),
    ShowcaseBlockType.artwork => _BlockCard(
        label: '',
        child: _ArtworkBody(block: block, assets: assets),
      ),
    ShowcaseBlockType.unknown => null,
  };
}

/// Shared card chrome: surface, border, optional small-caps label.
class _BlockCard extends StatelessWidget {
  final String label;
  final Widget child;

  const _BlockCard({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(HollowSpacing.md),
      decoration: BoxDecoration(
        color: hollow.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(hollow.radiusMd),
        border: Border.all(color: hollow.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty) ...[
            Text(
              label.toUpperCase(),
              style: HollowTypography.caption.copyWith(
                color: hollow.textSecondary,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: HollowSpacing.sm),
          ],
          child,
        ],
      ),
    );
  }
}

/// Text body via the chat parser — links only open on explicit tap;
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
      baseStyle: HollowTypography.body.copyWith(
        color: hollow.textPrimary.withValues(alpha: 0.9),
        fontSize: 13,
        height: 1.45,
      ),
    );
  }
}

/// A game cover from the replicated asset bundle, gamepad placeholder when
/// the bytes haven't arrived (or the game has no cover).
class _Cover extends StatelessWidget {
  final Uint8List? bytes;
  final double width;

  const _Cover({required this.bytes, required this.width});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final height = width * 4 / 3;
    if (bytes == null || bytes!.isEmpty) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: hollow.elevated,
          borderRadius: BorderRadius.circular(hollow.radiusSm),
          border: Border.all(color: hollow.border),
        ),
        child: Icon(
          LucideIcons.gamepad2,
          size: width * 0.4,
          color: hollow.textSecondary.withValues(alpha: 0.5),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusSm),
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

/// Now Playing: cover beside name/year.
class _GameRow extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;

  const _GameRow({required this.block, required this.assets});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _Cover(bytes: assets[block.coverHash], width: 64),
        const SizedBox(width: HollowSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                block.gameName,
                style: HollowTypography.body.copyWith(
                  color: hollow.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (block.gameYear != null) ...[
                const SizedBox(height: 2),
                Text(
                  '${block.gameYear}',
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Favorite Game: big centered cover + name + personal blurb.
class _FavoriteGameBody extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;

  const _FavoriteGameBody({required this.block, required this.assets});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _Cover(bytes: assets[block.coverHash], width: 140)),
        const SizedBox(height: HollowSpacing.sm),
        Text(
          block.gameName,
          textAlign: TextAlign.center,
          style: HollowTypography.body.copyWith(
            color: hollow.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (block.gameBlurb.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.xs),
          Text(
            block.gameBlurb,
            textAlign: TextAlign.center,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 12,
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

/// Game Shelf: cover grid with names underneath.
class _GameShelfBody extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;

  const _GameShelfBody({required this.block, required this.assets});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return Wrap(
      spacing: HollowSpacing.sm,
      runSpacing: HollowSpacing.sm,
      children: [
        for (final game in block.shelfGames)
          SizedBox(
            width: 68,
            child: Column(
              children: [
                _Cover(
                  bytes: assets[(game['cover'] as String?) ?? ''],
                  width: 68,
                ),
                const SizedBox(height: 3),
                Text(
                  (game['name'] as String?) ?? '',
                  textAlign: TextAlign.center,
                  style: HollowTypography.caption.copyWith(
                    color: hollow.textSecondary,
                    fontSize: 9,
                    height: 1.2,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Artwork: replicated image/GIF at natural aspect + optional caption.
class _ArtworkBody extends StatelessWidget {
  final ShowcaseBlock block;
  final Map<String, Uint8List> assets;

  const _ArtworkBody({required this.block, required this.assets});

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final bytes = assets[block.artworkHash];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (bytes == null || bytes.isEmpty)
          Container(
            height: 120,
            decoration: BoxDecoration(
              color: hollow.elevated,
              borderRadius: BorderRadius.circular(hollow.radiusSm),
              border: Border.all(color: hollow.border),
            ),
            child: Icon(
              LucideIcons.image,
              size: 28,
              color: hollow.textSecondary.withValues(alpha: 0.5),
            ),
          )
        else
          ClipRRect(
            borderRadius: BorderRadius.circular(hollow.radiusSm),
            child: AnimatedGifImage(
              bytes: bytes,
              width: double.infinity,
              fit: BoxFit.fitWidth,
            ),
          ),
        if (block.artworkCaption.isNotEmpty) ...[
          const SizedBox(height: HollowSpacing.xs),
          Text(
            block.artworkCaption,
            textAlign: TextAlign.center,
            style: HollowTypography.caption.copyWith(
              color: hollow.textSecondary,
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ],
    );
  }
}
