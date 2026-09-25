import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hollow/src/core/providers/settings_provider.dart';
import 'package:hollow/src/core/reduce_motion.dart';
import 'package:hollow/src/core/services/window_fullscreen.dart';
import 'package:hollow/src/theme/hollow_colors.dart';
import 'package:hollow/src/theme/hollow_spacing.dart';
import 'package:hollow/src/theme/hollow_theme.dart';
import 'package:hollow/src/theme/hollow_typography.dart';
import 'package:hollow/src/ui/animations/hollow_curves.dart';
import 'package:hollow/src/ui/call/call_person_tile.dart';
import 'package:hollow/src/ui/call/call_stage_bar.dart';
import 'package:hollow/src/ui/call/call_stage_data.dart';
import 'package:hollow/src/ui/call/call_theme.dart';
import 'package:hollow/src/ui/call/share_tile.dart';
import 'package:hollow/src/ui/components/edge_scroll_row.dart';
import 'package:hollow/src/ui/components/hollow_icon_button.dart';
import 'package:hollow/src/ui/components/overlay_hosts.dart';
import 'package:hollow/src/ui/media/fullscreen_media_chrome.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Turns one kind of call into what the stage draws. Watched from whichever
/// widget builds the stage, so the fullscreen route and the pane share it.
abstract class CallStageSource {
  const CallStageSource();

  /// Null once the call is gone.
  CallStageData? watchData(BuildContext context, WidgetRef ref);

  CallBarModel? watchBar(
    BuildContext context,
    WidgetRef ref,
    CallStageData data, {
    required bool fullscreen,
    required VoidCallback onFullscreen,
  });
}

/// The people strip above a focused source is collapsed. Session-sticky.
final callStripCollapsedProvider = StateProvider<bool>((_) => false);

/// The Layout control's offer for [data]: back to everyone while something is
/// centred, else the screen when there is one to centre on.
CallLayoutAction? stageLayoutAction(CallStageData data) {
  if (data.layoutFocus != null) return CallLayoutAction.showEveryone;
  if (data.focus != null || data.liveShares.isNotEmpty) {
    return CallLayoutAction.focusScreen;
  }
  return null;
}

void applyStageLayout(CallStageData data, CallLayoutAction action) {
  switch (action) {
    case CallLayoutAction.showEveryone:
      data.onGrid(true);
    case CallLayoutAction.focusScreen:
      if (data.focus != null) {
        data.onGrid(false);
      } else if (data.liveShares.isNotEmpty) {
        data.onFocus(data.liveShares.first.source);
      }
    case CallLayoutAction.backToChat:
      break;
  }
}

/// The call stage (D1): everyone as tiles, or one focused source with the
/// people strip ON TOP of it, and the bar floating at the bottom. Focus moves
/// only on a click (D7).
class CallStage extends ConsumerStatefulWidget {
  final CallStageSource source;

  /// Drawn inside [CallFullscreenRoute]: the focused source fills the window,
  /// the strip and bar float over it and fade when idle.
  final bool fullscreen;

  const CallStage({
    super.key,
    required this.source,
    this.fullscreen = false,
  });

  @override
  ConsumerState<CallStage> createState() => _CallStageState();
}

class _CallStageState extends ConsumerState<CallStage> {
  bool _chromeVisible = true;
  Timer? _hideTimer;
  int _pinned = 0;
  bool _closing = false;

  bool get _reduced => ReduceMotionController.instance.isReduced;

  @override
  void initState() {
    super.initState();
    if (widget.fullscreen) {
      HardwareKeyboard.instance.addHandler(_onKey);
      _scheduleHide();
    }
  }

  @override
  void dispose() {
    if (widget.fullscreen) HardwareKeyboard.instance.removeHandler(_onKey);
    _hideTimer?.cancel();
    super.dispose();
  }

  // --- fullscreen chrome ------------------------------------------------------

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!widget.fullscreen || _reduced || _pinned > 0) return;
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && _pinned == 0) setState(() => _chromeVisible = false);
    });
  }

  void _showChrome() {
    if (!widget.fullscreen) return;
    if (!_chromeVisible) setState(() => _chromeVisible = true);
    _scheduleHide();
  }

  void _pin(bool on) {
    _pinned = (_pinned + (on ? 1 : -1)).clamp(0, 99);
    if (on) {
      _hideTimer?.cancel();
      if (!_chromeVisible) setState(() => _chromeVisible = true);
    } else {
      _scheduleHide();
    }
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return false;
    if (ref.read(keybindCaptureActiveProvider)) return false;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return true;
    }
    _showChrome();
    return false;
  }

  void _close() {
    if (_closing || !mounted) return;
    _closing = true;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  void _toggleFullscreen() {
    if (widget.fullscreen) {
      _close();
    } else {
      openCallFullscreen(context, widget.source);
    }
  }

  // --- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final hollow = HollowTheme.of(context);
    final data = widget.source.watchData(context, ref);
    if (data == null) {
      if (widget.fullscreen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _close());
      }
      return const SizedBox.shrink();
    }
    final bar = widget.source.watchBar(
      context,
      ref,
      data,
      fullscreen: widget.fullscreen,
      onFullscreen: _toggleFullscreen,
    );
    return widget.fullscreen
        ? _fullscreenStage(hollow, data, bar)
        : _paneStage(hollow, data, bar);
  }

  Widget _paneStage(HollowTheme hollow, CallStageData data, CallBarModel? bar) {
    final focus = data.layoutFocus;
    return ColoredBox(
      color: hollow.background,
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                HollowSpacing.lg,
                HollowSpacing.lg,
                HollowSpacing.lg,
                bar == null ? HollowSpacing.lg : CallMetrics.barReserve,
              ),
              child: focus == null
                  ? StageGrid(tiles: _gridTiles(data))
                  : _focusLayout(hollow, data, focus),
            ),
          ),
          if (bar != null)
            Positioned(
              left: HollowSpacing.lg,
              right: HollowSpacing.lg,
              bottom: HollowSpacing.lg,
              child: Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: CallStageBar(model: bar),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _fullscreenStage(
      HollowTheme hollow, CallStageData data, CallBarModel? bar) {
    final focus = data.layoutFocus;
    final visible = _chromeVisible || _reduced;
    Widget fade(Widget child) => MouseRegion(
          onEnter: (_) => _pin(true),
          onExit: (_) => _pin(false),
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: _pin,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: visible ? HollowDurations.fast : HollowDurations.normal,
              child: IgnorePointer(ignoring: !visible, child: child),
            ),
          ),
        );

    final Widget main;
    if (focus == null) {
      main = Padding(
        padding: const EdgeInsets.all(HollowSpacing.xl),
        child: StageGrid(tiles: _gridTiles(data)),
      );
    } else {
      main = _focusedTile(data, focus, fullscreen: true, chrome: visible);
    }

    final strip = focus == null ? null : _stripTiles(data, focus);
    return ColoredBox(
      color: HollowColors.mediaBlack,
      child: MouseRegion(
        onHover: (_) => _showChrome(),
        child: Stack(
            children: [
              // Raw pointer downs, not a double-tap recognizer: one in the
              // arena would hold every single click on the bar for 300 ms.
              Positioned.fill(
                child: DoubleClickListener(onDoubleClick: _close, child: main),
              ),
              if (strip != null && strip.isNotEmpty)
                Positioned(
                  left: HollowSpacing.xl,
                  right: HollowSpacing.xl,
                  top: HollowSpacing.lg,
                  child: fade(SizedBox(
                    height: CallMetrics.stripTileHeight +
                        CallMetrics.ringOutset * 2,
                    child: EdgeScrollRow(
                      center: true,
                      semanticLabel: 'people',
                      fadeColor: HollowColors.mediaBlack,
                      padding: const EdgeInsets.all(CallMetrics.ringOutset),
                      children: _spaced(strip),
                    ),
                  )),
                ),
              if (bar != null)
                Positioned(
                  left: HollowSpacing.xl,
                  right: HollowSpacing.xl,
                  bottom: HollowSpacing.lg,
                  child: fade(Center(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: CallStageBar(model: bar),
                    ),
                  )),
                ),
            ],
          ),
      ),
    );
  }

  // --- layouts ------------------------------------------------------------------

  /// Offers first, then live shares, then people, you first.
  List<Widget> _gridTiles(CallStageData data) => [
        for (final s in data.shares)
          if (s.isOffer) _shareTile(data, s, CallTileSize.large),
        for (final s in data.shares)
          if (!s.isOffer) _shareTile(data, s, CallTileSize.large),
        for (final p in data.people) _personTile(data, p, CallTileSize.large),
      ];

  Widget _shareTile(CallStageData data, CallShare share, CallTileSize size,
      {VoidCallback? onTap, bool chrome = true}) {
    return ShareTile(
      key: ValueKey('share:${share.owner}'),
      share: share,
      size: size,
      chromeVisible: chrome,
      onTap: onTap ?? () => data.onFocus(share.source),
      onWatch: () => data.onWatch(share.owner),
      onStopWatching: () => data.onStopWatching(share.owner),
      onStopSharing: data.onStopSharing,
    );
  }

  Widget _personTile(CallStageData data, CallPerson person, CallTileSize size) {
    return CallPersonTile(
      key: ValueKey('person:${person.id}'),
      person: person,
      size: size,
      onTap: person.cameraOn ? () => data.onFocus(person.cameraSource) : null,
    );
  }

  /// The strip: the shares not focused, then everyone but a focused camera's
  /// owner.
  List<Widget> _stripTiles(CallStageData data, CallSourceId focus) {
    Widget sized(Widget child) => SizedBox(
          width: CallMetrics.stripTileWidth,
          height: CallMetrics.stripTileHeight,
          child: child,
        );
    return [
      for (final s in data.shares)
        if (s.source != focus) sized(_shareTile(data, s, CallTileSize.strip)),
      for (final p in data.people)
        if (!(focus.kind == CallSourceKind.camera && focus.owner == p.id))
          sized(_personTile(data, p, CallTileSize.strip)),
    ];
  }

  List<Widget> _spaced(List<Widget> tiles) => [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: HollowSpacing.sm),
          tiles[i],
        ],
      ];

  Widget _focusedTile(CallStageData data, CallSourceId focus,
      {required bool fullscreen, bool chrome = true}) {
    final share = data.shareFor(focus);
    if (share != null) {
      return _shareTile(
        data,
        share,
        CallTileSize.large,
        chrome: chrome,
        onTap: fullscreen ? _showChrome : _toggleFullscreen,
      );
    }
    final person = data.cameraFor(focus);
    if (person == null) return const SizedBox.shrink();
    return CallPersonTile(
      key: ValueKey('focus:${person.id}'),
      person: person,
      size: CallTileSize.large,
      onTap: fullscreen ? _showChrome : null,
      onDoubleTap: fullscreen ? null : _toggleFullscreen,
    );
  }

  Widget _focusLayout(
      HollowTheme hollow, CallStageData data, CallSourceId focus) {
    final collapsed = ref.watch(callStripCollapsedProvider);
    final strip = _stripTiles(data, focus);
    return Column(
      children: [
        if (strip.isNotEmpty && !collapsed)
          SizedBox(
            height: CallMetrics.stripTileHeight + CallMetrics.ringOutset * 2,
            child: Row(
              children: [
                Expanded(
                  child: EdgeScrollRow(
                    center: true,
                    semanticLabel: 'people',
                    fadeColor: hollow.background,
                    padding: const EdgeInsets.all(CallMetrics.ringOutset),
                    children: _spaced(strip),
                  ),
                ),
                const SizedBox(width: HollowSpacing.xs),
                HollowIconButton(
                  icon: LucideIcons.chevronUp,
                  label: 'Hide the people',
                  onPressed: () => ref
                      .read(callStripCollapsedProvider.notifier)
                      .state = true,
                ),
              ],
            ),
          )
        else if (strip.isNotEmpty)
          // The toggle keeps the right end in both states, so it is never
          // hunted for.
          Row(
            children: [
              Expanded(child: _SpeakingLine(people: data.people)),
              const SizedBox(width: HollowSpacing.xs),
              HollowIconButton(
                icon: LucideIcons.chevronDown,
                label: 'Show the people',
                onPressed: () => ref
                    .read(callStripCollapsedProvider.notifier)
                    .state = false,
              ),
            ],
          ),
        if (strip.isNotEmpty) const SizedBox(height: HollowSpacing.md),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            var w = box.maxWidth;
            var h = w * 9 / 16;
            if (h > box.maxHeight) {
              h = box.maxHeight;
              w = h * 16 / 9;
            }
            return Center(
              child: SizedBox(
                width: w,
                height: h,
                child: _focusedTile(data, focus, fullscreen: false),
              ),
            );
          }),
        ),
      ],
    );
  }
}

/// Everyone as 16:9 tiles, as large as fit, the group centred; past four rows
/// it scrolls. [footer] sits under the group (Join voice on a room you are not
/// in).
class StageGrid extends StatelessWidget {
  final List<Widget> tiles;
  final Widget? footer;

  const StageGrid({super.key, required this.tiles, this.footer});

  static const double gap = HollowSpacing.lg;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final n = tiles.length;
      if (n == 0) return Center(child: footer ?? const SizedBox.shrink());
      final cols = stageGridColumns(n);
      final rows = (n / cols).ceil();
      final footerRoom =
          footer == null ? 0.0 : HollowSpacing.xl + HollowSpacing.xxl;
      final width = box.maxWidth - CallMetrics.ringOutset * 2;
      final height = box.maxHeight - CallMetrics.ringOutset * 2 - footerRoom;
      var tileW = (width - gap * (cols - 1)) / cols;
      var tileH = tileW * 9 / 16;
      final scrolls = rows > 4;
      if (!scrolls) {
        final maxH = (height - gap * (rows - 1)) / rows;
        if (tileH > maxH) {
          tileH = maxH;
          tileW = tileH * 16 / 9;
        }
      }
      if (tileW <= 0 || tileH <= 0) return const SizedBox.shrink();

      final rowWidgets = <Widget>[];
      for (var r = 0; r < rows; r++) {
        final start = r * cols;
        final end = (start + cols).clamp(0, n);
        if (r > 0) rowWidgets.add(const SizedBox(height: gap));
        rowWidgets.add(Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = start; i < end; i++) ...[
              if (i > start) const SizedBox(width: gap),
              SizedBox(width: tileW, height: tileH, child: tiles[i]),
            ],
          ],
        ));
      }
      if (footer != null) {
        rowWidgets
          ..add(const SizedBox(height: HollowSpacing.xl))
          ..add(footer!);
      }
      final group = Padding(
        padding: const EdgeInsets.all(CallMetrics.ringOutset),
        child: Column(mainAxisSize: MainAxisSize.min, children: rowWidgets),
      );
      if (!scrolls) return Center(child: group);
      return SingleChildScrollView(child: Center(child: group));
    });
  }
}

/// With the strip collapsed, who is talking still shows: "Mira is speaking".
class _SpeakingLine extends ConsumerWidget {
  final List<CallPerson> people;
  const _SpeakingLine({required this.people});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hollow = HollowTheme.of(context);
    final talking = [
      for (final p in people)
        if (ref.watch(p.speaking) && !p.muted) p
    ];
    if (talking.isEmpty) return const SizedBox.shrink();
    final first = talking.first;
    final verb = talking.length > 1
        ? ' and others are speaking'
        : (first.isSelf ? ' are speaking' : ' is speaking');
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: first.name,
          style: TextStyle(
              color: callNameColor(hollow,
                  isSelf: first.isSelf, master: first.master)),
        ),
        TextSpan(text: verb),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: HollowTypography.label.copyWith(color: hollow.textSecondary),
    );
  }
}

/// Opens [source]'s stage fullscreen (D11): the window goes fullscreen through
/// [fullscreenProvider] and comes back exactly as it was found.
Future<void> openCallFullscreen(BuildContext context, CallStageSource source) {
  final reduce = ReduceMotionController.instance.isReduced;
  const fade = Duration(milliseconds: 150);
  return Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: true,
    fullscreenDialog: true,
    transitionDuration: reduce ? Duration.zero : fade,
    reverseTransitionDuration: reduce ? Duration.zero : fade,
    pageBuilder: (_, _, _) => CallFullscreenRoute(source: source),
    transitionsBuilder: (_, anim, _, child) =>
        reduce ? child : FadeTransition(opacity: anim, child: child),
  ));
}

/// The fullscreen stage's route: holds the window fullscreen while it is up.
class CallFullscreenRoute extends ConsumerStatefulWidget {
  final CallStageSource source;
  const CallFullscreenRoute({super.key, required this.source});

  @override
  ConsumerState<CallFullscreenRoute> createState() =>
      _CallFullscreenRouteState();
}

class _CallFullscreenRouteState extends ConsumerState<CallFullscreenRoute>
    with FullscreenMediaChrome<CallFullscreenRoute> {
  @override
  void initState() {
    super.initState();
    beginFullscreenMedia(null);
    unawaited(enterWindowFullscreen());
    OverlayHosts.register(this, _dismiss);
  }

  @override
  void dispose() {
    OverlayHosts.unregister(this);
    endFullscreenMedia();
    super.dispose();
  }

  void _dismiss() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Leaving the window's fullscreen some other way (the OS, F11) leaves
    // this surface too, so nothing is left filling a boxed window.
    ref.listen<bool>(fullscreenProvider, (prev, next) {
      if (prev == true && !next && enteredFullscreen) _dismiss();
    });
    return CallStage(source: widget.source, fullscreen: true);
  }
}
