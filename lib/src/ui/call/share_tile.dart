import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:hollow/src/core/providers/profile_provider.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/components/hollow_avatar.dart';
import 'package:hollow/src/ui/components/hollow_button.dart';
import 'package:hollow/src/ui/components/hollow_pressable.dart';
import 'package:hollow/src/ui/components/hollow_spinner.dart';
import 'package:hollow/src/ui/components/share_quality_chip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// A screen share on the stage, in its three states (issue #38): an OFFER
/// nothing streams from until Watch, someone else's LIVE share with Stop
/// watching on it, and your own share saying who is watching.
class ShareTile extends ConsumerWidget {
  final CallShare share;

  /// [CallTileSize.large] or [CallTileSize.strip].
  final CallTileSize size;
  final VoidCallback? onTap;
  final VoidCallback? onWatch;
  final VoidCallback? onStopWatching;
  final VoidCallback? onStopSharing;

  /// The labels and controls on a live share; the fullscreen stage fades them
  /// with the rest of its chrome.
  final bool chromeVisible;

  const ShareTile({
    super.key,
    required this.share,
    required this.size,
    this.onTap,
    this.onWatch,
    this.onStopWatching,
    this.onStopSharing,
    this.chromeVisible = true,
  });

  bool get _large => size == CallTileSize.large;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final body = share.isOffer
        ? _offer(hollow)
        : _live(context, ref, hollow);
    Widget tile = ClipRRect(
      borderRadius: BorderRadius.circular(hollow.radiusLg),
      child: body,
    );
    if (!share.isOffer && onTap != null) {
      tile = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: tile,
        ),
      );
    }
    return Semantics(
      label: share.isMine
          ? 'Your screen'
          : share.isOffer
              ? '${share.name} is sharing their screen'
              : "${share.name}'s screen",
      button: !share.isOffer && onTap != null,
      child: tile,
    );
  }

  Widget _offer(HollowTheme hollow) {
    final color =
        callNameColor(hollow, isSelf: false, master: share.master);
    final who = Text.rich(
      TextSpan(children: [
        TextSpan(text: share.name, style: TextStyle(color: color)),
        const TextSpan(text: ' is sharing'),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      style: (_large
              ? HollowTypography.label
              : HollowTypography.caption.copyWith(fontWeight: FontWeight.w500))
          .copyWith(color: hollow.textSecondary),
    );
    final watch = HollowButton.outline(
      compact: true,
      icon: _large ? const Icon(LucideIcons.eye, size: 14) : null,
      semanticLabel: 'Watch ${share.name}\'s screen',
      onPressed: onWatch,
      child: const Text('Watch'),
    );
    return ColoredBox(
      color: hollow.elevated,
      child: Padding(
        padding: const EdgeInsets.all(HollowSpacing.sm),
        // A crowded grid makes tiles short: the offer shrinks, never clips.
        child: Center(
          child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _large
                ? [
                    Icon(LucideIcons.monitor,
                        size: 24, color: hollow.textTertiary),
                    const SizedBox(height: HollowSpacing.sm),
                    who,
                    if (share.quality != null) ...[
                      const SizedBox(height: HollowSpacing.xxs),
                      Text(
                        callQualityText(share.quality!),
                        style: HollowTypography.monoSmall
                            .copyWith(color: hollow.textTertiary),
                      ),
                    ],
                    const SizedBox(height: HollowSpacing.md),
                    watch,
                  ]
                : [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.monitor,
                            size: 14, color: hollow.textTertiary),
                        const SizedBox(width: HollowSpacing.xs),
                        Flexible(child: who),
                      ],
                    ),
                    const SizedBox(height: HollowSpacing.xs),
                    watch,
                  ],
          ),
          ),
        ),
      ),
    );
  }

  Widget _live(BuildContext context, WidgetRef ref, HollowTheme hollow) {
    final media = callMediaTheme(hollow);
    final renderer = share.renderer;
    final title = share.isMine ? 'Your screen' : "${share.name}'s screen";
    final titleColor =
        callNameColor(media, isSelf: share.isMine, master: share.master);
    final children = <Widget>[
      if (renderer != null)
        RepaintBoundary(
          child: RTCVideoView(
            renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
          ),
        )
      else if (share.isMine)
        Center(
          child: Icon(LucideIcons.monitorUp,
              size: 24, color: media.textSecondary),
        )
      else
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HollowSpinner(color: media.textSecondary),
              if (_large) ...[
                const SizedBox(height: HollowSpacing.sm),
                Text('Connecting',
                    style: HollowTypography.caption
                        .copyWith(color: media.textSecondary)),
              ],
            ],
          ),
        ),
    ];

    if (!_large) {
      children.add(Positioned(
        left: HollowSpacing.xs,
        right: HollowSpacing.xs,
        bottom: HollowSpacing.xs,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: CallMediaLabel(
            padding: const EdgeInsets.symmetric(
              horizontal: HollowSpacing.xs,
              vertical: HollowSpacing.xxs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.monitor, size: 14, color: titleColor),
                const SizedBox(width: HollowSpacing.xs),
                Flexible(
                  child: Text(
                    share.isMine ? 'Your screen' : share.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: HollowTypography.caption.copyWith(
                        color: titleColor, fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
    } else {
      Widget chrome(Widget child) => AnimatedOpacity(
            opacity: chromeVisible ? 1 : 0,
            duration: HollowDurations.fast,
            child: IgnorePointer(ignoring: !chromeVisible, child: child),
          );
      // One row across the top. The control always stays; the watcher line
      // and then the title drop out as the tile narrows.
      final control = share.isMine
          ? CallScrimButton(
              icon: LucideIcons.monitorOff,
              label: 'Stop sharing',
              onTap: onStopSharing,
            )
          : CallScrimButton(
              icon: LucideIcons.eyeOff,
              label: 'Stop watching',
              onTap: onStopWatching,
            );
      children.add(Positioned(
        left: HollowSpacing.md,
        right: HollowSpacing.md,
        top: HollowSpacing.md,
        child: chrome(LayoutBuilder(builder: (context, box) {
          final showTitle = box.maxWidth >= _kTitleWidth;
          final showWatchers = share.isMine &&
              share.watchers.isNotEmpty &&
              box.maxWidth >= _kWatchersWidth;
          return Row(
            children: [
              if (showTitle)
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: CallMediaLabel(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: HollowTypography.label
                                    .copyWith(color: titleColor)),
                          ),
                          if (share.quality != null || renderer != null) ...[
                            const SizedBox(width: HollowSpacing.sm),
                            _QualityText(
                              renderer: share.isMine ? null : renderer,
                              sourceLabel: share.quality,
                              color: media.textSecondary,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                )
              else
                const Spacer(),
              if (showWatchers) ...[
                const SizedBox(width: HollowSpacing.sm),
                _WatcherLine(masters: share.watchers),
              ],
              const SizedBox(width: HollowSpacing.sm),
              control,
            ],
          );
        })),
      ));
    }

    return ColoredBox(
      color: HollowColors.mediaBlack,
      child: Stack(fit: StackFit.expand, children: children),
    );
  }
}

/// Narrower than these, the live share's top row sheds its title, then its
/// watcher line.
const double _kTitleWidth = 260;
const double _kWatchersWidth = 440;

/// The received resolution once frames arrive, the sharer's label until then.
class _QualityText extends StatelessWidget {
  final RTCVideoRenderer? renderer;
  final String? sourceLabel;
  final Color color;

  const _QualityText({
    required this.renderer,
    required this.sourceLabel,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    Widget text(String label) => Text(
          label.isEmpty ? '' : callQualityText(label),
          style: HollowTypography.monoSmall.copyWith(
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        );
    final r = renderer;
    if (r == null) return text(sourceLabel ?? '');
    return ValueListenableBuilder<RTCVideoValue>(
      valueListenable: r,
      builder: (_, v, _) => text(ShareQualityChip.receivedLabel(
          v.width.toInt(), v.height.toInt(), sourceLabel)),
    );
  }
}

/// "Mira is watching" or "2 watching", with up to three faces.
class _WatcherLine extends ConsumerWidget {
  final List<String> masters;
  const _WatcherLine({required this.masters});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profileProvider);
    final text = masters.length == 1
        ? '${displayNameFor(profiles, masters.first)} is watching'
        : '${masters.length} watching';
    return CallMediaLabel(
      padding: const EdgeInsets.fromLTRB(
        HollowSpacing.xs,
        HollowSpacing.xs,
        HollowSpacing.sm,
        HollowSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in masters.take(3)) ...[
            HollowAvatar(peerId: m, size: 18, frameId: ''),
            const SizedBox(width: HollowSpacing.xs),
          ],
          Flexible(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

/// A text control laid over video: Stop watching, Stop sharing.
class CallScrimButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const CallScrimButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    return HollowPressable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(hollow.radiusMd),
      backgroundColor: HollowColors.mediaScrim,
      padding: const EdgeInsets.symmetric(
        horizontal: HollowSpacing.sm,
        vertical: HollowSpacing.xs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: HollowColors.onMedia),
          const SizedBox(width: HollowSpacing.xs),
          Text(label,
              style:
                  HollowTypography.label.copyWith(color: HollowColors.onMedia)),
        ],
      ),
    );
  }
}
